# MapTiler Planet Tiles — v3 vs v4: отличия

## Источники

| | v3 (streets) | v4 (streets-v4) |
|---|---|---|
| Style URL | `https://api.maptiler.com/maps/streets/style.json` | `https://api.maptiler.com/maps/streets-v4/style.json` |
| Tiles URL | `https://api.maptiler.com/tiles/v3/{z}/{x}/{y}.pbf` | `https://api.maptiler.com/tiles/v4/{z}/{x}/{y}.pbf` |
| TileJSON | `https://api.maptiler.com/tiles/v3/tiles.json` | `https://api.maptiler.com/tiles/v4/tiles.json` |
| Схема | OpenMapTiles (`openmaptiles` source) | MapTiler Planet v4 (`maptiler_planet_v4` source) |

---

## Кодирование feature.identifier (OSM ID)

### v3 — мультипликатор 10

```
encodedID = osmID * 10 + typeCode
```

| typeCode | тип OSM |
|---|---|
| 0 | node |
| 1 | way |
| 4 | relation |

**Декодирование:**
```swift
osmID   = encodedID / 10
typeCode = encodedID % 10
```

### v4 — мультипликатор 32

```
encodedID = osmID * 32 + typeCode
```

| typeCode | тип OSM |
|---|---|
| 1 | node |
| 2 | way |
| 3 | relation |

**Декодирование:**
```swift
osmID    = encodedID / 32
typeCode = encodedID % 32
```

**Примеры (проверены эмпирически):**

| encodedID | osmID (реальный) | typeCode | тип |
|---|---|---|---|
| 587351459 | 18354733 | 3 | relation |
| 113338630689 | 3541832209 | 1 | node |
| 5402764450 | 168836389 | 2 | way |

---

## POI — структура слоёв

### v3

Все POI объединены в **один** source-layer `poi`.  
Style-слои: `poi_z14`, `poi_z15`, `poi_z16`, `poi_z16_subclass`, `poi_transit`.

Атрибуты фичи:
- `class` — категория (например, `fast_food`, `atm`)
- `subclass` — подкатегория

### v4

POI разбиты на **отдельные** source-layers по категориям:

| source-layer | содержимое |
|---|---|
| `poi_food` | кафе, рестораны, бары, фастфуд |
| `poi_shopping` | магазины, торговые центры |
| `poi_transport` | парковки, АЗС, велопрокат |
| `poi_station` | остановки, ж/д и авиастанции |
| `poi_healthcare` | больницы, аптеки, клиники |
| `poi_education` | школы, вузы, детсады |
| `poi_public` | банки, банкоматы, почта, пожарные части |
| `poi_tourism` | достопримечательности, замки, смотровые |
| `poi_accommodation` | отели, хостелы, кемпинги |
| `poi_culture` | религия, театры, музеи, кладбища |
| `poi_sport` | стадионы, фитнес, бассейны, поля |

Атрибуты фичи (те же, что в v3):
- `class` — категория
- `subclass` — подкатегория (опционально)
- `name` — название объекта
- `cuisine` — тип кухни (только в `poi_food`)

> **Примечание для фильтрации в коде**: все v4 POI source-layers начинаются с `"poi_"` → фильтр `sl.hasPrefix("poi")` покрывает оба формата. Также в обоих форматах присутствует `street_furniture`.

---

## Количество POI

v4 содержит **значительно больше POI**, чем v3, благодаря расширенной схеме тайлов и большему количеству source-layers. Особенно заметно на точках питания (`poi_food`) и транспорте.

---

## Спрайты и иконки

В v4 иконки для POI используют `class`/`subclass` напрямую как имена иконок (без префикса), либо явные `match`-выражения в стиле. В v4 значительно больше иконок для подкатегорий (`cuisine`, `subclass`).
