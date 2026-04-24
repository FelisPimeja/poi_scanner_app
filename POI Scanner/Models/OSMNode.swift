import Foundation

// MARK: - OSM Node (существующий объект из OSM/Overpass)

struct OSMNode: Identifiable, Codable {
    var id: Int64
    var type: OSMElementType
    var latitude: Double
    var longitude: Double
    var tags: [String: String]
    var version: Int
    var timestamp: String?

    // Конвертация в POI для редактирования
    func toPOI() -> POI {
        var poi = POI(coordinate: .init(latitude: latitude, longitude: longitude))
        poi.osmNodeId = id
        poi.osmVersion = version
        poi.tags = tags
        poi.status = .draft
        return poi
    }
}

enum OSMElementType: String, Codable {
    case node, way, relation
}

// MARK: - Overpass API Response

struct OverpassResponse: Codable {
    let elements: [OverpassElement]
}

struct OverpassElement: Codable {
    let type: String
    let id: Int64
    let lat: Double?
    let lon: Double?
    let center: Center?
    let tags: [String: String]?
    let version: Int?
    let timestamp: String?

    struct Center: Codable {
        let lat: Double
        let lon: Double
    }

    func toOSMNode() -> OSMNode? {
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
