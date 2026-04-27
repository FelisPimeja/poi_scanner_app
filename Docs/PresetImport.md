# Импорт справочника типов POI

## Обзор

Справочник типов POI (`POITypes.json`) генерируется автоматически из публичной схемы
[`@openstreetmap/id-tagging-schema`](https://github.com/openstreetmap/id-tagging-schema) —
той же базы данных, которую использует веб-редактор [iD Editor](https://github.com/openstreetmap/iD).

Это позволяет:
- **не поддерживать справочник вручную** — достаточно перезапустить скрипт при выходе новой версии схемы;
- **переиспользовать проверенную OSM-таксономию** — названия типов, поля, термины для поиска;
- **держать бандл приложения компактным** — в JSON попадает только нужный нам срез (~370 типов из ~1700).

---

## Структура файлов

```
Scripts/
  import_presets.js          ← скрипт импорта (Node.js, ESM)
POI Scanner/Resources/
  POITypes.json              ← результат (добавлен в Xcode-проект как ресурс бандла)
```

---

## Формат POITypes.json

```json
{
  "_generated": "2026-04-27T12:54:44.278Z",
  "_source": "https://github.com/openstreetmap/id-tagging-schema",
  "types": [
    {
      "id":      "amenity/cafe",
      "key":     "amenity",
      "value":   "cafe",
      "name":    "Кафе",
      "terms":   ["coffee", "coffeehouse", ...],
      "presets": ["cuisine", "opening_hours", "outdoor_seating", "phone", "website", ...]
    },
    ...
  ]
}
```

| Поле | Описание |
|------|----------|
| `id` | Уникальный идентификатор: `"key/value"` |
| `key` | Базовый OSM-ключ (`amenity`, `shop`, `craft`, `public_transport`, `healthcare`) |
| `value` | Значение базового ключа (`cafe`, `supermarket`, …) |
| `name` | Человекочитаемое название (русское, если задан перевод, иначе английское из схемы) |
| `terms` | Поисковые термины и синонимы из схемы (для нечёткого поиска в будущем) |
| `presets` | Список OSM-ключей, которые рекомендуется заполнить для данного типа |

---

## Запуск импорта

### Требования

- **Node.js ≥ 18** (встроенный `fetch`, поддержка ESM-модулей)
- Интернет-соединение (скачивает схему с CDN)

### Команда

```bash
node Scripts/import_presets.js
```

Скрипт всегда берёт тег `@latest` пакета `id-tagging-schema`, поэтому при каждом запуске
используется актуальная версия схемы.

### Когда перезапускать

- При выходе новой мажорной или минорной версии `id-tagging-schema`
  (следить на [GitHub Releases](https://github.com/openstreetmap/id-tagging-schema/releases))
- При добавлении нового базового ключа в фильтр `ALLOWED_BASE_KEYS`
- При расширении списка русских переводов в `NAME_OVERRIDES`

После обновления `POITypes.json` — закоммитить файл вместе со скриптом.

---

## Кастомизация скрипта

Все параметры вынесены в верхнюю часть `Scripts/import_presets.js`.

### Добавить новый базовый ключ

```js
const ALLOWED_BASE_KEYS = new Set([
  'amenity',
  'shop',
  'craft',
  'public_transport',
  'healthcare',
  'tourism',   // ← добавить сюда
]);
```

### Добавить или исправить русский перевод

```js
const NAME_OVERRIDES = {
  // ...
  'tourism/hotel': 'Гостиница',
  'tourism/museum': 'Музей',
};
```

Типы без записи в `NAME_OVERRIDES` получают английское название из схемы.

### Изменить набор универсальных полей

Поля, добавляемые к **каждому** типу независимо от схемы:

```js
const UNIVERSAL_EXTRA_FIELDS = ['opening_hours', 'phone', 'website'];
```

---

## Фильтры — что отбрасывается

Скрипт намеренно **исключает**:

| Критерий | Причина |
|----------|---------|
| Базовый ключ не в `ALLOWED_BASE_KEYS` | Дороги, рельеф, коммуникации, маршруты и т.д. — не POI |
| `searchable: false` | Скрытые/внутренние пресеты (не для пользователя) |
| `suggestion: true` | Брендовые пресеты из name-suggestion-index (McDonald's, Starbucks…) |
| `replacement` присутствует | Deprecated-пресеты с заменой |
| Значение тега `"*"` или `""` | Wildcard-пресеты (`healthcare/*`) |
| Более одного тега в `tags` | Составные пресеты (напр. `amenity=fast_food + cuisine=burger`) — слишком специфичны для верхнеуровневого выбора |

---

## Связь с кодом приложения

`POITypes.json` загружается в Swift-модели через `POITypeRegistry` (планируется).  
Используется в:
- `POITypePickerView` — экран выбора/поиска типа POI в редакторе
- `POIEditorView` — секция «Тип», подстановка пресетов после выбора
