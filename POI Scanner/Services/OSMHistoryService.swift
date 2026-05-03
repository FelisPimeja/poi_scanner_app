import Foundation

// MARK: - Models

/// Одна версия элемента OSM (из /api/0.6/{type}/{id}/history.json)
struct OSMElementVersion: Identifiable {
    let id: Int            // версия (1, 2, 3…)
    let version: Int
    let timestamp: Date
    let user: String
    let uid: Int64
    let changeset: Int64
    let tags: [String: String]
    let visible: Bool      // false = версия с удалением

    /// Diff относительно предыдущей версии
    var diff: VersionDiff = VersionDiff()
}

/// Разница тегов между двумя версиями
struct VersionDiff {
    enum TagChange { case added, modified, removed, unchanged }
    var changes: [String: TagChange] = [:]

    func change(for key: String) -> TagChange {
        changes[key] ?? .unchanged
    }
}

/// Метаданные чейнджсета (комментарий)
struct OSMChangesetInfo {
    let id: Int64
    let comment: String?   // тег "comment" чейнджсета
    let createdAt: Date?
}

// MARK: - Service

actor OSMHistoryService {

    static let shared = OSMHistoryService()
    private init() {}

    private let baseURL = "https://api.openstreetmap.org/api/0.6"
    private var changesetCache: [Int64: OSMChangesetInfo] = [:]

    // MARK: - Public API

    /// Загружает полную историю элемента. Возвращает версии от новых к старым.
    func fetchHistory(type: OSMElementType, id: Int64) async throws -> [OSMElementVersion] {
        let typeName = type.rawValue
        let url = URL(string: "\(baseURL)/\(typeName)/\(id)/history.json")!
        let data = try await fetch(url)
        let raw = try decodeHistoryResponse(from: data)

        var versions = raw.elements.map { el in
            OSMElementVersion(
                id:         el.version,
                version:    el.version,
                timestamp:  Self.parseDate(el.timestamp) ?? Date.distantPast,
                user:       el.user ?? "Anon",
                uid:        Int64(el.uid ?? 0),
                changeset:  Int64(el.changeset),
                tags:       el.tags ?? [:],
                visible:    el.visible ?? true
            )
        }

        // Вычисляем diff каждой версии относительно предыдущей
        for i in versions.indices {
            let prev = i > 0 ? versions[i - 1].tags : [:]
            versions[i].diff = computeDiff(prev: prev, current: versions[i].tags)
        }

        // Возвращаем от новых к старым
        return versions.reversed()
    }

    /// Загружает (или возвращает из кеша) информацию о чейнджсете.
    func changesetInfo(id: Int64) async throws -> OSMChangesetInfo {
        if let cached = changesetCache[id] { return cached }
        let url = URL(string: "\(baseURL)/changeset/\(id).json")!
        let data = try await fetch(url)
        let raw = try decodeChangesetResponse(from: data)
        let comment = raw.changeset.tags?["comment"]
        let info = OSMChangesetInfo(
            id: id,
            comment: comment,
            createdAt: Self.parseDate(raw.changeset.createdAt)
        )
        changesetCache[id] = info
        return info
    }

    // MARK: - Private

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OSMHistoryError.httpError(code)
        }
        return data
    }

    private func computeDiff(prev: [String: String], current: [String: String]) -> VersionDiff {
        var changes: [String: VersionDiff.TagChange] = [:]
        // Added or modified keys
        for (key, val) in current {
            if let prevVal = prev[key] {
                changes[key] = (prevVal == val) ? .unchanged : .modified
            } else {
                changes[key] = .added
            }
        }
        // Removed keys
        for key in prev.keys where current[key] == nil {
            changes[key] = .removed
        }
        return VersionDiff(changes: changes)
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Errors

enum OSMHistoryError: LocalizedError {
    case httpError(Int)
    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP \(code)"
        }
    }
}

// MARK: - Nonisolated decode helpers (Swift 6 isolation fix)

private nonisolated func decodeHistoryResponse(from data: Data) throws -> OSMHistoryResponse {
    try JSONDecoder().decode(OSMHistoryResponse.self, from: data)
}

private nonisolated func decodeChangesetResponse(from data: Data) throws -> OSMChangesetResponse {
    try JSONDecoder().decode(OSMChangesetResponse.self, from: data)
}

// MARK: - JSON models

private struct OSMHistoryResponse {
    let elements: [RawElement]
    struct RawElement {
        let version: Int
        let timestamp: String
        let user: String?
        let uid: Int?
        let changeset: Int
        let tags: [String: String]?
        let visible: Bool?
    }
}

// nonisolated Decodable extensions — предотвращают Swift 6 @MainActor-инференс
nonisolated extension OSMHistoryResponse: Decodable {}
nonisolated extension OSMHistoryResponse.RawElement: Decodable {}

private struct OSMChangesetResponse {
    let changeset: RawChangeset
    struct RawChangeset {
        let id: Int64
        let tags: [String: String]?
        let createdAt: String?
        enum CodingKeys: String, CodingKey {
            case id, tags
            case createdAt = "created_at"
        }
    }
}

nonisolated extension OSMChangesetResponse: Decodable {}
nonisolated extension OSMChangesetResponse.RawChangeset: Decodable {}
