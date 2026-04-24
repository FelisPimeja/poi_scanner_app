import Foundation
import UIKit

// MARK: - TestFixture

struct TestFixture: Codable {
    let id: String                              // совпадает с именем файла без расширения
    let description: String
    let expectedTags: [String: String]
    let minimumConfidence: [String: Double]     // минимально допустимый confidence для поля
    let optionalTags: [String]                  // теги, которые хорошо если есть, но не обязательны

    enum CodingKeys: String, CodingKey {
        case id, description, expectedTags, minimumConfidence, optionalTags
    }
}

// MARK: - FixtureLoader

enum FixtureLoader {

    // MARK: - Пути

    /// Корень папки Fixtures в исходниках проекта (на диске Mac, не в бандле).
    /// Приоритет:
    /// 1. Переменная окружения POI_FIXTURES_PATH (устанавливается в scheme)
    /// 2. #file — работает когда тесты запускаются с той же машины где исходники
    static var fixturesSourceURL: URL {
        if let envPath = ProcessInfo.processInfo.environment["POI_FIXTURES_PATH"] {
            return URL(fileURLWithPath: envPath)
        }
        // #file — абсолютный путь к этому файлу на машине сборки
        return URL(fileURLWithPath: #file)  // .../TestHelpers/FixtureLoader.swift
            .deletingLastPathComponent()    // .../TestHelpers/
            .deletingLastPathComponent()    // .../POI ScannerTests/
            .appendingPathComponent("Fixtures")
    }

    /// Папка с фото (не в git, не в бандле — читаем напрямую с диска)
    static var photosURL: URL {
        fixturesSourceURL.appendingPathComponent("Photos")
    }

    /// Папка с эталонными JSON (в git, в бандле как резерв)
    static var expectedURL: URL {
        // Сначала пробуем путь в исходниках (быстро, всегда актуально)
        let sourceURL = fixturesSourceURL.appendingPathComponent("Expected")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        // Fallback: из бандла (на случай CI без исходников)
        let testBundle = Bundle(for: FixtureLoaderMarker.self)
        if let url = testBundle.url(forResource: "Expected", withExtension: nil, subdirectory: "Fixtures") {
            return url
        }
        return sourceURL
    }

    // MARK: - Загрузка

    /// Загрузить одну фикстуру по id
    static func fixture(_ id: String) throws -> TestFixture {
        let url = expectedURL.appendingPathComponent("\(id).json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TestFixture.self, from: data)
    }

    /// Загрузить фото фикстуры
    static func photo(for fixture: TestFixture) throws -> UIImage {
        return try photo(fixture.id)
    }

    static func photo(_ id: String) throws -> UIImage {
        // Пробуем разные расширения (в обоих регистрах)
        for ext in ["jpg", "jpeg", "png", "heic", "JPG", "JPEG", "PNG", "HEIC"] {
            let url = photosURL.appendingPathComponent("\(id).\(ext)")
            if let image = UIImage(contentsOfFile: url.path) {
                return image
            }
        }
        throw FixtureError.photoNotFound(id)
    }

    /// Загрузить все доступные фикстуры (у которых есть и фото и JSON)
    static func allFixtures() -> [TestFixture] {
        guard let jsonFiles = try? FileManager.default.contentsOfDirectory(
            at: expectedURL, includingPropertiesForKeys: nil
        ) else { return [] }

        return jsonFiles
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                let id = url.deletingPathExtension().lastPathComponent
                return try? fixture(id)
            }
            .filter { fixture in
                // Только те у которых есть фото
                (try? photo(for: fixture)) != nil
            }
    }
}

// MARK: - FixtureError

enum FixtureError: LocalizedError {
    case photoNotFound(String)
    case jsonNotFound(String)

    var errorDescription: String? {
        switch self {
        case .photoNotFound(let id):
            return "Фото не найдено для фикстуры: \(id). Убедитесь что файл есть в Fixtures/Photos/"
        case .jsonNotFound(let id):
            return "Эталонный JSON не найден: \(id).json"
        }
    }
}

// MARK: - Marker class для Bundle lookup
// Нужен чтобы найти правильный Bundle в тест-таргете

private class FixtureLoaderMarker {}
