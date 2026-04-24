import Foundation

// MARK: - QRContentParser
// Парсит содержимое QR-кодов в OSM-теги.
//
// Поддерживаемые форматы:
//   • Обычные URL → contact:website
//   • Социальные сети → contact:vk, contact:instagram, contact:facebook,
//                       contact:telegram, contact:youtube, contact:tiktok, contact:ok
//   • Визитки vCard → name, phone, contact:website, addr:*
//   • Wi-Fi QR      → игнорируются (WIFI:…)
//   • Произвольный текст → передаётся в TextParser как дополнительный текст

enum QRContentParser {

    // MARK: - Результат парсинга

    struct QRResult {
        /// Теги и конфиденс, аналогично TextParser.ParseResult
        var tags: [String: String] = [:]
        var confidence: [String: Double] = [:]

        /// Исходный URL/текст из QR (для дополнительного прогона через TextParser)
        var rawText: String = ""

        /// Человекочитаемое описание источника
        var sourceLabel: String = ""
    }

    // MARK: - Public API

    /// Парсит массив QR-строк. Возвращает объединённый результат.
    static func parse(_ payloads: [String]) -> QRResult {
        var merged = QRResult()
        for payload in payloads {
            let result = parseSingle(payload)
            // Мёрджим: более высокий конфиденс побеждает
            for (key, value) in result.tags {
                let conf = result.confidence[key] ?? 0.7
                if conf > (merged.confidence[key] ?? 0) {
                    merged.tags[key] = value
                    merged.confidence[key] = conf
                }
            }
            if !result.rawText.isEmpty {
                merged.rawText += (merged.rawText.isEmpty ? "" : "\n") + result.rawText
            }
            if !result.sourceLabel.isEmpty {
                merged.sourceLabel = result.sourceLabel
            }
        }
        return merged
    }

    // MARK: - Private

    private static func parseSingle(_ payload: String) -> QRResult {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        // Wi-Fi QR — игнорируем
        if trimmed.uppercased().hasPrefix("WIFI:") { return QRResult() }

        // vCard
        if trimmed.uppercased().hasPrefix("BEGIN:VCARD") {
            return parseVCard(trimmed)
        }

        // URL
        if let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true {
            return parseURL(url, original: trimmed)
        }

        // Просто текст — передаём в TextParser
        var result = QRResult()
        result.rawText = trimmed
        return result
    }

    // MARK: - URL → теги

    private static func parseURL(_ url: URL, original: String) -> QRResult {
        var result = QRResult()
        result.rawText = original

        var host = (url.host ?? "").lowercased()
        // Убираем только ведущие префиксы-зеркала
        for prefix in ["www.", "m.", "mobile."] {
            if host.hasPrefix(prefix) { host = String(host.dropFirst(prefix.count)); break }
        }
        // ВКонтакте
        if host == "vk.com" || host == "vk.ru" {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let canonical = "https://vk.com/\(path)"
            result.tags["contact:vk"] = canonical
            result.confidence["contact:vk"] = 0.92
            result.sourceLabel = "VK QR"
            return result
        }

        // Instagram
        if host == "instagram.com" {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let canonical = "https://www.instagram.com/\(path)"
            result.tags["contact:instagram"] = canonical
            result.confidence["contact:instagram"] = 0.92
            result.sourceLabel = "Instagram QR"
            return result
        }

        // Facebook
        if host == "facebook.com" || host == "fb.com" || host == "fb.me" {
            let canonical = normalizedURL(original)
            result.tags["contact:facebook"] = canonical
            result.confidence["contact:facebook"] = 0.92
            result.sourceLabel = "Facebook QR"
            return result
        }

        // Telegram
        if host == "t.me" || host == "telegram.me" || host == "telegram.dog" {
            let canonical = normalizedURL(original)
            result.tags["contact:telegram"] = canonical
            result.confidence["contact:telegram"] = 0.92
            result.sourceLabel = "Telegram QR"
            return result
        }

        // YouTube
        if host == "youtube.com" || host == "youtu.be" {
            let canonical = normalizedURL(original)
            result.tags["contact:youtube"] = canonical
            result.confidence["contact:youtube"] = 0.90
            result.sourceLabel = "YouTube QR"
            return result
        }

        // TikTok
        if host == "tiktok.com" || host == "vm.tiktok.com" {
            let canonical = normalizedURL(original)
            result.tags["contact:tiktok"] = canonical
            result.confidence["contact:tiktok"] = 0.90
            result.sourceLabel = "TikTok QR"
            return result
        }

        // Одноклассники
        if host == "ok.ru" || host == "odnoklassniki.ru" {
            let canonical = normalizedURL(original)
            result.tags["contact:ok"] = canonical
            result.confidence["contact:ok"] = 0.90
            result.sourceLabel = "OK QR"
            return result
        }

        // WhatsApp
        if host == "wa.me" || host == "api.whatsapp.com" {
            // wa.me/79001234567 → извлекаем номер телефона
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.allSatisfy(\.isNumber), path.count >= 10 {
                let phone = formatPhone(path)
                result.tags["contact:whatsapp"] = phone
                result.confidence["contact:whatsapp"] = 0.90
            }
            result.sourceLabel = "WhatsApp QR"
            return result
        }

        // 2GIS / Яндекс карты / Google Maps — ссылки на организацию, берём только website
        let mapHosts = ["2gis.ru", "2gis.com", "yandex.ru", "maps.google.com", "goo.gl", "maps.app.goo.gl"]
        if mapHosts.contains(where: { host.hasSuffix($0) }) {
            // Не сохраняем как website — это ссылка на карту, не на сайт организации
            result.rawText = original
            return result
        }

        // Обычный сайт
        let clean = normalizedURL(original)
        result.tags["contact:website"] = clean
        result.confidence["contact:website"] = 0.88
        result.sourceLabel = "QR-код (сайт)"
        return result
    }

    // MARK: - vCard парсинг

    private static func parseVCard(_ vcard: String) -> QRResult {
        var result = QRResult()
        result.rawText = vcard
        result.sourceLabel = "vCard QR"

        let lines = vcard.components(separatedBy: .newlines)
        for line in lines {
            let upper = line.uppercased()

            if upper.hasPrefix("FN:") || upper.hasPrefix("N:") {
                // Полное имя
                let name = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && result.tags["name"] == nil {
                    result.tags["name"] = name
                    result.confidence["name"] = 0.75
                }
            } else if upper.hasPrefix("TEL") {
                // TEL;TYPE=...:+79001234567
                if let val = line.components(separatedBy: ":").last {
                    let phone = formatPhone(val.trimmingCharacters(in: CharacterSet.whitespaces))
                    if !phone.isEmpty {
                        result.tags["phone"] = phone
                        result.confidence["phone"] = 0.85
                    }
                }
            } else if upper.hasPrefix("URL:") {
                let urlStr = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                if let url = URL(string: urlStr), url.scheme?.hasPrefix("http") == true {
                    let sub = parseURL(url, original: urlStr)
                    for (k, v) in sub.tags where result.tags[k] == nil {
                        result.tags[k] = v
                        result.confidence[k] = sub.confidence[k] ?? 0.8
                    }
                }
            } else if upper.hasPrefix("ADR") {
                // ADR;TYPE=...:;;улица;город;;;страна
                let parts = line.components(separatedBy: ":").dropFirst().joined(separator: ":").components(separatedBy: ";")
                // vCard ADR: ;pobox;extended;street;city;region;postal;country
                if parts.count >= 4 {
                    let street = parts[safe: 3] ?? ""
                    let city   = parts[safe: 4] ?? ""
                    let postal = parts[safe: 6] ?? ""
                    if !street.isEmpty { result.tags["addr:street"] = street; result.confidence["addr:street"] = 0.75 }
                    if !city.isEmpty   { result.tags["addr:city"]   = city;   result.confidence["addr:city"]   = 0.75 }
                    if !postal.isEmpty { result.tags["addr:postcode"] = postal; result.confidence["addr:postcode"] = 0.80 }
                }
            }
        }
        return result
    }

    // MARK: - Helpers

    /// Нормализует URL: убирает UTM-параметры, trailing slash
    private static func normalizedURL(_ raw: String) -> String {
        guard var comps = URLComponents(string: raw) else { return raw }
        // Убираем стандартные трекинговые параметры
        let trackingKeys: Set<String> = ["utm_source","utm_medium","utm_campaign","utm_term","utm_content","fbclid","gclid","yclid"]
        comps.queryItems = comps.queryItems?.filter { !trackingKeys.contains($0.name.lowercased()) }
        if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
        var result = comps.url?.absoluteString ?? raw
        // Убираем trailing slash только если нет пути
        if result.hasSuffix("/") && (comps.path == "/" || comps.path.isEmpty) {
            result = String(result.dropLast())
        }
        return result
    }

    /// Форматирует телефон в международном формате
    private static func formatPhone(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 10 else { return raw }
        if digits.hasPrefix("7") && digits.count == 11 {
            let n = digits.dropFirst()
            return "+7 \(n.prefix(3)) \(n.dropFirst(3).prefix(3))-\(n.dropFirst(6).prefix(2))-\(n.dropFirst(8))"
        }
        if digits.hasPrefix("8") && digits.count == 11 {
            let n = digits.dropFirst()
            return "+7 \(n.prefix(3)) \(n.dropFirst(3).prefix(3))-\(n.dropFirst(6).prefix(2))-\(n.dropFirst(8))"
        }
        return "+\(digits)"
    }
}

// MARK: - Array safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
