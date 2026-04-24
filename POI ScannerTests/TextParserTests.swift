import XCTest
@testable import POI_Scanner

// MARK: - TextParserTests
// Unit тесты парсера — без OCR, на вход подаётся готовый текст

final class TextParserTests: XCTestCase {

    // MARK: - Phone

    func testParseRussianPhone() {
        let result = TextParser.parse("Звоните: 8 (495) 123-45-67")
        XCTAssertEqual(result.tags["phone"], "+7 495 123-45-67")
    }

    func testParseInternationalPhone() {
        let result = TextParser.parse("Tel: +7 916 555 00 11")
        XCTAssertNotNil(result.tags["phone"])
    }

    // MARK: - Website & Social

    func testParseWebsite() {
        let result = TextParser.parse("Наш сайт: https://example.ru")
        XCTAssertEqual(result.tags["website"], "https://example.ru")
    }

    func testParseVK() {
        let result = TextParser.parse("Мы ВКонтакте: vk.com/mycafe")
        XCTAssertNotNil(result.tags["contact:vk"])
        XCTAssertTrue(result.tags["contact:vk"]?.contains("vk.com") == true)
    }

    func testParseTelegramHandle() {
        let result = TextParser.parse("Пишите нам @mycafe_spb")
        XCTAssertEqual(result.tags["contact:telegram"], "https://t.me/mycafe_spb")
    }

    func testParseTelegramURL() {
        let result = TextParser.parse("Telegram: https://t.me/mychannel")
        XCTAssertEqual(result.tags["contact:telegram"], "https://t.me/mychannel")
    }

    func testParseInstagram() {
        let result = TextParser.parse("instagram.com/mycafe")
        XCTAssertNotNil(result.tags["contact:instagram"])
    }

    func testWebsiteNotOverriddenBySocial() {
        let result = TextParser.parse("Сайт: https://cafe.ru\nVK: vk.com/cafe")
        XCTAssertEqual(result.tags["website"], "https://cafe.ru")
        XCTAssertNotNil(result.tags["contact:vk"])
    }

    // MARK: - Opening Hours

    func testParse247() {
        let result = TextParser.parse("Работаем круглосуточно!")
        XCTAssertEqual(result.tags["opening_hours"], "24/7")
    }

    func testParseWeekdaysHours() {
        let result = TextParser.parse("Пн-Пт: 09:00-18:00")
        XCTAssertEqual(result.tags["opening_hours"], "Mo-Fr 09:00-18:00")
    }

    func testParseEverydayHours() {
        let result = TextParser.parse("Ежедневно с 10:00 до 22:00")
        XCTAssertEqual(result.tags["opening_hours"], "Mo-Su 10:00-22:00")
    }

    func testParseOpeningHoursWithDot() {
        let result = TextParser.parse("Пн-Вс 08.00–21.00")
        XCTAssertNotNil(result.tags["opening_hours"])
    }

    // MARK: - Legal

    func testParseINN() {
        let result = TextParser.parse("ИНН: 7701234567")
        XCTAssertEqual(result.tags["ref:INN"], "7701234567")
    }

    func testParseINNWithoutLabel() {
        // ИНН без лейбла не должен распознаваться (избегаем ложных срабатываний)
        let result = TextParser.parse("Счёт 1234567890")
        XCTAssertNil(result.tags["ref:INN"])
    }

    func testParseOGRN() {
        let result = TextParser.parse("ОГРН 1037700000001")
        XCTAssertEqual(result.tags["ref:OGRN"], "1037700000001")
    }

    // MARK: - Address

    func testParseStreet() {
        let result = TextParser.parse("ул. Ленина, д. 5")
        XCTAssertEqual(result.tags["addr:street"], "Ленина")
        XCTAssertEqual(result.tags["addr:housenumber"], "5")
    }

    func testParseProspekt() {
        let result = TextParser.parse("пр-т Невский, д.15а")
        XCTAssertEqual(result.tags["addr:street"], "Проспект Невский")
        XCTAssertEqual(result.tags["addr:housenumber"], "15а")
    }

    func testParsePostcode() {
        let result = TextParser.parse("119021, Москва, ул. Льва Толстого")
        XCTAssertEqual(result.tags["addr:postcode"], "119021")
    }

    // MARK: - Email

    func testParseEmail() {
        let result = TextParser.parse("Пишите: info@example.com")
        XCTAssertEqual(result.tags["email"], "info@example.com")
    }

    // MARK: - Edge Cases

    func testEmptyText() {
        let result = TextParser.parse("")
        XCTAssertTrue(result.isEmpty)
    }

    func testTextWithNoStructuredData() {
        let result = TextParser.parse("Добро пожаловать в наш магазин!")
        XCTAssertNil(result.tags["phone"])
        XCTAssertNil(result.tags["website"])
        XCTAssertNil(result.tags["opening_hours"])
    }

    func testConfidenceIsSet() {
        let result = TextParser.parse("ИНН: 7701234567")
        XCTAssertNotNil(result.confidence["ref:INN"])
        XCTAssertGreaterThan(result.confidence["ref:INN"]!, 0.8)
    }
}
