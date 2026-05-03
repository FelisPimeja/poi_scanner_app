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
        XCTAssertEqual(result.tags["contact:website"], "https://example.ru")
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
        XCTAssertEqual(result.tags["contact:website"], "https://cafe.ru")
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
        XCTAssertEqual(result.tags["addr:street"], "улица Ленина")
        XCTAssertEqual(result.tags["addr:housenumber"], "5")
    }

    func testParseStreetAdjective() {
        let result = TextParser.parse("ул. Садовая, д.19/1")
        XCTAssertEqual(result.tags["addr:street"], "Садовая улица")
        XCTAssertEqual(result.tags["addr:housenumber"], "19/1")
    }

    func testParseStreetGenitive() {
        let result = TextParser.parse("ул. Академика Королёва, д. 1")
        XCTAssertEqual(result.tags["addr:street"], "улица Академика Королёва")
    }

    // Порядковое числительное после прилагательного: "Останкинская 2-я ул" → "2-я Останкинская улица"
    func testParseStreetOrdinalSuffixReverse() {
        let result = TextParser.parse("Факт.адрес: 129515, г. Москва, Останкинская 2-я ул, дом 3")
        XCTAssertEqual(result.tags["addr:street"], "2-я Останкинская улица")
        XCTAssertEqual(result.tags["addr:housenumber"], "3")
    }

    // "1-я Останкинская ул." — числительное уже стоит первым, не трогаем
    func testParseStreetOrdinalPrefixDirect() {
        let result = TextParser.parse("ул. 1-я Останкинская, д.23")
        XCTAssertEqual(result.tags["addr:street"], "1-я Останкинская улица")
        XCTAssertEqual(result.tags["addr:housenumber"], "23")
    }

    // "Тверская-Ямская 1-я ул." → "1-я Тверская-Ямская улица"
    func testParseStreetCompoundOrdinalSuffix() {
        let result = TextParser.parse("Тверская-Ямская 1-я ул., д.7")
        XCTAssertEqual(result.tags["addr:street"], "1-я Тверская-Ямская улица")
        XCTAssertEqual(result.tags["addr:housenumber"], "7")
    }

    func testParseProspekt() {
        let result = TextParser.parse("пр-т Невский, д.15а")
        XCTAssertEqual(result.tags["addr:street"], "Проспект Невский")
        XCTAssertEqual(result.tags["addr:housenumber"], "15а")
    }

    func testParseHouseFraction() {
        let result = TextParser.parse("ул. Садовая, д.19/1")
        XCTAssertEqual(result.tags["addr:housenumber"], "19/1")
    }

    func testParseHouseWithKorpus() {
        let result = TextParser.parse("ул. Ленина, д. 5, к2")
        XCTAssertEqual(result.tags["addr:housenumber"], "5 к2")
    }

    func testParseHouseWithStroenie() {
        let result = TextParser.parse("ул. Ленина, д. 5 стр. 1")
        XCTAssertEqual(result.tags["addr:housenumber"], "5 с1")
    }

    func testParseHouseWithKorpusAndStroenie() {
        let result = TextParser.parse("ул. Берёзовая аллея, д. 6, к2 с1 соор3")
        XCTAssertEqual(result.tags["addr:housenumber"], "6 к2 с1 соор3")
    }

    func testParseDoor() {
        let r1 = TextParser.parse("оф. 558")
        XCTAssertEqual(r1.tags["addr:door"], "558")

        let r2 = TextParser.parse("офис 3")
        XCTAssertEqual(r2.tags["addr:door"], "3")

        let r3 = TextParser.parse("пом. II")
        XCTAssertEqual(r3.tags["addr:door"], "II")

        let r4 = TextParser.parse("ком. 12а")
        XCTAssertEqual(r4.tags["addr:door"], "12а")
    }

    func testParsePostcode() {
        let result = TextParser.parse("119021, Москва, ул. Льва Толстого")
        XCTAssertEqual(result.tags["addr:postcode"], "119021")
    }

    // MARK: - Email

    func testParseEmail() {
        let result = TextParser.parse("Пишите: info@example.com")
        XCTAssertEqual(result.tags["contact:email"], "info@example.com")
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

    // MARK: - Staircase (entrance=staircase)

    func testParseStaircaseBasic() {
        // IMG_9592: "Подъезд Nº4\nкв. 49-66"
        let result = TextParser.parse("Подъезд Nº4\nкв. 49-66")
        XCTAssertEqual(result.tags["entrance"], "staircase")
        XCTAssertEqual(result.tags["ref"], "4")
        XCTAssertEqual(result.tags["addr:flats"], "49-66")
        XCTAssertEqual(result.tags["access"], "private")
    }

    func testParseStaircaseUppercase() {
        // IMG_9608: "ПОДЪЕЗД Nº1\nКВ. 31 - 42"
        let result = TextParser.parse("ПОДЪЕЗД Nº1\nКВ. 31 - 42")
        XCTAssertEqual(result.tags["entrance"], "staircase")
        XCTAssertEqual(result.tags["ref"], "1")
        XCTAssertEqual(result.tags["addr:flats"], "31-42")
    }

    func testParseStaircaseNoNº() {
        // IMG_9943: "Подъезд 1\nкв. 1-8"
        let result = TextParser.parse("Подъезд 1\nкв. 1-8")
        XCTAssertEqual(result.tags["ref"], "1")
        XCTAssertEqual(result.tags["addr:flats"], "1-8")
        XCTAssertEqual(result.tags["entrance"], "staircase")
    }

    func testParseStaircaseMisspelled() {
        // IMG_9830: "Подьезд Nº 1\nкв 2-12A" (ь вместо ъ)
        let result = TextParser.parse("Подьезд Nº 1\nкв 2-12A")
        XCTAssertEqual(result.tags["ref"], "1")
        XCTAssertEqual(result.tags["addr:flats"], "2-12A")
        XCTAssertEqual(result.tags["entrance"], "staircase")
    }

    func testParseStaircaseHighRef() {
        // IMG_9318: "ПОДЪЕЗД Nº6\nкв. 99-118"
        let result = TextParser.parse("ПОДЪЕЗД Nº6\nкв. 99-118")
        XCTAssertEqual(result.tags["ref"], "6")
        XCTAssertEqual(result.tags["addr:flats"], "99-118")
    }

    func testParseStaircaseFlatsMultiple() {
        // IMG_9898: "Подъезд Nº1\nкв. 1-8, 51,52" → addr:flats=1-8;51;52
        let result = TextParser.parse("Подъезд Nº1\nкв. 1-8, 51,52")
        XCTAssertEqual(result.tags["addr:flats"], "1-8;51;52")
    }

    func testParseStaircaseFlatsMultipleWithSpaces() {
        // IMG_9900: "кв. 17-24, 55, 56" → addr:flats=17-24;55;56
        let result = TextParser.parse("Подъезд Nº2\nкв. 17-24, 55, 56")
        XCTAssertEqual(result.tags["addr:flats"], "17-24;55;56")
    }

    func testParseStaircaseFlatsRangeSPO() {
        // IMG_9374: "ПОДЪЕЗД Nº1\nкв. С 1 ПО 20" → addr:flats=1-20
        let result = TextParser.parse("ПОДЪЕЗД Nº1\nкв. С 1 ПО 20")
        XCTAssertEqual(result.tags["addr:flats"], "1-20")
        XCTAssertEqual(result.tags["ref"], "1")
    }

    func testParseStaircaseFlatsKvartiry() {
        // IMG_9908: "ПОДЪЕЗД\nквартиры 149-183"
        let result = TextParser.parse("ПОДЪЕЗД\nквартиры 149-183")
        XCTAssertEqual(result.tags["entrance"], "staircase")
        XCTAssertEqual(result.tags["addr:flats"], "149-183")
    }

    func testParseStaircaseNoTypeConflict() {
        // Если в результате уже есть amenity/shop — НЕ должны добавлять entrance=staircase.
        // Проверяем только что без POI-типов всё ставится (другие тесты уже покрывают это),
        // а здесь симулируем ситуацию через текст без подъезда — entrance не должен ставиться.
        let result = TextParser.parse("кв. 5-20")  // нет слова "подъезд" → hasStaircaseWord=false
        XCTAssertNil(result.tags["entrance"])
        // addr:flats тоже nil, т.к. нет триггера подъезда
        XCTAssertNil(result.tags["addr:flats"])

        // Со словом "подъезд" без POI-типа → entrance ставится
        let result2 = TextParser.parse("Подъезд Nº3\nкв. 5-20")
        XCTAssertEqual(result2.tags["entrance"], "staircase")
        XCTAssertEqual(result2.tags["addr:flats"], "5-20")
    }

    func testParseStaircaseWithAddress() {
        // IMG_9592 полный: подъезд + адрес
        let input = """
        Подъезд Nº4
        кв. 49-66
        Астраханский пер., д. 1/15
        """
        let result = TextParser.parse(input)
        XCTAssertEqual(result.tags["entrance"], "staircase")
        XCTAssertEqual(result.tags["ref"], "4")
        XCTAssertEqual(result.tags["addr:flats"], "49-66")
        XCTAssertEqual(result.tags["addr:housenumber"], "1/15")
    }
}
