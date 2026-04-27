import SwiftUI

// MARK: - OSMTagRow
// Единый компонент отображения тега OSM в обоих контекстах:
//   • карточка ноды (read-only)  → иконка в .secondary
//   • редактор POI (editable)    → иконка окрашена в цвет статуса;
//                                   если иконки нет — цветная точка (legacy)

struct OSMTagRow: View {
    let tagKey: String

    /// Только для read-only режима
    var readOnlyValue: String? = nil

    /// Для режима редактирования
    var editableValue: Binding<String>? = nil
    var status: FieldStatus? = nil

    /// Переопределить иконку (используется в секции адреса — первая строка = "house")
    var forceIcon: String? = nil
    /// Скрыть иконку и показать прозрачный спейсер (адрес: строки 2…N)
    var hideIcon: Bool = false
    /// Применить жирное начертание к значению (первичное название в группе Название)
    var isPrimary: Bool = false

    private var definition: OSMTagDefinition? { OSMTags.definition(for: tagKey) }

    /// Определение поля из POIFieldRegistry — используется как фолбэк
    /// когда OSMTags не содержит определения для данного ключа.
    private var poiField: POIField? { POIFieldRegistry.shared.field(forOSMKey: tagKey) }

    /// Человекочитаемая метка (из каталога OSMTags → POIField → авто-генерация)
    private var label: String {
        if let def = definition { return def.label }
        if let field = poiField { return field.label }
        return Self.localizedNameLabel(for: tagKey)
    }

    /// Генерирует метку для ключей вида "name:XX", "old_name:XX", "alt_name:XX" и т.п.
    /// Использует Locale для получения названия языка по ISO 639-1 коду.
    static func localizedNameLabel(for key: String) -> String {
        let nameBasePrefixes: [(prefix: String, base: String)] = [
            ("official_name:", "Официальное название"),
            ("old_name:",      "Старое название"),
            ("alt_name:",      "Альтернативное название"),
            ("full_name:",     "Полное название"),
            ("short_name:",    "Краткое название"),
            ("int_name:",      "Международное название"),
            ("name:",          "Название"),
        ]
        let isRu = AppSettings.shared.language == .ru
        let localeId = isRu ? "ru_RU" : "en_US"
        let locale = Locale(identifier: localeId)
        for (prefix, baseLabel) in nameBasePrefixes {
            if key.hasPrefix(prefix) {
                let langCode = String(key.dropFirst(prefix.count))
                // Используем Locale для получения названия языка
                let langName = locale.localizedString(forLanguageCode: langCode)
                              ?? langCode.uppercased()
                return "\(baseLabel) (\(langName))"
            }
        }
        // Префиксы здания: building:* и roof:*
        let buildingPrefixes: [(prefix: String, base: String)] = [
            ("building:", "Здание"),
            ("roof:",     "Крыша"),
        ]
        for (prefix, base) in buildingPrefixes {
            if key.hasPrefix(prefix) {
                let suffix = String(key.dropFirst(prefix.count))
                return "\(base) (\(suffix))"
            }
        }
        return key
    }

    /// SF Symbol для этого ключа (из каталога)
    private var icon: String? { definition?.icon }

    var body: some View {
        HStack(spacing: 10) {
            leadingIndicator
            tagContent
        }
        .padding(.vertical, 2)
    }

    // MARK: Leading indicator

    /// В режиме редактирования:
    ///   - иконка есть → иконка цвета статуса
    ///   - иконки нет  → цветная точка статуса
    /// В режиме просмотра:
    ///   - иконка есть → иконка .secondary
    ///   - иконки нет  → пустой резервированный блок (выравнивание по сетке)
    @ViewBuilder
    private var leadingIndicator: some View {
        let effectiveIcon: String? = hideIcon ? nil : (forceIcon ?? icon)
        if let iconName = effectiveIcon {
            Image(systemName: iconName)
                .font(.body)
                .foregroundStyle(status.map(\.color) ?? Color.secondary)
                .frame(width: 24, alignment: .center)
        } else if let status, !hideIcon {
            // нет иконки, но есть статус → точка
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundStyle(status.color)
                .frame(width: 24, alignment: .center)
        } else {
            // read-only без иконки → пустой блок той же ширины для выравнивания
            Color.clear
                .frame(width: 24, height: 1)
        }
    }

    // MARK: Tag content

    /// True если ключ — главное название (name или name:ru) в режиме просмотра.
    private var isMainNameKey: Bool {
        editableValue == nil && isPrimary
    }

    /// True если ключ входит в группу «Тип» и для него есть локализованный перевод.
    /// В таком случае в read-only показываем одну строку — только переведённое значение.
    /// cuisine исключён: у него несколько значений через ";", caption «Кухня» оставляем.
    private var isLocalizedTypeKey: Bool {
        guard editableValue == nil,
              AppSettings.shared.language == .ru else { return false }
        let typeKeys: Set<String> = ["amenity", "shop", "tourism", "leisure", "office", "craft"]
        return typeKeys.contains(tagKey.lowercased())
    }

    @ViewBuilder
    private var tagContent: some View {
        if isLocalizedTypeKey, let raw = readOnlyValue, !raw.isEmpty {
            // Одна строка: локализованное значение без подписи "Тип (shop)"
            let translated = OSMValueLocalizations.label(for: raw, key: tagKey.lowercased())
            Text(translated)
                .font(.body)
                .textSelection(.enabled)
        } else {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let binding = editableValue {
                switch definition?.inputType {
                case .select(let options):
                    SelectTagField(key: tagKey, options: options, value: binding)
                case .multiselect(let options):
                    MultiSelectTagField(key: tagKey, options: options, value: binding)
                case .openingHours:
                    OpeningHoursNavigatorRow(value: binding)
                case .boolean:
                    BooleanTagToggle(value: binding)
                default:
                    if tagKey == "check_date" {
                        CheckDateField(value: binding)
                    } else if let field = poiField, !field.options.isEmpty {
                        // Фолбэк: поле есть в POIFieldRegistry с вариантами значений
                        switch field.inputType {
                        case .select:
                            SelectTagField(key: tagKey, poiOptions: field.options, value: binding)
                        case .semiCombo:
                            MultiSelectTagField(key: tagKey, poiOptions: field.options, value: binding)
                        default:
                            TextField(tagKey, text: binding).font(.body)
                        }
                    } else if let field = poiField, field.inputType == .check {
                        BooleanTagToggle(value: binding)
                    } else {
                        TextField(tagKey, text: binding)
                            .font(.body)
                    }
                }
            } else {
                // Read-only boolean: показываем Да / Нет / — без списка частей
                if case .boolean? = definition?.inputType {
                    let localizedBool: String = {
                        switch readOnlyValue {
                        case "yes": return AppSettings.shared.language == .ru ? "Да"  : "Yes"
                        case "no":  return AppSettings.shared.language == .ru ? "Нет" : "No"
                        default:    return readOnlyValue ?? "—"
                        }
                    }()
                    Text(localizedBool)
                        .font(.body)
                        .foregroundStyle(readOnlyValue == "yes" ? .green
                                       : readOnlyValue == "no"  ? .red
                                       : .secondary)
                } else {
                // Значение может содержать несколько элементов через ";".
                // Отображаем каждый с новой строки.
                let parts = (readOnlyValue ?? "")
                    .split(separator: ";", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(parts.isEmpty ? [""] : parts, id: \.self) { part in
                        let display = Self.displayValue(forKey: tagKey, value: part)
                        if let url = Self.wikiURL(forKey: tagKey, value: part)
                                  ?? Self.contactURL(forKey: tagKey, value: part) {
                            Link(destination: url) {
                                Text(display)
                                    .font(isMainNameKey ? .body.weight(.semibold) : .body)
                                    .foregroundStyle(.blue)
                            }
                        } else {
                            Text(display)
                                .font(isMainNameKey ? .body.weight(.semibold) : .body)
                                .textSelection(.enabled)
                        }
                    }
                }
                } // end else boolean
            }
        }
        } // end else
    }

    // MARK: Wiki URL resolver

    /// Строит URL для wiki-ключей:
    /// - wikipedia / *:wikipedia  → https://{lang}.wikipedia.org/wiki/{title}
    ///   значение: "ru:Название статьи"
    /// - wikidata  / *:wikidata   → https://www.wikidata.org/wiki/{Q-id}
    ///   значение: "Q12345"
    private static func wikiURL(forKey key: String, value: String) -> URL? {
        let k = key.lowercased()
        if k == "wikipedia" || k.hasSuffix(":wikipedia") {
            // Формат: "lang:Title" или просто "Title" (язык en по умолчанию)
            let colonIdx = value.firstIndex(of: ":")
            let lang: String
            let title: String
            if let idx = colonIdx, value.distance(from: value.startIndex, to: idx) <= 5 {
                lang  = String(value[value.startIndex..<idx])
                title = String(value[value.index(after: idx)...])
            } else {
                lang  = "en"
                title = value
            }
            let encoded = title.replacingOccurrences(of: " ", with: "_")
                               .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            return URL(string: "https://\(lang).wikipedia.org/wiki/\(encoded)")
        }
        if k == "wikidata" || k.hasSuffix(":wikidata") {
            // Формат: "Q12345"
            guard value.hasPrefix("Q") || value.hasPrefix("P") else { return nil }
            return URL(string: "https://www.wikidata.org/wiki/\(value)")
        }
        return nil
    }

    // MARK: Contact URL resolver

    /// Строит кликабельный URL для contact-группы:
    /// - phone / contact:phone       → tel:
    /// - email / contact:email       → mailto:
    /// - website / contact:*         → прямой URL (https://...)
    /// - contact:telegram @username  → https://t.me/{username}
    private static func contactURL(forKey key: String, value: String) -> URL? {
        let k = key.lowercased()

        // Телефон → tel:
        if k == "phone" || k == "contact:phone" || k == "contact:whatsapp" {
            let digits = value.replacingOccurrences(of: " ", with: "")
            return URL(string: "tel:\(digits)")
        }

        // Email → mailto:
        if k == "email" || k == "contact:email" {
            return URL(string: "mailto:\(value)")
        }

        // Telegram: может быть @username или полный URL
        if k == "contact:telegram" {
            if value.hasPrefix("http") {
                return URL(string: value)
            }
            let username = value.hasPrefix("@") ? String(value.dropFirst()) : value
            return URL(string: "https://t.me/\(username)")
        }

        // Всё остальное contact:* с URL-значением
        if k == "website" || k.hasPrefix("contact:") {
            if value.hasPrefix("http") {
                return URL(string: value)
            }
            // На случай если схема опущена
            return URL(string: "https://\(value)")
        }

        return nil
    }

    // MARK: Display value formatter

    /// Возвращает отформатированное значение для read-only отображения:
    /// - тип (amenity/shop/…) → локализованное название (ru: «Цветочный магазин»)
    /// - телефон              → +7 (XXX) XXX-XX-XX
    /// - сайт                 → без http(s)://www.
    /// - соцсети              → @handle
    /// - opening_hours        → локализованные аббревиатуры дней (ru: Mo→Пн и т.д.)
    static func displayValue(forKey key: String, value: String) -> String {
        let k = key.lowercased()

        // Wikipedia: убираем языковой префикс "ru:Название" → "Название"
        if k == "wikipedia" || k.hasSuffix(":wikipedia") {
            if let colonIdx = value.firstIndex(of: ":"),
               value.distance(from: value.startIndex, to: colonIdx) <= 5 {
                return String(value[value.index(after: colonIdx)...])
            }
            return value
        }

        // Тип объекта: amenity, shop, tourism, leisure, office, craft, cuisine
        let typeKeys: Set<String> = ["amenity", "shop", "tourism", "leisure", "office", "craft", "cuisine"]
        if typeKeys.contains(k) {
            return OSMValueLocalizations.label(for: value, key: k)
        }

        // Телефон
        if k == "phone" || k == "contact:phone" || k.hasSuffix(":phone") {
            return formattedPhone(value)
        }

        // Часы работы
        if k == "opening_hours" {
            return localizedOpeningHours(value)
        }

        // Сайт
        if k == "website" || k == "contact:website" {
            return strippedWebURL(value)
        }

        // Соцсети: только URL-значения (содержат "://")
        if k.hasPrefix("contact:") && value.contains("://") {
            return formattedSocial(key: k, urlString: value)
        }

        return value
    }

    /// Форматирует ссылку на соцсеть в зависимости от платформы:
    /// - instagram, telegram, twitter/x, tiktok, facebook → @handle
    /// - youtube → @handle только если URL содержит /@, иначе strippedWebURL
    /// - vk → strippedWebURL (vk.com/company)
    /// - ok.ru → strippedWebURL (нет устоявшегося handle-формата)
    /// - whatsapp → форматированный номер телефона
    /// - прочие → strippedWebURL
    private static func formattedSocial(key: String, urlString: String) -> String {
        // WhatsApp — номер телефона
        if key == "contact:whatsapp" {
            // URL вида https://wa.me/79261234567 или просто номер
            if let url = URL(string: urlString),
               let host = url.host, host.contains("wa.me") {
                let digits = url.pathComponents
                    .filter { $0 != "/" && !$0.isEmpty }
                    .first ?? ""
                return formattedPhone(digits.isEmpty ? urlString : digits)
            }
            return formattedPhone(urlString)
        }

        // ВКонтакте, Одноклассники — показываем домен + путь без схемы
        if key == "contact:vk" || key == "contact:ok" {
            return strippedWebURL(urlString)
        }

        // YouTube — @handle только если в URL есть /@
        if key == "contact:youtube" {
            if urlString.contains("/@") {
                return extractAtHandle(from: urlString) ?? strippedWebURL(urlString)
            }
            return strippedWebURL(urlString)
        }

        // Instagram, Telegram, Twitter/X, TikTok, Facebook — @handle
        let atPlatforms = [
            "instagram.com", "t.me", "telegram.me",
            "twitter.com", "x.com", "tiktok.com", "facebook.com"
        ]
        if atPlatforms.contains(where: { urlString.contains($0) }) {
            return extractAtHandle(from: urlString) ?? strippedWebURL(urlString)
        }

        return strippedWebURL(urlString)
    }

    /// Извлекает @handle из URL: берёт первый значимый path-компонент.
    /// Пропускает служебные сегменты (user, channel, c, p, groups и т.д.).
    private static func extractAtHandle(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let skip = Set(["user", "channel", "c", "p", "groups", "pages", "people"])
        let components = url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
            .drop(while: { skip.contains($0.lowercased()) })
        guard let handle = components.first, !handle.isEmpty else { return nil }
        // Убираем ведущий @ если он уже есть, добавляем ровно один
        let clean = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        return "@\(clean)"
    }

    /// Форматирует российский номер: 79261234567 / 89261234567 → +7 (926) 123-45-67.
    /// Нераспознанные форматы возвращает без изменений.
    private static func formattedPhone(_ raw: String) -> String {
        // Обработка добавочного номера: "ext. 1234" или "ext 1234" → " доб. (1234)"
        var main = raw
        var ext = ""
        let extPattern = /\s*ext\.?\s*(\d+)/
        if let match = raw.firstMatch(of: extPattern) {
            main = String(raw[raw.startIndex..<match.range.lowerBound])
            ext = " доб. (\(match.1))"
        }

        let digits = main.filter(\.isNumber)
        guard digits.count == 11,
              digits.hasPrefix("7") || digits.hasPrefix("8") else { return raw }
        let d = Array("7" + digits.dropFirst())  // 11 цифр, первая всегда '7'
        let area  = String(d[1...3])
        let part1 = String(d[4...6])
        let part2 = String(d[7...8])
        let part3 = String(d[9...10])
        return "+7 (\(area)) \(part1)-\(part2)-\(part3)\(ext)"
    }

    /// Локализует аббревиатуры дней недели в строке opening_hours для русской локали.
    /// Mo→Пн, Tu→Вт, We→Ср, Th→Чт, Fr→Пт, Sa→Сб, Su→Вс.
    /// Для нерусских локалей возвращает оригинал.
    static func localizedOpeningHours(_ value: String) -> String {
        guard AppSettings.shared.language == .ru else { return value }
        // Заменяем двухбуквенные аббревиатуры OSM, не затрагивая числа и время
        let map: [(String, String)] = [
            ("Mo", "Пн"), ("Tu", "Вт"), ("We", "Ср"),
            ("Th", "Чт"), ("Fr", "Пт"), ("Sa", "Сб"), ("Su", "Вс")
        ]
        var result = value
        for (en, ru) in map {
            result = result.replacingOccurrences(of: en, with: ru)
        }
        return result
    }

    /// Убирает https://www., http://www., https://, http:// и финальный слэш.
    private static func strippedWebURL(_ url: String) -> String {
        var s = url
        for prefix in ["https://www.", "http://www.", "https://", "http://"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

}

// MARK: - BooleanTagToggle
/// Трёхпозиционный контрол для boolean-тегов (yes / no / не задано).
/// Использует Toggle: включён = "yes", выключен = "no".
/// Долгий тап на переключатель → сброс в пустое значение (тег удалится).
private struct BooleanTagToggle: View {
    @Binding var value: String

    private var isOn: Bool { value == "yes" }

    var body: some View {
        Toggle(isOn: Binding(
            get: { value == "yes" },
            set: { value = $0 ? "yes" : "no" }
        )) {
            if value.isEmpty {
                Text("Не задано")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Text(value == "yes"
                     ? (AppSettings.shared.language == .ru ? "Да"  : "Yes")
                     : (AppSettings.shared.language == .ru ? "Нет" : "No"))
                    .font(.body)
                    .foregroundStyle(value == "yes" ? .green : .red)
            }
        }
        .onTapGesture { } // нужен чтобы жест не перехватывал List row tap
        .contextMenu {
            Button(AppSettings.shared.language == .ru ? "Сбросить значение" : "Clear value",
                   role: .destructive) { value = "" }
        }
    }
}

// MARK: - SelectTagField
// Кнопка-меню для полей с одиночным выбором (.select)

private struct SelectTagField: View {
    let key: String
    let options: [String]
    /// Готовые переводы из POIField (если есть — используются вместо OSMValueLocalizations)
    let poiOptions: [POIFieldOption]
    @Binding var value: String

    init(key: String, options: [String], value: Binding<String>) {
        self.key = key
        self.options = options
        self.poiOptions = []
        self._value = value
    }

    init(key: String, poiOptions: [POIFieldOption], value: Binding<String>) {
        self.key = key
        self.options = poiOptions.map(\.value)
        self.poiOptions = poiOptions
        self._value = value
    }

    @State private var showCustomAlert = false
    @State private var customDraft = ""

    private func label(for opt: String) -> String {
        if let po = poiOptions.first(where: { $0.value == opt }) { return po.label }
        return OSMValueLocalizations.label(for: opt, key: key)
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button {
                    value = opt
                } label: {
                    if value == opt {
                        Label(label(for: opt), systemImage: "checkmark")
                    } else {
                        Text(label(for: opt))
                    }
                }
            }
            Divider()
            Button("Другое…") {
                customDraft = value
                showCustomAlert = true
            }
        } label: {
            HStack {
                Text(value.isEmpty ? "Выбрать…" : label(for: value))
                    .font(.body)
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Своё значение", isPresented: $showCustomAlert) {
            TextField(key, text: $customDraft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("OK") { value = customDraft.trimmingCharacters(in: .whitespaces) }
            Button("Отмена", role: .cancel) {}
        }
    }
}

// MARK: - MultiSelectTagField
// Кнопка, открывающая лист с множественным выбором (.multiselect)

// MARK: - CheckDateField
/// Поле check_date: DatePicker + кнопка «сегодня».
/// Хранит значение в OSM-формате "yyyy-MM-dd".
private struct CheckDateField: View {
    @Binding var value: String
    @State private var showPicker = false

    private static let osmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var parsedDate: Date {
        Self.osmFormatter.date(from: value) ?? Date()
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showPicker = true
            } label: {
                Text(value.isEmpty ? "Выбрать дату" : (Self.displayFormatter.string(from: parsedDate)))
                    .font(.body)
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            // Кнопка «сегодня»
            Button {
                value = Self.osmFormatter.string(from: Date())
            } label: {
                Image(systemName: "calendar.badge.clock")
                    .font(.body)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                DatePickerSheet(value: $value)
            }
            .presentationDetents([.medium])
        }
    }
}

private struct DatePickerSheet: View {
    @Binding var value: String
    @Environment(\.dismiss) private var dismiss

    private static let osmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    @State private var selected: Date

    init(value: Binding<String>) {
        _value = value
        _selected = State(initialValue: Self.osmFormatter.date(from: value.wrappedValue) ?? Date())
    }

    var body: some View {
        VStack {
            DatePicker("Дата проверки", selection: $selected, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
            Spacer()
        }
        .navigationTitle("Дата проверки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") {
                    value = Self.osmFormatter.string(from: selected)
                    dismiss()
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { dismiss() }
            }
        }
    }
}

private struct MultiSelectTagField: View {
    let key: String
    let options: [String]
    let poiOptions: [POIFieldOption]
    @Binding var value: String

    init(key: String, options: [String], value: Binding<String>) {
        self.key = key; self.options = options; self.poiOptions = []; self._value = value
    }
    init(key: String, poiOptions: [POIFieldOption], value: Binding<String>) {
        self.key = key
        self.options = poiOptions.map(\.value)
        self.poiOptions = poiOptions
        self._value = value
    }

    @State private var showSheet = false

    private func label(for opt: String) -> String {
        if let po = poiOptions.first(where: { $0.value == opt }) { return po.label }
        return OSMValueLocalizations.label(for: opt, key: key)
    }

    var displayText: String {
        if value.isEmpty { return "Выбрать…" }
        let parts = value.split(separator: ";").map {
            label(for: $0.trimmingCharacters(in: .whitespaces))
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button { showSheet = true } label: {
            HStack {
                Text(displayText)
                    .font(.body)
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "list.bullet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showSheet) {
            MultiSelectSheet(key: key, options: options, poiOptions: poiOptions, value: $value)
        }
    }
}

// MARK: - MultiSelectSheet

private struct MultiSelectSheet: View {
    let key: String
    let options: [String]
    let poiOptions: [POIFieldOption]
    @Binding var value: String

    @State private var selected: Set<String> = []
    @State private var customText = ""
    @Environment(\.dismiss) private var dismiss

    private func label(for opt: String) -> String {
        if let po = poiOptions.first(where: { $0.value == opt }) { return po.label }
        return OSMValueLocalizations.label(for: opt, key: key)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(options, id: \.self) { opt in
                        Button {
                            if selected.contains(opt) { selected.remove(opt) }
                            else { selected.insert(opt) }
                        } label: {
                            HStack {
                                Text(label(for: opt))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(opt) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
                Section("Своё значение") {
                    TextField("Введите значение", text: $customText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Выбор значений")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        var all = selected
                        let extra = customText.trimmingCharacters(in: .whitespaces)
                        if !extra.isEmpty { all.insert(extra) }
                        value = all.sorted().joined(separator: ";")
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .onAppear {
            selected = Set(
                value.split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
        }
    }
}

// MARK: - OpeningHoursNavigatorRow

/// Строка-навигатор для opening_hours в edit-режиме.
/// Показывает текущее значение + шеврон; тап открывает полноэкранный редактор.
private struct OpeningHoursNavigatorRow: View {
    @Binding var value: String
    @State private var isEditorPresented = false

    var body: some View {
        HStack(alignment: .top) {
            if value.isEmpty {
                Text("Не задано")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                let parts = OSMTagRow.localizedOpeningHours(value)
                    .split(separator: ";", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(parts, id: \.self) { part in
                        Text(part)
                            .font(.body)
                    }
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
        }
        .contentShape(Rectangle())
        .onTapGesture { isEditorPresented = true }
        .sheet(isPresented: $isEditorPresented) {
            OpeningHoursEditorScreen(value: $value)
        }
    }
}
