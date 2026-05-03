import XCTest
@testable import POI_Scanner

// MARK: - WebEnricherLiveTests
// Живые тесты: реальные HTTP-запросы к сайтам из тестовых фикстур.
// Запускать вручную — требуют интернета.
// Пометить в схеме как "disabled by default" или запускать через:
//   xcodebuild test -only-testing WebEnricherLiveTests

final class WebEnricherLiveTests: XCTestCase {

    // MARK: - URL list from fixtures

    /// Сайты из реальных эталонных фикстур
    static let fixtureURLs: [(tag: String, url: String, expectedKey: String?)] = [
        ("contact:website", "https://coffeehouse.ru",      "name"),
        ("contact:website", "https://leonardo.ru",         "name"),
        ("contact:website", "https://yves-rocher.ru",      "name"),
        ("contact:website", "https://loccitane.ru",        "name"),
        ("contact:website", "https://eyekraft.ru",         nil),
        ("contact:website", "https://miuz.ru",             "name"),
        ("contact:website", "https://vtb.ru",              "name"),
        ("contact:website", "https://www.pochta.ru",       "name"),
        ("contact:website", "https://beeline.ru",          "name"),
        ("contact:vk",      "https://vk.com/coffeehouse",  nil),
        ("contact:vk",      "https://vk.com/exomenu",      nil),
        ("contact:website", "https://taplink.cc/palchiki_com", nil),
        ("contact:website", "https://www.planetarium.ru",  "name"),
        ("contact:website", "https://yoko.ru",             nil),
    ]

    // MARK: - Tests

    /// Прогоняем все URL из фикстур через WebEnricher, печатаем результат
    func testEnrichAllFixtureURLs() async throws {
        let enricher = WebEnricher()
        var allResults: [WebFetchResult] = []

        // Каждый URL запрашиваем отдельно — иначе одинаковые теги (contact:website)
        // перезаписывают друг друга в словаре poiTags
        for item in Self.fixtureURLs {
            let results = await enricher.enrich(
                poiTags: [item.tag: item.url],
                parsedTags: [:]
            )
            allResults.append(contentsOf: results)
        }

        print("\n=== WebEnricher Live Results ===")
        for r in allResults {
            let urlConf = r.sourceTagConfidence < 1.0
                ? " [link conf: \(Int(r.sourceTagConfidence * 100))%]" : ""
            print("\n🌐 \(r.url.absoluteString) [\(r.sourceTag)]\(urlConf)")
            if let err = r.error {
                print("   ❌ \(err)")
            } else {
                for (k, v) in r.tags.sorted(by: { $0.key < $1.key }) {
                    let conf = r.confidence[k].map { " (\(Int($0 * 100))%)" } ?? ""
                    print("   \(k): \(v)\(conf)")
                }
                if r.tags.isEmpty { print("   (тегов не найдено)") }
                for s in r.rawSnippets.prefix(3) {
                    print("   › \(s.prefix(120))")
                }
            }
        }

        let successCount = allResults.filter { $0.error == nil }.count
        let total = Self.fixtureURLs.count
        print("\n=== Итого: \(successCount) успешных из \(total) URL ===\n")

        // Минимальная проверка — хотя бы 2 сайта ответили
        XCTAssertGreaterThanOrEqual(successCount, 2,
                             "Слишком мало успешных ответов — возможна проблема с сетью")
    }

    /// Детальный тест одного хорошего сайта — coffeehouse.ru
    func testCoffeehouse() async throws {
        let enricher = WebEnricher()
        let results = await enricher.enrich(
            poiTags: ["contact:website": "https://coffeehouse.ru"],
            parsedTags: [:]
        )
        XCTAssertEqual(results.count, 1)
        guard let r = results.first else { return }
        print("\n🌐 coffeehouse.ru")
        print("   error: \(r.error ?? "нет")")
        print("   tags: \(r.tags)")
        print("   snippets: \(r.rawSnippets.prefix(3))")
    }

    /// Тест collectURLs — только логика без сети
    func testCollectURLs() async {
        let enricher = WebEnricher()
        let tags = [
            "contact:website": "coffeehouse.ru",           // без схемы
            "contact:vk": "https://vk.com/coffeehouse",
            "contact:instagram": "https://instagram.com/coffeehouse",
            "name": "Coffee House",                        // не URL
        ]
        let urls = await enricher.collectURLs(poiTags: tags, parsedTags: [:])
        XCTAssertEqual(urls.count, 3)
        XCTAssertTrue(urls.allSatisfy { $0.0.scheme != nil },
                      "Все URL должны иметь схему (https://)")
        XCTAssertTrue(urls.contains { $0.0.absoluteString == "https://coffeehouse.ru" },
                      "coffeehouse.ru должен получить схему https://")
    }

    /// Тест WebDataParser на локальном HTML с Schema.org
    func testWebDataParserSchemaOrg() {
        let html = """
        <html><head>
        <script type="application/ld+json">
        {
          "@type": "LocalBusiness",
          "name": "Тестовая кофейня",
          "telephone": "+7 (495) 123-45-67",
          "openingHours": ["Mo-Fr 08:00-22:00", "Sa-Su 10:00-20:00"],
          "address": {
            "streetAddress": "ул. Арбат, 1",
            "addressLocality": "Москва"
          },
          "url": "https://test-cafe.ru"
        }
        </script>
        </head><body></body></html>
        """
        let url = URL(string: "https://test-cafe.ru")!
        let result = WebDataParser.parse(html: html, sourceURL: url)

        print("\nSchema.org parse result: \(result.tags)")
        XCTAssertEqual(result.tags["name"], "Тестовая кофейня")
        XCTAssertNotNil(result.tags["phone"], "Телефон должен быть извлечён")
        XCTAssertNotNil(result.tags["opening_hours"], "Часы работы должны быть извлечены")
        XCTAssertNotNil(result.tags["contact:website"])
    }

    /// Тест WebDataParser на HTML с Open Graph
    func testWebDataParserOpenGraph() {
        let html = """
        <html><head>
        <meta property="og:site_name" content="Цветочный магазин Роза">
        <meta property="og:title" content="Роза — доставка цветов">
        <meta property="og:description" content="Тел: +7-800-555-35-35. Работаем с 9 до 21">
        </head><body></body></html>
        """
        let url = URL(string: "https://roza-flowers.ru")!
        let result = WebDataParser.parse(html: html, sourceURL: url)

        print("\nOpenGraph parse result: \(result.tags)")
        XCTAssertEqual(result.tags["name"], "Цветочный магазин Роза")
    }
}
