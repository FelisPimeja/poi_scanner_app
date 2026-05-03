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

// MARK: - LastPOILocation
// Хранит координаты последней успешно добавленной точки POI.
// Записывается:
//   • при успешной загрузке нового POI, если точность ≤ 30 м
//   • при ручной расстановке точки на карте (coordinateSource == .manual)
// Используется как фоллбэк при плохом GPS (точность > 50 м или нет GPS).

struct LastPOILocation {
    let coordinate: CLLocationCoordinate2D
    let date: Date
}

enum LastPOILocationStore {

    private enum Keys {
        static let latitude  = "lastPOI.latitude"
        static let longitude = "lastPOI.longitude"
        static let date      = "lastPOI.date"
    }

    static var last: LastPOILocation? {
        let ud = UserDefaults.standard
        guard ud.object(forKey: Keys.latitude) != nil,
              ud.object(forKey: Keys.longitude) != nil else { return nil }
        let lat  = ud.double(forKey: Keys.latitude)
        let lon  = ud.double(forKey: Keys.longitude)
        let date = ud.object(forKey: Keys.date) as? Date ?? .distantPast
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard CLLocationCoordinate2DIsValid(coord) else { return nil }
        return LastPOILocation(coordinate: coord, date: date)
    }

    static func save(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let ud = UserDefaults.standard
        ud.set(coordinate.latitude,  forKey: Keys.latitude)
        ud.set(coordinate.longitude, forKey: Keys.longitude)
        ud.set(Date(),               forKey: Keys.date)
    }
}
