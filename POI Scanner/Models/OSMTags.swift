import Foundation

// MARK: - OSM Tag Definitions
// Справочник известных OSM тегов с метаданными для редактора

struct OSMTagDefinition {
    let key: String
    let label: String           // Человекочитаемое название
    let hint: String            // Подсказка для пользователя
    let wikiURL: String?        // Ссылка на OSM Wiki
    let group: TagGroup
    let inputType: InputType
    let icon: String?           // SF Symbol для строки тега (nil = только кружок-статус)

    init(key: String, label: String, hint: String,
         wikiURL: String? = nil,
         group: TagGroup,
         inputType: InputType,
         icon: String? = nil) {
        self.key       = key
        self.label     = label
        self.hint      = hint
        self.wikiURL   = wikiURL
        self.group     = group
        self.inputType = inputType
        self.icon      = icon
    }

    enum InputType {
        case text
        case phone
        case url
        case openingHours
        case select([String])
        case multiselect([String])
        case level
        case boolean
    }

    /// Порядок совпадает с порядком секций в tagListSection.
    enum TagGroup: String, CaseIterable {
        case type    = "Тип"
        case name    = "Название"
        case address = "Адрес"
        case hours   = "Часы работы"
        case contact = "Контакты"
        case wiki    = "Wiki"
        case other   = "Прочее"
    }
}

// MARK: - Tag Catalog

enum OSMTags {

    // MARK: Все определения

    static let all: [OSMTagDefinition] = [

        // ── Тип ──────────────────────────────────────────────────────────────
        .init(key: "amenity",  label: "Тип (amenity)",  hint: "Категория объекта",    wikiURL: "https://wiki.openstreetmap.org/wiki/Key:amenity", group: .type, inputType: .select(OSMTags.amenityValues), icon: "tag"),
        .init(key: "shop",     label: "Тип (shop)",     hint: "Тип магазина",          wikiURL: "https://wiki.openstreetmap.org/wiki/Key:shop",    group: .type, inputType: .select(OSMTags.shopValues),   icon: "cart"),
        .init(key: "tourism",  label: "Тип (tourism)",  hint: "Туристический объект",  wikiURL: "https://wiki.openstreetmap.org/wiki/Key:tourism", group: .type, inputType: .select(OSMTags.tourismValues), icon: "mappin"),
        .init(key: "leisure",  label: "Тип (leisure)",  hint: "Объект досуга",         wikiURL: "https://wiki.openstreetmap.org/wiki/Key:leisure", group: .type, inputType: .text,                          icon: "figure.walk"),
        .init(key: "office",   label: "Тип (office)",   hint: "Тип офиса",             wikiURL: "https://wiki.openstreetmap.org/wiki/Key:office",  group: .type, inputType: .text,                          icon: "briefcase"),
        .init(key: "cuisine",  label: "Кухня",          hint: "Тип кухни: italian; sushi", wikiURL: "https://wiki.openstreetmap.org/wiki/Key:cuisine", group: .type, inputType: .text,                     icon: "fork.knife"),

        // ── Название ─────────────────────────────────────────────────────────
        .init(key: "name",      label: "Название",        hint: "Официальное название объекта", wikiURL: "https://wiki.openstreetmap.org/wiki/Key:name",     group: .name, inputType: .text),
        .init(key: "name:ru",   label: "Название (рус)",  hint: "Название на русском языке",    wikiURL: nil,                                                group: .name, inputType: .text),
        .init(key: "brand",     label: "Бренд",           hint: "Название сети или бренда",     wikiURL: "https://wiki.openstreetmap.org/wiki/Key:brand",    group: .name, inputType: .text),
        .init(key: "operator",  label: "Оператор",        hint: "Юридическое лицо-оператор",    wikiURL: "https://wiki.openstreetmap.org/wiki/Key:operator", group: .name, inputType: .text),

        // ── Адрес ─────────────────────────────────────────────────────────────
        .init(key: "addr:city",        label: "Город",      hint: "Населённый пункт",    wikiURL: nil, group: .address, inputType: .text, icon: "building.columns"),
        .init(key: "addr:street",      label: "Улица",      hint: "Название улицы",      wikiURL: nil, group: .address, inputType: .text, icon: "road.lanes"),
        .init(key: "addr:housenumber", label: "Номер дома", hint: "Номер дома/строения", wikiURL: nil, group: .address, inputType: .text, icon: "house"),
        .init(key: "addr:floor",       label: "Этаж",       hint: "Этаж внутри здания",  wikiURL: nil, group: .address, inputType: .text, icon: "square.stack.3d.up"),
        .init(key: "addr:postcode",    label: "Индекс",     hint: "Почтовый индекс",     wikiURL: nil, group: .address, inputType: .text, icon: "envelope"),

        // ── Часы работы ──────────────────────────────────────────────────────
        .init(key: "opening_hours", label: "Часы работы", hint: "Формат OSM: Mo-Fr 09:00-18:00", wikiURL: "https://wiki.openstreetmap.org/wiki/Key:opening_hours", group: .hours, inputType: .openingHours, icon: "clock"),

        // ── Контакты ─────────────────────────────────────────────────────────
        .init(key: "phone",           label: "Телефон",  hint: "Формат: +7 XXX XXX-XX-XX",     wikiURL: "https://wiki.openstreetmap.org/wiki/Key:phone",   group: .contact, inputType: .phone, icon: "phone"),
        .init(key: "contact:phone",   label: "Телефон",  hint: "Формат: +7 XXX XXX-XX-XX",     wikiURL: nil,                                               group: .contact, inputType: .phone, icon: "phone"),
        .init(key: "website",         label: "Сайт",     hint: "Полный URL включая https://",   wikiURL: "https://wiki.openstreetmap.org/wiki/Key:website", group: .contact, inputType: .url,   icon: "globe"),
        .init(key: "contact:website", label: "Сайт",     hint: "Полный URL включая https://",   wikiURL: nil,                                               group: .contact, inputType: .url,   icon: "globe"),
        .init(key: "email",           label: "Email",    hint: "Электронная почта",             wikiURL: "https://wiki.openstreetmap.org/wiki/Key:email",   group: .contact, inputType: .text,  icon: "envelope.fill"),
        .init(key: "contact:email",   label: "Email",    hint: "Электронная почта",             wikiURL: nil,                                               group: .contact, inputType: .text,  icon: "envelope.fill"),

        .init(key: "contact:vk",        label: "ВКонтакте",     hint: "URL страницы VK",           wikiURL: nil, group: .contact, inputType: .url,   icon: "person.2"),
        .init(key: "contact:instagram",  label: "Instagram",    hint: "URL профиля Instagram",     wikiURL: nil, group: .contact, inputType: .url,   icon: "camera"),
        .init(key: "contact:telegram",   label: "Telegram",     hint: "URL или @username",         wikiURL: nil, group: .contact, inputType: .url,   icon: "paperplane"),
        .init(key: "contact:youtube",    label: "YouTube",      hint: "URL канала",                wikiURL: nil, group: .contact, inputType: .url,   icon: "play.rectangle"),
        .init(key: "contact:facebook",   label: "Facebook",     hint: "URL страницы Facebook",     wikiURL: nil, group: .contact, inputType: .url,   icon: "person.crop.square"),
        .init(key: "contact:tiktok",     label: "TikTok",       hint: "URL профиля TikTok",        wikiURL: nil, group: .contact, inputType: .url,   icon: "music.note"),
        .init(key: "contact:ok",         label: "Одноклассники", hint: "URL профиля OK.ru",        wikiURL: nil, group: .contact, inputType: .url,   icon: "person.2.circle"),
        .init(key: "contact:whatsapp",   label: "WhatsApp",     hint: "Номер телефона WhatsApp",   wikiURL: nil, group: .contact, inputType: .phone, icon: "message"),
        .init(key: "contact:twitter",    label: "Twitter / X",  hint: "URL профиля или @username",  wikiURL: nil, group: .contact, inputType: .url,   icon: "at"),

        // ── Wiki ─────────────────────────────────────────────────────────────
        .init(key: "wikipedia",       label: "Wikipedia",       hint: "Формат: ru:Название статьи", wikiURL: "https://wiki.openstreetmap.org/wiki/Key:wikipedia",       group: .wiki, inputType: .text, icon: "book"),
        .init(key: "wikidata",        label: "Wikidata",        hint: "Формат: Q12345",             wikiURL: "https://wiki.openstreetmap.org/wiki/Key:wikidata",        group: .wiki, inputType: .text, icon: "link"),
        .init(key: "brand:wikidata",  label: "Wikidata (бренд)", hint: "Wikidata-ID бренда",       wikiURL: "https://wiki.openstreetmap.org/wiki/Key:brand:wikidata",  group: .wiki, inputType: .text, icon: "link"),
        .init(key: "brand:wikipedia", label: "Wikipedia (бренд)", hint: "Wikipedia-статья бренда", wikiURL: nil,                                                       group: .wiki, inputType: .text, icon: "book"),

        // ── Прочее ───────────────────────────────────────────────────────────
        .init(key: "level",  label: "Уровень", hint: "Этаж: 0 = первый, -1 = подвал", wikiURL: "https://wiki.openstreetmap.org/wiki/Key:level",  group: .other, inputType: .level,                              icon: "square.stack.3d.up"),
        .init(key: "indoor", label: "Indoor",  hint: "Тип indoor объекта",            wikiURL: "https://wiki.openstreetmap.org/wiki/Key:indoor", group: .other, inputType: .select(["yes", "room", "corridor", "area"]), icon: "building"),

        .init(key: "payment:cash",          label: "Наличные",      hint: "yes / no", wikiURL: nil, group: .other, inputType: .boolean, icon: "banknote"),
        .init(key: "payment:visa",          label: "Visa",          hint: "yes / no", wikiURL: nil, group: .other, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:visa_electron", label: "Visa Electron", hint: "yes / no", wikiURL: nil, group: .other, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:mastercard",    label: "Mastercard",    hint: "yes / no", wikiURL: nil, group: .other, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:maestro",       label: "Maestro",       hint: "yes / no", wikiURL: nil, group: .other, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:mir",           label: "Мир",           hint: "yes / no", wikiURL: nil, group: .other, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:unionpay",      label: "UnionPay",      hint: "yes / no", wikiURL: nil, group: .other, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:jcb",           label: "JCB",           hint: "yes / no", wikiURL: nil, group: .other, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:apple_pay",     label: "Apple Pay",     hint: "yes / no", wikiURL: nil, group: .other, inputType: .boolean, icon: "applepay"),
        .init(key: "payment:google_pay",    label: "Google Pay",    hint: "yes / no", wikiURL: nil, group: .other, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:samsung_pay",   label: "Samsung Pay",   hint: "yes / no", wikiURL: nil, group: .other, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:sbp",           label: "СБП",           hint: "yes / no", wikiURL: nil, group: .other, inputType: .boolean, icon: "rublesign.arrow.trianglehead.counterclockwise.rotate.90"),

        .init(key: "ref:INN",  label: "ИНН",  hint: "Идентификационный номер налогоплательщика",      wikiURL: nil, group: .other, inputType: .text),
        .init(key: "ref:OGRN", label: "ОГРН", hint: "Основной государственный регистрационный номер", wikiURL: nil, group: .other, inputType: .text),
    ]

    // MARK: Быстрый доступ по ключу

    static let byKey: [String: OSMTagDefinition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.key, $0) }
    )

    static func definition(for key: String) -> OSMTagDefinition? {
        byKey[key]
    }

    static func tags(in group: OSMTagDefinition.TagGroup) -> [OSMTagDefinition] {
        all.filter { $0.group == group }
    }

    // MARK: Значения для select-полей

    static let amenityValues: [String] = [
        "restaurant", "cafe", "fast_food", "bar", "pub", "food_court",
        "bank", "atm", "pharmacy", "hospital", "clinic", "dentist",
        "school", "university", "library",
        "fuel", "parking", "car_wash",
        "post_office", "police", "fire_station",
        "cinema", "theatre", "gym", "spa",
        "toilets", "shelter"
    ]

    static let shopValues: [String] = [
        "supermarket", "convenience", "bakery", "butcher", "greengrocer",
        "clothes", "shoes", "electronics", "mobile_phone", "computer",
        "hardware", "furniture", "florist", "gift",
        "hairdresser", "beauty", "optician",
        "books", "stationery", "sports",
        "dry_cleaning", "laundry",
        "travel_agency", "photo"
    ]

    static let tourismValues: [String] = [
        "hotel", "hostel", "motel", "guest_house", "apartment",
        "attraction", "museum", "gallery", "viewpoint",
        "information", "tourism"
    ]
}
