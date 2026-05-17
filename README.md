# POI Scanner

iOS-приложение для сбора, валидации и загрузки точек интереса (POI) в OpenStreetMap. Основной сценарий: сфотографировать вывеску → OCR извлекает данные → проверить в редакторе → загрузить в OSM.

## Документация

| Документ | Содержание |
|---|---|
| [PLAN.md](PLAN.md) | Общая концепция, архитектура, стек, статус задач |
| [SCREENS.md](SCREENS.md) | Экраны и навигация |
| [Docs/Testing.md](Docs/Testing.md) | Тестовый пайплайн, фикстуры, скрипты |
| [Docs/PresetImport.md](Docs/PresetImport.md) | Генерация POITypes.json и POIFields.json |
| [Docs/MapTiler Tiles — v3 vs v4.md](Docs/MapTiler%20Tiles%20—%20v3%20vs%20v4.md) | Отличия форматов тайлов |

## Структура проекта

```
POI Scanner/          ← исходный код приложения
POI ScannerTests/     ← тесты и тестовые фикстуры
Scripts/              ← служебные скрипты
Docs/                 ← документация
Config/               ← URL-схемы и конфиги
```

## Быстрый старт для тестов

```bash
# 1. Добавить новые фото в POI ScannerTests/Fixtures/Photos/
# 2. Сжать до рабочего размера
./Scripts/compress_photos.sh

# 3. Сгенерировать черновые фикстуры (тест в Xcode)
#    POI ScannerTests → FixtureGenerator → testGenerateFixturesFromPhotos

# 4. Авторазметка черновиков
#    POI ScannerTests → DraftPromoter → testPromoteDraftsToExpected
#    → проверить Fixtures/Drafts/promoted/ → переложить в Fixtures/Expected/

# 5. Пересобрать OCR-кэш для быстрых прогонов
#    POI ScannerTests → VisionServiceTests → testBuildOCRCache

# 6. Прогнать отчёт по качеству (использует кэш, работает секунды)
#    POI ScannerTests → ExtractionPipelineTests → testExtractionQualityReportFast
```

Подробнее — [Docs/Testing.md](Docs/Testing.md).

## Внешние зависимости

- **MapLibre GL Native** (SPM) — карта
- Всё остальное — нативные Apple frameworks (Vision, NaturalLanguage, CoreLocation, PhotosUI, SwiftData)
