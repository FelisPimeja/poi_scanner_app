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

    private var floorLabel: String? {
        if let f = node.tags["addr:floor"], !f.isEmpty { return f }
        if let l = node.tags["level"], let lvl = Int(l) { return "\(lvl + 1) эт." }
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

    private static let contactAliases: [(short: String, full: String)] = [
        ("phone",   "contact:phone"),
        ("website", "contact:website"),
        ("email",   "contact:email"),
        ("fax",     "contact:fax"),
    ]

    static func normalizeExtracted(_ extracted: [String: String],
                                   against osm: [String: String]) -> [String: String] {
        var result = extracted
        for pair in contactAliases {
            if osm[pair.full] != nil, let val = extracted[pair.short], extracted[pair.full] == nil {
                result[pair.full] = val
                result.removeValue(forKey: pair.short)
            }
            if osm[pair.short] != nil, let val = extracted[pair.full], extracted[pair.short] == nil {
                result[pair.short] = val
                result.removeValue(forKey: pair.full)
            }
        }
        return result
    }

    static func build(osmTags: [String: String],
                      extractedTags: [String: String]) -> [TagDiffEntry] {
        let normalized = normalizeExtracted(extractedTags, against: osmTags)
        let allKeys = Set(osmTags.keys).union(normalized.keys).sorted()
        return allKeys.map { key in
            let osm = osmTags[key]
            let ext = normalized[key]
            let defaultResolution: DiffResolution
            switch (osm, ext) {
            case let (.some(a), .some(b)) where a == b: defaultResolution = .useOSM
            case (.some, .some):                        defaultResolution = .useExtracted
            case (.none, .some):                        defaultResolution = .useExtracted
            case (.some, .none):                        defaultResolution = .keepOSM
            default:                                    defaultResolution = .useOSM
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
