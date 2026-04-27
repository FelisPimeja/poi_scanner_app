import Foundation
import Combine

// MARK: - AppLanguage

enum AppLanguage: String, CaseIterable {
    case en = "en"
    case ru = "ru"

    var displayName: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        }
    }
}

// MARK: - AppSettings

/// Глобальные настройки приложения. Хранятся в UserDefaults.
/// Используется как @EnvironmentObject через всё приложение.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }

    /// Последний известный город (addr:city) — заполняется из OSM-тегов при сохранении POI
    /// или из Overpass-ответа при поиске дублей. Предлагается как подсказка при заполнении.
    @Published var lastCity: String {
        didSet { UserDefaults.standard.set(lastCity, forKey: "lastCity") }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        self.language = AppLanguage(rawValue: saved) ?? .en
        self.lastCity = UserDefaults.standard.string(forKey: "lastCity") ?? ""
    }
}
