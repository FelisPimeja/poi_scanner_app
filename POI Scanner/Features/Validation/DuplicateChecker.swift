import Foundation
import CoreLocation

// MARK: - DuplicateChecker
// Намеренно вынесен в отдельный файл без UIKit —
// это предотвращает вывод @MainActor-изоляции на actor в Swift 6.

actor DuplicateChecker {
    static let shared = DuplicateChecker()
    private init() {}

    private static let primaryKeys: [String] = [
        "amenity", "shop", "tourism", "office",
        "leisure", "craft", "healthcare", "emergency", "entrance",
    ]
    private static let nameKeys: [String]    = ["name", "name:ru", "brand", "operator"]
    private static let contactKeys: [String] = [
        "phone", "contact:phone", "website", "contact:website",
    ]

    /// Находит OSM-ноды в радиусе `radiusMeters`, похожие на `poi`.
    func findDuplicates(near poi: POI,
                        radiusMeters: Double = 50) async throws -> [DuplicateCandidate] {
        let lat = poi.coordinate.latitude
        let lon = poi.coordinate.longitude

        let elements = try await Self.fetchElements(lat: lat, lon: lon, radiusMeters: radiusMeters)

        let origin = CLLocation(latitude: lat, longitude: lon)
        var candidates: [DuplicateCandidate] = []

        for element in elements {
            guard let node = element.toOSMNode() else { continue }
            guard node.id != (poi.osmNodeId ?? -1) else { continue }
            // Обновляем lastCity из любого OSM-объекта в радиусе (не только дублей)
            if let city = node.tags["addr:city"], !city.isEmpty {
                let alreadySet = await MainActor.run { !AppSettings.shared.lastCity.isEmpty }
                if !alreadySet {
                    await MainActor.run { AppSettings.shared.lastCity = city }
                }
            }
            guard isSimilar(node: node, to: poi) else { continue }
            let dist = CLLocation(latitude: node.latitude, longitude: node.longitude)
                .distance(from: origin)
            candidates.append(DuplicateCandidate(node: node, distance: dist))
        }

        return candidates.sorted { $0.distance < $1.distance }
    }

    /// Сетевой запрос + декодирование JSON — полностью вне actor-изоляции.
    private nonisolated static func fetchElements(lat: Double, lon: Double,
                                                  radiusMeters: Double) async throws -> [OverpassElement] {
        let query = """
        [out:json][timeout:10];
        nwr(around:\(Int(radiusMeters)),\(lat),\(lon));
        out meta center;
        """

        var request = URLRequest(
            url: URL(string: "https://overpass-api.de/api/interpreter")!,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        let body = "data=" + (query.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? "")
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        // Декодируем через nonisolated free-function чтобы Swift 6 не выводил
        // @MainActor-изоляцию на синтезированный Decodable-инициализатор.
        return try decodeOverpassElements(from: data)
    }

    // MARK: Private helpers

    private func isSimilar(node: OSMNode, to poi: POI) -> Bool {
        // 1. Совпадение имени (похожее)
        for key in Self.nameKeys {
            if let a = node.tags[key], let b = poi.tags[key],
               namesAreSimilar(a, b) { return true }
        }
        // 2. Одинаковый тип — специальная логика для подъездов (entrance):
        //    entrance не имеет name, поэтому сравниваем entrance + ref.
        //    Два подъезда с одинаковым ref рядом — дубль;
        //    с разным ref — разные объекты, не дубль.
        if let nv = node.tags["entrance"], let pv = poi.tags["entrance"], nv == pv {
            let nodeRef = node.tags["ref"] ?? ""
            let poiRef  = poi.tags["ref"]  ?? ""
            // Если ref известен у обоих — сравниваем напрямую
            if !nodeRef.isEmpty && !poiRef.isEmpty {
                return nodeRef == poiRef
            }
            // Если ref неизвестен хотя бы у одного — считаем потенциальным дублем
            return true
        }
        // 3. Одинаковый тип (не entrance) + одно из них без имени
        for key in Self.primaryKeys where key != "entrance" {
            if let nv = node.tags[key], let pv = poi.tags[key], nv == pv {
                let nodeHasName = Self.nameKeys.contains { node.tags[$0] != nil }
                let poiHasName  = Self.nameKeys.contains { poi.tags[$0]  != nil }
                if !nodeHasName || !poiHasName { return true }
            }
        }
        // 4. Совпадение контактов
        for key in Self.contactKeys {
            if let a = node.tags[key], let b = poi.tags[key] {
                let na = digits(a), nb = digits(b)
                if na.count >= 6, na == nb { return true }
            }
        }
        return false
    }

    private func namesAreSimilar(_ a: String, _ b: String) -> Bool {
        let la = a.lowercased().trimmingCharacters(in: .whitespaces)
        let lb = b.lowercased().trimmingCharacters(in: .whitespaces)
        return la == lb || la.contains(lb) || lb.contains(la)
    }

    private func digits(_ s: String) -> String {
        s.filter(\.isNumber)
    }
}

// MARK: - nonisolated decode helper (Swift 6 isolation fix)

private nonisolated func decodeOverpassElements(from data: Data) throws -> [OverpassElement] {
    try JSONDecoder().decode(OverpassResponse.self, from: data).elements
}
