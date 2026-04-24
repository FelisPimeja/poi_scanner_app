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

    /// Извлекает координату из raw Data фото (из PhotosPicker / файла).
    /// Возвращает nil если EXIF GPS отсутствует или координата невалидна.
    static func coordinate(from data: Data) -> CLLocationCoordinate2D? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props  = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let gps    = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        else { return nil }

        return coordinate(fromGPSDict: gps)
    }

    /// Извлекает координату из словаря `info` делегата UIImagePickerController.
    static func coordinate(fromCameraInfo info: [UIImagePickerController.InfoKey: Any]) -> CLLocationCoordinate2D? {
        guard
            let metadata = info[.mediaMetadata] as? [String: Any],
            let gps = metadata[kCGImagePropertyGPSDictionary as String] as? [CFString: Any]
        else { return nil }

        return coordinate(fromGPSDict: gps)
    }

    // MARK: - Private

    private static func coordinate(fromGPSDict gps: [CFString: Any]) -> CLLocationCoordinate2D? {
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

        return coord
    }
}
