import Foundation

// MARK: - POIType

/// Один тип POI из справочника (запись POITypes.json).
struct POIType: Codable, Identifiable, Hashable {

    /// Уникальный идентификатор вида "amenity/cafe".
    var id: String { "\(key)/\(value)" }

    let key:     String      // базовый OSM-ключ: amenity, shop, craft…
    let value:   String      // значение: cafe, supermarket…
    let name:    String      // человекочитаемое название (рус/eng)
    let terms:   [String]    // поисковые синонимы
    let presets: [String]    // рекомендуемые OSM-ключи для этого типа

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case key, value, name, terms, presets
    }
}

// MARK: - POITypeRegistry

/// Загружает и хранит полный справочник типов POI из бандла.
final class POITypeRegistry {

    static let shared = POITypeRegistry()

    private(set) var types: [POIType] = []

    /// Базовые ключи, которые считаются «типовыми».
    static let baseKeys: Set<String> = [
        "amenity", "shop", "craft", "public_transport", "healthcare"
    ]

    private init() {
        load()
    }

    // MARK: - Loading

    private func load() {
        guard let url = Bundle.main.url(forResource: "POITypes", withExtension: "json") else {
            print("⚠️ POITypeRegistry: POITypes.json not found in bundle — type picker unavailable")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let container = try JSONDecoder().decode(POITypesFile.self, from: data)
            self.types = container.types
            print("✅ POITypeRegistry: loaded \(self.types.count) types")
        } catch {
            print("⚠️ POITypeRegistry: failed to decode POITypes.json: \(error)")
        }
    }

    // MARK: - Search

    /// Возвращает типы, чьё название или поисковые термины содержат `query`.
    /// При пустом запросе возвращает все типы в исходном порядке.
    func search(_ query: String) -> [POIType] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return types }
        return types.filter { type in
            type.name.lowercased().contains(q) ||
            type.value.contains(q) ||
            type.terms.contains { $0.contains(q) }
        }
    }

    /// Находит тип по ключу и значению.
    func find(key: String, value: String) -> POIType? {
        types.first { $0.key == key && $0.value == value }
    }

    // MARK: - Private

    private struct POITypesFile: Codable {
        let types: [POIType]
    }
}
