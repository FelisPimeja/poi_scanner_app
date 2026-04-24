import Foundation
import MapLibre

// MARK: - OverpassService

final class OverpassService {

    private let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.openstreetmap.fr/api/interpreter")!, // французский инстанс — стабильный
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://overpass.openstreetmap.ru/api/interpreter")!,
    ]

    // MARK: - Public API

    func fetchNodes(in bounds: MLNCoordinateBounds) async throws -> [OSMNode] {
        let query = buildListQuery(for: bounds)
        print("[Overpass] запрос:\n\(query)")
        let data = try await fetch(query: query)
        let raw = String(data: data, encoding: .utf8) ?? ""
        print("[Overpass] ответ (\(data.count) байт): \(raw.prefix(300))")
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        print("[Overpass] элементов в ответе: \(response.elements.count)")
        let nodes = response.elements.compactMap { $0.toOSMNode() }
        print("[Overpass] загружено нод: \(nodes.count)")
        return nodes
    }

    func fetchNodeDetails(id: Int64, type: OSMElementType) async throws -> OSMNode {
        // Запрашиваем строго по типу — node/way/relation могут иметь одинаковый числовой ID.
        let query: String
        switch type {
        case .node:
            query = """
            [out:json][timeout:10];
            node(\(id));
            out body meta;
            """
        case .way:
            query = """
            [out:json][timeout:10];
            way(\(id));
            out body center meta;
            """
        case .relation:
            query = """
            [out:json][timeout:10];
            relation(\(id));
            out body center meta;
            """
        }
        let data = try await fetch(query: query)
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        guard let node = response.elements.first?.toOSMNode() else {
            throw OverpassError.nodeNotFound(id)
        }
        return node
    }

    // MARK: - Query builder

    private func buildListQuery(for bounds: MLNCoordinateBounds) -> String {
        let sw = bounds.sw
        let ne = bounds.ne
        let bbox = "\(sw.latitude),\(sw.longitude),\(ne.latitude),\(ne.longitude)"
        let tags = ["amenity", "shop", "office", "tourism", "leisure"]
        // Строим union для node + way + relation по каждому тегу.
        // out center — Overpass возвращает центроид для way/relation вместо геометрии.
        let lines = tags.flatMap { tag in [
            "  node[\"\(tag)\"](\(bbox));",
            "  way[\"\(tag)\"](\(bbox));",
            "  relation[\"\(tag)\"](\(bbox));",
        ]}.joined(separator: "\n")
        return """
        [out:json][timeout:15];
        (
        \(lines)
        );
        out ids center tags qt;
        """
    }

    // MARK: - Network

    /// Запускает запрос параллельно ко всем эндпоинтам.
    /// Возвращает первый валидный ответ; остальные задачи отменяются.
    private func fetch(query: String) async throws -> Data {
        try Task.checkCancellation()

        typealias Indexed = (index: Int, result: Result<Data, Error>)

        return try await withThrowingTaskGroup(of: Indexed.self) { group in
            for (i, endpoint) in endpoints.enumerated() {
                group.addTask {
                    do {
                        let data = try await self.fetchFrom(url: endpoint, query: query)
                        return (i, .success(data))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }

            var lastError: Error = OverpassError.httpError(0)

            for try await (_, result) in group {
                switch result {
                case .success(let data):
                    group.cancelAll()
                    return data
                case .failure(let error):
                    if error is CancellationError {
                        group.cancelAll()
                        throw error
                    }
                    if let urlError = error as? URLError, urlError.code == .cancelled {
                        group.cancelAll()
                        throw urlError
                    }
                    print("[Overpass] ошибка: \(error.localizedDescription)")
                    lastError = error
                }
            }

            throw lastError
        }
    }

    private func fetchFrom(url: URL, query: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            .data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OverpassError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Проверяем что инстанс вернул реальные OSM данные.
        // Некоторые зеркала возвращают пустые elements с timestamp вида "113589" (не ISO) —
        // это означает что у инстанса нет актуальной базы данных.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let osm3s = json["osm3s"] as? [String: Any],
           let ts = osm3s["timestamp_osm_base"] as? String,
           !ts.contains("T") {
            print("[Overpass] \(url.host ?? "") — невалидный timestamp '\(ts)', пропускаем")
            throw OverpassError.invalidResponse(url.host ?? "unknown")
        }

        return data
    }
}

// MARK: - OverpassError

enum OverpassError: LocalizedError {
    case httpError(Int)
    case nodeNotFound(Int64)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Overpass API вернул статус \(code)"
        case .nodeNotFound(let id): return "Нода \(id) не найдена"
        case .invalidResponse(let host): return "Инстанс \(host) вернул невалидные данные"
        }
    }
}
