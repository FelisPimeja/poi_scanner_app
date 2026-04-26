import Foundation
import CoreLocation
import UIKit

// MARK: - DuplicateCandidate

struct DuplicateCandidate: Identifiable, Equatable {
    let node: OSMNode
    let distance: Double    // метры

    var id: Int64 { node.id }

    static func == (lhs: DuplicateCandidate, rhs: DuplicateCandidate) -> Bool {
        lhs.node.id == rhs.node.id
    }

    /// Цветовая палитра маркеров кандидатов (UIColor для MapLibre)
    static let palette: [UIColor] = [
        .systemRed,
        .systemOrange,
        UIColor(red: 0.55, green: 0.18, blue: 0.80, alpha: 1), // purple
        UIColor.systemTeal,
    ]

    /// Отображаемое имя узла в формате «Тип · Название (этаж)»
    var displayName: String {
        let typePart: String? = node.tags["amenity"].map { localizedType($0, key: "amenity") }
            ?? node.tags["shop"].map    { localizedType($0, key: "shop") }
            ?? node.tags["tourism"].map { localizedType($0, key: "tourism") }
            ?? node.tags["leisure"].map { localizedType($0, key: "leisure") }

        let namePart = node.tags["name"]

        var base: String
        switch (typePart, namePart) {
        case let (type?, name?): base = "\(type) · \(name)"
        case let (type?, nil):   base = type
        case let (nil, name?):   base = name
        default:                 base = "Без названия"
        }

        if let floorStr = floorLabel {
            base += " (\(floorStr))"
        }
        return base
    }

    /// Подпись этажа: сначала addr:floor (уже в региональном формате),
    /// иначе level с конвертацией 0→1, 1→2 и т.д.
    private var floorLabel: String? {
        if let f = node.tags["addr:floor"], !f.isEmpty { return f }
        if let l = node.tags["level"], let lvl = Int(l) {
            return "\(lvl + 1) эт."
        }
        return nil
    }

    private func localizedType(_ value: String, key: String) -> String {
        OSMValueLocalizations.dictionary(for: key)[value]
            ?? OSMValueLocalizations.dictionary(for: "amenity")[value]
            ?? value
    }
}

// MARK: - DiffResolution

enum DiffResolution: Equatable {
    case useOSM
    case useExtracted
    case custom(String)
    case keepOSM    // тег только в OSM — сохраняем без изменений
    case both       // оба значения через «;»
}

// MARK: - TagDiffEntry

struct TagDiffEntry: Identifiable, Equatable {
    let key: String
    let osmValue: String?
    let extractedValue: String?
    var resolution: DiffResolution
    var customEditText: String

    var id: String { key }

    enum Kind: Equatable {
        case conflict   // оба значения есть, они разные
        case same       // оба значения есть, одинаковые
        case newTag     // только в extracted
        case osmOnly    // только в OSM
    }

    var kind: Kind {
        switch (osmValue, extractedValue) {
        case let (.some(a), .some(b)): return a == b ? .same : .conflict
        case (.none, .some):           return .newTag
        case (.some, .none):           return .osmOnly
        default:                       return .same
        }
    }

    /// Итоговое значение тега для загрузки
    var resolvedValue: String? {
        switch resolution {
        case .useOSM:           return osmValue
        case .useExtracted:     return extractedValue
        case .custom(let s):    return s.isEmpty ? nil : s
        case .keepOSM:          return osmValue
        case .both:
            let parts = [osmValue, extractedValue].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: ";")
        }
    }

    /// Псевдонимы contact: ↔ короткий ключ (для нормализации перед diff)
    private static let contactAliases: [(short: String, full: String)] = [
        ("phone",   "contact:phone"),
        ("website", "contact:website"),
        ("email",   "contact:email"),
        ("fax",     "contact:fax"),
    ]

    /// Нормализует ключи extracted-словаря так, чтобы они совпадали с ключами OSM.
    /// Если OSM использует «contact:phone», а extracted — «phone», переименовываем.
    static func normalizeExtracted(_ extracted: [String: String],
                                   against osm: [String: String]) -> [String: String] {
        var result = extracted
        for pair in contactAliases {
            // OSM = full (contact:phone), extracted = short (phone)
            if osm[pair.full] != nil,
               let val = extracted[pair.short],
               extracted[pair.full] == nil {
                result[pair.full] = val
                result.removeValue(forKey: pair.short)
            }
            // OSM = short (phone), extracted = full (contact:phone)
            if osm[pair.short] != nil,
               let val = extracted[pair.full],
               extracted[pair.short] == nil {
                result[pair.short] = val
                result.removeValue(forKey: pair.full)
            }
        }
        return result
    }

    /// Строит массив diff-записей из двух словарей тегов
    static func build(osmTags: [String: String],
                      extractedTags: [String: String]) -> [TagDiffEntry] {
        let normalized = normalizeExtracted(extractedTags, against: osmTags)
        let allKeys = Set(osmTags.keys).union(normalized.keys).sorted()
        return allKeys.map { key in
            let osm = osmTags[key]
            let ext = normalized[key]
            let defaultResolution: DiffResolution
            switch (osm, ext) {
            case let (.some(a), .some(b)) where a == b:
                defaultResolution = .useOSM
            case (.some, .some):
                defaultResolution = .useExtracted
            case (.none, .some):
                defaultResolution = .useExtracted
            case (.some, .none):
                defaultResolution = .keepOSM
            default:
                defaultResolution = .useOSM
            }
            return TagDiffEntry(
                key: key,
                osmValue: osm,
                extractedValue: ext,
                resolution: defaultResolution,
                customEditText: ext ?? osm ?? ""
            )
        }
    }
}

// MARK: - DuplicateChecker

actor DuplicateChecker {
    static let shared = DuplicateChecker()
    private init() {}

    private static let primaryKeys: [String] = [
        "amenity", "shop", "tourism", "office",
        "leisure", "craft", "healthcare", "emergency",
    ]
    private static let nameKeys: [String]    = ["name", "name:ru", "brand", "operator"]
    private static let contactKeys: [String] = [
        "phone", "contact:phone", "website", "contact:website",
    ]

    /// Находит OSM-ноды в радиусе `radiusMeters`, похожие на `poi`.
    func findDuplicates(near poi: POI,
                        radiusMeters: Double = 30) async throws -> [DuplicateCandidate] {
        let lat = poi.coordinate.latitude
        let lon = poi.coordinate.longitude

        let query = """
        [out:json][timeout:10];
        node(around:\(Int(radiusMeters)),\(lat),\(lon));
        out meta;
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
        let resp = try JSONDecoder().decode(OverpassResponse.self, from: data)

        let origin = CLLocation(latitude: lat, longitude: lon)
        var candidates: [DuplicateCandidate] = []

        for element in resp.elements {
            guard let node = element.toOSMNode(), node.type == .node else { continue }
            guard node.id != (poi.osmNodeId ?? -1) else { continue }
            guard isSimilar(node: node, to: poi) else { continue }
            let dist = CLLocation(latitude: node.latitude, longitude: node.longitude)
                .distance(from: origin)
            candidates.append(DuplicateCandidate(node: node, distance: dist))
        }

        return candidates.sorted { $0.distance < $1.distance }
    }

    // MARK: Private helpers

    private func isSimilar(node: OSMNode, to poi: POI) -> Bool {
        // 1. Совпадение значения основного тега
        for key in Self.primaryKeys {
            if let nv = node.tags[key], let pv = poi.tags[key], nv == pv { return true }
        }
        // 2. Совпадение наличия основного тега (оба — кафе/аптека, разные имена)
        for key in Self.primaryKeys {
            if node.tags[key] != nil, poi.tags[key] != nil { return true }
        }
        // 3. Похожие названия / бренды
        for key in Self.nameKeys {
            if let a = node.tags[key], let b = poi.tags[key],
               namesAreSimilar(a, b) { return true }
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
