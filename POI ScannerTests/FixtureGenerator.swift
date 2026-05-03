import XCTest
@testable import POI_Scanner

// MARK: - FixtureGenerator
// Запускай этот тест ОДИН РАЗ для генерации черновых эталонных JSON.
// После запуска: найди JSON в консоли (или в /tmp/poi_fixtures/),
// скопируй в Fixtures/Expected/, отредактируй вручную.
//
// Запуск только этого теста:
// xcodebuild test ... -only-testing "POI ScannerTests/FixtureGenerator"

final class FixtureGenerator: XCTestCase {

    let vision = VisionService()

    func testGenerateFixturesFromPhotos() async throws {
        // Папка с фото
        let photosURL = FixtureLoader.photosURL
        // Черновики — рядом с исходниками проекта, в .gitignore
        let outputURL = FixtureLoader.fixturesSourceURL.appendingPathComponent("Drafts")

        // Создаём папку для вывода
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        // Получаем список фото
        let photoFiles = (try? FileManager.default.contentsOfDirectory(
            at: photosURL,
            includingPropertiesForKeys: nil
        )) ?? []

        let imageFiles = photoFiles.filter {
            ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !imageFiles.isEmpty else {
            XCTFail("Фото не найдены в: \(photosURL.path)\nПроверьте путь к папке Fixtures/Photos/")
            return
        }

        print("\n📸 Найдено фото: \(imageFiles.count)")
        print("📁 Результаты будут сохранены в: \(outputURL.path)\n")
        print(String(repeating: "─", count: 60))

        var results: [(id: String, draft: FixtureDraft)] = []

        for photoURL in imageFiles {
            let id = photoURL.deletingPathExtension().lastPathComponent

            // Пропускаем фото, для которых черновик уже существует
            let existingDraft = outputURL.appendingPathComponent("\(id).json")
            if FileManager.default.fileExists(atPath: existingDraft.path) {
                print("⏭️  Пропускаю (драфт есть): \(photoURL.lastPathComponent)")
                continue
            }

            print("\n🔍 Обрабатываю: \(photoURL.lastPathComponent)")

            guard let image = UIImage(contentsOfFile: photoURL.path) else {
                print("  ⚠️  Не удалось загрузить изображение")
                continue
            }

            // OCR и QR-детекция параллельно
            let lines: [RecognizedLine]
            let qrPayloads: [String]
            do {
                async let ocrTask = vision.recognizeText(in: image)
                async let qrTask  = vision.detectQRCodes(in: image)
                let ocrLines = try await ocrTask
                let qrResult = (try? await qrTask) ?? []   // QR недоступен на симуляторе — не fatal
                lines = ocrLines
                qrPayloads = qrResult
            } catch {
                print("  ❌ Ошибка OCR: \(error.localizedDescription)")
                continue
            }

            let fullText = lines.map(\.text).joined(separator: "\n")

            // Парсинг OCR
            var parseResult = TextParser.parse(fullText)

            // Парсинг QR
            let qrResult = QRContentParser.parse(qrPayloads)
            if !qrResult.rawText.isEmpty {
                let qrTextResult = TextParser.parse(qrResult.rawText)
                let scaledConf = qrTextResult.confidence.mapValues { $0 * 0.9 }
                parseResult.merge(tags: qrTextResult.tags, confidence: scaledConf)
            }
            parseResult.merge(tags: qrResult.tags, confidence: qrResult.confidence)

            // Печатаем распознанный текст
            print("\n  📝 Распознанный текст:")
            for line in lines {
                print("     [\(String(format: "%.0f%%", line.confidence * 100))] \(line.text)")
            }

            // Печатаем извлечённые теги
            print("\n  🏷  Извлечённые теги:")
            if parseResult.isEmpty {
                print("     (ничего не извлечено)")
            } else {
                for (key, value) in parseResult.tags.sorted(by: { $0.key < $1.key }) {
                    let conf = parseResult.confidence[key].map { String(format: "%.0f%%", $0 * 100) } ?? "?"
                    print("     \(key): \"\(value)\"  (confidence: \(conf))")
                }
            }

            // Создаём черновой JSON
            let draft = FixtureDraft(
                id: id,
                description: "TODO: описание фото",
                recognizedText: lines.map(\.text),
                qrPayloads: qrPayloads,
                extractedTags: parseResult.tags,
                extractedConfidence: parseResult.confidence.mapValues { Double($0) }
            )

            results.append((id: id, draft: draft))

            // Сохраняем черновой JSON
            let jsonURL = outputURL.appendingPathComponent("\(id).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(draft)
            try data.write(to: jsonURL)
            print("\n  ✅ Сохранено: \(jsonURL.path)")
        }

        print("\n" + String(repeating: "─", count: 60))
        print("✅ Готово. Обработано фото: \(results.count)/\(imageFiles.count)")
        print("""

Следующие шаги:
1. Открой папку: open "\(outputURL.path)"
2. Для каждого JSON:
   - Исправь поле "description"
   - Проверь "extractedTags" — оставь только правильные значения
   - Переименуй "extractedTags" → "expectedTags"
   - Добавь "minimumConfidence" для ключевых полей
   - Добавь "optionalTags" для необязательных
3. Готовые файлы перемести в Fixtures/Expected/ (они попадут в git)
   Черновики в Fixtures/Drafts/ — в .gitignore, не версионируются.

Пример финального JSON см. в Fixtures/Expected/example_cafe_01.json
""")
    }
}

// MARK: - FixtureDraft
// Черновая структура — отличается от финального TestFixture наличием recognizedText

struct FixtureDraft: Codable {
    let id: String
    var description: String
    let recognizedText: [String]        // Весь распознанный текст — для ручной проверки
    let qrPayloads: [String]            // Данные QR-кодов, найденных на фото
    var extractedTags: [String: String] // Переименуй в expectedTags после проверки
    let extractedConfidence: [String: Double]
}
