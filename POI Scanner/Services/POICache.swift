import Foundation
import MapLibre
import CoreLocation

// MARK: - POICache
// Кэширует результаты Overpass API в JSON-файл в Caches директории.
// Кэш привязан к bbox — при старте загружаем ноды если текущий центр карты
// находится внутри сохранённого bbox.

enum POICache {

    // MARK: - Stored structure

    private struct Entry: Codable {
        let nodes: [OSMNode]
        let swLat: Double
        let swLon: Double
        let neLat: Double
        let neLon: Double
        let savedAt: Date
    }

    // MARK: - Config

    /// Кэш считается устаревшим через 24 часа
    private static let maxAge: TimeInterval = 24 * 60 * 60

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("overpass_poi_cache.json")
    }

    // MARK: - Public API

    /// Сохраняет ноды вместе с bbox запроса
    static func save(nodes: [OSMNode], bounds: MLNCoordinateBounds) {
        let entry = Entry(
            nodes: nodes,
            swLat: bounds.sw.latitude,
            swLon: bounds.sw.longitude,
            neLat: bounds.ne.latitude,
            neLon: bounds.ne.longitude,
            savedAt: Date()
        )
        do {
            let data = try JSONEncoder().encode(entry)
            try data.write(to: cacheURL, options: .atomic)
            print("[POICache] сохранено \(nodes.count) нод, bbox \(String(format:"%.4f",bounds.ne.latitude-bounds.sw.latitude))°×\(String(format:"%.4f",bounds.ne.longitude-bounds.sw.longitude))°")
        } catch {
            print("[POICache] ошибка сохранения: \(error.localizedDescription)")
        }
    }

    /// Возвращает закэшированные ноды если центр карты находится внутри bbox кэша
    /// и кэш не устарел. Иначе — nil.
    static func load(for center: CLLocationCoordinate2D) -> (nodes: [OSMNode], bounds: MLNCoordinateBounds)? {
        guard let data = try? Data(contentsOf: cacheURL),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            print("[POICache] кэш отсутствует")
            return nil
        }

        // Проверяем возраст
        if Date().timeIntervalSince(entry.savedAt) > maxAge {
            print("[POICache] кэш устарел")
            return nil
        }

        // Проверяем что текущий центр внутри bbox кэша
        let insideLat = center.latitude  >= entry.swLat && center.latitude  <= entry.neLat
        let insideLon = center.longitude >= entry.swLon && center.longitude <= entry.neLon
        guard insideLat && insideLon else {
            print("[POICache] центр карты вне кэшированного bbox — запрос к Overpass")
            return nil
        }

        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: entry.swLat, longitude: entry.swLon),
            ne: CLLocationCoordinate2D(latitude: entry.neLat, longitude: entry.neLon)
        )
        print("[POICache] ✅ загружено из кэша \(entry.nodes.count) нод (возраст \(Int(Date().timeIntervalSince(entry.savedAt)/60)) мин)")
        return (entry.nodes, bounds)
    }

    /// Очищает кэш (например, при принудительном обновлении)
    static func invalidate() {
        try? FileManager.default.removeItem(at: cacheURL)
        print("[POICache] кэш сброшен")
    }
}
