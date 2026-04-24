import Foundation
import CoreLocation

// MARK: - MapPreferences
// Хранит последнее положение карты (центр + зум) в UserDefaults.
// Используется для восстановления позиции при следующем запуске.

enum MapPreferences {

    private enum Keys {
        static let latitude  = "map.center.latitude"
        static let longitude = "map.center.longitude"
        static let zoom      = "map.zoomLevel"
    }

    // Значения по умолчанию — Москва, zoom 14
    private static let defaultLatitude  = 55.7558
    private static let defaultLongitude = 37.6173
    private static let defaultZoom      = 14.0

    static var center: CLLocationCoordinate2D {
        get {
            let lat = UserDefaults.standard.object(forKey: Keys.latitude)  as? Double ?? defaultLatitude
            let lon = UserDefaults.standard.object(forKey: Keys.longitude) as? Double ?? defaultLongitude
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    static var zoomLevel: Double {
        get {
            guard UserDefaults.standard.object(forKey: Keys.zoom) != nil else { return defaultZoom }
            return UserDefaults.standard.double(forKey: Keys.zoom)
        }
    }

    static func save(center: CLLocationCoordinate2D, zoom: Double) {
        UserDefaults.standard.set(center.latitude,  forKey: Keys.latitude)
        UserDefaults.standard.set(center.longitude, forKey: Keys.longitude)
        UserDefaults.standard.set(zoom,             forKey: Keys.zoom)
    }
}
