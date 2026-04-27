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
        poi.osmType = type
        poi.tags = tags
        poi.status = .draft
        return poi
    }
}

enum OSMElementType: String, Codable {
    case node, way, relation
}
