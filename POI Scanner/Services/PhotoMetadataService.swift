import Foundation
import ImageIO
import CoreLocation
import UIKit

// MARK: - PhotoMetadataService
// Извлекает GPS-координаты из EXIF метаданных фотографии.
//
// Два источника:
//   • Data  — фото из галереи (PhotosPicker), EXIF сохранён в raw bytes
//   • cameraInfo — словарь из UIImagePickerController, содержит kCGImagePropertyGPSDictionary

enum PhotoMetadataService {

    /// Результат извлечения GPS из EXIF.
    struct GPSResult {
        let coordinate: CLLocationCoordinate2D
        /// Горизонтальная погрешность в метрах (kCGImagePropertyGPSHPositionalUncertainty, iOS 11+).
        /// nil если поле отсутствует в EXIF.
        let horizontalAccuracy: Double?
    }

    /// Извлекает координату из raw Data фото (из PhotosPicker / файла).
    /// Возвращает nil если EXIF GPS отсутствует или координата невалидна.
    static func coordinate(from data: Data) -> CLLocationCoordinate2D? {
        gpsResult(from: data)?.coordinate
    }

    /// Извлекает координату + точность из raw Data фото.
    static func gpsResult(from data: Data) -> GPSResult? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props  = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let gps    = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        else { return nil }

        return gpsResult(fromGPSDict: gps)
    }

    /// Извлекает координату из словаря `info` делегата UIImagePickerController.
    static func coordinate(fromCameraInfo info: [UIImagePickerController.InfoKey: Any]) -> CLLocationCoordinate2D? {
        guard
            let metadata = info[.mediaMetadata] as? [String: Any],
            let gps = metadata[kCGImagePropertyGPSDictionary as String] as? [CFString: Any]
        else { return nil }

        return gpsResult(fromGPSDict: gps)?.coordinate
    }

    /// Извлекает координату и точность GPS из словаря `info` делегата UIImagePickerController.
    static func gpsResult(fromCameraInfo info: [UIImagePickerController.InfoKey: Any]) -> GPSResult? {
        guard
            let metadata = info[.mediaMetadata] as? [String: Any],
            let gps = metadata[kCGImagePropertyGPSDictionary as String] as? [CFString: Any]
        else { return nil }

        return gpsResult(fromGPSDict: gps)
    }

    // MARK: - Capture date

    /// Извлекает дату съёмки (DateTimeOriginal) из raw Data фото.
    static func captureDate(from data: Data) -> Date? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props  = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif   = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }

        return exifDate(from: dateStr)
    }

    /// Извлекает дату съёмки из словаря `info` делегата UIImagePickerController.
    static func captureDate(fromCameraInfo info: [UIImagePickerController.InfoKey: Any]) -> Date? {
        guard
            let metadata = info[.mediaMetadata] as? [String: Any],
            let exif = metadata[kCGImagePropertyExifDictionary as String] as? [CFString: Any],
            let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }

        return exifDate(from: dateStr)
    }

    private static func exifDate(from string: String) -> Date? {
        // EXIF формат: "yyyy:MM:dd HH:mm:ss"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)
    }

    // MARK: - Private

    private static func gpsResult(fromGPSDict gps: [CFString: Any]) -> GPSResult? {
        guard
            let lat    = gps[kCGImagePropertyGPSLatitude]    as? Double,
            let lon    = gps[kCGImagePropertyGPSLongitude]   as? Double,
            let latRef = gps[kCGImagePropertyGPSLatitudeRef]  as? String,
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
        else { return nil }

        let latitude  = latRef.uppercased() == "S" ? -lat : lat
        let longitude = lonRef.uppercased() == "W" ? -lon : lon

        let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coord),
              coord.latitude  != 0 || coord.longitude != 0
        else { return nil }

        // "GPSHPositionalUncertainty" — iOS 11+, горизонтальная погрешность в метрах.
        // Некоторые камеры пишут DOP вместо — конвертируем HDOP→метры приближённо (× 5).
        let accuracy: Double?
        if let h = gps["GPSHPositionalUncertainty" as CFString] as? Double, h > 0 {
            accuracy = h
        } else if let dop = gps["GPSDOP" as CFString] as? Double, dop > 0 {
            accuracy = dop * 5.0
        } else {
            accuracy = nil
        }

        return GPSResult(coordinate: coord, horizontalAccuracy: accuracy)
    }

    // Оставляем для обратной совместимости
    private static func coordinate(fromGPSDict gps: [CFString: Any]) -> CLLocationCoordinate2D? {
        gpsResult(fromGPSDict: gps)?.coordinate
    }
}
