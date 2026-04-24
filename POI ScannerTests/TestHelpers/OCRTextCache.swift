import Foundation

// MARK: - OCRTextCache
//
// Кэш результатов OCR: словарь fixtureId → распознанный текст.
// Хранится в Fixtures/ocr_cache.json рядом с остальными фикстурами.
// Позволяет гонять парсер без повторного запуска Vision (экономит ~5 мин на 429 фикстурах).
//
// Использование:
//   1. Один раз: запусти testBuildOCRCache — создаст/обновит кэш.
//   2. Всегда: testExtractionQualityReportFast грузит кэш и тестирует только парсер.

struct OCRTextCache: Codable {
    /// fixtureId → OCR-текст
    var texts: [String: String]
    /// Дата создания кэша
    var builtAt: Date

    init(texts: [String: String] = [:]) {
        self.texts = texts
        self.builtAt = Date()
    }
}

// MARK: - Persistence

enum OCRTextCacheStorage {

    static var cacheURL: URL {
        FixtureLoader.fixturesSourceURL.appendingPathComponent("ocr_cache.json")
    }

    static func load() throws -> OCRTextCache {
        let data = try Data(contentsOf: cacheURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OCRTextCache.self, from: data)
    }

    static func save(_ cache: OCRTextCache) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cache)
        try data.write(to: cacheURL, options: .atomic)
    }

    static func exists() -> Bool {
        FileManager.default.fileExists(atPath: cacheURL.path)
    }
}
