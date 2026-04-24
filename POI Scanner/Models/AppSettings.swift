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

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        self.language = AppLanguage(rawValue: saved) ?? .en
    }
}
