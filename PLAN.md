# POI Scanner — План разработки

## Концепция

Мобильное iOS-приложение для быстрого сбора, валидации и загрузки данных о POI в OpenStreetMap. Основной сценарий: пользователь фотографирует вывеску или визитку заведения, приложение извлекает данные через OCR, пользователь проверяет и дополняет их в редакторе, затем загружает в OSM.

---

## Воркфлоу

```
MapView (главный экран)
  │
  ├─ тап на существующую OSM-ноду
  │     └─ BottomSheet: текущие теги + кнопка «Улучшить»
  │           └─ ValidationView (предзаполнен из OSM)
  │                 └─ опционально: CaptureView для дообогащения через OCR
  │
  └─ долгий тап / кнопка «+»
        └─ CoordinatePickerView (перетащи пин для точности)
              └─ CaptureView (фото — опционально)
                    └─ ExtractionView (OCR + парсинг)
                          └─ ValidationView (предзаполнен или пустой)
                                └─ Upload в OSM
```

---

## Структура проекта

```
POI Scanner/
├── App/
│   └── POI_ScannerApp.swift
│
├── Features/
│   ├── Map/
│   │   ├── MapView.swift                  # MLNMapView (UIViewRepresentable)
│   │   ├── MapViewModel.swift             # Overpass запросы, состояние карты
│   │   ├── OverpassService.swift          # Запросы к Overpass API
│   │   ├── IndoorLayerManager.swift       # Управление indoor слоями
│   │   ├── LevelPickerView.swift          # Переключатель этажей
│   │   ├── GeoJSONLayer.swift             # Управление слоями нод
│   │   └── CoordinatePickerView.swift     # Draggable пин для выбора координат
│   │
│   ├── Capture/
│   │   ├── CaptureView.swift              # Камера / PhotosUI
│   │   └── CaptureViewModel.swift
│   │
│   ├── Extraction/
│   │   ├── ExtractionView.swift           # Прогресс OCR + предпросмотр
│   │   ├── ExtractionViewModel.swift
│   │   └── TextParser.swift               # Regex + NLP парсинг полей
│   │
│   ├── Validation/
│   │   ├── ValidationView.swift           # Главный экран редактирования
│   │   ├── ValidationViewModel.swift
│   │   ├── TagEditorView.swift            # Расширенный редактор атрибутов
│   │   ├── OpeningHoursEditorView.swift   # Визуальный редактор часов работы
│   │   ├── POITypePickerView.swift        # Каталог OSM типов (amenity/shop/…)
│   │   └── OSMTagInfoView.swift           # Встроенные подсказки по тегам
│   │
│   └── Upload/
│       ├── UploadView.swift
│       └── OSMUploader.swift              # Changeset, node create/modify
│
├── Models/
│   ├── POI.swift                          # Главная модель данных
│   ├── OSMNode.swift                      # Существующая нода из OSM
│   ├── OSMTags.swift                      # Маппинг полей → OSM теги
│   └── ScanSession.swift                  # История сессий (SwiftData)
│
└── Services/
    ├── VisionService.swift                # Vision / VNRecognizeTextRequest
    ├── NLPService.swift                   # NaturalLanguage NER
    ├── LocationService.swift              # CoreLocation
    └── OSMAPIService.swift                # OSM API v0.6 (changeset, node)
```

---

## Компоненты — детали

### MapView (главный экран)
- Базовая карта на **MapLibre GL Native** (SPM: `maplibre-gl-native-distribution`)
- Векторные OSM тайлы: **Stadia Maps** для разработки / **Protomaps** для офлайн-продакшена
- Существующие OSM ноды загружаются через **Overpass API** как GeoJSON-слой
- Долгий тап → создание нового POI с перетаскиваемым пином
- Тап на ноду → BottomSheet с текущими тегами

### Indoor карта
- Тайлы: **indoor.equal** (`https://tiles.indoorequal.org/{z}/{x}/{y}.pbf`)
- Включаются автоматически при zoom ≥ 17
- **LevelPickerView** — вертикальный список доступных этажей здания
- Фильтрация слоя по уровню через `NSPredicate` на `level=*`
- При создании нового POI внутри здания: автоматически проставляются `level=*`, `indoor=yes`

### OCR + парсинг (Extraction)
- **`VNRecognizeTextRequest`** — OCR, поддержка русского и английского
- **`NSDataDetector`** — телефоны, email, URL
- **`NaturalLanguage`** — NER для имён и адресов
- **`TextParser`** — кастомные regex для:
  - часов работы → формат OSM (`Mo-Fr 09:00-18:00`)
  - соцсетей (`@handle`, `vk.com/…`, `t.me/…`)
  - юридических реквизитов (ИНН, ОГРН)

### ValidationView — редактор атрибутов
Сегменты (горизонтальный скролл):

| Сегмент | Теги |
|---|---|
| 🏷 Основное | `name`, `name:ru`, `brand`, `operator` |
| 📍 Адрес | `addr:street`, `addr:housenumber`, `addr:city`, `addr:floor` |
| 📞 Контакты | `phone`, `website`, `email` |
| 🕐 Часы работы | `opening_hours` + визуальный редактор |
| 🌐 Соцсети | `contact:vk`, `contact:telegram`, `contact:instagram` |
| 🏢 Расположение | `level`, `indoor`, `building` |
| ⚙️ Все теги | Таблица `key=value` для произвольных тегов |

Каждое поле имеет статус:
- 🟡 `extracted` — получено из OCR
- 🟢 `confirmed` — проверено пользователем
- ⚪️ `manual` — введено вручную

### OpeningHoursEditorView
- Визуальная сетка: дни недели × временные слоты
- Генерирует строку в формате OSM (`Mo-Fr 09:00-18:00; Sa 10:00-16:00`)
- Поддержка: круглосуточно (`24/7`), выходные, перерывы

### Upload
- Авторизация: **OAuth 2.0 PKCE** (OSM API)
- Создание changeset с `comment` и `source=survey`
- Существующая нода → `node modify`; новая → `node create`
- Локальное сохранение в **SwiftData** для истории и оффлайн-очереди

---

## Модель данных

```swift
struct POI: Identifiable, Codable {
    var id: UUID
    var coordinate: CLLocationCoordinate2D
    var osmNodeId: Int64?                       // nil = новый объект
    var tags: [String: String]                  // финальные OSM теги
    var sourceImages: [Data]
    var extractionConfidence: [String: Double]  // поле → уверенность OCR
    var status: POIStatus                       // draft / validated / uploaded
    var createdAt: Date
}

enum POIStatus: String, Codable {
    case draft
    case validated
    case uploaded
}
```

---

## Технологический стек

| Задача | Технология |
|---|---|
| Карта | MapLibre GL Native (SPM) |
| Векторные тайлы | Stadia Maps / Protomaps |
| Indoor карта | indoor.equal tiles |
| Overpass API | URLSession + async/await |
| OCR | `Vision` — `VNRecognizeTextRequest` |
| NER / язык | `NaturalLanguage` |
| Телефоны, URL | `NSDataDetector` |
| Геолокация | `CoreLocation` |
| Камера | `PhotosUI` / `AVFoundation` |
| Хранение | `SwiftData` |
| OSM авторизация | OAuth 2.0 PKCE |
| OSM API | URLSession, OSM API v0.6 |

---

## Порядок разработки

1. ✅ **Модели** — `POI.swift`, `OSMNode.swift`, `OSMTags.swift`
2. ✅ **Тестовые фикстуры** — каталог реальных фото + эталонные JSON, настройка тест-таргета
3. ✅ **`VisionService`** + **`TextParser`** — OCR и парсинг, покрыты тестами (21/21 ✅)
4. ✅ **`MapView`** — MapLibre + MapTiler тайлы + Overpass ноды (параллельные запросы, дебаунс, bbox-кэш)
5. ✅ **`CaptureView`** + **`ExtractionView`** — полный OCR флоу, GPS из PHAsset + EXIF fallback
6. ✅ **`ValidationView`** — редактор тегов (сегменты, статусы полей)
7. ✅ **`PhotoMetadataService`** — GPS координаты из EXIF raw bytes + PHAsset.location
8. ✅ **`MapPreferences`** — UserDefaults персистентность центра карты и zoom
9. ✅ **Draft POI маркеры** — оранжевые звёзды на карте, тап для редактирования черновика
10. ✅ **`POICache`** — Overpass POI кэш на диск (JSON, bbox-валидация, TTL 24ч)
11. 🔄 **Улучшение `TextParser`** ← **сейчас** (name 0%, website 0%, opening_hours 12%)
    - 11.1 🔄 **Расширение датасета** — прогнать `FixtureGenerator` на всех ~300 фото → черновые JSON в `Fixtures/Drafts/`
    - 11.2 ⏳ **`DraftPromoter`** — полуавтомат: отфильтровать пустые фото, переименовать поля, добавить дефолтные `minimumConfidence`, не трогать уже готовые `Expected`
    - 11.3 ⏳ **`DatasetAnalyzer`** — анализ драфтов: поля найденные OCR но не распознанные парсером, типичные нераспознанные паттерны, распределение по типам заведений
    - 11.4 ⏳ **Правки парсера** — на основе анализа: новые regex, расширение `opening_hours`, `name`, `website`, `amenity`
12. ⏳ **`CoordinatePickerView`** — draggable пин для уточнения координат
13. ⏳ **`IndoorLayerManager`** + **`LevelPickerView`** — indoor слой
14. ⏳ **`OSMAPIService`** + OAuth 2.0 PKCE + Upload — последним, когда флоу стабилен

---

## Результаты первого E2E прогона (19 апреля 2026)

Запущен `testExtractionQualityReport` по 20 эталонным фикстурам (реальные фото вывесок).

| Поле | Результат | Скор |
|------|-----------|------|
| `addr:postcode` | 13/13 | ✅ 100% |
| `ref:OGRN` | 5/5 | ✅ 100% |
| `phone` | 5/5 | ✅ 100% |
| `addr:street` | 9/11 | ✅ 81% |
| `ref:INN` | 5/7 | ⚠️ 71% |
| `addr:housenumber` | 6/12 | ❌ 50% |
| `opening_hours` | 2/16 | ❌ 12% |
| `name` | 0/10 | ❌ 0% |
| `website` | 0/5 | ❌ 0% |
| `amenity` | 0/2 | ❌ 0% |
| `addr:city` | 0/1 | ❌ 0% |

**Общий скор: 51%** — хороший результат для первого прогона, структурные данные (индекс, ОГРН, телефон) распознаются отлично.

### Бэклог улучшений TextParser

**Приоритет 1 — высокий импакт:**
- `name` (0%) — NLTagger не справляется с вывесками; нужна стратегия: первая «короткая» строка (≤5 слов) заглавными буквами / самая крупная строка из OCR `boundingBox`; попробовать несколько эвристик с fallback-цепочкой
- `website` (0%) — `NSDataDetector` не видит URL без `http://`; нужен regex для доменов типа `site.ru`, `www.example.com`
- `opening_hours` (12%) — часы разбиты на несколько строк; нужно склеивать соседние строки перед парсингом, расширить паттерны (диапазоны без явных дней)

**Приоритет 2 — средний импакт:**
- `addr:housenumber` (50%) — захватывает лишний текст после номера; ужесточить regex (граница слова после номера)
- `ref:INN` (71%) — regex не принимает 9-значные ИНН (ждёт 10 или 12 цифр)

**Примечание по эталонам:** эталонные JSON создавались на основе черновиков OCR, сами фото не проверялись визуально. Часть нулевых результатов может быть ошибкой в эталонах — стоит выборочно сверить при улучшении парсера.

---

## Будущие возможности (вне MVP)

### Обогащение данных из сайтов и соцсетей

Если в процессе OCR или из существующих OSM-данных найден `website`, `contact:vk`, `contact:instagram` и т.д. — их можно использовать как **дополнительный источник структурированных данных**, зачастую более актуальных и полных чем фото.

**Приоритет источников (от надёжного к менее):**
```
Сайт заведения (structured data / schema.org)
  > Соцсети (VK, Instagram, 2GIS — у них часто есть API)
    > OCR с фото
      > Существующие OSM теги
```

**Что можно извлекать:**
- `opening_hours` — расписание на сайте чаще актуально и уже структурировано
- `phone`, `email` — контакты в футере сайта
- `name`, `branch` — официальное название бренда
- `cuisine`, `delivery` — для заведений питания
- Фото заведения для визуальной проверки

**Технический подход:**
- `WebEnrichmentService.swift` — загружает страницу, ищет `schema.org/LocalBusiness` JSON-LD и OpenGraph теги (не требует парсинга HTML вручную)
- Для соцсетей — публичные API где доступны (VK API, возможно 2GIS)
- Результат показывается пользователю как **предложения** со статусом `suggested` (отдельный цвет в редакторе), не перезаписывает подтверждённые поля
- Запросы только с явного согласия пользователя (кнопка «Найти в интернете»)

**Влияние на тесты:**
- Добавить в фикстуры поле `websiteUrl` с мок-ответом
- `WebEnrichmentServiceTests` — тесты на парсинг JSON-LD и OpenGraph

---

## Внешние зависимости

| Пакет | Источник | Назначение |
|---|---|---|
| `maplibre-gl-native-distribution` | github.com/maplibre/maplibre-gl-native-distribution | Карта |

Все остальные технологии — нативные Apple frameworks, без внешних зависимостей.

---

## Тестирование на реальных фото

### Структура тест-таргета

```
POI ScannerTests/
├── Fixtures/
│   ├── Photos/                        # Реальные фото POI
│   │   ├── cafe_signboard_01.jpg
│   │   ├── shop_window_01.jpg
│   │   ├── business_card_01.jpg
│   │   └── ...
│   └── Expected/                      # Эталонные результаты парсинга
│       ├── cafe_signboard_01.json
│       ├── shop_window_01.json
│       └── ...
│
├── VisionServiceTests.swift           # OCR: точность распознавания текста
├── TextParserTests.swift              # Парсинг: поля из распознанного текста
├── ExtractionPipelineTests.swift      # E2E: фото → финальные теги POI
└── TestHelpers/
    ├── FixtureLoader.swift            # Загрузка фото и JSON из bundle
    └── ExtractionResultMatcher.swift  # Кастомные XCTAssert для сравнения тегов
```

### Формат эталонного JSON

```json
{
  "sourcePhoto": "cafe_signboard_01.jpg",
  "description": "Кофейня, вывеска + табличка с часами",
  "expectedTags": {
    "name": "Кофе Хауз",
    "amenity": "cafe",
    "phone": "+7 495 123-45-67",
    "opening_hours": "Mo-Su 08:00-22:00",
    "website": "https://example.com"
  },
  "minimumConfidence": {
    "name": 0.9,
    "phone": 0.95,
    "opening_hours": 0.7
  },
  "optionalTags": ["brand", "wifi", "outdoor_seating"]
}
```

### Уровни тестов

**Unit — `TextParserTests`**
Парсер тестируется отдельно от OCR: на вход подаётся готовый текст (как будто уже распознан), на выход — теги.
```swift
func testParseOpeningHours() {
    let text = "Работаем Пн-Пт с 9:00 до 18:00, Сб 10:00-16:00"
    let result = TextParser.parse(text)
    XCTAssertEqual(result.tags["opening_hours"], "Mo-Fr 09:00-18:00; Sa 10:00-16:00")
}
```

**Integration — `VisionServiceTests`**
OCR на реальных фото, проверяем что ключевые строки вообще распознаются:
```swift
func testRecognizesPhoneNumber() async throws {
    let image = FixtureLoader.photo("cafe_signboard_01")
    let strings = try await VisionService.recognizeText(in: image)
    XCTAssert(strings.joined().contains("+7 495"))
}
```

**E2E — `ExtractionPipelineTests`**
Полный конвейер фото → теги, сравниваем с эталоном:
```swift
func testFullExtractionPipeline() async throws {
    let fixture = FixtureLoader.fixture("cafe_signboard_01")
    let poi = try await ExtractionPipeline.run(image: fixture.photo)

    for (tag, expectedValue) in fixture.expectedTags {
        XCTAssertEqual(poi.tags[tag], expectedValue, "Тег \(tag) не совпал")
    }
}
```

### Метрики качества OCR

Отдельный тест генерирует **сводный отчёт** по всем фикстурам:

```swift
func testExtractionQualityReport() async throws {
    let report = await ExtractionQualityReporter.run(fixtures: FixtureLoader.allFixtures())
    // Выводит в консоль XCTest:
    // ✅ name:           18/20 (90%)
    // ✅ phone:          17/20 (85%)
    // ⚠️ opening_hours:  12/20 (60%)
    // ❌ website:         8/20 (40%)
    XCTAssert(report.overallScore > 0.7, "Общий скор ниже 70%: \(report.overallScore)")
}
```

Это позволяет отслеживать регрессии при изменении `TextParser` и видеть по каким типам полей OCR работает хуже всего.

