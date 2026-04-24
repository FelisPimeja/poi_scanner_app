import XCTest
@testable import POI_Scanner

// MARK: - DraftPromoter
// Полуавтоматическое продвижение черновых JSON (Fixtures/Drafts/) в эталонные (Fixtures/Expected/).
//
// Что делает:
//   1. Читает все *.json из Fixtures/Drafts/
//   2. Пропускает файлы у которых уже есть готовый Expected — не перетирает ручную разметку
//   3. Фильтрует «пустые» фото (0 извлечённых тегов) — они не несут пользы для обучения
//   4. Генерирует заготовку Expected JSON:
//      - extractedTags → expectedTags (значения надо проверить вручную!)
//      - description заполняется из первых строк OCR
//      - minimumConfidence — дефолтные пороги по типу поля
//      - optionalTags — пустой список (заполни вручную)
//   5. Сохраняет в Fixtures/Expected/  ← ТОЛЬКО после ручной проверки
//      (по умолчанию пишет в Fixtures/Drafts/promoted/ для просмотра перед перемещением)
//
// ВНИМАНИЕ: promoted JSON — это заготовки, не финальные эталоны.
// Перед переносом в Expected/ проверь каждый файл:
//   - Убедись что extractedTags правильные (OCR мог ошибиться)
//   - Добавь/удали поля вручную
//   - Поправь description

final class DraftPromoter: XCTestCase {

    // MARK: - Promote

    func testPromoteDraftsToExpected() throws {
        let draftsURL    = FixtureLoader.fixturesSourceURL.appendingPathComponent("Drafts")
        let promotedURL  = FixtureLoader.fixturesSourceURL.appendingPathComponent("Drafts/promoted")
        let expectedURL  = FixtureLoader.expectedURL

        try FileManager.default.createDirectory(at: promotedURL, withIntermediateDirectories: true)

        // Загружаем все черновики
        let draftFiles = (try? FileManager.default.contentsOfDirectory(
            at: draftsURL, includingPropertiesForKeys: nil
        )) ?? []

        let jsonFiles = draftFiles
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !jsonFiles.isEmpty else {
            throw XCTSkip("Нет черновиков в \(draftsURL.path). Сначала запусти FixtureGenerator.")
        }

        var promoted = 0
        var skippedExisting = 0
        var skippedEmpty = 0

        print("\n📋 DraftPromoter — обработка черновиков")
        print(String(repeating: "─", count: 60))

        for draftURL in jsonFiles {
            let id = draftURL.deletingPathExtension().lastPathComponent

            // Пропускаем уже готовые эталоны
            let existingExpected = expectedURL.appendingPathComponent("\(id).json")
            if FileManager.default.fileExists(atPath: existingExpected.path) {
                print("⏭  \(id) — уже есть в Expected/, пропускаю")
                skippedExisting += 1
                continue
            }

            // Декодируем черновик
            guard let data = try? Data(contentsOf: draftURL),
                  let draft = try? JSONDecoder().decode(FixtureDraft.self, from: data) else {
                print("⚠️  \(id) — не удалось декодировать черновик")
                continue
            }

            // Пропускаем пустые фото
            if draft.extractedTags.isEmpty {
                print("🈳  \(id) — нет извлечённых тегов, пропускаю")
                skippedEmpty += 1
                continue
            }

            // Генерируем описание из первых строк OCR
            let descriptionHint = draft.recognizedText.prefix(3)
                .joined(separator: " / ")
                .prefix(120)
            let description = "TODO: проверь теги. OCR: \(descriptionHint)"

            // Дефолтные пороги confidence по типу поля
            var minimumConfidence: [String: Double] = [:]
            for key in draft.extractedTags.keys {
                minimumConfidence[key] = defaultConfidence(for: key)
            }

            // Собираем promoted JSON
            let promoted_fixture = PromotedFixture(
                id: id,
                description: description,
                expectedTags: draft.extractedTags,
                minimumConfidence: minimumConfidence,
                optionalTags: [],
                _reviewNote: "ПРОВЕРЬ: значения взяты автоматически из OCR+парсера. Удали неверные поля."
            )

            // Сохраняем в Drafts/promoted/
            let outputURL = promotedURL.appendingPathComponent("\(id).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let outputData = try encoder.encode(promoted_fixture)
            try outputData.write(to: outputURL)

            let tags = draft.extractedTags.keys.sorted().joined(separator: ", ")
            print("✅  \(id) → promoted  [\(tags)]")
            promoted += 1
        }

        print("\n" + String(repeating: "─", count: 60))
        print("""
✅ Готово.
   Promoted:         \(promoted)
   Пропущено (уже есть Expected): \(skippedExisting)
   Пропущено (пустые):            \(skippedEmpty)

📁 Заготовки сохранены в:
   \(promotedURL.path)

Следующие шаги:
  1. Открой папку: open "\(promotedURL.path)"
  2. Для каждого JSON:
     - Проверь "expectedTags" — удали неверные значения (OCR мог ошибиться)
     - Поправь "description"
     - Убери поле "_reviewNote" когда проверил
  3. Проверенные файлы перемести в Fixtures/Expected/:
     cp "\(promotedURL.path)"/*.json "\(expectedURL.path)"/
""")

        // Тест не падает — это утилита
        XCTAssertGreaterThan(promoted + skippedExisting, 0, "Нечего продвигать")
    }

    // MARK: - Helpers

    /// Дефолтный порог confidence для поля (консервативные значения)
    private func defaultConfidence(for key: String) -> Double {
        switch key {
        case "phone":               return 0.90
        case "ref:INN", "ref:OGRN": return 0.90
        case "addr:postcode":       return 0.80
        case "website", "email":    return 0.80
        case "addr:street":         return 0.60
        case "addr:housenumber":    return 0.60
        case "opening_hours":       return 0.60
        case "name":                return 0.50
        case "amenity", "shop":     return 0.50
        default:                    return 0.60
        }
    }
}

// MARK: - PromotedFixture
// Расширенная структура с полем _reviewNote — напоминает что файл надо проверить

private struct PromotedFixture: Codable {
    let id: String
    var description: String
    var expectedTags: [String: String]
    var minimumConfidence: [String: Double]
    var optionalTags: [String]
    var _reviewNote: String
}
