import Foundation

// MARK: - WebEnricher
// Собирает URL-ссылки из тегов POI и ParseResult,
// загружает страницы в фоне (URLSession) и парсит контент.

actor WebEnricher {

    // MARK: - Config
    private let timeout: TimeInterval = 10
    private let maxURLs: Int = 5
    private let cacheTTL: TimeInterval = 3600   // 1 час
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                            "AppleWebKit/537.36 (KHTML, like Gecko) " +
                            "Chrome/124.0.0.0 Safari/537.36"

    // MARK: - Cache

    private struct CacheEntry {
        let result: WebFetchResult
        let cachedAt: Date
    }
    private var cache: [URL: CacheEntry] = [:]

    private func cachedResult(for url: URL) -> WebFetchResult? {
        guard let entry = cache[url],
              Date().timeIntervalSince(entry.cachedAt) < cacheTTL else { return nil }
        return entry.result
    }

    private func store(_ result: WebFetchResult) {
        cache[result.url] = CacheEntry(result: result, cachedAt: Date())
    }

    /// Очищает устаревшие записи кэша (вызывай при необходимости)
    func purgeExpiredCache() {
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.cachedAt) < cacheTTL }
    }

    // MARK: - Public API

    /// Основной метод: принимает теги POI + извлечённые теги из OCR/QR.
    /// Возвращает список результатов по каждой ссылке.
    func enrich(poiTags: [String: String], parsedTags: [String: String]) async -> [WebFetchResult] {
        let urls = collectURLs(poiTags: poiTags, parsedTags: parsedTags)
        guard !urls.isEmpty else { return [] }

        return await withTaskGroup(of: WebFetchResult?.self) { group in
            for (url, sourceTag) in urls.prefix(maxURLs) {
                group.addTask { [self] in
                    await self.fetchAndParse(url: url, sourceTag: sourceTag)
                }
            }
            var results: [WebFetchResult] = []
            for await result in group {
                if let r = result { results.append(r) }
            }
            // Сортируем по приоритету тега
            return results.sorted { priorityOf($0.sourceTag) > priorityOf($1.sourceTag) }
        }
    }

    // MARK: - URL collection

    /// Возвращает список (URL, тег-источник) без дублей.
    func collectURLs(poiTags: [String: String], parsedTags: [String: String]) -> [(URL, String)] {
        // Теги с URL, по приоритету обхода
        let contactKeys: [String] = [
            "contact:website", "website",
            "contact:vk",
            "contact:telegram",
            "contact:instagram",
            "contact:ok",
            "contact:facebook",
            "contact:twitter",
            "contact:whatsapp",
            "contact:viber",
            "contact:youtube",
            "contact:tiktok",
        ]

        var seen = Set<String>()
        var result: [(URL, String)] = []

        for key in contactKeys {
            for source in [poiTags, parsedTags] {
                guard let rawVal = source[key], !rawVal.isEmpty else { continue }
                let urlStr = normalizeToHTTPS(rawVal)
                guard !seen.contains(urlStr),
                      let url = URL(string: urlStr),
                      url.scheme != nil else { continue }
                seen.insert(urlStr)
                result.append((url, key))
            }
        }

        // Если сайта нет — пробуем вывести из email на кастомном домене
        let hasWebsite = result.contains { $0.1 == "contact:website" || $0.1 == "website" }
        if !hasWebsite {
            let allTags = poiTags.merging(parsedTags) { a, _ in a }
            if let emailVal = allTags["contact:email"] ?? allTags["email"],
               let domain = POIValueNormalizer.companyDomainFromEmail(emailVal) {
                let urlStr = "https://\(domain)"
                if !seen.contains(urlStr), let url = URL(string: urlStr) {
                    seen.insert(urlStr)
                    result.append((url, "email:domain"))
                }
            }
        }

        return result
    }

    // MARK: - Fetch + parse

    private func fetchAndParse(url: URL, sourceTag: String) async -> WebFetchResult {
        // Проверяем кэш
        if let cached = cachedResult(for: url) {
            return cached
        }

        var fetchResult = WebFetchResult(url: url, sourceTag: sourceTag,
                                         tags: [:], confidence: [:], rawSnippets: [])
        do {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
            request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("1", forHTTPHeaderField: "DNT")
            request.setValue("keep-alive", forHTTPHeaderField: "Connection")
            // Referer = корень того же хоста — снижает вероятность 403
            if let host = url.host {
                request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            // Проверяем Content-Type — обрабатываем только HTML
            if let http = response as? HTTPURLResponse {
                let ct = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                guard ct.contains("html") || ct.isEmpty else {
                    fetchResult.error = "Не HTML (Content-Type: \(ct))"
                    return fetchResult
                }
                let status = http.statusCode
                guard (200..<300).contains(status) else {
                    // Читаем тело ошибки — может содержать признаки VPN-блокировки
                    let bodyText = decodeHTML(data: data).lowercased()
                    fetchResult.sourceTagConfidence = confidenceForHTTPError(
                        statusCode: status, body: bodyText)
                    fetchResult.error = "HTTP \(status)"
                    return fetchResult
                }
            }

            // Декодируем с автоопределением кодировки
            let html = decodeHTML(data: data)
            guard !html.isEmpty else {
                fetchResult.error = "Пустой ответ"
                return fetchResult
            }

            // Для VK: проверяем на deactivated/banned аккаунт ДО парсинга
            if url.host?.contains("vk.com") == true && WebDataParser.isVKDeactivated(html: html) {
                fetchResult.sourceTagConfidence = 0.10
                fetchResult.error = "Аккаунт VK заблокирован или удалён"
                return fetchResult
            }

            let parsed = WebDataParser.parse(html: html, sourceURL: url)
            fetchResult.tags = parsed.tags
            fetchResult.confidence = parsed.confidence
            fetchResult.rawSnippets = parsed.snippets

        } catch let urlError as URLError {
            // Timeout — сайт может существовать, просто медленный или недостижимый
            if urlError.code == .timedOut || urlError.code == .networkConnectionLost {
                fetchResult.sourceTagConfidence = 0.6
            } else if urlError.code == .cannotFindHost || urlError.code == .cannotConnectToHost {
                // Хост не найден — ссылка скорее всего мертва
                fetchResult.sourceTagConfidence = 0.15
            }
            fetchResult.error = urlError.localizedDescription
        } catch {
            fetchResult.error = error.localizedDescription
        }
        // Кэшируем только успешные результаты (без ошибок)
        if fetchResult.error == nil {
            store(fetchResult)
        }
        return fetchResult
    }

    // MARK: - Helpers

    /// Вычисляет уверенность в валидности ссылки на основе HTTP-статуса.
    /// Если тело страницы упоминает VPN-блокировку — не снижаем оценку сильно,
    /// так как ссылка скорее всего рабочая, просто заблокирована VPN-ом пользователя.
    private func confidenceForHTTPError(statusCode: Int, body: String) -> Double {
        let vpnKeywords = [
            "vpn", "vpn-", "впн",
            "роскомнадзор", "roskomnadzor",
            "заблокирован", "заблокировано",
            "not available in your region",
            "недоступно в вашем регионе",
            "access restricted", "access denied",
            "restricted in your country",
            "your ip", "ваш ip",
            "proxy", "proxies",
            "georestrict", "geo-restrict",
        ]
        let isVPNBlock = vpnKeywords.contains { body.contains($0) }

        switch statusCode {
        case 403:
            // 403 с VPN-признаком — ссылка скорее всего рабочая, VPN мешает
            return isVPNBlock ? 0.65 : 0.40
        case 404:
            // Страница не найдена — ссылка скорее всего мертва
            return 0.10
        case 410:
            // Gone — ресурс удалён явно
            return 0.05
        case 503:
            // Service Unavailable — временная проблема или VPN
            return isVPNBlock ? 0.60 : 0.45
        case 429:
            // Too Many Requests — сайт существует, просто защита от ботов
            return 0.70
        case 417, 400, 405:
            // Клиентские ошибки без явной причины — неизвестно
            return 0.35
        case 500, 502, 504:
            // Серверные ошибки — временно, сайт скорее всего жив
            return 0.55
        default:
            return isVPNBlock ? 0.55 : 0.40
        }
    }

    private func decodeHTML(data: Data) -> String {
        // Пробуем UTF-8, затем Windows-1251 (распространён на российских сайтах)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1251) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(data: data, encoding: .ascii) ?? ""
    }

    private func normalizeToHTTPS(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http") { return trimmed }
        return "https://" + trimmed
    }

    private func priorityOf(_ tag: String) -> Int {
        switch tag {
        case "contact:website", "website":  return 10
        case "contact:vk":                  return 8
        case "contact:telegram":            return 7
        case "contact:instagram":           return 6
        case "contact:ok":                  return 5
        case "contact:facebook":            return 5
        case "contact:whatsapp":            return 4
        case "contact:viber":               return 4
        case "contact:twitter":             return 3
        case "contact:youtube":             return 3
        case "contact:tiktok":              return 2
        case "email:domain":                return 1  // самый низкий — предположение
        default:                            return 1
        }
    }
}
