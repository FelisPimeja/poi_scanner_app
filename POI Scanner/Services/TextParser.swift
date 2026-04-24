import Foundation
import NaturalLanguage

// MARK: - TextParser
// Парсит текст, распознанный OCR, и извлекает OSM-теги

struct TextParser {

    // MARK: - Public API

    /// Главный метод: принимает полный текст (из OCR), возвращает извлечённые теги с confidence
    static func parse(_ text: String) -> ParseResult {
        var result = ParseResult()

        // 0. Маскируем шумовые юридические сущности — они не нужны в OSM,
        //    но мешают другим экстракторам (телефоны, адреса, postcode).
        //    cleanText — текст с замаскированными блоками шума.
        let (cleanText, noiseResult) = maskNoiseEntities(in: text)
        // Сохраняем извлечённые из шума теги (КПП, operator и т.п.)
        for (tag, value) in noiseResult.tags {
            result.set(tag: tag, value: value, confidence: noiseResult.confidence[tag] ?? 0.7, status: .extracted)
        }

        // 1. DataDetector — телефоны, email, URL (высокая надёжность)
        extractDataDetectorFields(from: cleanText, into: &result)

        // 2. Brand + category classifier (name, shop, amenity, brand, cuisine)
        extractBrandAndCategory(from: cleanText, into: &result)

        // 3. Regex-парсеры
        extractOpeningHours(from: cleanText, into: &result)
        extractSocialNetworks(from: cleanText, into: &result)
        extractPaymentMethods(from: text, into: &result)   // из оригинала (до маскировки)
        extractLegalRequisites(from: cleanText, into: &result)
        extractAddress(from: cleanText, into: &result)

        // 4. NLP — имя организации (более низкая надёжность, если brand не нашёл)
        extractOrganizationName(from: cleanText, into: &result)

        return result
    }

    // MARK: - DataDetector

    private static let detector = try? NSDataDetector(types:
        NSTextCheckingResult.CheckingType.phoneNumber.rawValue |
        NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static func extractDataDetectorFields(from text: String, into result: inout ParseResult) {
        guard let detector else { return }
        // Применяем OCR-нормализацию цифр перед DataDetector (О→0 и т.п. в цифровом контексте)
        // Это исправляет "8 800 250 O 250" → "8 800 250 0 250" для корректной детекции телефона
        let normalizedText = normalizeOCRDigitsForPhone(text)
        let range = NSRange(normalizedText.startIndex..., in: normalizedText)
        let matches = detector.matches(in: normalizedText, options: [], range: range)

        for match in matches {
            switch match.resultType {
            case .phoneNumber:
                if let phone = match.phoneNumber, result.tags["phone"] == nil {
                    let normalized = normalizePhone(phone)
                    // Принимаем только то, что нормализовалось до +7 — отсеивает ИНН/КПП/ОГРН/часы работы
                    if normalized.hasPrefix("+7") {
                        result.set(tag: "phone", value: normalized, confidence: 0.9, status: .extracted)
                    }
                }
            case .link:
                if let url = match.url {
                    let urlString = url.absoluteString
                    classifyAndSetURL(urlString, into: &result)
                }
            default:
                break
            }
        }

        // Email отдельно (DataDetector его относит к .link)
        let emailRegex = try? NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: .caseInsensitive)
        emailRegex?.matches(in: text, range: NSRange(text.startIndex..., in: text)).forEach { match in
            if let range = Range(match.range, in: text), result.tags["contact:email"] == nil {
                result.set(tag: "contact:email", value: String(text[range]).lowercased(), confidence: 0.92, status: .extracted)
            }
        }

        // Regex-фоллбек для bare-доменов которые DataDetector пропускает
        // Например: "ROYALSEEDS.RU", "www.copy.ru", "modi.Ru" — без http://
        if result.tags["contact:website"] == nil {
            let bareURLRegex = try? NSRegularExpression(
                pattern: #"(?:^|[\s(])(?:www\.)?([a-z0-9][a-z0-9\-]{1,50}\.(?:ru|com|рф|net|org|info|biz|su))(?:[/\w\-\.]*)?(?=[\s,;)\n]|$)"#,
                options: [.caseInsensitive, .anchorsMatchLines]
            )
            if let m = bareURLRegex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                let domain = String(text[r]).lowercased()
                // Исключаем домены которые выглядят как ИНН/ОГРН или слишком короткие
                if domain.count >= 5 && !domain.first!.isNumber {
                    result.set(tag: "contact:website", value: "https://\(domain)", confidence: 0.8, status: .extracted)
                }
            }
        }

        // Regex-фоллбек для телефонов которые DataDetector пропустил
        // (например 8(900) 159-29-39 в контексте прайс-листа, или 8-495-680-42-88)
        if result.tags["phone"] == nil {
            // Форматы: 8(9XX)..., +7(9XX)..., 8 9XX ..., 8-9XX-..., тел:...
            let phoneRegex = try? NSRegularExpression(
                pattern: #"(?:^|[^\d])(?:тел[\.:]?\s*)?(\+?[78]\s*[-\(\s]?[3489]\d{2}[-\s\)]\s*\d{3}[\s\-]\d{2}[\s\-]\d{2})(?!\d)"#,
                options: [.caseInsensitive, .anchorsMatchLines]
            )
            phoneRegex?.matches(in: normalizedText, range: NSRange(normalizedText.startIndex..., in: normalizedText)).first.flatMap { m in
                Range(m.range(at: 1), in: normalizedText).map { String(normalizedText[$0]) }
            }.flatMap { raw -> String? in
                let normalized = normalizePhone(raw)
                return normalized.hasPrefix("+7") ? normalized : nil
            }.map {
                result.set(tag: "phone", value: $0, confidence: 0.85, status: .extracted)
            }
        }
    }

    private static func classifyAndSetURL(_ urlString: String, into result: inout ParseResult) {
        let lower = urlString.lowercased()

        // Пропускаем mailto: — это email, не сайт
        guard !lower.hasPrefix("mailto:") else { return }

        // Normalize: http → https, lowercase, убираем trailing slash
        var normalized = lower
        if normalized.hasPrefix("http://") {
            normalized = "https://" + normalized.dropFirst("http://".count)
        } else if !normalized.hasPrefix("https://") {
            normalized = "https://" + normalized
        }
        // Убираем trailing slash (кроме корневого https://host/)
        if normalized.hasSuffix("/") && normalized.filter({ $0 == "/" }).count > 2 {
            normalized = String(normalized.dropLast())
        }

        if lower.contains("vk.com") || lower.contains("vkontakte.ru") {
            result.set(tag: "contact:vk", value: normalized, confidence: 0.88, status: .extracted)
        } else if lower.contains("t.me") || lower.contains("telegram.me") {
            result.set(tag: "contact:telegram", value: normalized, confidence: 0.88, status: .extracted)
        } else if lower.contains("instagram.com") {
            result.set(tag: "contact:instagram", value: normalized, confidence: 0.88, status: .extracted)
        } else if lower.contains("tiktok.com") {
            result.set(tag: "contact:tiktok", value: normalized, confidence: 0.88, status: .extracted)
        } else if lower.contains("ok.ru") {
            result.set(tag: "contact:ok", value: normalized, confidence: 0.88, status: .extracted)
        } else if lower.contains("youtube.com") || lower.contains("youtu.be") {
            result.set(tag: "contact:youtube", value: normalized, confidence: 0.85, status: .extracted)
        } else if result.tags["contact:website"] == nil {
            result.set(tag: "contact:website", value: normalized, confidence: 0.82, status: .extracted)
        }
    }

    // MARK: - Brand & Category Classifier

    private struct BrandEntry {
        let patterns: [String]         // Паттерны для поиска в тексте (lowercased)
        let name: String?
        let mainTagKey: String?        // "shop" или "amenity" или "leisure" и т.д.
        let mainTagValue: String?
        let brand: String?
        let cuisine: String?
    }

    /// Извлекает name, shop/amenity, brand, cuisine по базе известных брендов и ключевых слов
    private static func extractBrandAndCategory(from text: String, into result: inout ParseResult) {
        // Нормализуем переносы строк в пробелы, чтобы многословные ключевые слова
        // ("ремонт обуви", "изготовление ключей" и т.п.) срабатывали даже если OCR
        // разбил их по строкам.
        let lower = text.lowercased().replacingOccurrences(of: "\n", with: " ")

        // 1. Проверяем базу брендов
        for entry in brandDatabase {
            let matched = entry.patterns.contains { lower.contains($0) }
            guard matched else { continue }

            if let name = entry.name, result.tags["name"] == nil {
                result.set(tag: "name", value: name, confidence: 0.75, status: .extracted)
            }
            if let key = entry.mainTagKey, let val = entry.mainTagValue, result.tags[key] == nil {
                result.set(tag: key, value: val, confidence: 0.75, status: .extracted)
            }
            if let brand = entry.brand, result.tags["brand"] == nil {
                result.set(tag: "brand", value: brand, confidence: 0.75, status: .extracted)
            }
            if let cuisine = entry.cuisine, result.tags["cuisine"] == nil {
                result.set(tag: "cuisine", value: cuisine, confidence: 0.7, status: .extracted)
            }
            // Останавливаемся только если бренд установил основной тег (shop/amenity/etc)
            // Если он только мимоходом упомянут (напр. Сбербанк на чеке ювелира), продолжаем
            if entry.mainTagKey != nil {
                return
            }
        }

        // 2. Ключевые слова категорий (если бренд не распознан или не имел основного тега)
        extractCategoryKeywords(from: lower, into: &result)
    }

    /// Категорийные ключевые слова → shop/amenity
    private static func extractCategoryKeywords(from lower: String, into result: inout ParseResult) {
        // Структура: (keywords, tagKey, tagValue, cuisine?)
        let categoryRules: [(keywords: [String], key: String, value: String, cuisine: String?)] = [
            // Amenity - еда
            (["ресторан", "restaurant", "brasserie", "трактория", "траттория", "trattoria"], "amenity", "restaurant", nil),
            (["кафе", " cafe", "coffee house", "coffeehouse", "кофен", "кофеен", "кофейн",
              "пекарня", "кофейня", "кондитерская", "кон дитерская", "кондитерск", "calé"], "amenity", "cafe", nil),
            (["fast food", "фастфуд", "быстрое питание"], "amenity", "fast_food", nil),
            (["пиццерия", "pizzeria", "pizza"], "amenity", "fast_food", "pizza"),
            (["шаурма", "shawarma", "донер", "doner kebab"], "amenity", "fast_food", "shawarma"),
            (["суши", "sushi", "роллы"], "amenity", "restaurant", "sushi"),
            (["бургер", "burger", "бургерная"], "amenity", "fast_food", "burger"),
            (["пончик", "donut", "donutto"], "amenity", "cafe", "donut"),
            (["блинная", "блины"], "amenity", "fast_food", "crepe"),
            (["чебурек"], "amenity", "fast_food", "cheburek"),
            (["паста", "pasta"], "amenity", "fast_food", "pasta"),
            (["греческая кухня", "greek street", "jreek street"], "amenity", "fast_food", "greek"),
            (["турецкая кухня", "турецкий"], "amenity", "fast_food", "turkish"),
            (["пирог", "пироги", "пирожковая", "пирожки"], "amenity", "fast_food", nil),
            (["столовая"], "amenity", "restaurant", nil),
            (["вьетнамская кухня", "vietnamese", "вьетнам"], "amenity", "restaurant", "vietnamese"),
            (["украинская кухня", "вареники"], "amenity", "restaurant", "ukrainian"),
            (["итальянская кухня", "il patio"], "amenity", "restaurant", "italian"),
            // Amenity - здоровье
            (["аптека", "аптеку", "аптеки", "аптечн", "pharmacy"], "amenity", "pharmacy", nil),
            (["клиника", "clinic", "медицинский центр", "медцентр", "диагностический центр"], "amenity", "clinic", nil),
            (["стоматолог", "стоматология", "зубной"], "amenity", "dentist", nil),
            (["лаборатория", "медицинская лаборатория", "laboratory", "анализы"], "amenity", "laboratory", nil),
            // Amenity - услуги (recycling + банкомат ПЕРЕД банком!)
            // recycling первым — "банки" (жестяные) иначе даёт bank
            (["вторсырье", "вторичное сырьё", "сбор отходов", "переработка", "recycling", "пункт приёма"],
             "amenity", "recycling", nil),
            (["смешанные отходы", "waste basket", "урна для мусора"], "amenity", "waste_basket", nil),
            // банкомат перед банком — "БАНКОМАТ ВНУТРИ ПОЧТА БАНК" → atm, не bank
            (["банкомат", "atm"], "amenity", "atm", nil),
            (["банк ", " банк ", "кредит", "ипотека", "вклад"], "amenity", "bank", nil),
            (["почтовое отделение", "почта", "почтовый"], "amenity", "post_office", nil),
            (["пункт выдачи", "пвз", "pick-up point", "выдача заказов", "примерки и выдачи"], "amenity", "parcel_pickup", nil),
            (["постамат", "parcel locker", "locker"], "amenity", "parcel_locker", nil),
            (["кинотеатр", "cinema", "кино"], "amenity", "cinema", nil),
            (["детский сад", "childcare", "детский центр"], "amenity", "childcare", nil),
            (["азс", "автозаправка", "заправка", "fuel"], "amenity", "fuel", nil),
            (["парковка", "parking"], "amenity", "parking", nil),
            (["туалет", "wc", "toilet"], "amenity", "toilets", nil),
            (["баня", "бани", "сауна", "public bath", "термы"], "amenity", "public_bath", nil),
            (["церковь", "храм", "собор", "монастырь", "часовня", "приход", "свт.", "мирликийск",
              "православный", "place of worship", "mosque", "мечеть"], "amenity", "place_of_worship", nil),
            (["молочно-раздаточный", "социальная служба", "социальная помощь",
              "social facility", "социальный"], "amenity", "social_facility", nil),
            // Shop - ремонт и мастерские (перед общими категориями, чтобы не проваливаться в shoes/clothes/jewelry)
            (["ремонт обуви", "shoe repair"], "shop", "shoe_repair", nil),
            (["ремонт ювелирных", "ювелирная мастерская"], "shop", "jewelry_repair", nil),
            (["ремонт одежды", "clothes repair"], "shop", "clothes_repair", nil),
            (["изготовление ключей", "ключи и замки", "замки и ключи", "locksmith"], "shop", "locksmith", nil),
            // Shop - туризм
            (["турагентство", "туристическое агентство", "туристическое бюро",
              "продажа туров", "туризм", "coral travel", "anextour", "tez-tour"], "shop", "travel_agency", nil),
            // Shop - одежда и обувь
            (["магазин одежды", "одежда и аксессуары", "магазин мужской одежды",
              "женская одежда", "мужская одежда", "детская одежда",
              "колготки", "бельё", "примерочн",
              "clothes", "clothing"], "shop", "clothes", nil),
            (["обувь", "shoes", "footwear", "обувной"], "shop", "shoes", nil),
            (["меховые изделия", "меховая", "межовая", "меховля", "шубы", "fur"], "shop", "fur", nil),
            // Shop - электроника
            (["цифровая и бытовая техника", "цифровая техника", "бытовая техника",
              "electronics", "электроника", "ремонт цифровой"], "shop", "electronics", nil),
            // mobile_phone_repair перед mobile_phone
            (["телефонов планшетов", "телефон планшетор", "телефонов ноутбуков", "планшетор ноутбуков",
              "компьют планшетор", "ремон телефон", "ремонт: телефонов",
              "диагностика телефонов", "ремонт и диагностика", "прошивка", "разблокировка",
              "mobile phone repair"], "shop", "mobile_phone_repair", nil),
            (["ремонт телефонов", "ремонт смартфонов",
              "mobile repair", "качественной связи"], "shop", "mobile_phone", nil),
            (["салон связи", "мобильные телефоны", "смартфоны"], "shop", "mobile_phone", nil),
            // Shop - продукты (специфичные перед convenience!)
            (["белорусские продукты", "фирменный магазин рыб", "deli"], "shop", "deli", nil),
            (["трав", "фитотерапия", "herbalist", "дары алтая", "сборы трав"], "shop", "herbalist", nil),
            (["кондитерские изделия", "confectionery", "зефир"], "shop", "confectionery", nil),
            // seafood перед convenience: "морепродукты" содержит "продукты"
            (["рыбный магазин", "рыбных магазинов", "морепродукты", "морская рыба", "рыба икра"], "shop", "seafood", nil),
            (["продукты", "продуктовый", "продуктов", "магазин у дома", "удобный магазин", "convenience"], "shop", "convenience", nil),
            (["супермаркет", "supermarket", "гипермаркет", "продукты питания"], "shop", "supermarket", nil),
            (["алкоголь", "алкогольный", "вино и", "винотека", "alcohol", "wine"], "shop", "alcohol", nil),
            (["табак ", "табачн", "vape sho", "smoke shop", "магазин бездымных"], "shop", "tobacco", nil),
            (["мясной", "мясник", "мясо"], "shop", "butcher", nil),
            // Shop - красота и здоровье (порядок важен!)
            (["парикмахерская", "hairdresser"], "shop", "hairdresser", nil),
            (["салон красоты", "beauty salon", "косметика и уход", "beauty",
              "make up", "makeup", "косметолог", "красоты"], "shop", "beauty", nil),
            (["барбершоп", "barbershop", "barber"], "shop", "barber", nil),
            (["ногтевой сервис", "ногтевая студия", "маникюр", "педикюр",
              "nail salon", "nails hair", "manicure", "pedicure"], "shop", "nail_salon", nil),
            (["косметика", "парфюмерия", "parfum", "cosmetics", "prof c osmetics", "prof cosmetics"], "shop", "cosmetics", nil),
            (["оптика", "очки", "линзы", "optician"], "shop", "optician", nil),
            (["ортопедия", "ортопедический", "топедический", "ортопед"], "shop", "orthopedics", nil),
            // Shop - дом и интерьер
            (["мебель", "furniture", "мебельный"], "shop", "furniture", nil),
            (["кухни", "кухня на заказ", "кухонная мебель"], "shop", "kitchen", nil),
            (["двери", "дверной", "doors"], "shop", "doors", nil),
            (["текстиль", "постельное бельё", "постельный"], "shop", "fabric", nil),
            (["матрасы", "кровати", "спальня", "matress"], "shop", "bed", nil),
            (["аквариум", "aquarium", "рыбки для дома"], "shop", "aquarium", nil),
            // Shop - прочее (специфичные перед общими)
            (["хобби", "хобби-гипермаркет", "творчество", "hobby"], "shop", "hobby", nil),
            (["садовый центр", "royalseeds", "garden centre", "семенной"], "shop", "garden_centre", nil),
            (["ювелир", "jewelry", "украшения", "бриллиант", "diamonds", "золото"], "shop", "jewelry", nil),
            (["зоомагазин", "зоотовары", "pet shop", "з00магазин", "зооцентр", "для животных"], "shop", "pet", nil),
            (["игрушки", "toys", "детские товары"], "shop", "toys", nil),
            (["спортивный", "спорт товары", "sports"], "shop", "sports", nil),
            (["книги", "книжный", "books"], "shop", "books", nil),
            (["канцтовары", "канцелярия", "stationery"], "shop", "stationery", nil),
            (["цветы", "флорист", "цветочный", "шветочный", "flowers", "florist"], "shop", "florist", nil),
            (["подарки", "подарков", "gift"], "shop", "gift", nil),
            (["ломбард"], "shop", "pawnbroker", nil),
            (["хозтовары", "строительные материалы", "сантехника и", "электрика", "doityourself", "kraftool"], "shop", "doityourself", nil),
            // tailor перед copyshop/photo (ателье с ксерокопией → tailor, не copyshop)
            (["ателье", "пошив", "tailor", "портной"], "shop", "tailor", nil),
            (["химчист", "dry cleaning"], "shop", "dry_cleaning", nil),
            // photo перед copyshop (ФОТО КОПИ ЦЕНТР → photo)
            (["фото", "фотоуслуги", "фотоцентр", "photo"], "shop", "photo", nil),
            (["ксерокопия", "копировальный", "копи центр", "печать документов", "copyshop", "копицентр"], "shop", "copyshop", nil),
            (["сувениры"], "shop", "gift", nil),
            (["товары для дома", "посуда", "houseware", "williams oliver"], "shop", "houseware", nil),
            (["пресса", "газеты", "newsagent", "нто"], "shop", "newsagent", nil),
            (["мороженое", "мороженoе", "марпжен", "ice cream", "ice_cream"], "shop", "ice_cream", nil),
            (["торговый центр", "торгового центра", "торгово-развлекательный", "мтц", "mall"], "shop", "mall", nil),
            (["церковная лавка", "церковный магазин"], "shop", "religion", nil),
            // Bar идёт ПОСЛЕ barber/barbershop, чтобы "бар" не срабатывало внутри "барбершоп"
            (["бар", " bar ", "\nbar\n", "паб", "pub"], "amenity", "bar", nil),
            // Leisure
            (["верёвочный парк", "канатный парк", "adventure park", "зиплайн"], "leisure", "adventure_park", nil),
            (["спортивная площадка", "футбольный клуб", "спортивный центр"], "leisure", "sports_centre", nil),
            (["игровой центр", "развлекательный центр", "аркада"], "leisure", "amusement_arcade", nil),
        ]

        for rule in categoryRules {
            let matched = rule.keywords.contains { lower.contains($0) }
            guard matched else { continue }
            if result.tags[rule.key] == nil {
                result.set(tag: rule.key, value: rule.value, confidence: 0.72, status: .extracted)
            }
            if let cuisine = rule.cuisine, result.tags["cuisine"] == nil {
                result.set(tag: "cuisine", value: cuisine, confidence: 0.65, status: .extracted)
            }
            break
        }
    }

    // MARK: - Brand Database

    private static let brandDatabase: [BrandEntry] = [
        // ── Телефония (первыми, чтобы не перебивались электроникой) ─────────────
        BrandEntry(patterns: ["мтс", "мой мтс", "мтс кешбэк", "mts", "mtc", "мобильные телесистемы"], name: "МТС", mainTagKey: "shop", mainTagValue: "mobile_phone", brand: "МТС", cuisine: nil),
        BrandEntry(patterns: ["мегафон", "megafon"], name: "МегаФон", mainTagKey: "shop", mainTagValue: "mobile_phone", brand: "МегаФон", cuisine: nil),
        BrandEntry(patterns: ["билайн", "beeline"], name: "Билайн", mainTagKey: "shop", mainTagValue: "mobile_phone", brand: "Билайн", cuisine: nil),
        // ── Одежда ───────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["твое", "tede", "tvoe", "tv0e"], name: "ТВОЕ", mainTagKey: "shop", mainTagValue: "clothes", brand: "ТВОЕ", cuisine: nil),
        BrandEntry(patterns: ["lichi", "личи"], name: "Lichi", mainTagKey: "shop", mainTagValue: "clothes", brand: "Lichi", cuisine: nil),
        BrandEntry(patterns: ["familia", "фамилия", "familru", "famil.ru"], name: "Familia", mainTagKey: "shop", mainTagValue: "clothes", brand: "Familia", cuisine: nil),
        BrandEntry(patterns: ["milavitsa", "милавица"], name: "Milavitsa", mainTagKey: "shop", mainTagValue: "clothes", brand: "Milavitsa", cuisine: nil),
        BrandEntry(patterns: ["urban tiger", "urbantiger"], name: "Urban Tiger", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["lc waikiki", "lcwaikiki"], name: "LC Waikiki", mainTagKey: "shop", mainTagValue: "clothes", brand: "LC Waikiki", cuisine: nil),
        BrandEntry(patterns: ["intimissimi", "intımissimi", "intımissımı"], name: "Intimissimi", mainTagKey: "shop", mainTagValue: "clothes", brand: "Intimissimi", cuisine: nil),
        BrandEntry(patterns: ["gate31", "gate 31"], name: "GATE31", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["tommy hilfiger", "tommyhilfiger", "tommy", "tommyihilfiger"], name: "Tommy Hilfiger", mainTagKey: "shop", mainTagValue: "clothes", brand: "Tommy Hilfiger", cuisine: nil),
        BrandEntry(patterns: ["lacoste"], name: "Lacoste", mainTagKey: "shop", mainTagValue: "clothes", brand: "Lacoste", cuisine: nil),
        BrandEntry(patterns: ["falconeri"], name: "Falconeri", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["тилли-стилли", "тилли стилли", "tilli-stilli"], name: "Тилли-Стилли", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["gulliver"], name: "Gulliver", mainTagKey: "shop", mainTagValue: "clothes", brand: "Gulliver", cuisine: nil),
        BrandEntry(patterns: ["stokmann", "стокманн", "ctokmahh"], name: "Стокманн", mainTagKey: "shop", mainTagValue: "department_store", brand: "Стокманн", cuisine: nil),
        BrandEntry(patterns: ["diplomat"], name: "Diplomat", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["карамелли", "karamelli"], name: "Карамелли", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["парижанка"], name: "Парижанка", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["стильпарк", "стиль парк"], name: "СтильПарк", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["guess"], name: "Guess", mainTagKey: "shop", mainTagValue: "clothes", brand: "Guess", cuisine: nil),
        BrandEntry(patterns: ["loft the original", "loft original", "lft trading", "ооо лфт"], name: "Loft", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["u.s. polo", "us polo", "u.s.polo"], name: "U.S. Polo Assn.", mainTagKey: "shop", mainTagValue: "clothes", brand: "U.S. Polo Assn.", cuisine: nil),
        BrandEntry(patterns: ["saboo"], name: "Saboo", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["m-lano", "mlano"], name: "M-LANO", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["menssegment"], name: "Menssegment", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["глория джинс", "gloria jeans"], name: "Глория Джинс", mainTagKey: "shop", mainTagValue: "clothes", brand: "Глория Джинс", cuisine: nil),
        BrandEntry(patterns: ["zara"], name: "Zara", mainTagKey: "shop", mainTagValue: "clothes", brand: "Zara", cuisine: nil),
        BrandEntry(patterns: ["h&m", "h & m", "hennes"], name: "H&M", mainTagKey: "shop", mainTagValue: "clothes", brand: "H&M", cuisine: nil),
        BrandEntry(patterns: ["cacharel", "cacharei", "ap фэшн", "ар фэшн"], name: "Cacharel", mainTagKey: "shop", mainTagValue: "clothes", brand: "Cacharel", cuisine: nil),
        BrandEntry(patterns: ["albione"], name: "Albione", mainTagKey: "shop", mainTagValue: "clothes", brand: "Albione", cuisine: nil),
        BrandEntry(patterns: ["glenfield", "glen filed"], name: "Glenfield", mainTagKey: "shop", mainTagValue: "clothes", brand: "Glenfield", cuisine: nil),
        BrandEntry(patterns: ["atami shop", "atami"], name: "Atami", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["alexander bogdanov", "bogdanov"], name: "Alexander Bogdanov", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["incanto"], name: "Incanto", mainTagKey: "shop", mainTagValue: "clothes", brand: "Incanto", cuisine: nil),
        BrandEntry(patterns: ["btk", "бтк групп", "бтк"  ], name: "БТК", mainTagKey: "shop", mainTagValue: "clothes", brand: "БТК", cuisine: nil),
        BrandEntry(patterns: ["марка рус", "марка рус"], name: nil, mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["ре трэйдинг", "ре трейдинг"], name: nil, mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["фэшн", "fashion"], name: nil, mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["lucky back", "lucky bacr"], name: "Lucky Back", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["moné", "mone"], name: "Moné", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        // ── Обувь ────────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["комфорт", "komfort"], name: "Комфорт", mainTagKey: "shop", mainTagValue: "shoes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["котофей"], name: "Котофей", mainTagKey: "shop", mainTagValue: "shoes", brand: "Котофей", cuisine: nil),
        // ── Электроника ──────────────────────────────────────────────────────────
        BrandEntry(patterns: ["dns", "ооо днс", "днс ритейл", "dns retail"], name: "DNS", mainTagKey: "shop", mainTagValue: "electronics", brand: "DNS", cuisine: nil),
        BrandEntry(patterns: ["xiaomi", "сяоми"], name: "Xiaomi", mainTagKey: "shop", mainTagValue: "electronics", brand: "Xiaomi", cuisine: nil),
        BrandEntry(patterns: ["redmond smart home", "redmond", "rodmond"], name: "Redmond", mainTagKey: "shop", mainTagValue: "electronics", brand: "Redmond", cuisine: nil),
        BrandEntry(patterns: ["restore:", "restore.ru", "ресторе"], name: "restore:", mainTagKey: "shop", mainTagValue: "electronics", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["всёсмарт", "vsesmart"], name: "ВсёСмарт", mainTagKey: "shop", mainTagValue: "electronics", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["м.видео", "мвидео", "mvideo", "м видео"], name: "М.Видео", mainTagKey: "shop", mainTagValue: "electronics", brand: "М.Видео", cuisine: nil),
        // ── Супермаркеты ─────────────────────────────────────────────────────────
        BrandEntry(patterns: ["пятёрочка", "пятерочка", "pyaterochka"], name: "Пятёрочка", mainTagKey: "shop", mainTagValue: "supermarket", brand: "Пятёрочка", cuisine: nil),
        BrandEntry(patterns: ["вкусвилл", "вкус вилл", "vkusvill"], name: "ВкусВилл", mainTagKey: "shop", mainTagValue: "supermarket", brand: "ВкусВилл", cuisine: nil),
        BrandEntry(patterns: ["лента", "supermarket lenta", "ооо лента"], name: "Лента", mainTagKey: "shop", mainTagValue: "supermarket", brand: "Лента", cuisine: nil),
        BrandEntry(patterns: ["мясновъ", "мяснов"], name: "Мясновъ", mainTagKey: "shop", mainTagValue: "supermarket", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["магнит", "magnit"], name: "Магнит", mainTagKey: "shop", mainTagValue: "supermarket", brand: "Магнит", cuisine: nil),
        // ── Аптеки ───────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["горздрав"], name: "Горздрав", mainTagKey: "amenity", mainTagValue: "pharmacy", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["ригла"], name: "Ригла", mainTagKey: "amenity", mainTagValue: "pharmacy", brand: "Ригла", cuisine: nil),
        BrandEntry(patterns: ["здравсити", "zdravcity"], name: "ЗдравСити", mainTagKey: "amenity", mainTagValue: "pharmacy", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["диалог аптек", "аптека диалог", "аптечная сеть диалог",
                               "диалог аптечная", "диалог столица"], name: "Диалог", mainTagKey: "amenity", mainTagValue: "pharmacy", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["helix", "хеликс"], name: "Helix", mainTagKey: "amenity", mainTagValue: "laboratory", brand: "Helix", cuisine: nil),
        // ── Ювелирные (до банков!) ────────────────────────────────────────────────
        BrandEntry(patterns: ["sokolov", "соколов"], name: "SOKOLOV", mainTagKey: "shop", mainTagValue: "jewelry", brand: "SOKOLOV", cuisine: nil),
        BrandEntry(patterns: ["золотой дом"], name: "Золотой Дом", mainTagKey: "shop", mainTagValue: "jewelry", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["евро-голд", "euro gold"], name: "Евро-Голд", mainTagKey: "shop", mainTagValue: "jewelry", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["diamant", "диамант ювелир"], name: "Diamant", mainTagKey: "shop", mainTagValue: "jewelry", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["miuz", "мюз"], name: "MIUZ Diamonds", mainTagKey: "shop", mainTagValue: "jewelry", brand: "MIUZ", cuisine: nil),
        BrandEntry(patterns: ["бронницкий ювелир"], name: "Бронницкий Ювелир", mainTagKey: "shop", mainTagValue: "jewelry", brand: nil, cuisine: nil),
        // ── Банки ────────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["сбербанк", "sberbank", "сбер банк"], name: "Сбербанк", mainTagKey: "amenity", mainTagValue: "bank", brand: "Сбербанк", cuisine: nil),
        BrandEntry(patterns: ["втб банк", "банк втб", "vtb"], name: "ВТБ", mainTagKey: "amenity", mainTagValue: "bank", brand: "ВТБ", cuisine: nil),
        BrandEntry(patterns: ["почта банк", "pochtabank", "pochta bank"], name: "Почта Банк", mainTagKey: "amenity", mainTagValue: "bank", brand: "Почта Банк", cuisine: nil),
        BrandEntry(patterns: ["россельхозбанк", "rshb"], name: "Россельхозбанк", mainTagKey: "amenity", mainTagValue: "bank", brand: "Россельхозбанк", cuisine: nil),
        BrandEntry(patterns: ["фора-банк", "фора банк", "fora bank"], name: "ФОРА-БАНК", mainTagKey: "amenity", mainTagValue: "bank", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["юнистрим", "unistream"], name: "Юнистрим", mainTagKey: "amenity", mainTagValue: "bank", brand: nil, cuisine: nil),
        // ── Почта ────────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["почта россии", "russian post", "russianpost", "pochta.ru"], name: "Почта России", mainTagKey: "amenity", mainTagValue: "post_office", brand: "Почта России", cuisine: nil),
        // ── Пункты выдачи ────────────────────────────────────────────────────────
        BrandEntry(patterns: ["wildberries", "вайлдберрис", " wb ", "wb "], name: "Wildberries", mainTagKey: "amenity", mainTagValue: "parcel_pickup", brand: "Wildberries", cuisine: nil),
        BrandEntry(patterns: ["ozon маркет", "ozon пункт", "пункт выдачи ozon", "пвз ozon"], name: "OZON", mainTagKey: "amenity", mainTagValue: "parcel_pickup", brand: "OZON", cuisine: nil),
        BrandEntry(patterns: ["ozon locker", "ozon постамат", "постамат ozon", "+ ozon", "dzon", "ozon"], name: "OZON", mainTagKey: "amenity", mainTagValue: "parcel_locker", brand: "OZON", cuisine: nil),
        BrandEntry(patterns: ["avito доставка", "avito пункт", "ваш заказ здесь avito", "avito"], name: "Avito", mainTagKey: "amenity", mainTagValue: "parcel_pickup", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["lamoda", "ламода"], name: "Lamoda", mainTagKey: "amenity", mainTagValue: "parcel_pickup", brand: "Lamoda", cuisine: nil),
        // ── Косметика ────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["лэтуаль", "л'этуаль", "letual", "eturel", "этуаль"], name: "Лэтуаль", mainTagKey: "shop", mainTagValue: "cosmetics", brand: "Лэтуаль", cuisine: nil),
        BrandEntry(patterns: ["yves rocher", "ив роше"], name: "Yves Rocher", mainTagKey: "shop", mainTagValue: "cosmetics", brand: "Yves Rocher", cuisine: nil),
        BrandEntry(patterns: ["иль де ботэ", "ile de beaute", "sephora"], name: "Иль де Ботэ", mainTagKey: "shop", mainTagValue: "cosmetics", brand: nil, cuisine: nil),
        // ── Оптика ───────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["айкрафт", "eyekraft", "ikraft"], name: "Айкрафт", mainTagKey: "shop", mainTagValue: "optician", brand: "Айкрафт", cuisine: nil),
        BrandEntry(patterns: ["доктор линз", "doctor lenz"], name: "Доктор Линз", mainTagKey: "shop", mainTagValue: "optician", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["оптик сити", "optik city"], name: "Оптик Сити", mainTagKey: "shop", mainTagValue: "optician", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["планетарий оптика", "планетарий", "planetarium.ru"], name: "Планетарий", mainTagKey: "shop", mainTagValue: "optician", brand: nil, cuisine: nil),
        // ── Алкоголь ─────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["красное & белое", "красное и белое", "красное&белое", "красное&"], name: "Красное & Белое", mainTagKey: "shop", mainTagValue: "alcohol", brand: "Красное & Белое", cuisine: nil),
        BrandEntry(patterns: ["ароматный мир", "арома маркет"], name: "Ароматный Мир", mainTagKey: "shop", mainTagValue: "alcohol", brand: "Ароматный Мир", cuisine: nil),
        // ── Мебель / интерьер ────────────────────────────────────────────────────
        BrandEntry(patterns: ["hoff", "хофф"], name: "Hoff", mainTagKey: "shop", mainTagValue: "furniture", brand: "Hoff", cuisine: nil),
        BrandEntry(patterns: ["askona", "аскона"], name: "Askona", mainTagKey: "shop", mainTagValue: "bed", brand: "Askona", cuisine: nil),
        BrandEntry(patterns: ["mollis"], name: "Mollis", mainTagKey: "shop", mainTagValue: "bed", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["mr. doors", "mr doors", "mrdoors"], name: "Mr.Doors", mainTagKey: "shop", mainTagValue: "doors", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["küchenland", "кюхенлэнд", "кюхенленд", "küchen land", "кюхен"], name: "Küchenland", mainTagKey: "shop", mainTagValue: "houseware", brand: "Küchenland", cuisine: nil),
        BrandEntry(patterns: ["мария хоум", "marya.ru", "maria home"], name: "Мария", mainTagKey: "shop", mainTagValue: "kitchen", brand: nil, cuisine: nil),
        // ── Хобби / спорт ────────────────────────────────────────────────────────
        BrandEntry(patterns: ["леонардо", "leonardo.ru", "планета увлечений"], name: "Леонардо", mainTagKey: "shop", mainTagValue: "hobby", brand: "Леонардо", cuisine: nil),
        BrandEntry(patterns: ["траектория"], name: "Траектория", mainTagKey: "shop", mainTagValue: "sports", brand: "Траектория", cuisine: nil),
        BrandEntry(patterns: ["4hands", "4 hands", "форхэндс"], name: "4Hands", mainTagKey: "shop", mainTagValue: "beauty", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["красивые люди"], name: "Красивые Люди", mainTagKey: "shop", mainTagValue: "beauty", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["leon beauty", "leon_beauty", "леон beauty"], name: "LEON BEAUTY SPACE", mainTagKey: "shop", mainTagValue: "beauty", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["fixprice", "фикс прайс", "fix price", "fix-price", "бэст прайс"], name: "Fix Price", mainTagKey: "shop", mainTagValue: "variety_store", brand: "Fix Price", cuisine: nil),
        BrandEntry(patterns: ["rieker"], name: "Rieker", mainTagKey: "shop", mainTagValue: "shoes", brand: "Rieker", cuisine: nil),
        BrandEntry(patterns: ["ecco-рос", "ecco shop", "ecco store", "ecco обув", "магазин ecco"], name: "ECCO", mainTagKey: "shop", mainTagValue: "shoes", brand: "ECCO", cuisine: nil),
        BrandEntry(patterns: ["modi fun shop", "ооо «моди»", "ооо моди"], name: "Modi", mainTagKey: "shop", mainTagValue: "clothes", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["indiashop"], name: "India Shop", mainTagKey: "shop", mainTagValue: "gift", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["loccitane", "l'occitane", "l occitane"], name: "L'Occitane", mainTagKey: "shop", mainTagValue: "cosmetics", brand: "L'Occitane", cuisine: nil),
        BrandEntry(patterns: ["tez-tour", "tez tour", "тез тур"], name: "TEZ TOUR", mainTagKey: "shop", mainTagValue: "travel_agency", brand: nil, cuisine: nil),
        // ── Телефония (старая позиция удалена — перенесено в начало DB) ─────────
        // ── Кафе / рестораны ─────────────────────────────────────────────────────
        BrandEntry(patterns: ["правда кофе", "pravda coffee", "дравда кофе", "правда koof"], name: "Правда Кофе", mainTagKey: "amenity", mainTagValue: "cafe", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["roaster", "hoaster"], name: "Roaster", mainTagKey: "amenity", mainTagValue: "cafe", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["price coffee"], name: "Price Coffee", mainTagKey: "amenity", mainTagValue: "cafe", brand: nil, cuisine: "coffee_shop"),
        BrandEntry(patterns: ["кофикс", "cofix", "cofixcafe"], name: "Кофикс", mainTagKey: "amenity", mainTagValue: "cafe", brand: "Кофикс", cuisine: nil),
        BrandEntry(patterns: ["шоколадница", "shokoladnitsa"], name: "Шоколадница", mainTagKey: "amenity", mainTagValue: "cafe", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["кантата", "cantata coffee"], name: "Кантата", mainTagKey: "amenity", mainTagValue: "cafe", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["просто пончики"], name: "Просто Пончики", mainTagKey: "amenity", mainTagValue: "cafe", brand: nil, cuisine: "donut"),
        BrandEntry(patterns: ["donutto"], name: "Donutto", mainTagKey: "amenity", mainTagValue: "cafe", brand: nil, cuisine: "donut"),
        BrandEntry(patterns: ["juice city", "джус сити"], name: "Juice City", mainTagKey: "amenity", mainTagValue: "cafe", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["pastacup"], name: "Pastacup", mainTagKey: "amenity", mainTagValue: "fast_food", brand: nil, cuisine: "pasta;pizza"),
        BrandEntry(patterns: ["greek street"], name: "Greek Street", mainTagKey: "amenity", mainTagValue: "fast_food", brand: nil, cuisine: "greek"),
        BrandEntry(patterns: ["il patio"], name: "Il Patio", mainTagKey: "amenity", mainTagValue: "restaurant", brand: nil, cuisine: "italian"),
        BrandEntry(patterns: ["ilao cake", "liao cake"], name: "ILAO Cake", mainTagKey: "amenity", mainTagValue: "cafe", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["lao lee", "лао ли"], name: "Lao Lee", mainTagKey: "amenity", mainTagValue: "restaurant", brand: nil, cuisine: "vietnamese"),
        BrandEntry(patterns: ["cafe de paris", "calé de paris", "café de paris"], name: "Café de Paris", mainTagKey: "amenity", mainTagValue: "cafe", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["food embassy"], name: "Food Embassy", mainTagKey: "amenity", mainTagValue: "restaurant", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["вареничная"], name: "Вареничная №1", mainTagKey: "amenity", mainTagValue: "restaurant", brand: nil, cuisine: "ukrainian"),
        BrandEntry(patterns: ["вкусно — и точка", "вкусно и точка", "вкусно - и точка", "mcdonalds", "мcdonald"], name: "Вкусно — и точка", mainTagKey: "amenity", mainTagValue: "fast_food", brand: nil, cuisine: "burger"),
        BrandEntry(patterns: ["донер 24", "doner 24"], name: "Донер 24", mainTagKey: "amenity", mainTagValue: "fast_food", brand: nil, cuisine: "shawarma"),
        BrandEntry(patterns: ["крымские чебуреки"], name: "Крымские Чебуреки", mainTagKey: "amenity", mainTagValue: "fast_food", brand: nil, cuisine: "cheburek"),
        BrandEntry(patterns: ["скалка"], name: "Скалка", mainTagKey: "amenity", mainTagValue: "fast_food", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["рестобург"], name: "#FAR", mainTagKey: "amenity", mainTagValue: "restaurant", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["#far бар", "far bar", "#far"], name: "#FAR", mainTagKey: "amenity", mainTagValue: "bar", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["мята лаунж", "мята lounge", "мята bar", "мята бар"], name: "Мята", mainTagKey: "amenity", mainTagValue: "bar", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["донар", "donar", "турецкий ресторан"], name: "Донар", mainTagKey: "amenity", mainTagValue: "fast_food", brand: nil, cuisine: "turkish"),
        // ── Питомцы ──────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["четыре лапы", "4 лапы"], name: "Четыре Лапы", mainTagKey: "shop", mainTagValue: "pet", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["ветка"], name: "Ветка", mainTagKey: "shop", mainTagValue: "pet", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["динозаврик"], name: "Динозаврик", mainTagKey: "shop", mainTagValue: "pet", brand: nil, cuisine: nil),
        // ── Спорт ────────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["новый футбол", "newfootball"], name: "Новый Футбол", mainTagKey: "shop", mainTagValue: "sports", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["psg academy"], name: "PSG Academy Russia", mainTagKey: "leisure", mainTagValue: "sports_centre", brand: nil, cuisine: nil),
        // ── Алкоголь ─────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["simple wine", "симпл вайн"], name: "Simple Wine", mainTagKey: "shop", mainTagValue: "alcohol", brand: "Simple Wine", cuisine: nil),
        BrandEntry(patterns: ["красное & белое", "красное и белое", "red white"], name: "Красное & Белое", mainTagKey: "shop", mainTagValue: "alcohol", brand: "Красное & Белое", cuisine: nil),
        BrandEntry(patterns: ["винлаб", "vinlab"], name: "ВинЛаб", mainTagKey: "shop", mainTagValue: "alcohol", brand: nil, cuisine: nil),
        // ── Красота ──────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["леон студия", "leon студия", "леон салон"], name: "ЛЕОН", mainTagKey: "shop", mainTagValue: "beauty", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["точка красоты"], name: "Точка Красоты", mainTagKey: "shop", mainTagValue: "beauty", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["созвездие красоты"], name: "Созвездие Красоты", mainTagKey: "shop", mainTagValue: "beauty", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["стиль бюро"], name: "Стиль Бюро", mainTagKey: "shop", mainTagValue: "beauty", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["искусство гармонии"], name: "Искусство Гармонии", mainTagKey: "shop", mainTagValue: "beauty", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["чёрная кость", "черная кость"], name: "Чёрная Кость", mainTagKey: "shop", mainTagValue: "barber", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["пальчики ногтевой", "студия пальчики"], name: "Пальчики", mainTagKey: "shop", mainTagValue: "nail_salon", brand: nil, cuisine: nil),
        // ── Игрушки / хобби ──────────────────────────────────────────────────────
        BrandEntry(patterns: ["город игрушек"], name: "Город Игрушек", mainTagKey: "shop", mainTagValue: "toys", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["мир кубиков"], name: "Мир Кубиков", mainTagKey: "shop", mainTagValue: "toys", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["леонардо хобби", "leonardo хобби", "леонардо творческий"], name: "Леонардо", mainTagKey: "shop", mainTagValue: "hobby", brand: "Леонардо", cuisine: nil),
        // ── Копировальные центры ──────────────────────────────────────────────────
        BrandEntry(patterns: ["copy.ru", "копи.ру", "copy ru"], name: "Copy.ru", mainTagKey: "shop", mainTagValue: "copyshop", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["регле", "regle"], name: "Регле", mainTagKey: "shop", mainTagValue: "copyshop", brand: nil, cuisine: nil),
        // ── Кухни ────────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["кухни мария", "мария кухни", "кухонная мария"], name: "Мария", mainTagKey: "shop", mainTagValue: "kitchen", brand: "Мария", cuisine: nil),
        BrandEntry(patterns: ["стильные кухни"], name: "Стильные Кухни", mainTagKey: "shop", mainTagValue: "kitchen", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["williams oliver", "вильямс оливер"], name: "Williams Oliver", mainTagKey: "shop", mainTagValue: "houseware", brand: nil, cuisine: nil),
        // ── Ортопедия ────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["здоровье ортопед", "ортопедический салон здоровье"], name: "Здоровье", mainTagKey: "shop", mainTagValue: "orthopedics", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["dr. sursil", "доктор сурсил", "sursil"], name: "Dr. Sursil", mainTagKey: "shop", mainTagValue: "orthopedics", brand: nil, cuisine: nil),
        // ── Клиники ──────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["медси", "medsi"], name: "МЕДСИ", mainTagKey: "amenity", mainTagValue: "clinic", brand: "МЕДСИ", cuisine: nil),
        BrandEntry(patterns: ["никамед", "nikamed"], name: "Никамед", mainTagKey: "amenity", mainTagValue: "clinic", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["медлайн люкс", "medline lux"], name: "Медлайн Люкс", mainTagKey: "amenity", mainTagValue: "dentist", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["пикассо стомат", "стоматология пикассо"], name: "Пикассо", mainTagKey: "amenity", mainTagValue: "clinic", brand: nil, cuisine: nil),
        // ── Постельное белье / текстиль ───────────────────────────────────────────
        BrandEntry(patterns: ["togas", "тогас"], name: "Togas", mainTagKey: "shop", mainTagValue: "fabric", brand: "Togas", cuisine: nil),
        BrandEntry(patterns: ["орматек", "ormatek"], name: "Орматек", mainTagKey: "shop", mainTagValue: "bed", brand: "Орматек", cuisine: nil),
        // ── Прочее ────────────────────────────────────────────────────────────────
        BrandEntry(patterns: ["белая ворона детск", "детский центр белая ворона"], name: "Белая Ворона", mainTagKey: "amenity", mainTagValue: "childcare", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["синема стар", "cinema star"], name: "Синема Стар", mainTagKey: "amenity", mainTagValue: "cinema", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["галактика развлек", "рц галактика", "развлекательный центр галактика"], name: "Галактика", mainTagKey: "leisure", mainTagValue: "amusement_arcade", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["золотые ручки ателье", "ателье золотые ручки"], name: "Золотые Ручки", mainTagKey: "shop", mainTagValue: "tailor", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["иана химчистка", "химчистка иана"], name: "Иана", mainTagKey: "shop", mainTagValue: "dry_cleaning", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["оиана химчистка", "химчистка оиана"], name: "Оиана", mainTagKey: "shop", mainTagValue: "dry_cleaning", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["цветочный маркет"], name: "Цветочный Маркет", mainTagKey: "shop", mainTagValue: "florist", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["самый рыбный"], name: "Самый Рыбный", mainTagKey: "shop", mainTagValue: "seafood", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["дары моря"], name: "Дары Моря", mainTagKey: "shop", mainTagValue: "seafood", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["рублевский"], name: "Рублевский", mainTagKey: "shop", mainTagValue: "butcher", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["русские корни"], name: "Русские Корни", mainTagKey: "shop", mainTagValue: "herbalist", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["кировская меховая", "меховая фабрика"], name: "Кировская меховая фабрика", mainTagKey: "shop", mainTagValue: "fur", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["ломбард привилегия"], name: "Ломбард Привилегия", mainTagKey: "shop", mainTagValue: "pawnbroker", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["азс вднх", "лукойл вднх", "азс лукойл"], name: "АЗС ВДНХ", mainTagKey: "amenity", mainTagValue: "fuel", brand: "ЛУКОЙЛ", cuisine: nil),
        BrandEntry(patterns: ["ресо-гарантия", "ресо гарантия", "ресо"], name: "РЕСО-Гарантия", mainTagKey: "amenity", mainTagValue: "insurance", brand: "РЕСО-Гарантия", cuisine: nil),
        BrandEntry(patterns: ["от а до я продукт", "магазин от а до я"], name: "От А до Я", mainTagKey: "shop", mainTagValue: "convenience", brand: nil, cuisine: nil),
        BrandEntry(patterns: ["м. маркет", "м маркет продукт", "маркет w.", "маркет w"], name: "М. Маркет", mainTagKey: "shop", mainTagValue: "supermarket", brand: nil, cuisine: nil),
    ]

    // MARK: - Opening Hours

    /// Парсит часы работы в формат OSM
    private static func extractOpeningHours(from text: String, into result: inout ParseResult) {
        let lower = text.lowercased()

        // 24/7
        if let r = try? NSRegularExpression(pattern: #"24\/7|круглосуточно"#, options: .caseInsensitive),
           r.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
            result.set(tag: "opening_hours", value: "24/7", confidence: 0.95, status: .extracted)
            return
        }

        // Уже готовый OSM формат (Mo-Su 10:00-22:00)
        if let r = try? NSRegularExpression(pattern: #"(?:Mo|Tu|We|Th|Fr|Sa|Su)[\-\w,;\s]+\d{2}:\d{2}-\d{2}:\d{2}"#),
           let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(m.range, in: text) {
            result.set(tag: "opening_hours", value: String(text[range]), confidence: 0.85, status: .extracted)
            return
        }

        // Паттерн времени — объединяет HH:MM, HH.MM, HH:MM – HH:MM с пробелами и без
        // Используем один универсальный «захватчик» времени (\d{1,2}[:.]\d{2})
        let t = #"(\d{1,2}[:.]\d{2})"#
        let dash = #"\s*[–\-]\s*"#

        // Структуры (паттерн → осм-дни)
        let mosuTriggers: [String] = [
            // ПН-ВС / пн-вс / пон-вск
            #"(?:пн|пон)[–\-]+(?:вс|вск|воскр)"#,
            "ежедневно", "без выходных", "без перерыва и выходных",
            "7 дней в неделю", "7days",
        ]
        let mofrTriggers: [String] = [
            #"(?:пн|пон)[–\-]+(?:пт|пят)"#,
            "понедельник.*пятница", "пн.*пт",
        ]
        // Полные названия дней
        let mosuFullDayPattern = #"понедельник\s*[\-–]\s*воскресенье"#
        let mofrFullDayPattern = #"понедельник\s*[\-–]\s*пятница"#

        // Поиск времени: HH:MM - HH:MM (с пробелами или без, разным разделителем)
        let timeRangePattern = t + dash + t
        guard let timeRegex = try? NSRegularExpression(pattern: timeRangePattern, options: .caseInsensitive) else { return }

        // Помощник: найти первое совпадение времени в тексте
        func firstTimeRange(in str: String) -> (String, String)? {
            guard let m = timeRegex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
                  let r1 = Range(m.range(at: 1), in: str),
                  let r2 = Range(m.range(at: 2), in: str) else { return nil }
            return (String(str[r1]), String(str[r2]))
        }

        func normalizeTime(_ t: String) -> String {
            let parts = t.split(omittingEmptySubsequences: true, whereSeparator: { $0 == ":" || $0 == "." })
            guard parts.count == 2 else { return t }
            let h = String(parts[0]).count == 1 ? "0\(parts[0])" : String(parts[0])
            let m = String(parts[1])
            return "\(h):\(m)"
        }

        func buildOSM(days: String, open: String, close: String) -> String {
            "\(days) \(normalizeTime(open))-\(normalizeTime(close))"
        }

        // Проверяем Mo-Su триггеры
        let hasMoSuFull = (try? NSRegularExpression(pattern: mosuFullDayPattern, options: .caseInsensitive))?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
        let hasMoFrFull = (try? NSRegularExpression(pattern: mofrFullDayPattern, options: .caseInsensitive))?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil

        let hasMoSuTrigger = hasMoSuFull || mosuTriggers.contains { lower.contains($0) }
        let hasMoFrTrigger = !hasMoSuTrigger && (hasMoFrFull || mofrTriggers.contains { (try? NSRegularExpression(pattern: $0))?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil })

        if hasMoSuTrigger || hasMoFrTrigger {
            let days = hasMoSuTrigger ? "Mo-Su" : "Mo-Fr"
            if let (open, close) = firstTimeRange(in: lower) {
                result.set(tag: "opening_hours", value: buildOSM(days: days, open: open, close: close), confidence: 0.72, status: .extracted)
                return
            }
        }

        // "с HH:MM до HH:MM" / "с HH до HH"
        if let r = try? NSRegularExpression(pattern: #"с\s+(\d{1,2}[:.]\d{2})\s+до\s+(\d{1,2}[:.]\d{2})"#, options: .caseInsensitive),
           let m = r.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r1 = Range(m.range(at: 1), in: lower),
           let r2 = Range(m.range(at: 2), in: lower) {
            let open = String(lower[r1]); let close = String(lower[r2])
            result.set(tag: "opening_hours", value: buildOSM(days: "Mo-Su", open: open, close: close), confidence: 0.62, status: .extracted)
            return
        }

        // "Режим работы" / "Часы работы" / "Время работы" + HH:MM - HH:MM
        let headerKeywords = ["режим работы", "часы работы", "время работы", "работаем", "открыто с", "мы открыты"]
        for kw in headerKeywords {
            if lower.contains(kw) {
                if let (open, close) = firstTimeRange(in: lower) {
                    result.set(tag: "opening_hours", value: buildOSM(days: "Mo-Su", open: open, close: close), confidence: 0.65, status: .extracted)
                    return
                }
            }
        }

        // Bare HH:MM - HH:MM (любой формат)
        if let (open, close) = firstTimeRange(in: lower) {
            result.set(tag: "opening_hours", value: buildOSM(days: "Mo-Su", open: open, close: close), confidence: 0.55, status: .extracted)
            return
        }

        // Bare HH-HH (числа 8-24, без разделителя минут)
        if let r = try? NSRegularExpression(pattern: #"\b((?:[89]|1\d|2[0-4]))\s*[–\-]\s*((?:[89]|1\d|2[0-4]))\b"#),
           let m = r.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r1 = Range(m.range(at: 1), in: lower),
           let r2 = Range(m.range(at: 2), in: lower) {
            let open = String(lower[r1]).leftPadded(to: 2, with: "0") + ":00"
            let close = String(lower[r2]).leftPadded(to: 2, with: "0") + ":00"
            result.set(tag: "opening_hours", value: "Mo-Su \(open)-\(close)", confidence: 0.5, status: .extracted)
        }
    }

    private static func tryExtractHours(pattern: String, days: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let matchRange = Range(match.range, in: text) else { return nil }
        let matchStr = String(text[matchRange])
        return buildOSMHours(days: days, match: matchStr)
    }

    private static func buildOSMHours(days: String, match: String) -> String? {
        let timeRegex = try? NSRegularExpression(pattern: #"(\d{1,2})[:\.h](\d{2})"#)
        let range = NSRange(match.startIndex..., in: match)
        let matches = timeRegex?.matches(in: match, range: range) ?? []
        guard matches.count >= 2 else { return nil }

        func time(from m: NSTextCheckingResult) -> String? {
            guard let r1 = Range(m.range(at: 1), in: match),
                  let r2 = Range(m.range(at: 2), in: match) else { return nil }
            let h = String(match[r1]).leftPadded(to: 2, with: "0")
            let min = String(match[r2])
            return "\(h):\(min)"
        }

        guard let open = time(from: matches[0]), let close = time(from: matches[1]) else { return nil }
        return "\(days) \(open)-\(close)"
    }

    // MARK: - Social Networks (handle-based)

    private static func extractSocialNetworks(from text: String, into result: inout ParseResult) {
        // WhatsApp: "WhatsApp +7 (925) 294-91-85" или "WhatsApp: 8-925-..."
        if result.tags["contact:whatsapp"] == nil {
            let waRegex = try? NSRegularExpression(
                pattern: #"[Ww]hats[Aa]pp[:\s]*(\+?[78][\s\-\(\)]*[3489]\d{2}[\s\-\(\)]*\d{3}[\s\-]\d{2}[\s\-]\d{2})"#
            )
            if let m = waRegex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                let phone = normalizePhone(String(text[r]))
                if phone.hasPrefix("+7") {
                    result.set(tag: "contact:whatsapp", value: phone, confidence: 0.85, status: .extracted)
                }
            }
        }

        // Bare handles: "vk.com/handle", "t.me/handle", "instagram.com/handle" — без https://
        // DataDetector уже ловит полные URL в classifyAndSetURL, здесь — только bare (без схемы)
        let bareHandlePatterns: [(pattern: String, tag: String, prefix: String)] = [
            (#"(?<![/\w])vk\.com/([a-zA-Z0-9_\.]{2,40})(?=[^\w/]|$)"#, "contact:vk", "https://vk.com/"),
            (#"(?<![/\w])t\.me/([a-zA-Z0-9_]{4,40})(?=[^\w/]|$)"#, "contact:telegram", "https://t.me/"),
            (#"(?<![/\w])instagram\.com/([a-zA-Z0-9_\.]{2,40})/?(?=[^\w/]|$)"#, "contact:instagram", "https://www.instagram.com/"),
            (#"(?<![/\w])tiktok\.com/@([a-zA-Z0-9_\.]{2,40})(?=[^\w/]|$)"#, "contact:tiktok", "https://www.tiktok.com/@"),
            (#"(?<![/\w])ok\.ru/([a-zA-Z0-9_\.]{2,40})(?=[^\w/]|$)"#, "contact:ok", "https://ok.ru/"),
        ]

        for (pattern, tag, prefix) in bareHandlePatterns {
            guard result.tags[tag] == nil else { continue }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { continue }
            let handle = String(text[r]).lowercased()
            result.set(tag: tag, value: prefix + handle, confidence: 0.82, status: .extracted)
        }

        // Bare @handle (без домена, не email) → Telegram
        // Только если нет уже извлечённого Telegram и handle без точки (не домен, не email)
        if result.tags["contact:telegram"] == nil {
            let atHandleRegex = try? NSRegularExpression(
                pattern: #"(?<![a-zA-Z0-9/])@([a-zA-Z][a-zA-Z0-9_]{3,39})(?!\.[a-zA-Z])"#
            )
            if let m = atHandleRegex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                let handle = String(text[r])
                result.set(tag: "contact:telegram", value: "https://t.me/\(handle)", confidence: 0.65, status: .extracted)
            }
        }
    }

    // MARK: - Payment Methods

    private static func extractPaymentMethods(from text: String, into result: inout ParseResult) {
        let lower = text.lowercased()

        // Каждый маркер: (ключ OSM, паттерн)
        let markers: [(tag: String, pattern: String)] = [
            ("payment:visa",          #"\bvisa\b"#),
            ("payment:visa_electron", #"\bvisa\s+electron\b"#),
            ("payment:mastercard",    #"\bmastercard\b"#),
            ("payment:maestro",       #"\bmaestro\b"#),
            ("payment:unionpay",      #"\bunionpay\b"#),
            ("payment:jcb",           #"\bjcb\b"#),
            ("payment:apple_pay",     #"\bapple\s+pay\b"#),
            ("payment:google_pay",    #"\bgoogle\s+pay\b|\bg\s+pay\b"#),
            ("payment:samsung_pay",   #"\bsamsung\s+pay\b"#),
            // МИР — только если рядом платёжный контекст (visa/mastercard/сбп/карт)
            // или явная форма «карта Мир» / «карт* МИР» / «МИР» отдельным словом среди карт
            ("payment:mir",           #"карт\w*\s*[«"]?\s*мир\b|\bмир\b(?=[\s,]*(?:visa|mastercard|unionpay|сбп|pay))|\bмир\b(?:\s+\S+){0,3}\s+(?:visa|mastercard|unionpay|сбп)|(?:visa|mastercard|unionpay|сбп)(?:\s+\S+){0,3}\s+\bмир\b"#),
            ("payment:sbp",           #"\bсбп\b|система быстрых платежей"#),
            ("payment:cash",          #"\bналичн"#),
        ]

        for (tag, pattern) in markers {
            guard result.tags[tag] == nil else { continue }
            if let _ = lower.range(of: pattern, options: .regularExpression) {
                result.set(tag: tag, value: "yes", confidence: 0.85, status: .extracted)
            }
        }
    }

    // MARK: - Legal Requisites

    // MARK: - Noise Entity Masking

    /// Маскирует шумовые юридические блоки, которые не нужны в OSM,
    /// но могут мешать другим экстракторам (телефоны, postcode, адрес).
    /// Возвращает (очищенный текст, извлечённые из шума теги).
    private static func maskNoiseEntities(in text: String) -> (String, ParseResult) {
        var result = ParseResult()
        var masked = text

        // ── Вспомогательная функция маскировки совпадений ─────────────────────
        func maskMatches(of pattern: String, in str: inout String, options: NSRegularExpression.Options = [.caseInsensitive]) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            // Заменяем совпадения на пробелы той же длины, чтобы не сдвигать позиции других токенов
            let _ = str as NSString
            let matches = regex.matches(in: str, range: NSRange(str.startIndex..., in: str))
            var result = str
            for match in matches.reversed() {
                let range = match.range
                let replacement = String(repeating: " ", count: range.length)
                result = (result as NSString).replacingCharacters(in: range, with: replacement)
            }
            str = result
        }

        // ── ИНН и ОГРН нормализуем с OCR-коррекцией и извлекаем ДО маскировки ─
        let normalizedForRequisites = normalizeOCRDigits(in: text)

        if let regex = try? NSRegularExpression(
            // Захватываем жадно до 12 символов — validatedINN() отрежет лишнее по контрольной сумме
            pattern: #"ИНН\s*(?:[/\\:;,№]\s*(?:КПП\s*)?)?([О0-9lIоОЗзБ]{10,12})"#,
            options: .caseInsensitive),
           let m = regex.firstMatch(in: normalizedForRequisites, range: NSRange(normalizedForRequisites.startIndex..., in: normalizedForRequisites)),
           let r = Range(m.range(at: 1), in: normalizedForRequisites) {
            let raw = normalizeOCRDigits(in: String(normalizedForRequisites[r]))
            if let inn = validatedINN(raw) {
                result.set(tag: "ref:INN", value: inn, confidence: 0.93, status: .extracted)
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"(?:ОГРНИП|ОГРН)\s*[/\\:;,№]?\s*([0-9lIОоЗзБ]{13}|[0-9lIОоЗзБ]{15})"#, options: .caseInsensitive),
           let m = regex.firstMatch(in: normalizedForRequisites, range: NSRange(normalizedForRequisites.startIndex..., in: normalizedForRequisites)),
           let r = Range(m.range(at: 1), in: normalizedForRequisites) {
            let digits = normalizeOCRDigits(in: String(normalizedForRequisites[r]))
            if digits.count == 13 || digits.count == 15 {
                result.set(tag: "ref:OGRN", value: digits, confidence: 0.95, status: .extracted)
            }
        }

        // ── ИП ФИО → operator (до маскировки, чтобы поймать правильное значение) ─
        //    "ИП Иванов Иван Иванович" / "Индивидуальный предприниматель Фамилия Имя"
        //    [^\S\n]+ — пробелы без переноса строки, чтобы не захватывать следующую строку
        let ipPattern = #"(?:ИП|Индивидуальный\s+предприниматель)\s+([А-ЯЁA-Z][а-яёa-zA-Z]+(?:[^\S\n]+[А-ЯЁA-Z][а-яёa-zA-Z\.]+){1,3})"#
        if let regex = try? NSRegularExpression(pattern: ipPattern, options: .caseInsensitive),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text) {
            let name = String(text[r])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                // Убираем OCR-артефакт: латинская буква после точки в инициале ("А.B" → "А.")
                .replacingOccurrences(of: #"(\.[А-ЯЁа-яё]?)[A-Za-z]+$"#, with: "$1",
                                       options: .regularExpression)
            result.set(tag: "operator", value: "ИП " + name, confidence: 0.7, status: .extracted)
        }

        // ── ООО/АО/ОАО/ЗАО/ПАО/НКО/МУП/ГУП/ФГУП/ГБУ/АНО → operator ────────
        //    "ООО «ЛОМ»", "АО «Глория Джинс»", 'ГБУ "Жилищник"'
        //    Захватываем тип организации и название раздельно — форматируем в «»
        if result.tags["operator"] == nil {
            let orgPattern = #"(ООО|ОАО|ЗАО|ПАО|АО|НКО|МУП|ГУП|ФГУП|ГБУ|АНО|НП)\s*[«"]\s*([^»"\n]{2,60})\s*[»"]"#
            if let regex = try? NSRegularExpression(pattern: orgPattern, options: []),
               let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let rType = Range(m.range(at: 1), in: text),
               let rName = Range(m.range(at: 2), in: text) {
                let orgType = String(text[rType])
                let orgName = String(text[rName])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
                if !orgName.isEmpty && orgName.count <= 60 {
                    result.set(tag: "operator", value: "\(orgType) «\(orgName)»", confidence: 0.65, status: .extracted)
                }
            }
        }

        // ── Маскируем шумовые блоки ────────────────────────────────────────────

        // КПП: 9 цифр с префиксом
        maskMatches(of: #"КПП\s*[/\\:;]?\s*\d{9}"#, in: &masked)

        // БИК: 9 цифр
        maskMatches(of: #"БИК\s*[/\\:;]?\s*\d{9}"#, in: &masked)

        // Расчётный / корреспондентский счёт: 20 цифр (407..., 408..., 301...)
        maskMatches(of: #"(?:р/?с|к/?с|расч(?:ётный|ётн\.?)?|корр(?:\.?\s*счёт)?)\s*[/\\:;]?\s*\d{20}"#, in: &masked)
        // Просто 20-значные числа (без префикса — страховка)
        maskMatches(of: #"\b(?:40[1-9]|30[12])\d{17}\b"#, in: &masked)

        // ОКТМО / ОКАТО
        maskMatches(of: #"(?:ОКТМО|ОКАТО)\s*[/\\:;]?\s*\d{8,11}"#, in: &masked)

        // ИНН — маскируем после извлечения (включая формат с пробелами "ИНН 7726 0690 5083")
        maskMatches(of: #"ИНН\s*[/\\:;,№]?\s*\d[\d\s]{9,14}"#, in: &masked)
        // OCR-артефакт: значение ИНН стоит НА СТРОКУ ВЫШЕ метки "ИНН:" (IMG_9627 и подобные)
        maskMatches(of: #"(?<!\d)\d{10,12}\s*\n\s*(?:ИНН|инн)\b"#, in: &masked)
        // Одиночный лейбл ИНН:/инн: на своей строке без числа (остаток от маскировки выше)
        maskMatches(of: #"^[иИ]НН\s*[:/]?\s*$"#, in: &masked, options: [.caseInsensitive, .anchorsMatchLines])

        // ОГРНИП / ОГРН — маскируем только само число, без захвата следующих строк
        // Также покрываем OCR-разрыв: "ОГРІ\nН" или "ОГР\nН"
        maskMatches(of: #"(?:ОГРНИП|ОГРН)\s*[/\\:;]?\s*\d{13,15}"#, in: &masked)
        maskMatches(of: #"ОГР[^\n]{0,3}\n[^\n]{0,3}\s*\d{13,15}"#, in: &masked)

        // ВАЖНО: НЕ маскируем ООО/ИП + название в кавычках —
        // название может совпадать с брендом в brandDatabase.
        // Маскируем только ФИО предпринимателя (не несёт полезной информации для OSM).
        maskMatches(of: ipPattern, in: &masked)
        // "Индивидуальный предприниматель ФИО"
        maskMatches(of: #"Индивидуальный предприниматель\s+[А-ЯЁ][а-яё]+(?:\s+[А-ЯЁ][а-яё\.]+){1,3}"#, in: &masked)
        // "Общество с ограниченной ответственностью" — длинная форма без названия бренда
        maskMatches(of: #"Общество с ограниченной ответственностью"#, in: &masked)

        // Межрайонная/районная инспекция ФНС (название органа — шум)
        maskMatches(of: #"(?:Межрайонная|районная)\s+инспекция\s+[^\n]+"#, in: &masked)

        // ДАТА ДД.ММ.ГГГГ (часто рядом с ОГРН)
        maskMatches(of: #"ДАТА\s+\d{2}\.\d{2}\.\d{4}"#, in: &masked)

        // ── Маскируем осиротевшие слова-указатели ─────────────────────────────
        // После того как значения (ИНН, ОГРН, КПП, ...) замаскированы, остаются
        // «голые» лейблы вроде «ИНН:», «тел.:», «факс» — они сбивают DataDetector
        // и другие экстракторы.
        // Маскируем лейбл только если за ним НЕ идёт полезное значение.
        let orphanLabels = [
            // Реквизиты
            #"ИНН\s*[:/]?"#, #"КПП\s*[:/]?"#, #"БИК\s*[:/]?"#,
            #"ОГРН(?:ИП)?\s*[:/]?"#, #"ОКТМО\s*[:/]?"#, #"ОКАТО\s*[:/]?"#,
            #"р\s*/\s*с\s*[:/]?"#, #"к\s*/\s*с\s*[:/]?"#,
            // Контакты (маскируем ТОЛЬКО сам лейбл, не следующую строку с номером)
            #"(?:тел(?:ефон)?|phone|факс|fax)\s*[.:/]?"#,
            #"контактный телефон\s*[:/]?"#,
            // Адресные лейблы (сам маркер, без следующего адреса — он нужен экстрактору)
            #"(?:юридический|фактический|юр\.|факт\.)\s+адрес\s*[:/]?"#,
        ]
        // Лейбл на своей строке (пустая строка или только пробелы после)
        for label in orphanLabels {
            maskMatches(of: "(?m)^\(label)\\s*$", in: &masked, options: [.caseInsensitive])
        }

        return (masked, result)
    }

    /// Точечная OCR-коррекция цифр: O→0, З→3, l/I→1, Б→6 — только для числовых контекстов
    private static func normalizeOCRDigits(in text: String) -> String {
        // Применяем только внутри последовательностей, которые должны быть цифрами
        // (между явными цифрами или рядом с ними)
        var result = text
        let substitutions: [(String, String)] = [
            ("О", "0"), ("о", "0"),   // кириллица О → ноль
            ("З", "3"), ("з", "3"),   // кириллица З → тройка (осторожно — только в digit-контексте)
            ("l", "1"), ("I", "1"),   // латиница l, I → единица
        ]
        // Применяем замену только внутри "цифро-подобных" кластеров (\d+X\d+ или X\d+)
        for (from, to) in substitutions {
            let pattern = "(?<=\\d)\(NSRegularExpression.escapedPattern(for: from))(?=\\d)|(?<=\\d)\(NSRegularExpression.escapedPattern(for: from))$|^\(NSRegularExpression.escapedPattern(for: from))(?=\\d)"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: to)
            }
        }
        return result
    }

    /// Расширенная OCR-нормализация для телефонного контекста:
    /// дополнительно покрывает случай "250 O 250" (О окружена пробелами между цифрами).
    private static func normalizeOCRDigitsForPhone(_ text: String) -> String {
        var result = normalizeOCRDigits(in: text)
        // Кириллическая/латинская O между цифрой+пробел и пробел+цифра: "250 O 250"
        let spaceSubstitutions: [(String, String)] = [
            ("О", "0"), ("о", "0"), ("O", "0"), ("o", "0"),
        ]
        for (from, to) in spaceSubstitutions {
            let pattern = "(?<=\\d )\(NSRegularExpression.escapedPattern(for: from))(?= \\d)"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: to)
            }
        }
        return result
    }

    // MARK: - Legal Requisites

    private static func extractLegalRequisites(from text: String, into result: inout ParseResult) {
        // ИНН и ОГРН уже извлечены в maskNoiseEntities с OCR-нормализацией.
        // Этот метод — fallback для текста, который не прошёл через маскировку,
        // либо для форматов без явного префикса (редко).

        // ИНН: 10 или 12 цифр, часто предваряется "ИНН"
        if result.tags["ref:INN"] == nil {
            let innRegex = try? NSRegularExpression(
                pattern: #"(?:[ИI]НН\s*(?:[/\\:;,№]\s*(?:КПП\s*)?)?|НН\s+)(\d{12}(?!\d)|\d{10}(?!\d))"#,
                options: .caseInsensitive)
            innRegex?.matches(in: text, range: NSRange(text.startIndex..., in: text)).first.flatMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }.map { result.set(tag: "ref:INN", value: $0, confidence: 0.93, status: .extracted) }
        }

        // ОГРН: 13 или 15 цифр
        if result.tags["ref:OGRN"] == nil {
            let ogrnRegex = try? NSRegularExpression(pattern: #"(?:ОГРН\s*[:№]?\s*)(\d{13}|\d{15})"#, options: .caseInsensitive)
            ogrnRegex?.matches(in: text, range: NSRange(text.startIndex..., in: text)).first.flatMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }.map { result.set(tag: "ref:OGRN", value: $0, confidence: 0.95, status: .extracted) }
        }
    }

    // MARK: - Address

    /// Типы адресных фрагментов — определяют приоритет при выборе.
    private enum AddressBlockKind: Int {
        case factual = 3      // "фактический адрес", "адрес магазина" — высший приоритет
        case heuristic = 2    // строки, похожие на адрес по содержимому (без явного маркера)
        case legal = 1        // "юридический адрес", "адрес регистрации" — низший приоритет
    }

    private static func extractAddress(from text: String, into result: inout ParseResult) {
        // ── Шаг 1: находим адресные фрагменты ────────────────────────────────
        let fragments = findAddressFragments(in: text)

        // ── Шаг 2 + 3: парсим каждый фрагмент, берём первый успешный по приоритету ──
        for fragment in fragments.sorted(by: { $0.kind.rawValue > $1.kind.rawValue }) {
            parseAddressFragment(fragment.text, priority: fragment.kind, into: &result)
            if result.tags["addr:street"] != nil && result.tags["addr:housenumber"] != nil { break }
        }
    }

    private struct AddressBlock {
        let text: String   // уже склеенный в одну строку адресный фрагмент
        let kind: AddressBlockKind
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ШАГ 1: поиск адресных фрагментов
    // ──────────────────────────────────────────────────────────────────────────

    /// Возвращает список адресных фрагментов: по явным маркерам + по эвристике.
    private static func findAddressFragments(in text: String) -> [AddressBlock] {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var fragments: [AddressBlock] = []

        // ── 1a. Явные маркеры ──────────────────────────────────────────────
        // Фактический / маркер магазина (высший приоритет)
        // "фактическ" — частичный матч для OCR-маглов: "фактический апоес", "Фактический аарес" и т.п.
        let factualPatterns = [
            "фактический адрес", "факт. адрес", "факт.адрес",
            "адрес магазина", "адрес торговой точки", "адрес объекта", "наш адрес",
            "фактическ",   // fallback: любой OCR-мангл "фактический"
            "магазин №", "магазин no", "магазин nº", "магазин n°", // "Магазин №30402, г. ..."
            "рактическ",   // OCR-мангл: "практический адрес" / "рактический вдрео"
        ]
        // Юридический адрес (низший приоритет)
        let legalPatterns = [
            "юридический адрес", "юр. адрес", "юр.адрес",
            "адрес регистрации", "адрес юридического лица",
            "адрес места нахождения", "место нахождения",
            "юридического лица",
            "оридическ", // OCR-мангл: "Оридический адрес" вместо "Юридический адрес"
        ]
        // Слабый маркер "адрес:" — фактический если нет более специфичного
        let weakFactualPatterns = ["адрес:"]

        // Для маркеров: текст после маркера на той же строке + следующие строки (maxNextLines).
        // Для legal maxNextLines=0 — юр. адрес обычно на одной строке,
        // а захват следующей строки рискует поглотить адрес магазина.
        func extractAfterMarker(markerLine: String, markerPattern: String,
                                lineIndex: Int, allLines: [String],
                                maxNextLines: Int) -> String {
            let lower = markerLine.lowercased()
            guard let r = lower.range(of: markerPattern, options: .caseInsensitive) else { return "" }
            let sameLine = String(markerLine[r.upperBound...]).trimmingCharacters(in: .init(charactersIn: " :.,"))
            var parts: [String] = []
            if !sameLine.isEmpty { parts.append(sameLine) }
            if maxNextLines > 0 {
                let nextLines = allLines.dropFirst(lineIndex + 1).prefix(maxNextLines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                parts.append(contentsOf: nextLines)
            }
            return parts.joined(separator: " ")
        }

        var foundFactual = false
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            if let pat = factualPatterns.first(where: { lower.contains($0) }) {
                let text = extractAfterMarker(markerLine: line, markerPattern: pat, lineIndex: i, allLines: lines, maxNextLines: 2)
                if !text.isEmpty { fragments.append(.init(text: text, kind: .factual)); foundFactual = true }
            }
        }
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            if let pat = legalPatterns.first(where: { lower.contains($0) }) {
                // maxNextLines=0: юр. адрес берём только с текущей строки (не захватываем адрес магазина на следующей)
                let text = extractAfterMarker(markerLine: line, markerPattern: pat, lineIndex: i, allLines: lines, maxNextLines: 0)
                if !text.isEmpty { fragments.append(.init(text: text, kind: .legal)) }
            }
        }
        if !foundFactual {
            for (i, line) in lines.enumerated() {
                let lower = line.lowercased()
                if let pat = weakFactualPatterns.first(where: { lower.contains($0) }) {
                    let text = extractAfterMarker(markerLine: line, markerPattern: pat, lineIndex: i, allLines: lines, maxNextLines: 2)
                    if !text.isEmpty { fragments.append(.init(text: text, kind: .factual)) }
                }
            }
        }

        // ── 1b. Эвристика: строки, похожие на адрес ──────────────────────
        // Признаки адресной строки (проверяем каждую строку и пары строк):
        let streetTypeRx = try? NSRegularExpression(
            pattern: #"(?:^|[\s,])(?:ул|пер|пр-т|пр-кт|пр-?д|наб|пл|проспект|переулок|набережная|площадь|проезд|шоссе|бульвар)\b"#,
            options: .caseInsensitive)
        let houseRx = try? NSRegularExpression(
            pattern: #"\bд\.?\s*\d|\bдом\s*\d"#,
            options: .caseInsensitive)
        let postcodeRx = try? NSRegularExpression(pattern: #"\b[1-9]\d{5}\b"#)

        // Все маркерные строки: не добавляем их как heuristic (они уже обработаны как factual/legal)
        let allMarkers = factualPatterns + legalPatterns + weakFactualPatterns
        func isMarkerLine(_ s: String) -> Bool {
            let low = s.lowercased()
            return allMarkers.contains(where: { low.contains($0) })
        }

        func isAddressLike(_ s: String) -> Bool {
            guard s.count > 5 else { return false }
            let r = NSRange(s.startIndex..., in: s)
            let hasStreetType = streetTypeRx?.firstMatch(in: s, range: r) != nil
            let hasHouse      = houseRx?.firstMatch(in: s, range: r) != nil
            let hasPostcode   = postcodeRx?.firstMatch(in: s, range: r) != nil
            // Bare-адрес без "д.": "Улица, 29" или "Москва, Улица, 29"
            let hasBareNumber = (try? NSRegularExpression(pattern: #"[А-ЯЁа-яё]{4,},\s*\d"#))?.firstMatch(in: s, range: r) != nil
            // OCR-split суффикс: "Долгоруков кая, 35" — "word suffix, digit"
            let hasSplitSuffix = (try? NSRegularExpression(pattern: #"[А-ЯЁа-яё]{4,}\s+(?:ская|ской|ский|кая|ное|ная),\s*\d"#, options: .caseInsensitive))?.firstMatch(in: s, range: r) != nil
            return hasPostcode || hasStreetType || hasHouse || hasBareNumber || hasSplitSuffix
        }

        // Собираем группы из 1-3 соседних строк, похожих на адрес
        // Bare-число на следующей строке (типа "39/6" без "д.")
        let bareNumberRx = try? NSRegularExpression(pattern: #"^\d[\d/\-]*$"#)
        var i = 0
        while i < lines.count {
            // Маркерные строки не добавляем как heuristic — уже обработаны
            if !isMarkerLine(lines[i]) && isAddressLike(lines[i]) {
                var group = [lines[i]]
                var j = i + 1
                while j < lines.count && j < i + 3 {
                    let next = lines[j]
                    let r = NSRange(next.startIndex..., in: next)
                    let isBareNum = bareNumberRx?.firstMatch(in: next, range: r) != nil
                    // Маркерные строки не тянем в группу — иначе legal-адрес
                    // попадает в heuristic-фрагмент и перекрывает правильный адрес
                    guard !isMarkerLine(next) else { break }
                    if houseRx?.firstMatch(in: next, range: r) != nil ||
                       postcodeRx?.firstMatch(in: next, range: r) != nil ||
                       streetTypeRx?.firstMatch(in: next, range: r) != nil ||
                       isBareNum {
                        group.append(next)
                        j += 1
                    } else { break }
                }
                let combined = group.joined(separator: " ")
                // Не дублируем только против factual-фрагментов (legal не блокирует heuristic)
                let alreadyCovered = fragments.contains { $0.kind == .factual && $0.text.contains(combined.prefix(30)) }
                if !alreadyCovered {
                    // Если после группы сразу идут строки с ОГРН/ИНН — это регистрационный адрес, приоритет как legal
                    let nextLines = lines[j..<min(j+3, lines.count)]
                    let nextText = nextLines.joined(separator: " ").lowercased()
                    let isRegistration = nextText.contains("огрн") || nextText.contains("инн") ||
                                         combined.lowercased().contains("огрн") || combined.lowercased().contains("инн")
                    let kind: AddressBlockKind = isRegistration ? .legal : .heuristic
                    fragments.append(.init(text: combined, kind: kind))
                }
                i = j
            } else {
                i += 1
            }
        }

        return fragments
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ШАГ 2: парсинг частей адреса внутри одного фрагмента
    // ──────────────────────────────────────────────────────────────────────────

    /// Парсит один адресный фрагмент (уже короткая строка) и заполняет result.
    private static func parseAddressFragment(_ text: String, priority: AddressBlockKind, into result: inout ParseResult) {
        // Legal — чуть ниже confidence, но выше порога 0.6 (legal * 0.9 >= 0.6 → legal >= 0.67)
        let cityConf: Double   = priority == .legal ? 0.68 : 0.82
        let streetConf: Double = priority == .legal ? 0.68 : 0.72
        let houseConf: Double  = priority == .legal ? 0.68 : 0.77
        let postConf: Double   = priority == .legal ? 0.68 : 0.84

        // OCR часто разбивает почтовый индекс пробелом: "129 090" → "129090"
        var normalized = text
        if let r = try? NSRegularExpression(pattern: #"\b(\d{3})\s(\d{3})\b"#) {
            normalized = r.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "$1$2")
        }
        // OCR-артефакт: "УЛ.І" / "УЛ\І" / "УЛ|" / "УЛИ" (кириллица И как разделитель) перед именем
        if let r = try? NSRegularExpression(pattern: #"(ул|пер|наб|пл|пр-д)\s*[ІIИи|\\\/]\.?\s*"#, options: .caseInsensitive) {
            normalized = r.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "$1. ")
        }
        // OCR дублирует букву в типе улицы: "улл." → "ул."
        if let r = try? NSRegularExpression(pattern: #"\bул{2,}\."#, options: .caseInsensitive) {
            normalized = r.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "ул.")
        }
        // OCR разбивает суффикс "ская" как " кая" (пропускает 'с'):
        // "Долгоруков кая" → "Долгоруковская"
        if let r = try? NSRegularExpression(pattern: #"([А-ЯЁа-яё]{4,}ов)\s+кая\b"#, options: .caseInsensitive) {
            normalized = r.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "$1ская")
        }
        // OCR пишет порядковые числительные в расширенной форме: "1-ая" → "1-я", "2-ого" → "2-го"
        if let r = try? NSRegularExpression(pattern: #"\b(\d+)-а([яю])\b"#, options: .caseInsensitive) {
            normalized = r.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "$1-$2")
        }
        if let r = try? NSRegularExpression(pattern: #"\b(\d+)-о([йго])\b"#, options: .caseInsensitive) {
            normalized = r.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "$1-$2")
        }
        // OCR разбивает суффиксы русских слов пробелом: "Долгоруков ская" → "Долгоруковская"
        // Паттерн: слово 5+ букв, пробел, суффикс (ская/ский/кого/ского/ной/ному/...)
        let suffixRx = try? NSRegularExpression(
            pattern: #"([А-ЯЁа-яё]{4,})\s+(ская|ской|ского|ские|ских|ском|ский|кого|ному|ная|ной|ного|ные|ных|ном|ную)"#,
            options: .caseInsensitive)
        if let r = suffixRx {
            normalized = r.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "$1$2")
        }

        // Город
        let cityList = "Москва|Санкт-Петербург|Санкт Петербург|Новосибирск|Екатеринбург|Казань|Нижний Новгород|Самара|Омск|Краснодар|Ростов-на-Дону|Воронеж|Пермь|Красноярск|Волгоград|Тюмень|Мытищи|Химки|Подольск|Красногорск|Одинцово|Балашиха|Щёлково|Лобня|Зеленоград|Троицк|Щербинка"
        let cityRegex = try? NSRegularExpression(
            pattern: #"(?:г(?:ород)?\.?\s*|city\s+)(\#(cityList))"#, options: .caseInsensitive)
        cityRegex?.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).first.flatMap { m in
            Range(m.range(at: 1), in: normalized).map { String(normalized[$0]) }
        }.map { result.set(tag: "addr:city", value: $0, confidence: cityConf, status: .extracted) }

        // Улица — расширенный список префиксов
        // Паттерн 1: тип. имя (стандартный порядок)
        // Паттерн 1: тип. имя (стандартный порядок)
        // ВАЖНО: убраны lookahead-паттерны пр(?=оспект) и пл(?=ощадь) — они захватывали
        // неверную группу 2 (например "оспект" вместо имени улицы).
        // Для "пр." требуем точку или дефис-т чтобы не матчить внутри "проспект".
        // Группа 1 = тип, группа 2 = имя
        let streetRegex = try? NSRegularExpression(
            pattern: #"(улица|ул|пр-кт|пр-т|пр\.|проспект|переулок|пер|набережная|наб|площадь|бульвар|б-р|пр-?д|проезд|аллея|шоссе|тракт)(?:\.\s*|\s+)((?:\d{1,3}-[а-яёА-ЯЁ]{1,3}|[А-ЯЁа-яёA-Za-z])[А-ЯЁа-яёA-Za-z0-9\-\s]{1,50}?)(?:\s*[,;]|\s+д\.|\s+дом\b|\s+\d+[^-]|\n|$)"#,
            options: .caseInsensitive
        )
        // Паттерн 2: обратный порядок — "Оружейный пер.", "Долгоруковская ул.", "Олимпийский проспект"
        // Добавлены: пр-кт, б-р. Имя может начинаться с "1-я", "2-й" etc.
        // Защита от телефонов: имя не может начинаться с 6+ цифр подряд.
        let streetRevRegex = try? NSRegularExpression(
            pattern: #"((?:\d{1,3}-[а-яёА-ЯЁ]|[А-ЯЁа-яё])[А-ЯЁа-яёA-Za-z0-9\-\s]*?)\s+(проспект|пр-кт|пр-т|переулок|пер\.?|набережная|наб\.?|площадь|пл\.?|проезд|пр-д\.?|шоссе|бульвар|б-р|улица|ул\.?|аллея|тракт)(?:\.{0,2}\s*[,;]|\.{0,2}\s+д\.|\s+дом\b|\s+\d+|\n|$)"#,
            options: .caseInsensitive
        )
        // Паттерн 3: bare — "Москва, Долгоруковская, 29" (без явного типа и "д.")
        let streetBareRegex = try? NSRegularExpression(
            pattern: #"(?:г\.?\s*[А-ЯЁа-яё][А-ЯЁа-яё\-]*|[А-ЯЁа-яё]{3,}),\s+([А-ЯЁа-яё][А-ЯЁа-яёA-Za-z0-9\-\s]{3,30}?),\s+(?:д\.?\s*)?\d+"#,
            options: .caseInsensitive
        )

        // Нормализация: тип + имя → addr:street
        // isReverse=true: тип после имени → "имя тип_полный"
        // isReverse=false: тип до имени → правила конвенции OSM
        func makeStreetValue(typeRaw: String, name: String, isReverse: Bool = false) -> String {
            let t = typeRaw.lowercased().trimmingCharacters(in: .init(charactersIn: ". \t"))
            let nm = name.trimmingCharacters(in: .whitespaces)
            // Убираем хвостовые одиночные символы ("НОВОСЛОБОДСКАЯ З" → "НОВОСЛОБОДСКАЯ")
            // Убираем хвостовые номера: "Нежинская 9-140" → "Нежинская" (квартирный/офисный номер)
            let nmClean = nm
                .replacingOccurrences(of: #"\s+\d[\d\-]+$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+[А-ЯЁа-яёA-Za-z0-9]$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !nmClean.isEmpty else { return "" }

            // ALL CAPS → SentenceCase по словам: "ШЕРЕМЕТЬЕВСКАЯ" → "Шереметьевская"
            // Слова из только заглавных букв (кириллица/латиница) приводим к Title Case.
            // Короткие служебные токены (1-Я, 4-Я, и т.д.) не трогаем — они уже в нужном виде.
            func toSentenceCase(_ s: String) -> String {
                guard s == s.uppercased(), s.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
                    return s
                }
                let lower = s.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            let nmNorm = nmClean.components(separatedBy: " ").map(toSentenceCase).joined(separator: " ")

            // Полный суффикс для reverse-порядка
            func suffix() -> String {
                if t.hasPrefix("пер") { return "переулок" }
                if t.hasPrefix("наб") { return "набережная" }
                if t.hasPrefix("пл")  { return "площадь" }
                if t.hasPrefix("пр-д") || t.hasPrefix("прое") { return "проезд" }
                if t == "б-р" || t.hasPrefix("буль") { return "бульвар" }
                if t.hasPrefix("шосс") { return "шоссе" }
                if t.hasPrefix("пр") { return "проспект" } // пр-т, пр-кт, проспект
                return "" // улица/ул → без суффикса
            }

            if isReverse {
                let s = suffix()
                return s.isEmpty ? nmNorm : "\(nmNorm) \(s)"
            }

            // Стандартный порядок:
            if t.hasPrefix("ул") { return nmNorm }           // ул./улица → только имя (адъективная форма)
            // Все варианты проспекта → "Проспект Имя" (генитив: "Мира", "Стачки" и т.д.)
            if t.hasPrefix("пр") && !t.hasPrefix("пр-д") && !t.hasPrefix("прое") {
                let cap = nmNorm.prefix(1).uppercased() + nmNorm.dropFirst()
                return "Проспект \(cap)"
            }
            if t.hasPrefix("пер") { return "\(nmNorm) переулок" }
            if t.hasPrefix("наб") { return "\(nmNorm) набережная" }
            if t.hasPrefix("пл")  { return "\(nmNorm) площадь" }
            if t.hasPrefix("пр-д") || t.hasPrefix("прое") { return "\(nmNorm) проезд" }
            if t == "б-р" || t.hasPrefix("буль") { return "бульвар \(nmNorm)" }
            if t.hasPrefix("шосс") { return "\(nmNorm) шоссе" }
            return nmNorm
        }

        if result.tags["addr:street"] == nil,
           let m = streetRegex?.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let r1 = Range(m.range(at: 1), in: normalized),
           let r2 = Range(m.range(at: 2), in: normalized) {
            let streetVal = makeStreetValue(typeRaw: String(normalized[r1]), name: String(normalized[r2]), isReverse: false)
            if !streetVal.isEmpty {
                result.set(tag: "addr:street", value: streetVal, confidence: streetConf, status: .extracted)
            }
        }
        // Паттерн 2: обратный порядок
        if result.tags["addr:street"] == nil,
           let m = streetRevRegex?.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let r1 = Range(m.range(at: 1), in: normalized),
           let r2 = Range(m.range(at: 2), in: normalized) {
            let streetVal = makeStreetValue(typeRaw: String(normalized[r2]), name: String(normalized[r1]), isReverse: true)
            if !streetVal.isEmpty {
                result.set(tag: "addr:street", value: streetVal, confidence: streetConf * 0.9, status: .extracted)
            }
        }
        // Паттерн 3: bare
        if result.tags["addr:street"] == nil,
           let m = streetBareRegex?.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let r1 = Range(m.range(at: 1), in: normalized) {
            let name = String(normalized[r1]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                // Для bare используем полный streetConf (не снижаем) — паттерн с городом достаточно надёжен
                result.set(tag: "addr:street", value: name, confidence: streetConf, status: .extracted)
            }
        }

        // Дом — "д. 5", "д.12а", "дом 3/2", "д5"
        // стр./корп. добавляем к housenumber если идут сразу после (OSM-практика: "1 стр. 4")
        let houseRegex = try? NSRegularExpression(
            pattern: #"д(?:ом)?\.?\s*(\d+\s*[а-яёА-ЯЁ]?(?:[\/\-]\d+[а-яёА-ЯЁ]?)?)"#,
            options: .caseInsensitive
        )
        if let m = houseRegex?.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let r = Range(m.range(at: 1), in: normalized) {
            var house = String(normalized[r]).trimmingCharacters(in: .whitespaces)
            let afterHouse = String(normalized[r.upperBound...].prefix(30))
            if let strMatch = try? NSRegularExpression(pattern: #"^\s*,?\s*стр(?:оение)?\.?\s*(\d+)"#, options: .caseInsensitive),
               let sm = strMatch.firstMatch(in: afterHouse, range: NSRange(afterHouse.startIndex..., in: afterHouse)),
               let sr = Range(sm.range(at: 1), in: afterHouse) {
                house += " стр. " + String(afterHouse[sr])
            } else if let korpMatch = try? NSRegularExpression(pattern: #"^\s*,?\s*к(?:орп(?:ус)?)?\.?\s*(\d+[а-яёА-ЯЁ]?)"#, options: .caseInsensitive),
                      let km = korpMatch.firstMatch(in: afterHouse, range: NSRange(afterHouse.startIndex..., in: afterHouse)),
                      let kr = Range(km.range(at: 1), in: afterHouse) {
                house += " к. " + String(afterHouse[kr])
            }
            if !house.isEmpty {
                result.set(tag: "addr:housenumber", value: house, confidence: houseConf, status: .extracted)
            }
        }

        // Почтовый индекс: 6 цифр начиная с 1-9 (не часть более длинного числа)
        let postcodeRegex = try? NSRegularExpression(pattern: #"(?<!\d)([1-9]\d{5})(?!\d)"#)
        postcodeRegex?.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).first.flatMap { m in
            Range(m.range(at: 1), in: normalized).map { String(normalized[$0]) }
        }.map { result.set(tag: "addr:postcode", value: $0, confidence: postConf, status: .extracted) }
    }

    /// OCR-коррекции специфичные для адресного текста:
    /// Пробел внутри индекса ("129 090" → "129090")
    // NOTE: latin→cyrillic substitution намеренно убрана —
    // глобальная замена слов нарушала housenumber/brand в соседних блоках.

    // MARK: - Organization Name (NLP)

    private static func extractOrganizationName(from text: String, into result: inout ParseResult) {
        guard result.tags["name"] == nil else { return }  // Не перезаписываем если уже есть

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            if tag == .organizationName {
                let name = String(text[tokenRange])
                if name.count >= 2 {
                    result.set(tag: "name", value: name, confidence: 0.55, status: .extracted)
                    return false  // Берём первое совпадение
                }
            }
            return true
        }
    }

    // MARK: - Helpers

    private static func normalizePhone(_ phone: String) -> String {
        var digits = phone.filter { $0.isNumber }
        // 8XXXXXXXXXX → +7XXXXXXXXXX
        if digits.hasPrefix("8") && digits.count == 11 {
            digits = "7" + digits.dropFirst()
        }
        // 10-значный без кода страны: (495) XXX-XX-XX, 9XX XXX-XX-XX
        // Добавляем 7, только если начинается с 3,4,5,6,8,9 — НЕ с 7
        // (10-digit ИНН начинаются с 7, и мы не хотим их путать с телефонами)
        if digits.count == 10, let first = digits.first, "345689".contains(first) {
            digits = "7" + digits
        }
        guard digits.count == 11, digits.hasPrefix("7") else { return phone }
        let d = Array(digits).map { String($0) }
        return "+\(d[0]) \(d[1...3].joined()) \(d[4...6].joined())-\(d[7...8].joined())-\(d[9...10].joined())"
    }
}

// MARK: - ParseResult

struct ParseResult {
    private(set) var tags: [String: String] = [:]
    private(set) var confidence: [String: Double] = [:]
    private(set) var fieldStatus: [String: FieldStatus] = [:]

    mutating func set(tag key: String, value: String, confidence: Double, status: FieldStatus) {
        // Не перезаписываем если уже есть более уверенное значение
        if let existing = self.confidence[key], existing >= confidence { return }
        tags[key] = value
        self.confidence[key] = confidence
        fieldStatus[key] = status
    }

    /// Мёрджит теги из другого источника (напр. QR-парсер).
    /// Значения с более высоким конфидентом побеждают.
    mutating func merge(tags newTags: [String: String], confidence newConf: [String: Double], status: FieldStatus = .extracted) {
        for (key, value) in newTags {
            let conf = newConf[key] ?? 0.7
            set(tag: key, value: value, confidence: conf, status: status)
        }
    }

    var isEmpty: Bool { tags.isEmpty }

    /// Применить результат к POI
    func apply(to poi: inout POI) {
        for (key, value) in tags {
            if poi.tags[key] == nil {  // Не перезаписываем существующие OSM теги
                poi.tags[key] = value
                poi.extractionConfidence[key] = confidence[key]
                poi.fieldStatus[key] = fieldStatus[key] ?? .extracted
            }
        }
    }
}

// MARK: - INN checksum validation

/// Проверяет ИНН по контрольной сумме (алгоритм Минфина РФ).
/// Принимает 10–12 цифр. Пробует варианты в порядке убывания длины:
/// 12 цифр → INN-12, 10 цифр → INN-10, первые 10 из 11–12 → INN-10.
/// Возвращает валидный ИНН или nil.
private func validatedINN(_ s: String) -> String? {
    let digits = s.compactMap { $0.wholeNumberValue }
    guard digits.count >= 10 else { return nil }

    // Пробуем 12 цифр как ИНН-12
    if digits.count >= 12 {
        let d12 = Array(digits.prefix(12))
        if isValidINN12(d12) { return d12.map(String.init).joined() }
    }
    // Пробуем 10 цифр как ИНН-10
    let d10 = Array(digits.prefix(10))
    if isValidINN10(d10) { return d10.map(String.init).joined() }

    // Контрольные суммы не сошлись (возможно OCR-искажение) — возвращаем как есть
    // только если длина строго 10 или 12
    if digits.count >= 12 { return Array(digits.prefix(12)).map(String.init).joined() }
    if digits.count == 10 { return d10.map(String.init).joined() }
    // Иная длина (11 и т.д.) — скорее всего OCR-артефакт, не возвращаем ничего
    return nil
}

private func innChecksum(_ digits: [Int], weights: [Int]) -> Int {
    zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10
}

private func isValidINN10(_ d: [Int]) -> Bool {
    guard d.count == 10 else { return false }
    let w = [2, 4, 10, 3, 5, 9, 4, 6, 8]
    return innChecksum(Array(d.prefix(9)), weights: w) == d[9]
}

private func isValidINN12(_ d: [Int]) -> Bool {
    guard d.count == 12 else { return false }
    let w1 = [7, 2, 4, 10, 3, 5, 9, 4, 6, 8]
    let w2 = [3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8]
    return innChecksum(Array(d.prefix(10)), weights: w1) == d[10]
        && innChecksum(Array(d.prefix(11)), weights: w2) == d[11]
}

// MARK: - String helper

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        if self.count >= length { return self }
        return String(repeating: character, count: length - self.count) + self
    }
}
