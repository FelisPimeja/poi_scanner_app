# POI Scanner — Экраны и навигация

## Схема переходов

```
┌─────────────────────────────────────────────────────────┐
│                    MapView (карта)                      │
│                    ──────────────                       │
│  • MapLibre-карта с нодами OSM и черновиками            │
│  • [+] кнопка добавления POI                            │
│  • Кнопка геолокации                                    │
│  • FloorPicker (indoor-режим)                           │
└─────┬──────────┬───────────────┬───────────────┬────────┘
      │          │               │               │
   тап на     тап на           тап на           [+]
  OSM-ноду  черновик (🟠)    indoor POI        кнопка
      │          │               │               │
      ▼          ▼               ▼               ▼
┌──────────┐ ┌──────────┐  (то же что   ┌─────────────┐
│NodeSheet │ │Validation│   OSM-нода)   │  Capture    │
│(просмотр)│ │  View    │               │   View      │
│──────────│ │(черновик)│               │─────────────│
│Теги OSM  │ │          │               │ • Камера    │
│[Закрыть] │ └────┬─────┘               │ • Галерея   │
│[Улучшить]│      │                     │ • Пропустить│
└────┬─────┘  Сохранить /               └──┬──────┬───┘
     │        ↑ OSM                        │      │
  [Улучшить]                          фото │   Пропустить
     │ (inline,                            │      │
     │  без sheet)                         ▼      ▼
     ▼                               ┌──────────┐ ┌──────────┐
┌──────────┐                         │Extraction│ │Validation│
│NodeSheet │                         │  View    │ │  View    │
│(редактир)│                         │──────────│ │(пустой)  │
│──────────│                         │OCR прогр.│ └────┬─────┘
│[Segmented│                         │QR-скан   │      │
│ Control] │                         └────┬─────┘  Сохранить /
│──────────│                              │        ↑ OSM
│Simplified│                         распознано
│  Tags    │                              │
│──────────│                              ▼
│[Отмена]  │                        ┌──────────┐
│[Сохранить│                        │Validation│
│[↑ OSM]  ]│                        │  View    │
└──────────┘                        │(заполнен)│
                                    │──────────│
                                    │Simplified│
                                    │  / Tags  │
                                    │[Фото 🔍] │
                                    │[Отмена]  │
                                    │[Сохранить│
                                    │[↑ OSM]  ]│
                                    └──────────┘
```

---

## Официальные названия экранов

| Swift-имя | Название в общении | Файл |
|---|---|---|
| `MapView` | **Карта** | `Features/Map/MapView.swift` |
| `OSMNodeSheet` (просмотр) | **NodeSheet / Карточка ноды** | `Features/Map/MapView.swift` |
| `OSMNodeSheet` (редактирование) | **NodeEditor** | `Features/Map/MapView.swift` |
| `CaptureView` | **Capture** | `Features/Capture/CaptureView.swift` |
| `ExtractionView` | **Extraction** | `Features/Extraction/ExtractionView.swift` |
| `ValidationView` | **Validation** | `Features/Validation/ValidationView.swift` |

---

## Флоу А — Новый POI

Триггер: кнопка `[+]` на карте.

```
Карта
  └─[+]──► Capture
               ├─[Снять / Галерея]──► Extraction ──► Validation (заполнен)
               └─[Пропустить]────────────────────────► Validation (пустой)
```

**Состояния:**
- `viewModel.isAddingPOI = true` → показывает Capture
- `extractionItemForNew` → показывает Extraction
- `manualPOIForNew` → показывает Validation (пустой, Пропустить)

**Результат:** `viewModel.saveDraftPOI(_:)` → оранжевый маркер 🟠 на карте

---

## Флоу Б — Улучшение существующей ноды

Триггер: тап на синий маркер OSM-ноды на карте.

```
Карта
  └─[тап на ноду]──► NodeSheet (просмотр)
                          └─[Улучшить]──► NodeSheet (NodeEditor, inline)
                                              ├─ вкладка Simplified
                                              │    └─ редактируемые поля с метками
                                              └─ вкладка Tags
                                                   └─ сырые key/value, свайп — удалить
```

**Кнопки в NodeEditor:**
- `[Отмена]` — возврат в режим просмотра (без сохранения)
- `[Сохранить]` → `viewModel.saveDraftPOI(_:)` → оранжевый маркер 🟠
- `[↑ OSM]` → авторизация (если нужно) → загрузка changeset → закрыть

**Состояния:**
- `viewModel.selectedNode` → показывает NodeSheet
- `viewModel.isLoadingDetails` → спиннер в NodeSheet пока грузятся теги

---

## Флоу В — Редактирование черновика

Триггер: тап на оранжевый маркер 🟠 (сохранённый черновик).

```
Карта
  └─[тап на 🟠]──► Validation (черновик)
                        ├─[Сохранить] → обновляет черновик на карте
                        └─[↑ OSM]    → загружает в OSM, статус uploaded
```

**Состояния:**
- `viewModel.selectedDraftPOI` → показывает Validation

---

## Статусы POI

| Статус | Когда | Маркер |
|---|---|---|
| `.draft` | Только создан | 🟠 оранжевая звезда |
| `.validated` | Сохранён через [Сохранить] | 🟠 оранжевая звезда |
| `.uploading` | В процессе загрузки | — |
| `.uploaded` | Успешно загружен в OSM | — (исчезает с карты черновиков) |
| `.failed` | Ошибка загрузки | 🟠 оранжевая звезда |

---

## Компоненты внутри экранов

### ValidationView
- **Simplified** (единственный режим) — поля с переведёнными метками, цветные статусы:
  - 🟡 OCR — извлечено автоматически
  - 🔵 Suggested — предложено из QR / сайта
  - 🟢 Confirmed — подтверждено пользователем
  - ⚪ Manual — введено вручную
- `AddTagRow` — добавить произвольный тег
- `[↑ OSM]` — иконка upload, в toolbar справа

### NodeEditor (внутри NodeSheet)
- **Simplified** — аналог ValidationView, те же `OSMTagRow` с editableValue
- **Tags** — `TagPairRow` построчно: `key` + `value`, свайп влево → удалить

### ExtractionView
- Показывает прогресс OCR + QR параллельно
- При ошибке — `[Заполнить вручную]` → skipToManual → Validation (пустой)
- Координатный бейдж: 🟢 EXIF GPS из фото / серый — центр карты
