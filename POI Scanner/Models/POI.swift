import Foundation
import CoreLocation

// MARK: - CoordinateSource

/// Источник координат POI — отображается под строкой DMS в превью карты.
enum CoordinateSource: String, Codable {
    case photo      // EXIF GPS из фото
    case gps        // текущая геопозиция устройства
    case mapCenter  // центр карты на момент создания
    case manual     // пользователь выставил вручную в CoordinatePicker

    var label: String {
        switch self {
        case .photo:     return "Координаты из фото"
        case .gps:       return "Текущая геопозиция GPS"
        case .mapCenter: return "Центр карты"
        case .manual:    return "Выставлено вручную"
        }
    }
}

// MARK: - POI

struct POI: Identifiable, Codable {
    var id: UUID = UUID()
    var coordinate: Coordinate
    var coordinateSource: CoordinateSource = .mapCenter
    var osmNodeId: Int64?                           // nil = новый объект
    var osmVersion: Int?                            // версия ноды для modify
    var osmType: OSMElementType?                    // тип OSM объекта (node/way/relation)
    var tags: [String: String] = [:]                // финальные OSM теги
    var fieldStatus: [String: FieldStatus] = [:]    // статус каждого поля
    var extractionConfidence: [String: Double] = [:]
    var sourceImageNames: [String] = []             // имена файлов в bundle (для тестов)
    var status: POIStatus = .draft
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // CLLocationCoordinate2D не Codable — используем обёртку
    struct Coordinate: Codable, Equatable {
        var latitude: Double
        var longitude: Double

        var clCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        init(_ coordinate: CLLocationCoordinate2D) {
            self.latitude = coordinate.latitude
            self.longitude = coordinate.longitude
        }

        init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }
}

// MARK: - POIStatus

enum POIStatus: String, Codable, CaseIterable {
    case draft       // Создан, не проверен
    case validated   // Проверен пользователем
    case uploading   // В процессе загрузки
    case uploaded    // Загружен в OSM
    case failed      // Ошибка загрузки

    var label: String {
        switch self {
        case .draft:      return "Черновик"
        case .validated:  return "Проверен"
        case .uploading:  return "Загружается"
        case .uploaded:   return "Загружен"
        case .failed:     return "Ошибка"
        }
    }
}

// MARK: - FieldStatus

enum FieldStatus: String, Codable {
    case extracted  // 🟡 Получено из OCR, не проверено
    case suggested  // 🔵 Предложено из сайта / соцсетей
    case confirmed  // 🟢 Подтверждено пользователем
    case manual     // ⚪️ Введено вручную

    var emoji: String {
        switch self {
        case .extracted:  return "🟡"
        case .suggested:  return "🔵"
        case .confirmed:  return "🟢"
        case .manual:     return "⚪️"
        }
    }
}
