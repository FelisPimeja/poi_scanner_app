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

        // 2. Создаём или обновляем ноду
        var updated = poi
        if let nodeID = poi.osmNodeId {
            // modify
            try await modifyNode(poi: poi, nodeID: nodeID, changesetID: changesetID, token: token)
        } else {
            // create
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
        let url = URL(string: "\(baseURL)/node/\(nodeID)")!
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

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Необходима авторизация в OSM"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .unexpectedResponse(let msg):
            return "Неожиданный ответ сервера: \(msg)"
        }
    }
}
