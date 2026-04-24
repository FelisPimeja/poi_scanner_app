import Vision
import UIKit
import CoreML

// MARK: - VisionService
// Обёртка над Vision framework для OCR текста с изображений

actor VisionService {

    // MARK: - Public API

    /// Распознаёт весь текст на изображении.
    /// Возвращает массив строк в порядке сверху вниз.
    func recognizeText(in image: UIImage, languages: [String] = ["ru", "en"]) async throws -> [RecognizedLine] {
        guard let cgImage = normalizedCGImage(from: image) else {
            throw VisionError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let lines = observations.compactMap { observation -> RecognizedLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedLine(
                        text: candidate.string,
                        confidence: Double(candidate.confidence),
                        boundingBox: observation.boundingBox
                    )
                }
                continuation.resume(returning: lines)
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.01  // Игнорируем мелкий нечитаемый текст

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Удобный метод — возвращает просто строки без метаданных
    func recognizeTextStrings(in image: UIImage, languages: [String] = ["ru", "en"]) async throws -> [String] {
        let lines = try await recognizeText(in: image, languages: languages)
        return lines.map(\.text)
    }

    /// Полный текст одной строкой (для передачи в TextParser)
    func recognizeFullText(in image: UIImage, languages: [String] = ["ru", "en"]) async throws -> String {
        let lines = try await recognizeText(in: image, languages: languages)
        return lines.map(\.text).joined(separator: "\n")
    }

    // MARK: - QR-коды

    /// Детектирует QR-коды на изображении.
    /// Возвращает список декодированных строк (обычно URL).
    func detectQRCodes(in image: UIImage) async throws -> [String] {
        guard let cgImage = normalizedCGImage(from: image) else {
            throw VisionError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false

            let request = VNDetectBarcodesRequest { request, error in
                guard !resumed else { return }
                resumed = true
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let payloads = (request.results as? [VNBarcodeObservation] ?? [])
                    .filter { $0.symbology == .qr }
                    .compactMap(\.payloadStringValue)
                    .filter { !$0.isEmpty }
                continuation.resume(returning: payloads)
            }
            request.symbologies = [.qr]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                // Если колбек не вызвался (напр., нет баркодов) — resume здесь не нужен:
                // Vision всегда вызывает completion handler, даже при пустом результате.
            } catch {
                guard !resumed else { return }
                resumed = true
                continuation.resume(throwing: error)
            }
        }
    }
    // MARK: - Private

    /// Возвращает CGImage из UIImage.
    /// Для HEIC/CIImage-backed изображений, у которых .cgImage == nil,
    /// перерисовывает через UIGraphicsImageRenderer чтобы получить пиксельные данные.
    private func normalizedCGImage(from image: UIImage) -> CGImage? {
        if let cg = image.cgImage { return cg }
        // Fallback: принудительный рендер в растр
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(at: .zero) }.cgImage
    }
}

// MARK: - RecognizedLine

struct RecognizedLine: Sendable {
    let text: String
    let confidence: Double          // 0.0 – 1.0
    let boundingBox: CGRect         // Нормализованные координаты (0–1)
}

// MARK: - VisionError

enum VisionError: LocalizedError {
    case invalidImage
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Не удалось получить CGImage из UIImage"
        case .recognitionFailed(let reason):
            return "OCR завершился с ошибкой: \(reason)"
        }
    }
}
