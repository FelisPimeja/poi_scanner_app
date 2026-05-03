import Foundation

// MARK: - POIFieldInputType

/// Тип ввода для поля — определяет виджет в редакторе.
enum POIFieldInputType: String, Codable {
    case check          // булев чекбокс (yes / no / пусто)
    case select         // один вариант из фиксированного списка
    case semiCombo      // свободный ввод + подсказки; множество через «;»
    case multiCombo     // несколько булевых подключей (fuel:diesel, fuel:lpg…)
    case text           // произвольная строка
    case number         // число
    case url            // URL
    case tel            // телефон
    case email          // email
    case openingHours   // время работы (специальный виджет)
}

// MARK: - POIFieldOption

/// Один допустимый вариант значения с переводом.
struct POIFieldOption: Codable, Hashable {
    let value: String   // OSM-значение (например "pizza")
    let label: String   // Человекочитаемое название (например "Пицца")
}

// MARK: - POIField

/// Описание одного OSM-поля из id-tagging-schema.
struct POIField: Codable, Identifiable {

    /// Идентификатор поля (совпадает с ключом в fields.json, например "cuisine").
    let id: String

    /// Реальный OSM-ключ, которым пишется тег (например "cuisine", "fuel:diesel").
    let osmKey: String

    /// Тип виджета ввода.
    let inputType: POIFieldInputType

    /// Русский лейбл поля (например "Кухня").
    let label: String

    /// Список допустимых значений. Пуст для check/text/number/url/tel/email/openingHours.
    let options: [POIFieldOption]

    /// Префикс ключа для multiCombo (например "fuel:").
    let keyPrefix: String?

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, osmKey, inputType, label, options, keyPrefix
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(String.self,              forKey: .id)
        osmKey    = try c.decode(String.self,              forKey: .osmKey)
        inputType = try c.decode(POIFieldInputType.self,   forKey: .inputType)
        label     = try c.decode(String.self,              forKey: .label)
        options   = try c.decodeIfPresent([POIFieldOption].self, forKey: .options) ?? []
        keyPrefix = try c.decodeIfPresent(String.self,     forKey: .keyPrefix)
    }
}

// MARK: - POIFieldRegistry

/// Загружает и хранит справочник полей из бандла.
final class POIFieldRegistry {

    static let shared = POIFieldRegistry()

    private(set) var fields: [POIField] = []

    /// Псевдо-ключи групп multiCombo (оканчиваются на ":"), например "payment:", "fuel:".
    /// Используется в редакторе, чтобы не рендерить их как обычные tag-строки.
    private(set) var groupAliasKeys: Set<String> = []

    /// Быстрый поиск по `id` поля (например "cuisine").
    private var byID: [String: POIField] = [:]

    /// Быстрый поиск по `osmKey` (например "cuisine" → field).
    private var byOSMKey: [String: POIField] = [:]

    /// Индекс по `keyPrefix` (например "fuel:" → field с multiCombo).
    private var byKeyPrefix: [String: POIField] = [:]

    private init() { load() }

    // MARK: - Lookup

    func field(id fieldID: String) -> POIField? {
        byID[fieldID]
    }

    func field(forOSMKey key: String) -> POIField? {
        // Точное совпадение (например "fuel:") или без trailing colon ("fuel")
        byOSMKey[key] ?? byOSMKey[key.hasSuffix(":") ? String(key.dropLast()) : key + ":"]
    }

    /// Ищет поле по ключу-подключу вида "fuel:diesel" → поле с keyPrefix "fuel:".
    /// Возвращает (поле, суффикс) — суффикс можно использовать для уточнения метки.
    func field(forSubKey key: String) -> (field: POIField, suffix: String)? {
        guard let colonIdx = key.lastIndex(of: ":") else { return nil }
        let prefix = String(key[...colonIdx])          // e.g. "fuel:"
        let suffix = String(key[key.index(after: colonIdx)...]) // e.g. "diesel"
        guard let f = byKeyPrefix[prefix] else { return nil }
        return (f, suffix)
    }

    // MARK: - Private

    private func load() {
        // PBXFileSystemSynchronizedRootGroup может положить файл в корень бандла
        // ИЛИ в подпапку Resources/ — проверяем оба варианта.
        let url: URL? = Bundle.main.url(forResource: "POIFields", withExtension: "json")
            ?? Bundle.main.url(forResource: "POIFields", withExtension: "json", subdirectory: "Resources")
        guard let url else {
            // Диагностика: выведем список всех JSON-файлов в бандле
            let bundlePath = Bundle.main.bundlePath
            let allFiles = (try? FileManager.default.subpathsOfDirectory(atPath: bundlePath)) ?? []
            let jsons = allFiles.filter { $0.hasSuffix(".json") }
            print("⚠️ POIFieldRegistry: POIFields.json not found in bundle — field hints unavailable")
            print("   Bundle JSON files: \(jsons)")
            return
        }
        print("ℹ️ POIFieldRegistry: loading from \(url.lastPathComponent) at \(url.path)")
        do {
            let data = try Data(contentsOf: url)
            let container = try JSONDecoder().decode(POIFieldsFile.self, from: data)
            self.fields = container.fields
            for f in fields {
                byID[f.id] = f
                if byOSMKey[f.osmKey] == nil { byOSMKey[f.osmKey] = f }
                if let prefix = f.keyPrefix, byKeyPrefix[prefix] == nil {
                    byKeyPrefix[prefix] = f
                }
            }
            // Берём groupAliasKeys из JSON (новый формат) или вычисляем из полей (старый формат)
            if let fromJSON = container.groupAliasKeys {
                self.groupAliasKeys = Set(fromJSON)
            } else {
                self.groupAliasKeys = Set(fields.compactMap {
                    $0.inputType == .multiCombo && $0.osmKey.hasSuffix(":") ? $0.osmKey : nil
                })
            }
            print("✅ POIFieldRegistry: loaded \(self.fields.count) fields | groupAliasKeys: \(groupAliasKeys.sorted().joined(separator: ", "))")
        } catch {
            print("⚠️ POIFieldRegistry: failed to decode POIFields.json: \(error)")
        }
    }

    private struct POIFieldsFile: Codable {
        let groupAliasKeys: [String]?
        let fields: [POIField]
    }
}
