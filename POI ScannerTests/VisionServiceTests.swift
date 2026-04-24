import XCTest
@testable import POI_Scanner

// MARK: - VisionServiceTests
// Integration тесты OCR на реальных фото из Fixtures/Photos/

final class VisionServiceTests: XCTestCase {

    let vision = VisionService()

    // MARK: - Базовая проверка распознавания

    /// Проверяем что OCR вообще возвращает текст для каждого фото в Fixtures
    func testAllPhotosProduceText() async throws {
        let fixtures = FixtureLoader.allFixtures()
        guard !fixtures.isEmpty else {
            throw XCTSkip("Нет доступных фикстур. Убедитесь что фото есть в Fixtures/Photos/")
        }

        for fixture in fixtures {
            let image = try FixtureLoader.photo(for: fixture)
            let text = try await vision.recognizeFullText(in: image)
            XCTAssertFalse(
                text.isEmpty,
                "[\(fixture.id)] OCR не распознал ни одной строки"
            )
        }
    }

    /// Для каждой фикстуры: ключевые ожидаемые строки должны присутствовать в распознанном тексте
    func testKeyStringsAreRecognized() async throws {
        let fixtures = FixtureLoader.allFixtures()
        guard !fixtures.isEmpty else {
            throw XCTSkip("Нет доступных фикстур")
        }

        for fixture in fixtures {
            let image = try FixtureLoader.photo(for: fixture)
            let lines = try await vision.recognizeText(in: image)
            let fullText = lines.map(\.text).joined(separator: " ").lowercased()

            // Проверяем что название (name) хотя бы частично присутствует в тексте
            if let expectedName = fixture.expectedTags["name"] {
                let nameWords = expectedName.lowercased().split(separator: " ").map(String.init)
                let foundWords = nameWords.filter { fullText.contains($0) }
                let ratio = Double(foundWords.count) / Double(nameWords.count)

                XCTAssertGreaterThan(
                    ratio, 0.5,
                    "[\(fixture.id)] Название '\(expectedName)' слабо распознано: найдено \(foundWords)"
                )
            }
        }
    }

    // MARK: - OCR Cache Builder

    /// Прогоняет Vision по всем фото и сохраняет результаты в Fixtures/ocr_cache.json.
    /// Запускай один раз (или при добавлении новых фикстур).
    /// После этого используй testExtractionQualityReportFast для быстрой итерации парсера.
    func testBuildOCRCache() async throws {
        let fixtures = FixtureLoader.allFixtures()
        guard !fixtures.isEmpty else {
            throw XCTSkip("Нет доступных фикстур")
        }

        var existing: OCRTextCache
        if OCRTextCacheStorage.exists() {
            existing = (try? OCRTextCacheStorage.load()) ?? OCRTextCache()
            print("🔄 Обновляем существующий кэш (\(existing.texts.count) записей)...")
        } else {
            existing = OCRTextCache()
            print("🆕 Создаём новый кэш...")
        }

        var processed = 0
        for fixture in fixtures {
            guard let image = try? FixtureLoader.photo(for: fixture) else {
                print("⚠️  [\(fixture.id)] Фото не найдено, пропускаем")
                continue
            }
            let text = try await vision.recognizeFullText(in: image)
            existing.texts[fixture.id] = text
            processed += 1
            if processed % 50 == 0 {
                print("   ... обработано \(processed)/\(fixtures.count)")
            }
        }

        existing.builtAt = Date()
        try OCRTextCacheStorage.save(existing)
        print("✅ Кэш сохранён: \(processed) фикстур → \(OCRTextCacheStorage.cacheURL.path)")
    }

    // MARK: - Уверенность OCR

    func testConfidenceIsReasonable() async throws {
        let fixtures = FixtureLoader.allFixtures()
        guard !fixtures.isEmpty else { throw XCTSkip("Нет доступных фикстур") }

        for fixture in fixtures {
            let image = try FixtureLoader.photo(for: fixture)
            let lines = try await vision.recognizeText(in: image)
            let avgConfidence = lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Double(lines.count)

            XCTAssertGreaterThan(
                avgConfidence, 0.4,
                "[\(fixture.id)] Средний confidence OCR подозрительно низкий: \(String(format: "%.2f", avgConfidence))"
            )
        }
    }
}
