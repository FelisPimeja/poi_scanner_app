import Foundation

// MARK: - WebFetchResult
// Результат загрузки и парсинга одной ссылки

struct WebFetchResult: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let sourceTag: String           // "contact:website", "contact:vk", и т.д.
    var tags: [String: String]      // извлечённые теги (ключ OSM → значение)
    var confidence: [String: Double]
    var rawSnippets: [String]       // короткие фрагменты текста, которые помогли извлечь данные
    var fetchedAt: Date = Date()
    var error: String?              // nil = успех

    /// Уверенность в том, что ссылка валидна (1.0 = ОК, <0.5 = ошибка HTTP, ~0.5 = VPN-блок)
    var sourceTagConfidence: Double = 1.0

    var isEmpty: Bool { tags.isEmpty && error == nil }
}

// MARK: - WebDataParser
// Статический парсер HTML-страницы. Не делает сетевых запросов.

enum WebDataParser {

    // MARK: - Public API

    /// Парсит сырой HTML и возвращает извлечённые теги.
    static func parse(html: String, sourceURL: URL) -> (tags: [String: String],
                                                         confidence: [String: Double],
                                                         snippets: [String]) {
        var tags: [String: String] = [:]
        var confidence: [String: Double] = [:]
        var snippets: [String] = []

        // 1. Schema.org JSON-LD (наивысший приоритет)
        let schemaResult = parseSchemaOrg(html: html)
        merge(from: schemaResult.tags, conf: schemaResult.confidence,
              into: &tags, intoConf: &confidence)
        snippets += schemaResult.snippets

        // 2. HTML Microdata (itemprop — альтернативный способ разметки Schema.org)
        let microdataResult = parseMicrodata(html: html)
        merge(from: microdataResult.tags, conf: microdataResult.confidence,
              into: &tags, intoConf: &confidence)
        snippets += microdataResult.snippets

        // 3. Open Graph
        let ogResult = parseOpenGraph(html: html)
        merge(from: ogResult.tags, conf: ogResult.confidence,
              into: &tags, intoConf: &confidence)
        snippets += ogResult.snippets

        // 4. <title> тег — fallback для имени
        let titleResult = parseTitle(html: html)
        merge(from: titleResult.tags, conf: titleResult.confidence,
              into: &tags, intoConf: &confidence)

        // 5. Прогоняем видимый текст через TextParser
        let visibleText = extractVisibleText(html: html)
        if !visibleText.isEmpty {
            let textResult = TextParser.parse(visibleText)
            // Ниже уверенность чем у структурированных источников
            for (key, value) in textResult.tags {
                let conf = (textResult.confidence[key] ?? 0.6) * 0.75
                if (confidence[key] ?? 0) < conf {
                    tags[key] = value
                    confidence[key] = conf
                }
            }
            let snippet = String(visibleText.prefix(300))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !snippet.isEmpty {
                snippets.append("(text) \(snippet)…")
            }
        }

        // 6. VK apiPrefetchCache — встроенный JSON с данными группы/пользователя
        if sourceURL.host?.contains("vk.com") == true {
            let vkResult = parseVKPrefetch(html: html)
            merge(from: vkResult.tags, conf: vkResult.confidence,
                  into: &tags, intoConf: &confidence)
            snippets += vkResult.snippets
        }

        return (tags, confidence, snippets)
    }

    /// Проверяет, содержит ли VK-страница признак заблокированного/удалённого аккаунта.
    /// Вызывать только для vk.com URL.
    static func isVKDeactivated(html: String) -> Bool {
        // VK встраивает статус аккаунта в apiPrefetchCache JSON
        return html.contains("\"deactivated\":\"banned\"")
            || html.contains("\"deactivated\":\"deleted\"")
            || html.contains("User was deleted or banned")
    }

    // MARK: - Schema.org JSON-LD

    private static func parseSchemaOrg(html: String) -> (tags: [String: String],
                                                          confidence: [String: Double],
                                                          snippets: [String]) {
        var tags: [String: String] = [:]
        var confidence: [String: Double] = [:]
        var snippets: [String] = []

        // Ищем все <script type="application/ld+json">...</script>
        let pattern = #"<script[^>]+type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return (tags, confidence, snippets)
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = re.matches(in: html, range: range)

        for match in matches {
            guard let r = Range(match.range(at: 1), in: html) else { continue }
            let jsonStr = String(html[r])
            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { continue }

            // Может быть объект или массив объектов
            let items: [[String: Any]]
            if let arr = obj as? [[String: Any]] {
                items = arr
            } else if let dict = obj as? [String: Any] {
                items = [dict]
            } else { continue }

            for item in items {
                let typeVal = (item["@type"] as? String ?? "").lowercased()
                // LocalBusiness и его подтипы (Restaurant, Cafe, Store, …)
                let isLocalBusiness = typeVal.contains("localbusiness") ||
                    typeVal.contains("restaurant") || typeVal.contains("cafe") ||
                    typeVal.contains("store") || typeVal.contains("hotel") ||
                    typeVal.contains("organization") || typeVal.contains("place")
                guard isLocalBusiness else { continue }

                snippets.append("(schema.org) @type: \(item["@type"] as? String ?? "?")")

                if let name = item["name"] as? String, !name.isEmpty {
                    let (cleaned, opVal) = cleanName(name)
                    if let cleaned {
                        tags["name"] = cleaned
                        confidence["name"] = 0.88
                    }
                    if let opVal, tags["operator"] == nil {
                        tags["operator"] = opVal
                        confidence["operator"] = 0.75
                    }
                }

                if let phone = item["telephone"] as? String, !phone.isEmpty {
                    let normalized = normalizePhone(phone)
                    if !normalized.isEmpty {
                        tags["phone"] = normalized
                        confidence["phone"] = 0.88
                    }
                }

                if let hours = item["openingHours"] as? String, !hours.isEmpty {
                    if let oh = parseSchemaOpeningHours(hours) {
                        tags["opening_hours"] = oh
                        confidence["opening_hours"] = 0.82
                    }
                } else if let hoursArr = item["openingHours"] as? [String], !hoursArr.isEmpty {
                    if let oh = parseSchemaOpeningHours(hoursArr.joined(separator: "; ")) {
                        tags["opening_hours"] = oh
                        confidence["opening_hours"] = 0.82
                    }
                }

                if let addrObj = item["address"] as? [String: Any] {
                    if let street = addrObj["streetAddress"] as? String, !street.isEmpty {
                        let (st, hn) = POIValueNormalizer.streetAddress(street)
                        tags["addr:street"] = st ?? street
                        confidence["addr:street"] = st != nil ? 0.80 : 0.72
                        if let hn, tags["addr:housenumber"] == nil {
                            tags["addr:housenumber"] = hn
                            confidence["addr:housenumber"] = 0.75
                        }
                    }
                    if let postcode = addrObj["postalCode"] as? String, !postcode.isEmpty {
                        tags["addr:postcode"] = POIValueNormalizer.postcode(postcode) ?? postcode
                        confidence["addr:postcode"] = 0.85
                    }
                    if let city = addrObj["addressLocality"] as? String, !city.isEmpty {
                        tags["addr:city"] = city
                        confidence["addr:city"] = 0.80
                    }
                }

                if let website = item["url"] as? String, !website.isEmpty,
                   tags["contact:website"] == nil {
                    tags["contact:website"] = normalizeURL(website)
                    confidence["contact:website"] = 0.85
                }

                if let desc = item["description"] as? String, !desc.isEmpty {
                    snippets.append("(schema.org) description: \(desc.prefix(120))")
                }
            }
        }

        return (tags, confidence, snippets)
    }

    // MARK: - Open Graph

    private static func parseOpenGraph(html: String) -> (tags: [String: String],
                                                          confidence: [String: Double],
                                                          snippets: [String]) {
        var tags: [String: String] = [:]
        var confidence: [String: Double] = [:]
        var snippets: [String] = []

        // <meta property="og:..." content="..." />  или name=
        let pattern = #"<meta\s+(?:[^>]*\s+)?(?:property|name)=["'](og:[^"']+)["'][^>]+content=["']([^"']+)["']"#
        let pattern2 = #"<meta\s+(?:[^>]*\s+)?content=["']([^"']+)["'][^>]+(?:property|name)=["'](og:[^"']+)["']"#

        func extractOG(pat: String) {
            guard let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) else { return }
            let range = NSRange(html.startIndex..., in: html)
            for match in re.matches(in: html, range: range) {
                let (keyIdx, valIdx) = pat == pattern ? (1, 2) : (2, 1)
                guard let kr = Range(match.range(at: keyIdx), in: html),
                      let vr = Range(match.range(at: valIdx), in: html) else { continue }
                let key = String(html[kr])
                let val = htmlDecode(String(html[vr]))
                switch key {
                case "og:title":
                    if tags["name"] == nil {
                        let (cleaned, opVal) = cleanName(stripPlatformSuffix(val))
                        if let cleaned {
                            tags["name"] = cleaned
                            confidence["name"] = 0.70
                            snippets.append("(og:title) \(cleaned)")
                        }
                        if let opVal, tags["operator"] == nil {
                            tags["operator"] = opVal
                            confidence["operator"] = 0.60
                        }
                    }
                case "og:description":
                    snippets.append("(og:description) \(val.prefix(120))")
                    // Пробуем извлечь телефон/адрес из описания
                    let descParsed = TextParser.parse(val)
                    for (k, v) in descParsed.tags {
                        let c = (descParsed.confidence[k] ?? 0.5) * 0.70
                        if (confidence[k] ?? 0) < c {
                            tags[k] = v
                            confidence[k] = c
                        }
                    }
                case "og:site_name":
                    if tags["name"] == nil {
                        let (cleaned, _) = cleanName(val)
                        if let cleaned {
                            tags["name"] = cleaned
                            confidence["name"] = 0.60
                        }
                    }
                default: break
                }
            }
        }
        extractOG(pat: pattern)
        extractOG(pat: pattern2)

        return (tags, confidence, snippets)
    }

    // MARK: - Visible text extraction

    private static func extractVisibleText(html: String) -> String {
        var text = html
        // Убираем <script> и <style>
        for tag in ["script", "style", "noscript", "svg"] {
            let p = "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>"
            text = text.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        // Убираем все теги
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Декодируем HTML entities
        text = htmlDecode(text)
        // Схлопываем пробелы/переносы
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTML Microdata (itemprop)

    /// Парсит Schema.org Microdata — атрибуты itemprop="name", itemprop="telephone" и т.д.
    /// Поддерживает плоскую разметку (не вложенную).
    private static func parseMicrodata(html: String) -> (tags: [String: String],
                                                          confidence: [String: Double],
                                                          snippets: [String]) {
        var tags: [String: String] = [:]
        var confidence: [String: Double] = [:]
        var snippets: [String] = []

        // Проверяем, есть ли вообще itemtype с Schema.org
        guard html.contains("schema.org") else { return (tags, confidence, snippets) }

        // Извлекаем content или текст из тегов с itemprop
        let pattern = #"<[a-z]+[^>]+itemprop=["']([^"']+)["'][^>]*(?:content=["']([^"']+)["']|>([^<]*)<)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return (tags, confidence, snippets)
        }

        let range = NSRange(html.startIndex..., in: html)
        for match in re.matches(in: html, range: range) {
            guard let propR = Range(match.range(at: 1), in: html) else { continue }
            let prop = String(html[propR]).lowercased()

            // Значение: из content= или из текста элемента
            var val = ""
            if let r = Range(match.range(at: 2), in: html), !html[r].isEmpty {
                val = htmlDecode(String(html[r]))
            } else if let r = Range(match.range(at: 3), in: html) {
                val = htmlDecode(String(html[r])).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !val.isEmpty else { continue }

            switch prop {
            case "name":
                if tags["name"] == nil {
                    let (cleaned, opVal) = cleanName(val)
                    if let cleaned {
                        tags["name"] = cleaned
                        confidence["name"] = 0.82
                        snippets.append("(microdata) name: \(cleaned)")
                    }
                    if let opVal, tags["operator"] == nil {
                        tags["operator"] = opVal
                        confidence["operator"] = 0.70
                    }
                }
            case "telephone":
                let phone = normalizePhone(val)
                if !phone.isEmpty, tags["phone"] == nil {
                    tags["phone"] = phone
                    confidence["phone"] = 0.82
                }
            case "openinghours", "openinghoursspecification":
                if tags["opening_hours"] == nil {
                    if let oh = parseSchemaOpeningHours(val) {
                        tags["opening_hours"] = oh
                        confidence["opening_hours"] = 0.75
                    }
                }
            case "streetaddress":
                if tags["addr:street"] == nil {
                    let (st, hn) = POIValueNormalizer.streetAddress(val)
                    tags["addr:street"] = st ?? val
                    confidence["addr:street"] = 0.75
                    if let hn, tags["addr:housenumber"] == nil {
                        tags["addr:housenumber"] = hn
                        confidence["addr:housenumber"] = 0.70
                    }
                }
            case "postalcode":
                if tags["addr:postcode"] == nil {
                    tags["addr:postcode"] = POIValueNormalizer.postcode(val) ?? val
                    confidence["addr:postcode"] = 0.80
                }
            case "addresslocality":
                if tags["addr:city"] == nil {
                    tags["addr:city"] = val
                    confidence["addr:city"] = 0.75
                }
            case "email":
                if tags["contact:email"] == nil,
                   let normalized = POIValueNormalizer.email(val) {
                    tags["contact:email"] = normalized
                    confidence["contact:email"] = 0.80
                }
            case "url":
                if tags["contact:website"] == nil {
                    tags["contact:website"] = normalizeURL(val)
                    confidence["contact:website"] = 0.75
                }
            default: break
            }
        }

        return (tags, confidence, snippets)
    }

    // MARK: - <title> tag

    /// Извлекает имя из HTML <title>. Чистит шаблонные суффиксы вида "Название | Сайт".
    private static func parseTitle(html: String) -> (tags: [String: String],
                                                       confidence: [String: Double],
                                                       snippets: [String]) {
        let pattern = #"<title[^>]*>([^<]+)</title>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(match.range(at: 1), in: html) else {
            return ([:], [:], [])
        }

        var title = htmlDecode(String(html[r])).trimmingCharacters(in: .whitespacesAndNewlines)
        // Убираем суффикс "Название | Домен" или "Название — Слоган"
        let separators = [" | ", " - ", " — ", " · ", " :: "]
        for sep in separators {
            if let idx = title.range(of: sep) {
                title = String(title[..<idx.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        // Убираем суффиксы агрегаторов/платформ через общий хелпер
        title = stripPlatformSuffix(title)

        guard title.count >= 2 else { return ([:], [:], []) }
        let (cleaned, _) = cleanName(title)
        guard let cleaned else { return ([:], [:], []) }
        return (["name": cleaned], ["name": 0.55], ["(title) \(cleaned)"])
    }

    // MARK: - VK apiPrefetchCache

    /// Извлекает теги POI из встроенного JSON (apiPrefetchCache) на страницах vk.com.
    /// VK встраивает данные группы/пользователя прямо в HTML до рендеринга.
    /// Парсит данные VK-группы из массива `apiPrefetchCache`, который VK сервер
    /// встраивает прямо в HTML страницы как результат server-side prefetch API вызовов.
    /// Ищем запись с method="groups.getById" → response.groups[0] — это чистый JSON объект группы.
    private static func parseVKPrefetch(html: String) -> (tags: [String: String],
                                                           confidence: [String: Double],
                                                           snippets: [String]) {
        var tags: [String: String] = [:]
        var conf: [String: Double] = [:]
        var snippets: [String] = []

        // --- Извлекаем JSON-массив apiPrefetchCache ---
        // Структура в HTML: {"apiPrefetchCache":[{...},{...},...]}
        // Ищем маркер "apiPrefetchCache":[ и находим конец массива по балансу скобок
        let marker = #""apiPrefetchCache":["#
        guard let markerRange = html.range(of: marker) else {
            return (tags, conf, snippets)
        }
        // absStart — позиция открывающей [ массива
        let absStart = html.index(before: markerRange.upperBound) // последний символ маркера = '['

        // Проходим до соответствующей закрывающей ]
        var depth = 0
        var absEnd = absStart
        for idx in html[absStart...].indices {
            switch html[idx] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { absEnd = idx; break }
            default: break
            }
            if depth == 0 && idx >= absStart { break }
        }

        guard absEnd > absStart,
              let data = String(html[absStart...absEnd]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return (tags, conf, snippets)
        }

        // --- Ищем запись groups.getById → response.groups[0] ---
        guard let entry = array.first(where: { $0["method"] as? String == "groups.getById" }),
              let response = entry["response"] as? [String: Any],
              let groups = response["groups"] as? [[String: Any]],
              let group = groups.first else {
            return (tags, conf, snippets)
        }

        // --- name ---
        if let name = group["name"] as? String {
            let decoded = htmlDecode(name)
            let (cleaned, _) = cleanName(decoded)
            if let cleaned {
                tags["name"] = cleaned
                conf["name"] = 0.82
                snippets.append("(vk) name: \(cleaned)")
            }
        }

        // --- site ---
        if let site = group["site"] as? String, !site.isEmpty {
            let url = normalizeURL(site)
            if !url.isEmpty {
                tags["contact:website"] = url
                conf["contact:website"] = 0.82
                snippets.append("(vk) contact:website: \(url)")
            }
        }

        // --- phone (поле верхнего уровня — публичный телефон группы) ---
        if let phone = group["phone"] as? String, !phone.isEmpty {
            let normalized = normalizePhone(htmlDecode(phone))
            if !normalized.isEmpty {
                tags["phone"] = normalized
                conf["phone"] = 0.82
                snippets.append("(vk) phone: \(normalized)")
            }
        }

        // --- contacts:[{phone, email}] — контакты администраторов ---
        if let contacts = group["contacts"] as? [[String: Any]] {
            var phones: [String] = []
            var emails: [String] = []
            for contact in contacts {
                if let p = contact["phone"] as? String {
                    let n = normalizePhone(htmlDecode(p))
                    if !n.isEmpty && !phones.contains(n) { phones.append(n) }
                }
                if let e = contact["email"] as? String, e.contains("@") {
                    let n = e.lowercased()
                    if !emails.contains(n) { emails.append(n) }
                }
            }
            // Контакты администраторов могут дополнять публичный телефон
            if !phones.isEmpty && tags["phone"] == nil {
                tags["phone"] = phones.joined(separator: "; ")
                conf["phone"] = 0.78
                snippets.append("(vk) phone (contacts): \(tags["phone"]!)")
            }
            if !emails.isEmpty {
                tags["contact:email"] = emails.joined(separator: "; ")
                conf["contact:email"] = 0.82
                snippets.append("(vk) contact:email: \(tags["contact:email"]!)")
            }
        }

        // --- status → TextParser → opening_hours ---
        if let status = group["status"] as? String, !status.isEmpty {
            let decoded = htmlDecode(status)
            snippets.append("(vk) status: \(decoded)")
            let parsed = TextParser.parse(decoded)
            if let hoursValue = parsed.tags["opening_hours"], !hoursValue.isEmpty {
                let hoursConf = min((parsed.confidence["opening_hours"] ?? 0.7) * 0.85, 0.65)
                tags["opening_hours"] = hoursValue
                conf["opening_hours"] = hoursConf
                snippets.append("(vk) opening_hours: \(hoursValue) [\(Int(hoursConf * 100))%]")
            }
        }

        // --- addresses.main_address → addr:street + addr:city ---
        if let addresses = group["addresses"] as? [String: Any],
           let mainAddr = addresses["main_address"] as? [String: Any] {
            if let address = mainAddr["address"] as? String, !address.isEmpty {
                let decoded = htmlDecode(address)
                let (street, housenumber) = POIValueNormalizer.streetAddress(decoded)
                if let street {
                    tags["addr:street"] = street
                    conf["addr:street"] = 0.70
                    snippets.append("(vk) addr:street: \(street)")
                }
                if let housenumber {
                    tags["addr:housenumber"] = housenumber
                    conf["addr:housenumber"] = 0.70
                    snippets.append("(vk) addr:housenumber: \(housenumber)")
                }
            }
            if let city = (mainAddr["city"] as? [String: Any])?["title"] as? String, !city.isEmpty {
                tags["addr:city"] = htmlDecode(city)
                conf["addr:city"] = 0.70
                snippets.append("(vk) addr:city: \(tags["addr:city"]!)")
            }
        }

        return (tags, conf, snippets)
    }

    private static func merge(from src: [String: String], conf srcConf: [String: Double],
                               into dst: inout [String: String], intoConf dstConf: inout [String: Double]) {
        for (key, val) in src {
            let c = srcConf[key] ?? 0.5
            if (dstConf[key] ?? 0) < c {
                dst[key] = val
                dstConf[key] = c
            }
        }
    }

    /// Обёртка для лаконичного использования в парсерах
    private static func normalizePhone(_ s: String) -> String { POIValueNormalizer.phone(s) }
    private static func normalizeURL(_ s: String) -> String { POIValueNormalizer.url(s) }
    private static func cleanName(_ raw: String) -> (name: String?, operatorValue: String?) { POIValueNormalizer.name(raw) }
    private static func isGenericPlatformName(_ s: String) -> Bool { POIValueNormalizer.isGenericPlatformName(s) }

    private static func parseSchemaOpeningHours(_ s: String) -> String? {
        POIValueNormalizer.openingHours(s)
    }

    /// Убирает суффиксы платформ/агрегаторов из строки title/og:title.
    /// Например: "Palchiki_com at Taplink" → "Palchiki_com"
    private static func stripPlatformSuffix(_ s: String) -> String {
        let patterns = [
            #"\s+at\s+\w+"#,           // "Name at Taplink", "Name at Facebook"
            #"\s+в\s+ВКонтакте"#,
            #"\s+в\s+Инстаграм"#,
            #"\s+on\s+Instagram"#,
            #"\s+on\s+Facebook"#,
        ]
        var result = s
        for pat in patterns {
            result = result
                .replacingOccurrences(of: pat + "$", with: "",
                                      options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// Минимальный HTML entities decoder
    private static func htmlDecode(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&amp;",   with: "&")
            .replacingOccurrences(of: "&lt;",    with: "<")
            .replacingOccurrences(of: "&gt;",    with: ">")
            .replacingOccurrences(of: "&quot;",  with: "\"")
            .replacingOccurrences(of: "&#39;",   with: "'")
            .replacingOccurrences(of: "&apos;",  with: "'")
            .replacingOccurrences(of: "&nbsp;",  with: " ")
            .replacingOccurrences(of: "&ndash;", with: "-")
            .replacingOccurrences(of: "&mdash;", with: "–")
            .replacingOccurrences(of: "&laquo;", with: "«")
            .replacingOccurrences(of: "&raquo;", with: "»")
            .replacingOccurrences(of: "&lsquo;", with: "'")
            .replacingOccurrences(of: "&rsquo;", with: "'")
            .replacingOccurrences(of: "&ldquo;", with: "\"")
            .replacingOccurrences(of: "&rdquo;", with: "\"")
            .replacingOccurrences(of: "&hellip;", with: "…")
            .replacingOccurrences(of: "&trade;", with: "™")
            .replacingOccurrences(of: "&reg;",   with: "®")
            .replacingOccurrences(of: #"&#(\d+);"#, with: { match in
                guard let code = UInt32(match.dropFirst(2).dropLast()),
                      let scalar = Unicode.Scalar(code) else { return match }
                return String(scalar)
            }, options: .regularExpression)
            .replacingOccurrences(of: #"&#x([0-9a-fA-F]+);"#, with: { match in
                guard let code = UInt32(match.dropFirst(3).dropLast(), radix: 16),
                      let scalar = Unicode.Scalar(code) else { return match }
                return String(scalar)
            }, options: .regularExpression)
    }
}

// MARK: - String regex replace with transform
private extension String {
    func replacingOccurrences(of pattern: String,
                              with transform: (String) -> String,
                              options: NSString.CompareOptions) -> String {
        guard options.contains(.regularExpression),
              let re = try? NSRegularExpression(pattern: pattern) else { return self }
        var result = self
        let matches = re.matches(in: self, range: NSRange(self.startIndex..., in: self))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}
