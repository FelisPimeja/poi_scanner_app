import Foundation

// MARK: - Overpass API Response
// Намеренно вынесено в отдельный файл — изолировано от @MainActor-типов,
// чтобы Swift 6 не выводил @MainActor-изоляцию на синтезированные Codable-конформансы.

struct OverpassResponse: Sendable {
    let elements: [OverpassElement]
}

// nonisolated Decodable — предотвращает Swift 6 @MainActor-инференс
nonisolated extension OverpassResponse: Decodable {}

struct OverpassElement: Sendable {
    let type: String
    let id: Int64
    let lat: Double?
    let lon: Double?
    let center: Center?
    let tags: [String: String]?
    let version: Int?
    let timestamp: String?

    struct Center: Sendable {
        let lat: Double
        let lon: Double
    }
}

nonisolated extension OverpassElement: Decodable {}
nonisolated extension OverpassElement.Center: Decodable {}

extension OverpassElement {
    nonisolated func toOSMNode() -> OSMNode? {
        let resolvedLat: Double
        let resolvedLon: Double
        let elementType: OSMElementType
        switch type {
        case "node":
            guard let lat, let lon else { return nil }
            resolvedLat = lat
            resolvedLon = lon
            elementType = .node
        case "way":
            guard let c = center else { return nil }
            resolvedLat = c.lat
            resolvedLon = c.lon
            elementType = .way
        case "relation":
            guard let c = center else { return nil }
            resolvedLat = c.lat
            resolvedLon = c.lon
            elementType = .relation
        default:
            return nil
        }
        return OSMNode(
            id: id,
            type: elementType,
            latitude: resolvedLat,
            longitude: resolvedLon,
            tags: tags ?? [:],
            version: version ?? 1,
            timestamp: timestamp
        )
    }
}
