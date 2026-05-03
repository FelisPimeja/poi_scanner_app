import Foundation

// MARK: - OSMValueLocalizations
// Словари переводов OSM-значений на русский язык.
// Ключ — OSM-значение (английское), значение — перевод для отображения.
// Хранение и выгрузка в OSM всегда используют оригинальные английские значения.

enum OSMValueLocalizations {

    // MARK: Lookup

    /// Возвращает локализованное название OSM-значения для заданного ключа.
    /// Если перевода нет — возвращает само значение.
    static func label(for value: String, key: String) -> String {
        guard AppSettings.shared.language == .ru else { return value }
        let dict = dictionary(for: key)
        if let found = dict[value] { return found }
        // Fallback: для multiCombo-полей ищем суффикс в options POIFieldRegistry.
        // Например: key = "fuel:diesel" → parentField = fuel:, suffix = "diesel"
        if let (parentField, suffix) = POIFieldRegistry.shared.field(forSubKey: key),
           suffix == value,
           let opt = parentField.options.first(where: { $0.value == value }) {
            return opt.label
        }
        // Или: key уже является prefix (например "fuel:"), value — суффикс
        if let field = POIFieldRegistry.shared.field(forOSMKey: key.hasSuffix(":") ? key : key + ":"),
           let opt = field.options.first(where: { $0.value == value }) {
            return opt.label
        }
        return value
    }

    /// Возвращает словарь переводов для данного ключа (или пустой если ключ неизвестен).
    static func dictionary(for key: String) -> [String: String] {
        switch key {
        case "amenity":                     return amenity
        case "shop":                        return shop
        case "tourism":                     return tourism
        case "leisure":                     return leisure
        case "office":                      return office
        case "craft":                       return craft
        case "cuisine":                     return cuisine
        case "building", "building:part":      return building
        case "building:material":              return buildingMaterial
        case "building:architecture":          return buildingArchitecture
        case "roof:shape":                     return roofShape
        case "roof:material":                  return roofMaterial
        default:
            // Для multiCombo-подключей (fuel:diesel, payment:visa…) — строим словарь из options
            // родительского поля через keyPrefix-индекс реестра.
            if let (parentField, _) = POIFieldRegistry.shared.field(forSubKey: key),
               !parentField.options.isEmpty {
                return Dictionary(uniqueKeysWithValues: parentField.options.map { ($0.value, $0.label) })
            }
            // Для ключей с trailing-colon (fuel:, payment:) — ищем напрямую.
            let prefix = key.hasSuffix(":") ? key : key + ":"
            if let field = POIFieldRegistry.shared.field(forOSMKey: prefix),
               !field.options.isEmpty {
                return Dictionary(uniqueKeysWithValues: field.options.map { ($0.value, $0.label) })
            }
            return [:]
        }
    }

    // MARK: - amenity

    static let amenity: [String: String] = [
        // Общественное питание
        "restaurant":           "Ресторан",
        "cafe":                 "Кафе",
        "fast_food":            "Фастфуд",
        "bar":                  "Бар",
        "pub":                  "Паб",
        "biergarten":           "Пивной сад",
        "food_court":           "Фудкорт",
        "ice_cream":            "Мороженое",

        // Образование
        "school":               "Школа",
        "university":           "Университет",
        "college":              "Колледж",
        "kindergarten":         "Детский сад",
        "library":              "Библиотека",
        "driving_school":       "Автошкола",
        "language_school":      "Языковая школа",
        "music_school":         "Музыкальная школа",
        "dancing_school":       "Школа танцев",
        "surf_school":          "Школа сёрфинга",
        "first_aid_school":     "Курсы первой помощи",
        "toy_library":          "Библиотека игрушек",
        "traffic_park":         "Детский автогородок",
        "research_institute":   "НИИ",
        "training":             "Учебный центр",

        // Транспорт
        "parking":              "Парковка",
        "parking_entrance":     "Въезд на парковку",
        "parking_space":        "Парковочное место",
        "motorcycle_parking":   "Мотопарковка",
        "bicycle_parking":      "Велопарковка",
        "bicycle_rental":       "Прокат велосипедов",
        "bicycle_repair_station": "Велоремонт (самообслуживание)",
        "bicycle_wash":         "Мойка велосипедов",
        "car_rental":           "Прокат автомобилей",
        "car_sharing":          "Каршеринг",
        "car_wash":             "Автомойка",
        "fuel":                 "АЗС",
        "charging_station":     "Зарядка ЭВ",
        "vehicle_inspection":   "Технический осмотр",
        "compressed_air":       "Насос для шин",
        "bus_station":          "Автовокзал",
        "ferry_terminal":       "Паромный терминал",
        "taxi":                 "Стоянка такси",
        "boat_rental":          "Прокат лодок",
        "boat_sharing":         "Шеринг лодок",
        "boat_storage":         "Хранение лодок",
        "driver_training":      "Автодром",
        "grit_bin":             "Ящик с песком",
        "weighbridge":          "Весовой контроль",

        // Финансы
        "bank":                 "Банк",
        "atm":                  "Банкомат",
        "bureau_de_change":     "Обмен валюты",
        "money_transfer":       "Денежные переводы",
        "payment_centre":       "Центр оплаты",
        "payment_terminal":     "Платёжный терминал",

        // Здоровье
        "pharmacy":             "Аптека",
        "hospital":             "Больница",
        "clinic":               "Клиника",
        "doctors":              "Кабинет врача",
        "dentist":              "Стоматология",
        "veterinary":           "Ветеринар",
        "social_facility":      "Соцучреждение",
        "nursing_home":         "Дом престарелых",
        "baby_hatch":           "Беби-бокс",

        // Развлечения, искусство и культура
        "cinema":               "Кинотеатр",
        "theatre":              "Театр",
        "nightclub":            "Ночной клуб",
        "casino":               "Казино",
        "gambling":             "Игровой зал",
        "arts_centre":          "Центр искусств",
        "community_centre":     "Дом культуры",
        "conference_centre":    "Конференц-центр",
        "events_venue":         "Ивент-площадка",
        "exhibition_centre":    "Выставочный центр",
        "music_venue":          "Концертная площадка",
        "planetarium":          "Планетарий",
        "studio":               "Студия",
        "social_centre":        "Социальный центр",
        "stage":                "Сцена",
        "fountain":             "Фонтан",
        "public_bookcase":      "Книжный обмен",
        "stripclub":            "Стрип-клуб",
        "brothel":              "Публичный дом",
        "swingerclub":          "Свингер-клуб",
        "love_hotel":           "Любовный отель",

        // Общественная служба
        "police":               "Полиция",
        "fire_station":         "Пожарная часть",
        "post_office":          "Почта",
        "post_box":             "Почтовый ящик",
        "post_depot":           "Почтовый сортировочный центр",
        "courthouse":           "Суд",
        "prison":               "Тюрьма",
        "townhall":             "Администрация",
        "ranger_station":       "Станция рейнджеров",

        // Благоустройство
        "toilets":              "Туалет",
        "shelter":              "Укрытие",
        "bench":                "Скамейка",
        "drinking_water":       "Питьевая вода",
        "water_point":          "Точка водозабора",
        "shower":               "Душ",
        "telephone":            "Таксофон",
        "bbq":                  "Барбекю",
        "parcel_locker":        "Постамат",
        "lounge":               "Бизнес-зал",
        "dressing_room":        "Раздевалка",
        "dog_toilet":           "Туалет для собак",
        "give_box":             "Коробка даров",
        "mailroom":             "Почтовая комната",
        "watering_place":       "Водопой",

        // Переработка отходов
        "recycling":            "Пункт приёма вторсырья",
        "waste_basket":         "Урна",
        "waste_disposal":       "Мусорный бак",
        "waste_transfer_station": "Мусороперегрузочная станция",
        "sanitary_dump_station": "Слив канализации",

        // Другое
        "marketplace":          "Рынок",
        "vending_machine":      "Торговый автомат",
        "internet_cafe":        "Интернет-кафе",
        "place_of_worship":     "Храм",
        "monastery":            "Монастырь",
        "grave_yard":           "Кладбище",
        "crematorium":          "Крематорий",
        "funeral_hall":         "Траурный зал",
        "mortuary":             "Морг",
        "dive_centre":          "Дайвинг-центр",
        "public_bath":          "Баня",
        "photo_booth":          "Фотоавтомат",
        "clock":                "Уличные часы",
        "kitchen":              "Общественная кухня",
        "hunting_stand":        "Охотничья вышка",
        "animal_boarding":      "Гостиница для животных",
        "animal_breeding":      "Питомник",
        "animal_shelter":       "Приют для животных",
        "animal_training":      "Дрессировка животных",
        "refugee_site":         "Лагерь беженцев",
        "spa":                  "СПА",
        "gym":                  "Спортзал",
    ]

    // MARK: - shop

    static let shop: [String: String] = [
        // Продовольственные
        "supermarket":      "Супермаркет",
        "convenience":      "Продукты",
        "bakery":           "Пекарня",
        "butcher":          "Мясная лавка",
        "greengrocer":      "Овощи и фрукты",
        "dairy":            "Молочные продукты",
        "seafood":          "Морепродукты",
        "deli":             "Деликатесы",
        "cheese":           "Сыр",
        "chocolate":        "Шоколад",
        "confectionery":    "Кондитерская",
        "pastry":           "Выпечка",
        "pasta":            "Макаронные изделия",
        "spices":           "Специи",
        "nuts":             "Орехи и сухофрукты",
        "health_food":      "Здоровое питание",
        "frozen_food":      "Замороженные продукты",
        "farm":             "Фермерский магазин",
        "ice_cream":        "Мороженое",
        "coffee":           "Кофейный магазин",
        "tea":              "Чайный магазин",
        "wine":             "Вино",
        "alcohol":          "Алкоголь",
        "beverages":        "Напитки",
        "water":            "Питьевая вода",

        // Универсальные магазины
        "mall":             "Торговый центр",
        "department_store": "Универмаг",
        "wholesale":        "Оптовый магазин",
        "general":          "Хозяйственный магазин",
        "kiosk":            "Киоск",
        "variety_store":    "Магазин фикс.цены",

        // Одежда, обувь и аксессуары
        "clothes":          "Одежда",
        "shoes":            "Обувь",
        "shoe_repair":      "Ремонт обуви",
        "boutique":         "Бутик",
        "fashion":          "Модная одежда",
        "fashion_accessories": "Модные аксессуары",
        "jewelry":          "Ювелирный магазин",
        "watches":          "Часы",
        "bag":              "Сумки",
        "leather":          "Кожаные изделия",
        "fabric":           "Ткани",
        "sewing":           "Товары для шитья",
        "wool":             "Пряжа",
        "baby_goods":       "Детские товары",

        // Эконом, секонд-хенд
        "second_hand":      "Секонд-хенд",
        "charity":          "Благотворительный магазин",

        // Красота, здоровье
        "hairdresser":      "Парикмахерская",
        "beauty":           "Салон красоты",
        "cosmetics":        "Косметика",
        "chemist":          "Бытовая химия",
        "optician":         "Оптика",
        "perfumery":        "Парфюмерия",
        "massage":          "Массажный салон",
        "tattoo":           "Тату-салон",
        "piercing":         "Пирсинг",
        "medical_supply":   "Медтехника",
        "hearing_aids":     "Слуховые аппараты",
        "herbalist":        "Травы и фитотерапия",
        "nutrition_supplements": "Спортивное питание",
        "hairdresser_supply": "Товары для волос",
        "erotic":           "Интим-товары",

        // Хозтовары, строительство, сад
        "hardware":         "Хозтовары",
        "doityourself":     "Строительный магазин",
        "electrical":       "Электротовары",
        "florist":          "Цветочный магазин",
        "garden_centre":    "Садовый центр",
        "garden_furniture": "Садовая мебель",
        "paint":            "Краски",
        "glaziery":         "Стекло и остекление",
        "locksmith":        "Ключи и замки",
        "gas":              "Газовые баллоны",
        "appliance":        "Бытовая техника",
        "bathroom_furnishing": "Сантехника",
        "houseware":        "Посуда и товары для дома",
        "fireplace":        "Камины и печи",
        "agrarian":         "Агромагазин",
        "energy":           "Накопители энергии",
        "security":         "Системы безопасности",
        "tool_hire":        "Прокат инструментов",
        "trade":            "Оптовый склад",

        // Мебель и интерьер
        "furniture":        "Мебель",
        "kitchen":          "Кухонная студия",
        "bed":              "Кровати и матрасы",
        "carpet":           "Ковры",
        "curtain":          "Шторы",
        "flooring":         "Напольные покрытия",
        "tiles":            "Плитка",
        "doors":            "Двери",
        "lighting":         "Светильники",
        "interior_decoration": "Декор интерьера",
        "antiques":         "Антиквариат",
        "candles":          "Свечи",
        "window_blind":     "Жалюзи",

        // Электроника
        "electronics":      "Электроника",
        "mobile_phone":     "Мобильные телефоны",
        "computer":         "Компьютеры",
        "hifi":             "Hi-Fi аудиотехника",
        "vacuum_cleaner":   "Пылесосы",
        "radiotechnics":    "Радиодетали",
        "printer_ink":      "Картриджи и чернила",
        "telecommunication": "Телекоммуникации",

        // Спорт, транспорт
        "sports":           "Спортивные товары",
        "outdoor":          "Туристическое снаряжение",
        "bicycle":          "Велосипеды",
        "car":              "Автосалон",
        "car_parts":        "Автозапчасти",
        "car_repair":       "Автосервис",
        "motorcycle":       "Мотоциклы",
        "motorcycle_repair": "Ремонт мотоциклов",
        "tyres":            "Шины",
        "fishing":          "Рыболовные товары",
        "hunting":          "Охотничий магазин",
        "ski":              "Лыжи и сноуборд",
        "scuba_diving":     "Дайвинг-снаряжение",
        "surf":             "Сёрфинг",
        "golf":             "Гольф-товары",
        "swimming_pool":    "Бассейны и СПА",
        "boat":             "Лодки",
        "atv":              "Квадроциклы",
        "scooter":          "Скутеры",
        "snowmobile":       "Снегоходы",
        "trailer":          "Прицепы",
        "truck":            "Грузовики",
        "caravan":          "Кемперы",
        "military_surplus": "Военный секонд-хенд",
        "fuel":             "Топливо",

        // Художественные, музыкальные
        "art":              "Галерея / арт-магазин",
        "music":            "Музыка (CD/винил)",
        "musical_instrument": "Музыкальные инструменты",
        "camera":           "Фотоаппараты",
        "photo":            "Фотоуслуги",
        "craft":            "Творчество и рукоделие",
        "games":            "Настольные игры",
        "video_games":      "Видеоигры",
        "video":            "Видеопрокат",
        "model":            "Сборные модели",
        "frame":            "Рамки и багет",
        "collector":        "Коллекционные товары",
        "anime":            "Аниме",

        // Книги, канцтовары
        "books":            "Книги",
        "stationery":       "Канцтовары",
        "newsagent":        "Пресса и табак",
        "gift":             "Подарки",
        "ticket":           "Билеты",
        "lottery":          "Лотерейные билеты",

        // Прочие услуги
        "dry_cleaning":     "Химчистка",
        "laundry":          "Прачечная",
        "travel_agency":    "Турагентство",
        "copyshop":         "Копировальный центр",
        "outpost":          "Пункт выдачи заказов",
        "pawnbroker":       "Ломбард",
        "money_lender":     "Микрозаймы",
        "funeral_directors": "Ритуальные услуги",
        "pet":              "Зоомагазин",
        "pet_grooming":     "Груминг",
        "toys":             "Игрушки",
        "tobacco":          "Табак",
        "e-cigarette":      "Электронные сигареты",
        "cannabis":         "Конопля (легальная)",
        "pyrotechnics":     "Пиротехника",
        "weapons":          "Оружие",
        "religion":         "Религиозные товары",
        "party":            "Товары для праздника",
        "bookmaker":        "Букмекерская контора",
        "rental":           "Прокат",
        "storage_rental":   "Аренда склада/бокса",
    ]

    // MARK: - tourism

    static let tourism: [String: String] = [
        "hotel":        "Гостиница",
        "hostel":       "Хостел",
        "motel":        "Мотель",
        "guest_house":  "Гостевой дом",
        "apartment":    "Апартаменты",
        "attraction":   "Достопримечательность",
        "museum":       "Музей",
        "gallery":      "Галерея",
        "viewpoint":    "Смотровая площадка",
        "information":  "Информационный пункт",
        "tourism":      "Туризм",
    ]

    // MARK: - leisure

    static let leisure: [String: String] = [
        "fitness_centre":  "Фитнес-центр",
        "swimming_pool":   "Бассейн",
        "sports_centre":   "Спортивный центр",
        "stadium":         "Стадион",
        "pitch":           "Спортивная площадка",
        "track":           "Трек",
        "golf_course":     "Гольф-клуб",
        "park":            "Парк",
        "garden":          "Сад",
        "playground":      "Детская площадка",
        "dog_park":        "Площадка для собак",
        "marina":          "Марина",
        "slipway":         "Слип",
        "cinema":          "Кинотеатр",
        "dance":           "Танцевальная студия",
        "bowling_alley":   "Боулинг",
        "escape_game":     "Квест-комната",
        "amusement_arcade":"Игровые автоматы",
        "sauna":           "Сауна",
        "spa":             "Спа",
        "hackerspace":     "Хакерспейс",
    ]

    // MARK: - office

    static let office: [String: String] = [
        "company":               "Компания",
        "government":            "Государственное учреждение",
        "ngo":                   "НКО",
        "association":           "Ассоциация",
        "lawyer":                "Юридическая фирма",
        "accountant":            "Бухгалтерия",
        "financial":             "Финансы",
        "insurance":             "Страховая",
        "it":                    "IT-компания",
        "consulting":            "Консалтинг",
        "estate_agent":          "Агентство недвижимости",
        "architect":             "Архитектурное бюро",
        "employment_agency":     "Кадровое агентство",
        "travel_agent":          "Турагентство",
        "educational_institution":"Учебное заведение",
        "research":              "Научная организация",
        "physician":             "Медицинский кабинет",
        "therapist":             "Кабинет психолога",
        "notary":                "Нотариус",
    ]

    // MARK: - craft

    static let craft: [String: String] = [
        "carpenter":           "Столярная мастерская",
        "plumber":             "Сантехник",
        "electrician":         "Электрик",
        "painter":             "Маляр",
        "tailor":              "Ателье",
        "shoemaker":           "Сапожная мастерская",
        "jeweller":            "Ювелирная мастерская",
        "watchmaker":          "Часовая мастерская",
        "photographer":        "Фотограф",
        "printer":             "Типография",
        "bookbinder":          "Переплётная мастерская",
        "car_repair":          "Автосервис",
        "electronics_repair":  "Ремонт электроники",
        "hvac":                "Климатическое оборудование",
        "bakery":              "Пекарня",
        "confectionery":       "Кондитерская",
        "brewery":             "Пивоварня",
        "distillery":          "Дистиллерия",
        "metal_construction":  "Металлоконструкции",
        "stonemason":          "Каменотёс",
        "tiler":               "Плиточник",
    ]

    // MARK: - cuisine
    // Стиль: национальные кухни — прилагательное («Итальянская»),
    //        конкретные блюда и напитки — существительное («Пицца», «Кофе»).

    static let cuisine: [String: String] = [
        // Национальные кухни (прилагательное)
        "russian":        "Русская",
        "european":       "Европейская",
        "italian":        "Итальянская",
        "french":         "Французская",
        "spanish":        "Испанская",
        "greek":          "Греческая",
        "turkish":        "Турецкая",
        "japanese":       "Японская",
        "chinese":        "Китайская",
        "korean":         "Корейская",
        "thai":           "Тайская",
        "vietnamese":     "Вьетнамская",
        "asian":          "Азиатская",
        "indian":         "Индийская",
        "georgian":       "Грузинская",
        "armenian":       "Армянская",
        "azerbaijani":    "Азербайджанская",
        "uzbek":          "Узбекская",
        "caucasian":      "Кавказская",
        "american":       "Американская",
        "mexican":        "Мексиканская",
        "lebanese":       "Ливанская",
        "arab":           "Арабская",
        "vegetarian":     "Вегетарианская",
        "vegan":          "Веганская",
        "international":  "Интернациональная",
        "regional":       "Региональная",
        // Блюда и напитки (существительное)
        "pizza":          "Пицца",
        "pasta":          "Паста",
        "sushi":          "Суши",
        "burger":         "Бургеры",
        "steak":          "Стейки",
        "barbecue":       "Барбекю",
        "seafood":        "Морепродукты",
        "fish_and_chips": "Рыба с картошкой",
        "coffee_shop":    "Кофе",
        "tea":            "Чай",
        "ice_cream":      "Мороженое",
        "cake":           "Выпечка",
        "donut":          "Пончики",
        "sandwich":       "Сэндвичи",
        "noodle":         "Лапша",
        "hotdog":         "Хот-доги",
        "kebab":          "Кебаб",
        "shawarma":       "Шаурма",
        "fast_food":      "Фастфуд",
    ]

    // MARK: - building

    static let building: [String: String] = [
        "yes":                  "Здание",
        // Жилые
        "apartments":           "Многоквартирный дом",
        "house":                "Жилой дом",
        "detached":             "Отдельный дом",
        "semidetached_house":   "Дом на две семьи",
        "terrace":              "Рядовая застройка",
        "residential":          "Жилое здание",
        "dormitory":            "Общежитие",
        "bungalow":             "Бунгало",
        "farm":                 "Фермерский дом",
        "houseboat":            "Плавучий дом",
        // Коммерческие
        "commercial":           "Коммерческое здание",
        "retail":               "Торговое здание",
        "office":               "Офисное здание",
        "industrial":           "Промышленное здание",
        "warehouse":            "Складское здание",
        "kiosk":                "Киоск",
        "supermarket":          "Супермаркет",
        // Религиозные
        "religious":            "Религиозное сооружение",
        "cathedral":            "Собор",
        "chapel":               "Часовня",
        "church":               "Церковь",
        "mosque":               "Мечеть",
        "synagogue":            "Синагога",
        "temple":               "Храм",
        "monastery":            "Монастырь",
        // Общественные
        "civic":                "Гражданское здание",
        "public":               "Общественное здание",
        "school":               "Школа",
        "college":              "Колледж",
        "university":           "ВУЗ",
        "hospital":             "Больница",
        "kindergarten":         "Детский сад",
        "government":           "Правительственное здание",
        "fire_station":         "Пожарная часть",
        "train_station":        "Вокзал",
        "museum":               "Музей",
        "toilets":              "Туалет",
        "transportation":       "Транспортное здание",
        // Сельскохозяйственные
        "farm_auxiliary":       "Нежилая постройка фермы",
        "barn":                 "Амбар",
        "greenhouse":           "Теплица",
        "stable":               "Конюшня",
        "cowshed":              "Коровник",
        // Спортивные
        "sports_hall":          "Спортивный зал",
        "sports_centre":        "Спортивный центр",
        "stadium":              "Стадион",
        "grandstand":           "Трибуна",
        // Гаражи / хранение
        "garage":               "Гараж",
        "garages":              "Гаражи (ГСК)",
        "parking":              "Парковочное здание",
        "shed":                 "Сарай",
        "carport":              "Навес для машины",
        // Технические
        "service":              "Служебная постройка",
        "transformer_tower":    "Трансформаторная башня",
        "water_tower":          "Водонапорная башня",
        // Прочие
        "construction":         "Строящееся здание",
        "ruins":                "Руины",
    ]

    // MARK: - building:material

    static let buildingMaterial: [String: String] = [        "brick":            "Кирпич",
        "plaster":          "Штукатурка",
        "concrete":         "Бетон",
        "wood":             "Дерево",
        "metal":            "Металл",
        "steel":            "Сталь",
        "glass":            "Стекло",
        "stone":            "Камень",
        "cement_block":     "Шлакоблок",
        "masonry":          "Кладка",
        "timber_framing":   "Фахверк",
        "sandstone":        "Песчаник",
        "limestone":        "Известняк",
        "marble":           "Мрамор",
        "clay":             "Глина",
        "mud":              "Глинобетон",
        "adobe":            "Саман",
        "rammed_earth":     "Землебит",
        "plastic":          "Пластик",
        "vinyl":            "Сайдинг (винил)",
        "copper":           "Медь",
        "mirror":           "Зеркальное стекло",
        "tiles":            "Плитка",
        "slate":            "Шифер",
        "tin":              "Жесть",
        "metal_plates":     "Металлические пластины",
        "bamboo":           "Бамбук",
        "solar_panels":     "Солнечные панели",
    ]

    // MARK: - building:architecture

    static let buildingArchitecture: [String: String] = [
        // Средневековые
        "islamic":               "Исламская архитектура",
        "romanesque":            "Романская архитектура",
        "gothic":                "Готическая архитектура",
        // XV–XVIII вв.
        "renaissance":           "Архитектура Возрождения",
        "mannerism":             "Маньеризм",
        "ottoman":               "Османская архитектура",
        "baroque":               "Барокко",
        "rococo":                "Рококо",
        // XIX в.
        "neoclassicism":         "Классицизм",
        "empire":                "Ампир",
        "eclectic":              "Эклектика",
        "historicism":           "Историзм",
        "georgian":              "Георгианская архитектура",
        "victorian":             "Викторианская архитектура",
        "pseudo-russian":        "Псевдорусский стиль",
        "moorish_revival":       "Неомавританский стиль",
        "neo-romanesque":        "Неороманский стиль",
        "neo-gothic":            "Неоготика",
        "pseudo-gothic":         "Псевдоготика",
        "russian_gothic":        "Русская псевдоготика",
        "neo-byzantine":         "Неовизантийский стиль",
        "neo-renaissance":       "Неоренессанс",
        "neo-baroque":           "Необарокко",
        // 1900–1950
        "art_nouveau":           "Модерн (ар-нуво)",
        "nothern_modern":        "Северный модерн",
        "functionalism":         "Функционализм",
        "constructivism":        "Конструктивизм",
        "postconstructivism":    "Постконструктивизм",
        "cubism":                "Кубизм",
        "new_objectivity":       "Новая вещественность",
        "art_deco":              "Ар-деко",
        "international_style":   "Интернациональный стиль",
        "amsterdam_school":      "Амстердамская школа",
        "stalinist_neoclassicism": "Сталинский ампир",
        // 1950–н.в.
        "modern":                "Архитектурный модернизм",
        "brutalist":             "Брутализм",
        "postmodern":            "Постмодернизм",
        "contemporary":          "Современная архитектура",
        // Народная
        "vernacular":            "Народная архитектура",
    ]

    // MARK: - roof:shape

    static let roofShape: [String: String] = [
        "flat":         "Плоская",
        "gabled":       "Двускатная",
        "hipped":       "Вальмовая",
        "pyramidal":    "Пирамидальная",
        "skillion":     "Односкатная",
        "half-hipped":  "Полувальмовая",
        "side_hipped":  "Боковая вальмовая",
        "mansard":      "Мансардная",
        "gambrel":      "Ломаная",
        "cone":         "Коническая",
        "dome":         "Купол",
        "onion":        "Луковичная",
        "round":        "Округлая",
        "saltbox":      "Несимметричная",
        "sawtooth":     "Пилообразная",
        "butterfly":    "«Бабочка»",
        "crosspitched": "Крестообразная",
    ]

    // MARK: - roof:material

    static let roofMaterial: [String: String] = [
        "roof_tiles":       "Черепица",
        "metal":            "Металл",
        "metal_sheet":      "Металлический лист",
        "concrete":         "Бетон",
        "asphalt":          "Рубероид/асфальт",
        "asphalt_shingle":  "Битумная черепица",
        "tar_paper":        "Толь",
        "eternit":          "Шифер (этернит)",
        "glass":            "Стекло",
        "acrylic_glass":    "Оргстекло",
        "slate":            "Природный шифер",
        "wood":             "Дерево",
        "copper":           "Медь",
        "zinc":             "Цинк",
        "grass":            "Зелёная кровля",
        "thatch":           "Солома/камыш",
        "gravel":           "Гравий",
        "stone":            "Камень",
        "plastic":          "Пластик",
        "solar_panels":     "Солнечные панели",
    ]
}
