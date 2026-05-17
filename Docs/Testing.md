# Тестирование — пайплайн и скрипты

## Обзор

Тестовый слой проверяет три уровня: от изолированного парсинга текста до полного цикла фото → OSM-теги. В основе — набор реальных фотографий вывесок (~477 шт.) с эталонными JSON-файлами.

```
Fixtures/Photos/        ← реальные фото (не в git, ~200 МБ после сжатия)
Fixtures/Expected/      ← эталонные JSON (в git, 406 файлов)
Fixtures/Drafts/        ← черновики автогенерации (не в git)
Fixtures/ocr_cache.json ← кэш OCR-текстов (не в git)
```

---

## Уровни тестов

### 1. Unit — `TextParserTests`

Парсер изолирован от OCR: на вход подаётся готовый текст, на выход — OSM-теги.

**Файл:** `POI ScannerTests/TextParserTests.swift`

Охват:
- Телефоны (российские, международные, нормализация +7)
- Сайты и соцсети (VK, Telegram, Instagram)
- Часы работы (диапазоны, 24/7, каждый день)
- Юридические реквизиты (ИНН, ОГРН)
- Адреса (улицы, номера домов с корпусом/строением)
- Email, подъезды, диапазоны квартир

Запуск одного теста:
```bash
./Scripts/run_tests.sh unit
```

---

### 2. Integration — `VisionServiceTests`

OCR на реальных фото, проверяем базовое качество распознавания.

**Файл:** `POI ScannerTests/VisionServiceTests.swift`

| Тест | Что проверяет |
|---|---|
| `testAllPhotosProduceText` | OCR возвращает непустой текст для каждого фото |
| `testKeyStringsAreRecognized` | Название (`name`) присутствует в распознанном тексте (>50% слов) |
| `testConfidenceIsReasonable` | Средний confidence OCR > 40% |
| `testBuildOCRCache` | Прогоняет OCR по всем фото и сохраняет кэш → `ocr_cache.json` |

> `testBuildOCRCache` — служебный тест. Запускается вручную один раз после добавления новых фото или после пересжатия.

---

### 3. E2E — `ExtractionPipelineTests`

Полный конвейер: фото → OCR → парсер → сравнение с эталоном.

**Файл:** `POI ScannerTests/ExtractionPipelineTests.swift`

| Тест | Что делает |
|---|---|
| `testAllFixturesExtraction` | Строгая проверка по каждой фикстуре, падает на первом расхождении |
| `testExtractionQualityReport` | Сводный отчёт по всем тегам; падает только если общий скор < 50% |
| `testExtractionQualityReportFast` | То же, но использует `ocr_cache.json` — секунды вместо минут |
| `testDiagnoseTag` | Подробный разбор одного тега по всем фикстурам (для отладки парсера) |

**Рекомендуемый рабочий цикл при работе над парсером:**
1. `./Scripts/run_tests.sh quality` — быстрая итерация (использует кэш)
2. `./Scripts/run_tests.sh quality-slow` — финальная проверка на живом OCR
3. `./Scripts/run_tests.sh all` — строгий прогон перед мержем

---

## Формат эталонного JSON

Файл: `Fixtures/Expected/<id>.json`

```json
{
  "id": "IMG_9592",
  "description": "Кофейня, вывеска + табличка с часами",
  "expectedTags": {
    "name": "Кофе Хауз",
    "amenity": "cafe",
    "phone": "+7 495 123-45-67",
    "opening_hours": "Mo-Su 08:00-22:00"
  },
  "minimumConfidence": {
    "name": 0.9,
    "phone": 0.95,
    "opening_hours": 0.7
  },
  "optionalTags": ["brand", "wifi"]
}
```

Поле `minimumConfidence` — нижняя граница уверенности парсера для тега. Если парсер нашёл значение, но с confidence ниже порога — тест всё равно падает.

---

## Воркфлоу добавления новых фото

```
1. Сбросить фото в Fixtures/Photos/
2. ./Scripts/compress_photos.sh           ← сжать до 1500px/JPEG 80%
3. Запустить testGenerateFixturesFromPhotos  ← генерация черновиков (Drafts/)
4. Запустить testPromoteDraftsToExpected     ← авторазметка (Drafts/promoted/)
5. Проверить файлы в Drafts/promoted/ вручную
6. Переместить проверенные файлы в Fixtures/Expected/
7. Запустить testBuildOCRCache              ← пересобрать кэш (если нужна скорость)
```

### FixtureGenerator — шаг 3

**Файл:** `POI ScannerTests/FixtureGenerator.swift`

Прогоняет OCR + QR-детекцию по каждому фото, применяет парсер и сохраняет черновик:

```json
{
  "sourcePhoto": "IMG_9592.jpg",
  "recognizedText": ["КОФЕ ХАУЗ", "Пн-Вс 08:00-22:00", "+7 495 123-45-67"],
  "extractedTags": { "phone": "+7 495 123-45-67", "opening_hours": "Mo-Su 08:00-22:00" },
  "extractedConfidence": { "phone": 0.98, "opening_hours": 0.72 }
}
```

Уже готовые `Expected` файлы не перезаписываются.

### DraftPromoter — шаг 4

**Файл:** `POI ScannerTests/DraftPromoter.swift`

Читает черновики и создаёт заготовки `Expected` с:
- `extractedTags` → `expectedTags` (нужна ручная проверка!)
- дефолтными порогами `minimumConfidence` (0.5–0.9 по типу поля)
- `description` из первых строк OCR

Результат — `Drafts/promoted/*.json`. Просмотри каждый файл перед переносом в `Expected/`.

---

## OCR-кэш

**Файл:** `Fixtures/ocr_cache.json`

Хранит результаты OCR в виде `{ "IMG_9592": "КОФЕ ХАУЗ\nПн-Вс 08:00..." }`. Позволяет прогонять парсер без Vision (5 мин → секунды).

Пересобрать кэш:
```
Запустить testBuildOCRCache в VisionServiceTests
```

Кэш становится неактуальным после:
- добавления новых фото
- пересжатия фото (размер влияет на OCR при критически малых деталях)
- обновления `VisionService`

---

## Скрипты

### `Scripts/run_tests.sh`

Запускает тесты на симуляторе **iPhone 17**. Принимает команду:

| Команда | Что делает |
|---|---|
| `unit` | TextParserTests + QRContentParserTests (без OCR, быстро) |
| `quality` | Отчёт по качеству через OCR-кэш (секунды) |
| `quality-slow` | Отчёт по качеству с живым OCR (~5 мин) |
| `generate` | Генерация черновых фикстур из фото |
| `promote` | Авторазметка черновиков → `Drafts/promoted/` |
| `build-cache` | Пересборка OCR-кэша |
| `all` | Все тесты (без generate/promote/build-cache) |

```bash
./Scripts/run_tests.sh generate    # прогнать OCR по новым фото
./Scripts/run_tests.sh quality      # быстрый отчёт по парсеру
```

---

### `Scripts/compress_photos.sh`

Сжимает фото для тестов: HEIC → JPEG 1500px / 80%. Убирает оригинальные HEIC. Перепаковывает крупные JPEG/PNG.

```bash
# Стандартный запуск (Fixtures/Photos/):
./Scripts/compress_photos.sh

# Новая порция фото из конкретной папки:
./Scripts/compress_photos.sh ~/Downloads/new_poi_photos
```

Параметры сжатия задаются переменными в начале скрипта: `MAX_PX`, `JPEG_QUALITY`, `SIZE_THRESHOLD_KB`.

После сжатия пересобери OCR-кэш (`testBuildOCRCache`), если он использовался.

### `Scripts/import_presets.js`

Генерирует `POITypes.json` и `POIFields.json` из схемы `@openstreetmap/id-tagging-schema`.

```bash
node Scripts/import_presets.js
```

Подробнее: [Docs/PresetImport.md](PresetImport.md)

---

## Метрики качества (последний прогон — апрель 2026)

| Поле | Результат | Скор |
|---|---|---|
| `addr:postcode` | 13/13 | ✅ 100% |
| `ref:OGRN` | 5/5 | ✅ 100% |
| `phone` | 5/5 | ✅ 100% |
| `addr:street` | 9/11 | ✅ 81% |
| `ref:INN` | 5/7 | ⚠️ 71% |
| `addr:housenumber` | 6/12 | ❌ 50% |
| `opening_hours` | 2/16 | ❌ 12% |
| `name` | 0/10 | ❌ 0% |
| `website` | 0/5 | ❌ 0% |

**Общий скор: 51%** (порог: 50%)

Бэклог улучшений парсера — в [PLAN.md](../PLAN.md#бэклог-улучшений-textparser).
