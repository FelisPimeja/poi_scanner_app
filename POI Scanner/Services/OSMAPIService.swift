import Foundation

// MARK: - OSMAPIService
// Загружает POI в OpenStreetMap через API v0.6 (XML)

@MainActor
final class OSMAPIService {

    static let shared = OSMAPIService()

    private let baseURL = "https://api.openstreetmap.org/api/0.6"
    private let authService = OSMAuthService.shared

    private init() {}

    // MARK: - Public API

    /// Создаёт или обновляет узел в OSM. Возвращает обновлённый POI.
    func upload(poi: POI) async throws -> POI {
        guard let token = authService.accessToken else {
            throw OSMAPIError.notAuthenticated
        }

        // 1. Открываем changeset
        let changesetID = try await createChangeset(
            comment: "POI Scanner: \(poi.tags["name"] ?? "unnamed")",
            token: token
        )

        defer {
            Task { try? await closeChangeset(changesetID, token: token) }
        }

        // 2. Создаём или обновляем объект
        var updated = poi
        if let osmID = poi.osmNodeId {
            // Всегда получаем актуальную версию из API перед modify —
            // Overpass и кэш могут отставать.
            switch poi.osmType {
            case .way:
                let currentVersion = try await fetchCurrentVersion(type: "way", id: osmID, token: token)
                var withFreshVersion = poi
                withFreshVersion.osmVersion = currentVersion
                let nodeRefs = try await fetchWayNodeRefs(wayID: osmID, token: token)
                try await modifyWay(poi: withFreshVersion, wayID: osmID, nodeRefs: nodeRefs, changesetID: changesetID, token: token)
            case .relation:
                let currentVersion = try await fetchCurrentVersion(type: "relation", id: osmID, token: token)
                var withFreshVersion = poi
                withFreshVersion.osmVersion = currentVersion
                let members = try await fetchRelationMembers(relationID: osmID, token: token)
                try await modifyRelation(poi: withFreshVersion, relationID: osmID, members: members, changesetID: changesetID, token: token)
            default:
                let currentVersion = try await fetchCurrentVersion(type: "node", id: osmID, token: token)
                var withFreshVersion = poi
                withFreshVersion.osmVersion = currentVersion
                try await modifyNode(poi: withFreshVersion, nodeID: osmID, changesetID: changesetID, token: token)
            }
        } else {
            let newID = try await createNode(poi: poi, changesetID: changesetID, token: token)
            updated.osmNodeId = newID
        }
        updated.status = .uploaded
        updated.updatedAt = Date()
        return updated
    }

    // MARK: - Changeset

    private func createChangeset(comment: String, token: String) async throws -> Int {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <osm>
          <changeset>
            <tag k="created_by" v="POI Scanner (iOS)"/>
            <tag k="comment" v="\(xmlEscape(comment))"/>
          </changeset>
        </osm>
        """
        let url = URL(string: "\(baseURL)/changeset/create")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = xml.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        guard let idString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let id = Int(idString) else {
            throw OSMAPIError.unexpectedResponse("Cannot parse changeset ID")
        }
        return id
    }

    private func closeChangeset(_ id: Int, token: String) async throws {
        let url = URL(string: "\(baseURL)/changeset/\(id)/close")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Node

    /// Запрашивает актуальную версию объекта прямо из OSM API.
    /// type = "node" | "way" | "relation"
    private func fetchCurrentVersion(type: String, id: Int64, token: String) async throws -> Int {
        let url = URL(string: "\(baseURL)/\(type)/\(id)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        let xml = String(data: data, encoding: .utf8) ?? ""
        // Ищем версию в теге вида: <node id="123" version="7" ...>
        // Паттерн: ищем открывающий тег объекта, затем атрибут version внутри него.
        let openTag = "<\(type) "
        guard let tagStart = xml.range(of: openTag) else {
            throw OSMAPIError.unexpectedResponse("Тег <\(type) не найден в ответе")
        }
        // Берём только первый тег объекта, до первого ">"
        let tagContent: Substring
        if let tagEnd = xml[tagStart.lowerBound...].firstIndex(of: ">") {
            tagContent = xml[tagStart.lowerBound..<tagEnd]
        } else {
            tagContent = xml[tagStart.lowerBound...]
        }
        guard let vRange = tagContent.range(of: "version=\""),
              let vEnd = tagContent[vRange.upperBound...].firstIndex(of: "\"") else {
            throw OSMAPIError.unexpectedResponse("version не найден в теге \(type)/\(id)")
        }
        let versionStr = String(tagContent[vRange.upperBound..<vEnd])
        guard let version = Int(versionStr) else {
            throw OSMAPIError.unexpectedResponse("Не удалось распарсить version: \(versionStr)")
        }
        return version
    }

    private func createNode(poi: POI, changesetID: Int, token: String) async throws -> Int64 {
        let xml = nodeXML(poi: poi, changesetID: changesetID, nodeID: "")
        let url = URL(string: "\(baseURL)/node/create")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = xml.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        guard let idString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let id = Int64(idString) else {
            throw OSMAPIError.unexpectedResponse("Cannot parse created node ID")
        }
        return id
    }

    private func modifyNode(poi: POI, nodeID: Int64, changesetID: Int, token: String) async throws {
        let version = poi.osmVersion ?? 1
        let xml = nodeXML(poi: poi, changesetID: changesetID, nodeID: "\(nodeID)", version: version)
        print("[OSMUpload] 📤 PUT node/\(nodeID) version=\(version) osmVersion_in_poi=\(String(describing: poi.osmVersion)) tags=\(poi.tags)")
        print("[OSMUpload] 📄 XML:\n\(xml)")
        let url = URL(string: "\(baseURL)/node/\(nodeID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = xml.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Way modify

    /// Загружает актуальный список node refs для way из OSM API (нужен для modify).
    private func fetchWayNodeRefs(wayID: Int64, token: String) async throws -> [Int64] {
        let url = URL(string: "\(baseURL)/way/\(wayID)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        // Парсим XML: <nd ref="..."/>
        let xml = String(data: data, encoding: .utf8) ?? ""
        let refs = xml.components(separatedBy: "<nd ref=\"").dropFirst().compactMap { chunk -> Int64? in
            guard let end = chunk.firstIndex(of: "\"") else { return nil }
            return Int64(chunk[chunk.startIndex..<end])
        }
        guard !refs.isEmpty else {
            throw OSMAPIError.unexpectedResponse("Way \(wayID) содержит нулевое количество nd ref")
        }
        return refs
    }

    private func modifyWay(poi: POI, wayID: Int64, nodeRefs: [Int64], changesetID: Int, token: String) async throws {
        guard let version = poi.osmVersion else {
            throw OSMAPIError.unexpectedResponse("Версия way \(wayID) неизвестна — обновите объект")
        }
        let tagsXML = poi.tags.map { k, v in
            "    <tag k=\"\(xmlEscape(k))\" v=\"\(xmlEscape(v))\"/>"
        }.joined(separator: "\n")
        let refsXML = nodeRefs.map { "    <nd ref=\"\($0)\"/>" }.joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <osm>
          <way id="\(wayID)" version="\(version)" changeset="\(changesetID)">
        \(refsXML)
        \(tagsXML)
          </way>
        </osm>
        """
        let url = URL(string: "\(baseURL)/way/\(wayID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = xml.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Relation modify

    /// Загружает актуальный список member'ов для relation из OSM API.
    private func fetchRelationMembers(relationID: Int64, token: String) async throws -> [(type: String, ref: Int64, role: String)] {
        let url = URL(string: "\(baseURL)/relation/\(relationID)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        let xml = String(data: data, encoding: .utf8) ?? ""
        // Парсим <member type="..." ref="..." role="..."/>
        var members: [(type: String, ref: Int64, role: String)] = []
        let chunks = xml.components(separatedBy: "<member ").dropFirst()
        for chunk in chunks {
            guard let end = chunk.firstIndex(of: ">") ?? chunk.firstIndex(of: "/") else { continue }
            let attrs = String(chunk[chunk.startIndex..<end])
            func attr(_ name: String) -> String {
                guard let r = attrs.range(of: "\(name)=\""),
                      let e = attrs[r.upperBound...].firstIndex(of: "\"") else { return "" }
                return String(attrs[r.upperBound..<e])
            }
            let type_ = attr("type")
            guard let ref = Int64(attr("ref")), !type_.isEmpty else { continue }
            members.append((type: type_, ref: ref, role: attr("role")))
        }
        return members
    }

    private func modifyRelation(poi: POI, relationID: Int64,
                                members: [(type: String, ref: Int64, role: String)],
                                changesetID: Int, token: String) async throws {
        guard let version = poi.osmVersion else {
            throw OSMAPIError.unexpectedResponse("Версия relation \(relationID) неизвестна")
        }
        let tagsXML = poi.tags.map { k, v in
            "    <tag k=\"\(xmlEscape(k))\" v=\"\(xmlEscape(v))\"/>"
        }.joined(separator: "\n")
        let membersXML = members.map { m in
            "    <member type=\"\(m.type)\" ref=\"\(m.ref)\" role=\"\(xmlEscape(m.role))\"/>"
        }.joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <osm>
          <relation id="\(relationID)" version="\(version)" changeset="\(changesetID)">
        \(membersXML)
        \(tagsXML)
          </relation>
        </osm>
        """
        let url = URL(string: "\(baseURL)/relation/\(relationID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = xml.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - XML helpers

    private func nodeXML(poi: POI, changesetID: Int, nodeID: String, version: Int = 1) -> String {
        let idAttr = nodeID.isEmpty ? "" : " id=\"\(nodeID)\""
        let versionAttr = nodeID.isEmpty ? "" : " version=\"\(version)\""
        let lat = poi.coordinate.latitude
        let lon = poi.coordinate.longitude
        let tagsXML = poi.tags.map { k, v in
            "    <tag k=\"\(xmlEscape(k))\" v=\"\(xmlEscape(v))\"/>"
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <osm>
          <node\(idAttr)\(versionAttr) lat="\(lat)" lon="\(lon)" changeset="\(changesetID)">
        \(tagsXML)
          </node>
        </osm>
        """
    }

    private func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'",  with: "&apos;")
    }

    // MARK: - Validation

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OSMAPIError.unexpectedResponse("Not an HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OSMAPIError.httpError(http.statusCode, body)
        }
    }
}

// MARK: - Errors

enum OSMAPIError: LocalizedError {
    case notAuthenticated
    case httpError(Int, String)
    case unexpectedResponse(String)
    case unsupportedType(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Необходима авторизация в OSM"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .unexpectedResponse(let msg):
            return "Неожиданный ответ сервера: \(msg)"
        case .unsupportedType(let msg):
            return msg
        }
    }
}
