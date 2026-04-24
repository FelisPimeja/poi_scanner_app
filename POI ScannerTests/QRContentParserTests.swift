import XCTest
@testable import POI_Scanner

final class QRContentParserTests: XCTestCase {

    // MARK: - Websites

    func testParseSimpleWebsite() {
        let r = QRContentParser.parse(["https://example.com"])
        XCTAssertEqual(r.tags["contact:website"], "https://example.com")
        XCTAssertGreaterThanOrEqual(r.confidence["contact:website"]!, 0.8)
    }

    func testWebsiteStripsUTM() {
        let r = QRContentParser.parse(["https://example.com/page?utm_source=qr&utm_medium=print"])
        XCTAssertEqual(r.tags["contact:website"], "https://example.com/page")
    }

    // MARK: - Социальные сети

    func testVKProfile() {
        let r = QRContentParser.parse(["https://vk.com/mycafe"])
        XCTAssertEqual(r.tags["contact:vk"], "https://vk.com/mycafe")
        XCTAssertNil(r.tags["contact:website"])
    }

    func testInstagram() {
        let r = QRContentParser.parse(["https://www.instagram.com/myshop/"])
        XCTAssertEqual(r.tags["contact:instagram"], "https://www.instagram.com/myshop")
    }

    func testTelegram() {
        let r = QRContentParser.parse(["https://t.me/mychannel"])
        XCTAssertEqual(r.tags["contact:telegram"], "https://t.me/mychannel")
    }

    func testWhatsAppNumber() {
        let r = QRContentParser.parse(["https://wa.me/79001234567"])
        XCTAssertEqual(r.tags["contact:whatsapp"], "+7 900 123-45-67")
    }

    // MARK: - Wi-Fi игнорируется

    func testWifiIgnored() {
        let r = QRContentParser.parse(["WIFI:T:WPA;S:MyNetwork;P:password;;"])
        XCTAssertTrue(r.tags.isEmpty)
    }

    // MARK: - vCard

    func testVCardPhone() {
        let vcard = """
        BEGIN:VCARD
        VERSION:3.0
        FN:Кафе Ромашка
        TEL;TYPE=WORK:+79001234567
        URL:https://romashka.ru
        END:VCARD
        """
        let r = QRContentParser.parse([vcard])
        XCTAssertEqual(r.tags["contact:website"], "https://romashka.ru")
        XCTAssertFalse(r.tags["phone"]?.isEmpty ?? true)
    }

    // MARK: - Множественные QR

    func testMultiplePayloads() {
        let r = QRContentParser.parse([
            "https://vk.com/mycafe",
            "https://t.me/mycafe_bot"
        ])
        XCTAssertEqual(r.tags["contact:vk"], "https://vk.com/mycafe")
        XCTAssertEqual(r.tags["contact:telegram"], "https://t.me/mycafe_bot")
    }

    // MARK: - Пустой ввод

    func testEmptyInput() {
        let r = QRContentParser.parse([])
        XCTAssertTrue(r.tags.isEmpty)
    }

    // MARK: - Карты не попадают в website

    func testMapLinkIgnored() {
        let r = QRContentParser.parse(["https://2gis.ru/moscow/firm/1234567"])
        XCTAssertNil(r.tags["contact:website"])
    }
}
