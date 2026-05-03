# Импорт справочника типов POI

## Обзор

Справочники `POITypes.json` и `POIFields.json` генерируются автоматически из публичной схемы
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
  import_presets.js                ← скрипт импорта (Node.js ≥ 18, ESM)
POI Scanner/Resources/
  POITypes.json                    ← 372 типа POI (amenity/shop/craft/…)
  POIFields.json                   ← 183 определения полей с RU-переводами
Docs/
  PresetImport.md                  ← этот файл
```

---

## Форматы файлов

### POITypes.json

```json
{
  "_generated": "2026-04-27T17:01:51.343Z",
  "_source": "https://github.com/openstreetmap/id-tagging-schema",
  "types": [
    {
      "id":      "amenity/cafe",
      "key":     "amenity",
      "value":   "cafe",
      "name":    "Кафе",
      "terms":   ["coffee", "coffeehouse", ...],
      "presets": ["cuisine", "diet:", "opening_hours", "payment:", "phone", "website", ...]
    },
    ...
  ]
}
```

| Поле | Описание |
|------|----------|
| `id` | Уникальный идентификатор: `"key/value"` |
| `key` | Базовый OSM-ключ |
| `value` | Значение базового ключа |
| `name` | Русское название (из `NAME_OVERRIDES` → схемы) |
| `terms` | Поисковые синонимы и термины из схемы |
| `presets` | Список ключей/псевдонимов групп, рекомендованных для данного типа |

Текущее распределение по ключам:

| Ключ | Типов |
|------|-------|
| `amenity` | 131 |
| `shop` | 170 |
| `craft` | 50 |
| `healthcare` | 17 |
| `public_transport` | 4 |
| **Итого** | **372** |

### POIFields.json

```json
{
  "_generated": "2026-04-27T17:01:51.343Z",
  "_source": "https://github.com/openstreetmap/id-tagging-schema",
  "fields": [
    {
      "id":        "diet_multi",
      "osmKey":    "diet:",
      "inputType": "multiCombo",
      "label":     "Диета",
      "keyPrefix": "diet:",
      "options": [
        { "value": "vegan",        "label": "Веганская диета" },
        { "value": "vegetarian",   "label": "Вегетарианская диета" },
        ...
      ]
    },
    ...
  ]
}
```

| Поле | Описание |
|------|----------|
| `id` | ID поля из схемы |
| `osmKey` | Тег, как он записан в `presets` типа (может оканчиваться на `:` для multiCombo-групп) |
| `inputType` | `text`, `select`, `check`, `multiCombo`, `semiCombo`, `openingHours`, `url`, `tel`, `email`, `number` |
| `label` | Человекочитаемое название на русском |
| `options` | Только для `select` / `semiCombo` / `multiCombo` — список возможных значений с переводами |
| `keyPrefix` | Только для `multiCombo` — префикс субключей (напр. `"fuel:"` → теги `fuel:diesel`, `fuel:lpg`, …) |

---

## Группы multiCombo-полей

Поля с `inputType: "multiCombo"` и `osmKey` вида `"prefix:"` отображаются в редакторе
как **именованные секции** (аналогично «Адресу» или «Способам оплаты»), а не как отдельные строки.
Соответствующий псевдоним прописывается в `presets` типа.

| Псевдоним в `presets` | Группа в редакторе | Ключи тегов |
|-----------------------|--------------------|-------------|
| `payment:` | Способы оплаты | `payment:cash`, `payment:visa`, … |
| `fuel:` | Виды топлива | `fuel:diesel`, `fuel:lpg`, … |
| `diet:` | Питание | `diet:vegan`, `diet:halal`, … |
| `recycling:` | Приём вторсырья | `recycling:paper`, `recycling:glass_bottles`, … |
| `currency:` | Принимаемые валюты | `currency:RUB`, `currency:EUR`, … |
| `service:bicycle:` | Велосервис | `service:bicycle:repair`, … |
| `service:vehicle:` | Автосервис | `service:vehicle:tyres`, … |

---

## Запуск импорта

### Требования

- **Node.js ≥ 18** (встроенный `fetch`, поддержка ESM)
- Интернет-соединение (скачивает схему с CDN)

### Команда

```bash
node Scripts/import_presets.js
```

Скрипт всегда берёт тег `@latest` пакета `id-tagging-schema`, поэтому при каждом запуске
используется актуальная версия схемы.

### Когда перезапускать

- При выходе новой версии `id-tagging-schema`
  (следить на [GitHub Releases](https://github.com/openstreetmap/id-tagging-schema/releases))
- При добавлении нового базового ключа в `ALLOWED_BASE_KEYS`
- При расширении `NAME_OVERRIDES`

После обновления JSON-файлов — закоммитить их вместе со скриптом.

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

После добавления — перезапустить скрипт и добавить переводы в `NAME_OVERRIDES`.

### Добавить русский перевод названия типа

```js
const NAME_OVERRIDES = {
  // ...
  'tourism/hotel':  'Гостиница',
  'tourism/museum': 'Музей',
};
```

Типы без записи в `NAME_OVERRIDES` получают название из RU-перевода схемы,
а при его отсутствии — английское название.

### Изменить набор универсальных полей

Поля, добавляемые к **каждому** типу независимо от схемы:

```js
const UNIVERSAL_EXTRA_FIELDS = ['opening_hours', 'phone', 'website'];
```

---

## Фильтры — что отбрасывается

| Критерий | Причина |
|----------|---------|
| Базовый ключ не в `ALLOWED_BASE_KEYS` | Дороги, рельеф, маршруты и т.д. — не POI |
| `searchable: false` | Скрытые/внутренние пресеты |
| `suggestion: true` | Брендовые пресеты из name-suggestion-index |
| `replacement` присутствует | Deprecated-пресеты |
| Значение тега `"*"` или `""` | Wildcard-пресеты (`healthcare/*`) |
| Более одного тега в `tags` | Составные пресеты (`amenity=fast_food + cuisine=burger`) — слишком специфичны |

---

## Связь с кодом приложения

| Файл | Роль |
|------|------|
| `POITypeRegistry.swift` | Загружает `POITypes.json`; предоставляет поиск по ключу/значению и список пресетов |
| `POIFieldRegistry.swift` | Загружает `POIFields.json`; индексирует поля по `osmKey` и `keyPrefix` |
| `POITypePickerView.swift` | Выбор типа POI — использует `name` и `terms` |
| `POIEditorView.swift` | Секция «Тип», подстановка пресетов, отображение multiCombo-групп |
| `OSMNodeInfoView.swift` | Read-only карточка — группировка тегов по `TagGroup` |
| `OSMTags.swift` | Статический справочник известных тегов; предикаты `is*Key()` для определения группы |
| `OSMValueLocalizations.swift` | Словари переводов значений тегов; fallback через `POIFieldRegistry` |
