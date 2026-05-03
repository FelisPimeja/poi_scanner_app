import Foundation

// MARK: - POIValueNormalizer
//
// Центральный namespace для нормализации значений OSM-тегов.
// Используется TextParser, WebDataParser, QRContentParser и любым будущим
// источником данных о POI.
//
// Принцип: каждая функция принимает "сырое" строковое значение из любого
// источника и возвращает нормализованное значение в формате, ожидаемом OSM.

enum POIValueNormalizer {

    // ─────────────────────────────────────────────
    // MARK: - Phone
    // ─────────────────────────────────────────────

    /// Нормализует телефонный номер к формату «+7 XXX XXX-XX-XX».
    /// Принимает любой формат: 8(XXX)…, +7XXX…, 10-значный без кода и т.д.
    /// Возвращает пустую строку, если номер не распознан.
    static func phone(_ raw: String) -> String {
        var digits = raw.filter { $0.isNumber }
        // 8XXXXXXXXXX → 7XXXXXXXXXX
        if digits.hasPrefix("8") && digits.count == 11 {
            digits = "7" + digits.dropFirst()
        }
        // 10-значный без кода страны — добавляем 7, если начинается с 3,4,5,6,9
        // (не трогаем ИНН и прочие числа начинающиеся с 7)
        if digits.count == 10, let first = digits.first, "345689".contains(first) {
            digits = "7" + digits
        }
        guard digits.count == 11, digits.hasPrefix("7") else { return "" }
        let d = Array(digits).map { String($0) }
        return "+\(d[0]) \(d[1...3].joined()) \(d[4...6].joined())-\(d[7...8].joined())-\(d[9...10].joined())"
    }

    // ─────────────────────────────────────────────
    // MARK: - URL / Website
    // ─────────────────────────────────────────────

    /// Нормализует URL: добавляет схему https://, приводит к lowercase,
    /// убирает лишний trailing slash.
    static func url(_ raw: String) -> String {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if u.hasPrefix("http://") {
            u = "https://" + u.dropFirst("http://".count)
        } else if !u.hasPrefix("https://") {
            u = "https://" + u
        }
        // Убираем trailing slash только если это не корень домена
        if u.hasSuffix("/") && u.filter({ $0 == "/" }).count > 2 {
            u = String(u.dropLast())
        }
        return u
    }

    /// Классифицирует URL по домену → возвращает (osmTag, normalizedURL).
    /// Например: "vk.com/myshop" → ("contact:vk", "https://vk.com/myshop")
    static func classifyURL(_ raw: String) -> (tag: String, value: String)? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.hasPrefix("mailto:") else { return nil }
        let normalized = url(raw)

        // Российские соцсети
        if      lower.contains("vk.com")        || lower.contains("vkontakte.ru")  { return ("contact:vk",        normalized) }
        else if lower.contains("ok.ru")                                             { return ("contact:ok",        normalized) }
        else if lower.contains("dzen.ru")        || lower.contains("zen.yandex")    { return ("contact:website",   normalized) } // Яндекс Дзен → как сайт

        // Мессенджеры
        else if lower.contains("t.me")           || lower.contains("telegram.me")   { return ("contact:telegram",  normalized) }
        else if lower.contains("wa.me")          || lower.contains("whatsapp.com")  { return ("contact:whatsapp",  normalized) }
        else if lower.contains("viber.com")                                         { return ("contact:viber",     normalized) }

        // Западные соцсети
        else if lower.contains("instagram.com")                                     { return ("contact:instagram", normalized) }
        else if lower.contains("facebook.com")   || lower.contains("fb.com")        { return ("contact:facebook",  normalized) }
        else if lower.contains("twitter.com")    || lower.contains("x.com")         { return ("contact:twitter",   normalized) }
        else if lower.contains("tiktok.com")                                        { return ("contact:tiktok",    normalized) }
        else if lower.contains("youtube.com")    || lower.contains("youtu.be")      { return ("contact:youtube",   normalized) }
        else if lower.contains("pinterest.com")                                     { return ("contact:website",   normalized) } // Pinterest → как сайт
        else if lower.contains("linkedin.com")                                      { return ("contact:website",   normalized) } // LinkedIn → как сайт

        // Агрегаторы ссылок (taplink, linktree и т.п.) → обходим как сайт
        else if lower.contains("taplink.cc")     || lower.contains("linktree.com")
             || lower.contains("beacons.ai")     || lower.contains("bio.link")      { return ("contact:website",   normalized) }

        else                                                                         { return ("contact:website",   normalized) }
    }

    // ─────────────────────────────────────────────
    // MARK: - Email
    // ─────────────────────────────────────────────

    /// Публичные почтовые провайдеры — email на таких доменах не несёт информации о сайте компании.
    nonisolated(unsafe) static let publicEmailDomains: Set<String> = [
        "gmail.com", "googlemail.com",
        "yandex.ru", "yandex.com", "ya.ru",
        "mail.ru", "bk.ru", "inbox.ru", "list.ru", "internet.ru",
        "rambler.ru", "lenta.ru", "autorambler.ru",
        "outlook.com", "hotmail.com", "hotmail.ru", "live.com", "live.ru", "msn.com",
        "icloud.com", "me.com", "mac.com",
        "yahoo.com", "yahoo.ru",
        "protonmail.com", "proton.me",
        "tutanota.com", "tutanota.de",
        "ukr.net", "meta.ua", "i.ua",
        "vk.com",
    ]

    /// Возвращает домен для проверки сайта компании, если email на кастомном домене.
    /// Например "info@exomenu.ru" → "exomenu.ru", "user@gmail.com" → nil
    nonisolated static func companyDomainFromEmail(_ emailStr: String) -> String? {
        guard let atIdx = emailStr.lastIndex(of: "@") else { return nil }
        let domain = String(emailStr[emailStr.index(after: atIdx)...]).lowercased()
        guard !domain.isEmpty,
              !publicEmailDomains.contains(domain),
              domain.contains(".") else { return nil }
        return domain
    }

    /// Нормализует email: lowercase, trim. Возвращает nil если не похоже на email.
    static func email(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), trimmed.contains("."),
              !trimmed.hasPrefix("@"), !trimmed.hasSuffix("@") else { return nil }
        return trimmed
    }

    // ─────────────────────────────────────────────
    // MARK: - Opening Hours
    // ─────────────────────────────────────────────

    /// Нормализует строку часов работы к формату OSM opening_hours.
    ///
    /// Понимает:
    /// - Уже готовый OSM формат: "Mo-Fr 09:00-18:00" → без изменений
    /// - Schema.org массив: "Mo-Fr 09:00-18:00; Sa 10:00-16:00"
    /// - Русский формат "круглосуточно" → "24/7"
    /// - Запятые как разделитель → заменяет на ";"
    ///
    /// Возвращает nil, если формат не распознан или строка пустая.
    static func openingHours(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Русский "круглосуточно"
        let lower = trimmed.lowercased()
        if lower.contains("круглосуточно") || lower == "24/7" || lower == "24 / 7" {
            return "24/7"
        }

        // Уже в формате OSM (содержит день недели Mo/Tu/We/... и время HH:MM)
        let osmPattern = #"^(Mo|Tu|We|Th|Fr|Sa|Su|PH|SH)"#
        if (try? NSRegularExpression(pattern: osmPattern))?.firstMatch(
            in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            // Нормализуем разделитель
            let normalized = trimmed
                .replacingOccurrences(of: ",", with: ";")
                .replacingOccurrences(of: #"\s*;\s*"#, with: "; ",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }

        // Пробуем разобрать русский вид "Пн-Пт 9:00-18:00"
        return parseRussianHours(trimmed)
    }

    /// Разбирает часы в русском формате вида "Пн-Пт 9:00-18:00", "ежедневно 10-22" и т.п.
    private static func parseRussianHours(_ s: String) -> String? {
        let lower = s.lowercased()

        // Маппинг русских дней → OSM
        let dayMap: [(pattern: String, osm: String)] = [
            (#"пн[\s\-–]+пт|понедельник[\s\-–]+пятниц"#,    "Mo-Fr"),
            (#"пн[\s\-–]+сб"#,                               "Mo-Sa"),
            (#"пн[\s\-–]+вс|пн[\s\-–]+нд"#,                 "Mo-Su"),
            (#"сб[\s\-–]+вс|сб[\s\-–]+нд"#,                 "Sa-Su"),
            (#"ежедневно|каждый день|все дни"#,              "Mo-Su"),
            (#"будни|рабочие дни"#,                          "Mo-Fr"),
            (#"выходные"#,                                   "Sa-Su"),
        ]

        var days = "Mo-Su" // fallback
        for (pattern, osm) in dayMap {
            if (try? NSRegularExpression(pattern: pattern))?.firstMatch(
                in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
                days = osm
                break
            }
        }

        // Ищем время вида HH:MM-HH:MM или H-HH
        let timePattern = #"(\d{1,2})[:\.h]?(\d{2})?[\s\-–]+(\d{1,2})[:\.h]?(\d{2})?"#
        guard let re = try? NSRegularExpression(pattern: timePattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }

        func capture(_ idx: Int) -> String? {
            guard let r = Range(m.range(at: idx), in: s), !s[r].isEmpty else { return nil }
            return String(s[r])
        }

        let h1 = capture(1) ?? "00"
        let m1 = capture(2) ?? "00"
        let h2 = capture(3) ?? "00"
        let m2 = capture(4) ?? "00"

        let open  = "\(h1.count == 1 ? "0" + h1 : h1):\(m1)"
        let close = "\(h2.count == 1 ? "0" + h2 : h2):\(m2)"

        return "\(days) \(open)-\(close)"
    }

    // ─────────────────────────────────────────────
    // MARK: - Name
    // ─────────────────────────────────────────────

    /// Имена платформ/агрегаторов, которые не являются названием POI.
    nonisolated(unsafe) static let genericPlatformNames: Set<String> = [
        "вконтакте", "vkontakte", "vk", "instagram", "инстаграм",
        "facebook", "фейсбук", "telegram", "телеграм", "youtube", "ютуб",
        "tiktok", "тикток", "odnoklassniki", "одноклассники", "ok",
        "taplink", "linktree", "twitter", "x", "whatsapp", "viber",
        "yandex", "яндекс", "google", "2gis", "2гис", "zoon",
    ]

    /// Проверяет, является ли строка названием платформы, а не заведения.
    static func isGenericPlatformName(_ s: String) -> Bool {
        genericPlatformNames.contains(s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Нормализует имя POI:
    /// - Отбрасывает имена платформ (ВКонтакте и т.п.)
    /// - Снимает юридические формы ООО/ИП/… → `operator`
    /// - Убирает типографические кавычки вокруг имени
    /// - Фильтрует мусорные строки (только символы, числа-заглушки, слишком короткие)
    ///
    /// Возвращает `(name, operatorValue?)`.
    /// Если имя не подходит — возвращает `(nil, nil)`.
    static func name(_ raw: String) -> (name: String?, operatorValue: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenericPlatformName(trimmed) else { return (nil, nil) }

        // Фильтруем имена из одних спецсимволов / служебных строк
        // (например og:title = "©", "™", "- -", "404", "Error" и т.п.)
        let meaningfulChars = trimmed.unicodeScalars.filter { scalar in
            CharacterSet.letters.union(.decimalDigits).contains(scalar)
        }
        guard meaningfulChars.count >= 2 else { return (nil, nil) }

        // Фильтруем очевидно техничные строки-заглушки
        let junkPatterns = [
            #"^\d{3,4}$"#,                      // "404", "503"
            #"^(error|undefined|null|none)$"#,   // технические строки
            #"^[\p{P}\p{S}\s]+$"#,               // только пунктуация/символы
        ]
        for pat in junkPatterns {
            if trimmed.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil {
                return (nil, nil)
            }
        }

        // Прогоняем через TextParser — он снимает "ООО «Ромашка»" → operator + name
        let parsed = TextParser.parse(trimmed)
        let cleanedName = parsed.tags["name"] ?? trimmed
        let operatorVal = parsed.tags["operator"]

        // Финальная чистка: убираем типографические кавычки вокруг всего имени
        let unquoted = cleanedName
            .replacingOccurrences(of: #"^[«""'„](.+)[»""']$"#, with: "$1",
                                   options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (unquoted.isEmpty ? nil : unquoted, operatorVal)
    }

    // ─────────────────────────────────────────────
    // MARK: - Address fragments
    // ─────────────────────────────────────────────

    /// Нормализует строку адреса (streetAddress из Schema.org/Microdata).
    /// Пытается разделить улицу и номер дома.
    ///
    /// Возвращает `(street?, housenumber?)`.
    static func streetAddress(_ raw: String) -> (street: String?, housenumber: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        let parsed = TextParser.parse(trimmed)
        return (parsed.tags["addr:street"], parsed.tags["addr:housenumber"])
    }

    /// Нормализует индекс (почтовый код).
    static func postcode(_ raw: String) -> String? {
        let digits = raw.filter { $0.isNumber }
        // Российский индекс — ровно 6 цифр
        guard digits.count == 6 else { return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw }
        return digits
    }

    // ─────────────────────────────────────────────
    // MARK: - Website canonicalization
    // ─────────────────────────────────────────────

    /// Убирает UTM-параметры и прочие трекинговые query-параметры из URL.
    static func canonicalURL(_ raw: String) -> String {
        let normalized = url(raw)
        guard var components = URLComponents(string: normalized) else { return normalized }
        let trackingPrefixes = ["utm_", "ref", "fbclid", "gclid", "yclid",
                                "_openstat", "from", "source"]
        components.queryItems = components.queryItems?.filter { item in
            !trackingPrefixes.contains(where: { item.name.lowercased().hasPrefix($0) })
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.string ?? normalized
    }
}
