import XCTest
@testable import POI_Scanner

// MARK: - ExtractionPipelineTests
// E2E тесты: реальное фото → OCR → парсинг → сравнение с эталонными тегами

final class ExtractionPipelineTests: XCTestCase {

    let vision = VisionService()

    // MARK: - E2E по каждой фикстуре

    func testAllFixturesExtraction() async throws {
        let fixtures = FixtureLoader.allFixtures()
        guard !fixtures.isEmpty else {
            throw XCTSkip("Нет доступных фикстур. Убедитесь что фото есть в Fixtures/Photos/")
        }

        for fixture in fixtures {
            let image = try FixtureLoader.photo(for: fixture)
            let text = try await vision.recognizeFullText(in: image)
            let result = TextParser.parse(text)

            ExtractionResultMatcher.validate(result: result, against: fixture)
        }
    }

    // MARK: - Quality Report (не падает, только печатает)

    /// Запускает все фикстуры и печатает сводный отчёт по качеству.
    /// Падает только если общий скор ниже порога.
    func testExtractionQualityReport() async throws {
        let fixtures = FixtureLoader.allFixtures()
        guard !fixtures.isEmpty else {
            throw XCTSkip("Нет доступных фикстур")
        }

        var qualityReport = QualityReport()

        for fixture in fixtures {
            guard let image = try? FixtureLoader.photo(for: fixture) else { continue }
            guard let text = try? await vision.recognizeFullText(in: image) else { continue }
            let result = TextParser.parse(text)

            // validate без XCTFail — собираем только статистику
            let report = validateSilently(result: result, against: fixture)
            qualityReport.fixtureReports.append(report)
        }

        qualityReport.printSummary()

        XCTAssertGreaterThan(
            qualityReport.overallScore, 0.5,
            "Общий скор ниже 50% — что-то сломалось в парсере"
        )
    }

    // MARK: - Fast Quality Report (только парсер, без OCR)

    /// Быстрая версия testExtractionQualityReport: использует кэш OCR-текстов.
    /// Не делает никаких вызовов Vision — запускается за секунды.
    ///
    /// Предварительно запусти testBuildOCRCache (один раз).
    func testExtractionQualityReportFast() async throws {
        let cache: OCRTextCache
        do {
            cache = try OCRTextCacheStorage.load()
        } catch {
            throw XCTSkip("OCR-кэш не найден. Сначала запусти VisionServiceTests/testBuildOCRCache.")
        }

        let fixtures = FixtureLoader.allFixtures()
        guard !fixtures.isEmpty else { throw XCTSkip("Нет доступных фикстур") }

        // Предупреждение если кэш неполный
        let uncached = fixtures.filter { cache.texts[$0.id] == nil }
        if !uncached.isEmpty {
            print("⚠️  Нет в кэше \(uncached.count) фикстур: \(uncached.prefix(5).map(\.id).joined(separator: ", "))...")
        }

        let cacheAge = Date().timeIntervalSince(cache.builtAt)
        let ageHours = Int(cacheAge / 3600)
        print("📦 Кэш от \(cache.builtAt) (\(ageHours)ч назад), \(cache.texts.count) записей")

        var qualityReport = QualityReport()

        for fixture in fixtures {
            guard let text = cache.texts[fixture.id] else { continue }
            let result = TextParser.parse(text)
            let report = validateSilently(result: result, against: fixture)
            qualityReport.fixtureReports.append(report)
        }

        qualityReport.printSummary()

        // Если задана переменная окружения DETAIL_TAG — печатаем детали по конкретному тегу
        // Пример: запустить тест с переменной DETAIL_TAG=ref:INN
        if let detailTag = ProcessInfo.processInfo.environment["DETAIL_TAG"] {
            qualityReport.printFailures(for: detailTag)
        }

        // Порог 49% (не 50%) — кэш может давать чуть иные результаты чем реальный OCR (~0.5% разброс)
        XCTAssertGreaterThan(
            qualityReport.overallScore, 0.49,
            "Общий скор ниже 49% — что-то сломалось в парсере (кэш может отличаться от реального OCR на ~0.5%)"
        )
    }

    // MARK: - Tag Diagnostics

    /// Детальный разбор провалов по конкретному тегу.
    /// Меняй tagToDiagnose и запускай этот тест.
    func testDiagnoseTag() throws {
        let tagToDiagnose = "addr:street"   // ← меняй здесь

        let cache = try {
            guard OCRTextCacheStorage.exists() else {
                throw XCTSkip("OCR-кэш не найден. Сначала запусти VisionServiceTests/testBuildOCRCache.")
            }
            return try OCRTextCacheStorage.load()
        }()

        let fixtures = FixtureLoader.allFixtures()
        var qualityReport = QualityReport()

        for fixture in fixtures {
            guard let text = cache.texts[fixture.id] else { continue }
            let result = TextParser.parse(text)
            let report = validateSilently(result: result, against: fixture)
            qualityReport.fixtureReports.append(report)
        }

        qualityReport.printFailures(for: tagToDiagnose)
    }

    // MARK: - Helpers

    /// Валидация без XCTFail — только сбор статистики
    private func validateSilently(result: ParseResult, against fixture: TestFixture) -> FieldReport {
        var report = FieldReport(fixtureId: fixture.id)
        for (tag, expectedValue) in fixture.expectedTags {
            let actual = result.tags[tag]
            let confidence = result.confidence[tag] ?? 0.0
            let minConfidence = fixture.minimumConfidence[tag] ?? 0.6

            if let actual, actual.lowercased() == expectedValue.lowercased(), confidence >= minConfidence {
                report.fields[tag] = .success(actual, confidence)
            } else if let actual, actual.lowercased() != expectedValue.lowercased() {
                report.fields[tag] = .wrongValue(expected: expectedValue, actual: actual)
            } else if let actual {
                report.fields[tag] = .lowConfidence(value: actual, confidence: confidence, minimum: minConfidence)
            } else {
                report.fields[tag] = .missing(expectedValue)
            }
        }
        return report
    }
}
