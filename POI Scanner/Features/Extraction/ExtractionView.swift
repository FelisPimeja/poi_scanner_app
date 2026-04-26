import SwiftUI
import Combine
import CoreLocation

// MARK: - ExtractionView
// Запускает OCR на фото, показывает прогресс, передаёт результат в ValidationView

struct ExtractionView: View {
    let image: UIImage
    let coordinate: CLLocationCoordinate2D
    let coordinateFromPhoto: Bool           // true = EXIF GPS из фото, false = центр карты
    let existingNode: OSMNode?              // nil = новый POI
    var onSave: ((POI) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ExtractionViewModel

    init(image: UIImage, coordinate: CLLocationCoordinate2D, coordinateFromPhoto: Bool = false, existingNode: OSMNode? = nil, onSave: ((POI) -> Void)? = nil) {
        self.image = image
        self.coordinate = coordinate
        self.coordinateFromPhoto = coordinateFromPhoto
        self.existingNode = existingNode
        self.onSave = onSave
        _viewModel = StateObject(wrappedValue: ExtractionViewModel())
    }

    var body: some View {
        Group {
            if let poi = viewModel.extractedPOI {
                ValidationView(poi: poi, sourceImage: image, onSave: onSave)
            } else {
                extractionProgress
            }
        }
        .task {
            await viewModel.extract(from: image, coordinate: coordinate,
                                    existingNode: existingNode,
                                    coordinateFromPhoto: coordinateFromPhoto)
        }
    }

    // MARK: - Прогресс экран

    private var extractionProgress: some View {
        VStack(spacing: 24) {
            Spacer()

            // Превью фото
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)

            // Бейдж с источником координат (только для нового POI)
            if existingNode == nil {
                coordinateBadge
            }

            if let error = viewModel.errorMessage {
                // Ошибка
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text("Не удалось распознать текст")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Заполнить вручную") {
                        viewModel.skipToManual(coordinate: coordinate, existingNode: existingNode)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                // Загрузка
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text(viewModel.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .navigationTitle("Распознавание")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { dismiss() }
            }
        }
    }

    // MARK: - Бейдж координат

    private var coordinateBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: coordinateFromPhoto ? "camera.fill" : "map")
                .font(.caption.weight(.semibold))
                .foregroundStyle(coordinateFromPhoto ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(coordinateFromPhoto ? "Координаты из фото (EXIF GPS)" : "Координаты: центр карты")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(coordinateFromPhoto ? .green : .secondary)
                Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            coordinateFromPhoto
                ? Color.green.opacity(0.12)
                : Color(.systemFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(coordinateFromPhoto ? Color.green.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - ExtractionViewModel

@MainActor
final class ExtractionViewModel: ObservableObject {
    @Published var extractedPOI: POI?
    @Published var statusText = "Распознаём текст…"
    @Published var errorMessage: String?

    private let vision = VisionService()

    func extract(from image: UIImage, coordinate: CLLocationCoordinate2D,
                 existingNode: OSMNode?, coordinateFromPhoto: Bool = false) async {
        do {
            statusText = "Распознаём текст и QR-коды…"

            // OCR — обязательный шаг, ошибка здесь — фатальная
            let ocrText = try await vision.recognizeFullText(in: image)

            // QR — опциональный шаг, сбой не должен прерывать OCR
            let qrPayloads = (try? await vision.detectQRCodes(in: image)) ?? []

            statusText = "Анализируем данные…"

            // Парсинг OCR-текста
            var parseResult = TextParser.parse(ocrText)

            // Парсинг QR-содержимого
            let qrResult = QRContentParser.parse(qrPayloads)

            // Если QR содержит произвольный текст (не URL/соцсеть) — прогоняем через TextParser
            if !qrResult.rawText.isEmpty && !qrPayloads.isEmpty {
                let qrTextResult = TextParser.parse(qrResult.rawText)
                // Понижаем конфиденс QR-текстовых тегов на 10%
                let scaledConf = qrTextResult.confidence.mapValues { $0 * 0.9 }
                parseResult.merge(tags: qrTextResult.tags, confidence: scaledConf)
            }

            // Мёрджим структурированные теги из QR (сайт, соцсети, телефон из vCard и т.д.)
            parseResult.merge(tags: qrResult.tags, confidence: qrResult.confidence)

            var poi: POI
            if let node = existingNode {
                poi = node.toPOI()
                for (key, value) in parseResult.tags {
                    if poi.fieldStatus[key] != .confirmed {
                        poi.tags[key] = value
                        poi.fieldStatus[key] = parseResult.fieldStatus[key] ?? .extracted
                        poi.extractionConfidence[key] = parseResult.confidence[key]
                    }
                }
            } else {
                poi = POI(coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude))
                poi.coordinateSource = coordinateFromPhoto ? .photo : .mapCenter
                poi.tags = parseResult.tags
                poi.fieldStatus = parseResult.fieldStatus
                poi.extractionConfidence = parseResult.confidence
            }

            extractedPOI = poi

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func skipToManual(coordinate: CLLocationCoordinate2D, existingNode: OSMNode?) {
        if let node = existingNode {
            extractedPOI = node.toPOI()
        } else {
            extractedPOI = POI(coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
    }
}
