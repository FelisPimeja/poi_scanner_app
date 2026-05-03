import SwiftUI
import PhotosUI
import AVFoundation
import CoreLocation

// MARK: - AddPhotoFlow
// Компонент для добавления фото к уже открытому редактору POI.
// Запускает OCR + веб-обогащение и применяет результаты в POIEditViewModel.
//
// Использование: как .sheet() или .fullScreenCover() из тулбара POIEditorView.

struct AddPhotoFlow: View {
    /// POI к которому добавляются данные (для передачи в ExtractionViewModel).
    let existingPOI: POI
    /// ViewModel редактора — сюда применяем результаты.
    let editVM: POIEditViewModel
    /// Колбэк для обновления poi.tags в родительском View (для syncMergedTags и т.д.)
    var onTagsExtracted: (([String: String], [String: Double]) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var selectedItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var cameraPermissionDenied = false
    @State private var isProcessing = false
    @State private var statusText = ""
    @State private var errorMessage: String?

    private let vision = VisionService()
    private let enricher = WebEnricher()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "camera.badge.plus")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)

                Text("Добавить фото")
                    .font(.title2.weight(.semibold))

                Text("Приложение дополнит карточку POI данными с фото или QR-кода")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                if isProcessing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    VStack(spacing: 12) {
                        // Камера
                        Button {
                            requestCameraAndOpen()
                        } label: {
                            Label("Снять фото", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.accentColor)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        // Галерея
                        PhotosPicker(selection: $selectedItem,
                                     matching: .images,
                                     photoLibrary: .shared()) {
                            Label("Выбрать из галереи", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color(.secondarySystemFill))
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal, 24)
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                }

                Spacer()
            }
            .navigationTitle("Добавить данные с фото")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
            .alert("Нет доступа к камере", isPresented: $cameraPermissionDenied) {
                Button("Открыть Настройки") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Разрешите доступ к камере в Настройках → Конфиденциальность")
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPickerView(
                    onCapture: { image, coord, acc, date in
                        showCamera = false
                        Task { await process(image: image) }
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
            .onChange(of: selectedItem) { _, item in
                guard let item else { return }
                Task { await loadPickerItem(item) }
            }
        }
    }

    // MARK: - Camera permission

    private func requestCameraAndOpen() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { DispatchQueue.main.async { showCamera = true } }
            }
        default:
            cameraPermissionDenied = true
        }
    }

    // MARK: - Gallery picker

    private func loadPickerItem(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        await process(image: image)
    }

    // MARK: - OCR + Enrichment pipeline

    @MainActor
    private func process(image: UIImage) async {
        isProcessing = true
        errorMessage = nil

        do {
            statusText = "Распознаём текст и QR-коды…"
            let ocrText   = try await vision.recognizeFullText(in: image)
            let qrPayloads = (try? await vision.detectQRCodes(in: image)) ?? []

            statusText = "Анализируем данные…"
            var parseResult = TextParser.parse(ocrText)

            let qrResult = QRContentParser.parse(qrPayloads)
            if !qrResult.rawText.isEmpty {
                let qrTextResult = TextParser.parse(qrResult.rawText)
                let scaledConf = qrTextResult.confidence.mapValues { $0 * 0.9 }
                parseResult.merge(tags: qrTextResult.tags, confidence: scaledConf)
            }
            parseResult.merge(tags: qrResult.tags, confidence: qrResult.confidence)

            // Применяем OCR-теги в VM (source = .ocr)
            editVM.applyOCR(tags: parseResult.tags, confidence: parseResult.confidence)

            // Уведомляем редактор об извлечённых тегах (для syncMergedTags и undo-стека)
            onTagsExtracted?(parseResult.tags, parseResult.confidence)

            // Веб-обогащение — в фоне, не блокируем закрытие
            statusText = "Загружаем данные из ссылок…"
            let results = await enricher.enrich(
                poiTags: existingPOI.tags,
                parsedTags: parseResult.tags
            )
            editVM.applyWebResults(results)

            isProcessing = false
            dismiss()

        } catch {
            isProcessing = false
            errorMessage = error.localizedDescription
        }
    }
}
