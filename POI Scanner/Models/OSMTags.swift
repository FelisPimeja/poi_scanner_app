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
        case name    = "Название"
        case type    = "Тип"
        case brand   = "Бренд"
        case address = "Адрес"
        case hours   = "Часы работы"
        case contact = "Контакты"
        case payment = "Способы оплаты"
        case legal   = "Юридические данные"
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
        .init(key: "leisure",  label: "Тип (leisure)",  hint: "Объект досуга",         wikiURL: "https://wiki.openstreetmap.org/wiki/Key:leisure", group: .type, inputType: .select(OSMTags.leisureValues),  icon: "figure.walk"),
        .init(key: "office",   label: "Тип (office)",   hint: "Тип офиса",             wikiURL: "https://wiki.openstreetmap.org/wiki/Key:office",  group: .type, inputType: .select(OSMTags.officeValues),   icon: "briefcase"),
        .init(key: "craft",    label: "Тип (craft)",    hint: "Тип мастерской",        wikiURL: "https://wiki.openstreetmap.org/wiki/Key:craft",   group: .type, inputType: .select(OSMTags.craftValues),    icon: "wrench.and.screwdriver"),
        .init(key: "cuisine",  label: "Кухня",          hint: "Тип кухни: italian; sushi", wikiURL: "https://wiki.openstreetmap.org/wiki/Key:cuisine", group: .type, inputType: .multiselect(OSMTags.cuisineValues), icon: "fork.knife"),

        // ── Название ─────────────────────────────────────────────────────────
        .init(key: "name",      label: "Название",        hint: "Официальное название объекта", wikiURL: "https://wiki.openstreetmap.org/wiki/Key:name",     group: .name, inputType: .text),
        .init(key: "name:ru",   label: "Название (рус)",  hint: "Название на русском языке",    wikiURL: nil,                                                group: .name, inputType: .text),
        .init(key: "brand",           label: "Бренд",            hint: "Название сети или бренда",      wikiURL: "https://wiki.openstreetmap.org/wiki/Key:brand",           group: .brand, inputType: .text),
        .init(key: "brand:en",        label: "Бренд (англ)",     hint: "Название бренда на английском", wikiURL: nil,                                                       group: .brand, inputType: .text),
        .init(key: "network",         label: "Сеть",             hint: "Название сети объектов",        wikiURL: "https://wiki.openstreetmap.org/wiki/Key:network",          group: .brand, inputType: .text),
        .init(key: "brand:wikidata",  label: "Wikidata (бренд)", hint: "Wikidata-ID бренда",            wikiURL: "https://wiki.openstreetmap.org/wiki/Key:brand:wikidata",  group: .brand, inputType: .text, icon: "link"),
        .init(key: "brand:wikipedia", label: "Wikipedia (бренд)", hint: "Wikipedia-статья бренда",     wikiURL: nil,                                                       group: .brand, inputType: .text, icon: "book"),

        // ── Юридические данные ───────────────────────────────────────────────
        .init(key: "operator",        label: "Юридическое лицо", hint: "Юридическое лицо-оператор",    wikiURL: "https://wiki.openstreetmap.org/wiki/Key:operator",  group: .legal, inputType: .text),
        .init(key: "ref:INN",         label: "ИНН",              hint: "Идентификационный номер налогоплательщика",      wikiURL: nil, group: .legal, inputType: .text),
        .init(key: "ref:OGRN",        label: "ОГРН",             hint: "Основной государственный регистрационный номер", wikiURL: nil, group: .legal, inputType: .text),
        .init(key: "ref:okved",        label: "ОКВЭД",           hint: "Код вида экономической деятельности",            wikiURL: nil, group: .legal, inputType: .text),

        // ── Адрес ─────────────────────────────────────────────────────────────
        .init(key: "addr:country",     label: "Страна",     hint: "Код страны (RU, US…)", wikiURL: nil, group: .address, inputType: .text, icon: "globe"),
        .init(key: "addr:city",        label: "Город",      hint: "Населённый пункт",    wikiURL: nil, group: .address, inputType: .text, icon: "building.columns"),
        .init(key: "addr:suburb",      label: "Район",      hint: "Район города",         wikiURL: nil, group: .address, inputType: .text, icon: "map"),
        .init(key: "addr:street",      label: "Улица",      hint: "Название улицы",      wikiURL: nil, group: .address, inputType: .text, icon: "road.lanes"),
        .init(key: "addr:housenumber", label: "Номер дома", hint: "Номер дома/строения", wikiURL: nil, group: .address, inputType: .text, icon: "house"),
        .init(key: "addr:unit",        label: "Квартира/Офис", hint: "Номер помещения",  wikiURL: nil, group: .address, inputType: .text, icon: "door.right.hand.closed"),
        .init(key: "addr:floor",       label: "Этаж",       hint: "Этаж внутри здания",  wikiURL: nil, group: .address, inputType: .text, icon: "square.stack.3d.up"),
        .init(key: "addr:postcode",    label: "Индекс",     hint: "Почтовый индекс",     wikiURL: nil, group: .address, inputType: .text, icon: "envelope"),
        .init(key: "addr2:street",     label: "Улица (2)",  hint: "Второй адрес — улица", wikiURL: nil, group: .address, inputType: .text, icon: "road.lanes"),
        .init(key: "addr2:housenumber",label: "Дом (2)",    hint: "Второй адрес — дом",  wikiURL: nil, group: .address, inputType: .text, icon: "house"),

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

        // ── Способы оплаты ───────────────────────────────────────────────────
        .init(key: "payment:cash",          label: "Наличные",      hint: "yes / no", wikiURL: nil, group: .payment, inputType: .boolean, icon: "banknote"),
        .init(key: "payment:visa",          label: "Visa",          hint: "yes / no", wikiURL: nil, group: .payment, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:visa_electron", label: "Visa Electron", hint: "yes / no", wikiURL: nil, group: .payment, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:mastercard",    label: "Mastercard",    hint: "yes / no", wikiURL: nil, group: .payment, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:maestro",       label: "Maestro",       hint: "yes / no", wikiURL: nil, group: .payment, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:mir",           label: "Мир",           hint: "yes / no", wikiURL: nil, group: .payment, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:unionpay",      label: "UnionPay",      hint: "yes / no", wikiURL: nil, group: .payment, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:jcb",           label: "JCB",           hint: "yes / no", wikiURL: nil, group: .payment, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:apple_pay",     label: "Apple Pay",     hint: "yes / no", wikiURL: nil, group: .payment, inputType: .boolean, icon: "applepay"),
        .init(key: "payment:google_pay",    label: "Google Pay",    hint: "yes / no", wikiURL: nil, group: .payment, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:samsung_pay",   label: "Samsung Pay",   hint: "yes / no", wikiURL: nil, group: .payment, inputType: .boolean, icon: "creditcard"),
        .init(key: "payment:sbp",           label: "СБП",           hint: "yes / no", wikiURL: nil, group: .payment, inputType: .boolean, icon: "rublesign.arrow.trianglehead.counterclockwise.rotate.90"),

        // ── Прочее ───────────────────────────────────────────────────────────
        .init(key: "level",  label: "Уровень", hint: "Этаж: 0 = первый, -1 = подвал", wikiURL: "https://wiki.openstreetmap.org/wiki/Key:level",  group: .other, inputType: .level,                              icon: "square.stack.3d.up"),
        .init(key: "indoor", label: "Indoor",  hint: "Тип indoor объекта",            wikiURL: "https://wiki.openstreetmap.org/wiki/Key:indoor", group: .other, inputType: .select(["yes", "room", "corridor", "area"]), icon: "building"),

        // ── Служебные (только отображение, не редактируются) ─────────────────
        .init(key: "type",    label: "Тип геометрии", hint: "", group: .other, inputType: .text, icon: "cube"),
        .init(key: "id",      label: "OSM ID",        hint: "", group: .other, inputType: .text, icon: "number"),
        .init(key: "version", label: "Версия",        hint: "", group: .other, inputType: .text, icon: "clock.arrow.2.circlepath"),
        .init(key: "lat",     label: "Широта",        hint: "", group: .other, inputType: .text, icon: "location"),
        .init(key: "lon",     label: "Долгота",       hint: "", group: .other, inputType: .text, icon: "location"),
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

    /// Ключи, считающиеся «именем» объекта и объединяемые в сворачиваемую группу «Название».
    /// Порядок важен: первый найденный в тегах объекта используется как заголовок группы.
    static let nameKeys: [String] = [
        "name", "name:ru", "name:en", "name:de", "name:fr", "name:es",
        "name:zh", "name:ar", "name:ja", "name:ko",
        "int_name", "official_name", "official_name:ru", "official_name:en",
        "full_name", "alt_name", "old_name",
        "short_name", "loc_name", "reg_name", "nat_name",
        "name:left", "name:right",
    ]

    /// Возвращает true, если ключ относится к «имени» объекта —
    /// либо входит в nameKeys, либо начинается с "name:" или "official_name:".
    static func isNameKey(_ key: String) -> Bool {
        key.hasPrefix("name:") || key.hasPrefix("official_name:") || nameKeys.contains(key)
    }

    /// Ключи, попадающие в группу «Бренд».
    /// Приоритет отображения: brand → operator → network → brand:* прочие.
    static let brandPrimaryKeys: [String] = ["brand", "operator", "network"]

    static func isBrandKey(_ key: String) -> Bool {
        key == "brand" || key.hasPrefix("brand:") || key == "network" || key == "branch"
    }

    /// Ключи группы «Юридические данные».
    /// Приоритет: operator → ref:* → прочие.
    static let legalPrimaryKeys: [String] = ["operator"]

    static func isLegalKey(_ key: String) -> Bool {
        key == "operator" || key.hasPrefix("ref:")
    }

    /// Возвращает true, если ключ относится к способам оплаты.
    static func isPaymentKey(_ key: String) -> Bool {
        key.hasPrefix("payment:")
    }

    /// Возвращает true, если ключ относится к контактным данным.
    /// Охватывает все contact:* ключи, а также phone, website, email.
    static func isContactKey(_ key: String) -> Bool {
        key.hasPrefix("contact:") || key == "phone" || key == "website" || key == "email"
    }

    /// Возвращает true, если ключ относится к адресу объекта.
    /// Охватывает addr:* и addr2:* (второй вход/адрес).
    static func isAddressKey(_ key: String) -> Bool {
        key.hasPrefix("addr:") || key.hasPrefix("addr2:")
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

    static let leisureValues: [String] = [
        "fitness_centre", "swimming_pool", "sports_centre", "stadium",
        "pitch", "track", "golf_course",
        "park", "garden", "playground", "dog_park",
        "marina", "slipway",
        "cinema", "dance", "bowling_alley", "escape_game",
        "amusement_arcade", "sauna", "spa", "hackerspace"
    ]

    static let officeValues: [String] = [
        "company", "government", "ngo", "association",
        "lawyer", "accountant", "financial", "insurance",
        "it", "consulting", "estate_agent", "architect",
        "employment_agency", "travel_agent",
        "educational_institution", "research",
        "physician", "therapist", "notary"
    ]

    static let craftValues: [String] = [
        "carpenter", "plumber", "electrician", "painter",
        "tailor", "shoemaker", "jeweller", "watchmaker",
        "photographer", "printer", "bookbinder",
        "car_repair", "electronics_repair", "hvac",
        "bakery", "confectionery", "brewery", "distillery",
        "metal_construction", "stonemason", "tiler"
    ]

    static let cuisineValues: [String] = [
        "russian", "european", "italian", "pizza", "pasta",
        "french", "spanish", "greek", "turkish",
        "japanese", "sushi", "chinese", "korean", "thai", "vietnamese", "asian",
        "indian", "georgian", "armenian", "azerbaijani", "uzbek", "caucasian",
        "american", "burger", "steak", "barbecue",
        "mexican", "lebanese", "arab",
        "seafood", "fish_and_chips",
        "vegetarian", "vegan",
        "coffee_shop", "tea", "ice_cream", "cake", "donut",
        "sandwich", "noodle", "hotdog", "kebab", "shawarma",
        "fast_food", "international", "regional"
    ]
}
