#!/usr/bin/env node
/**
 * import_presets.js
 *
 * Downloads the latest @openstreetmap/id-tagging-schema and generates:
 *   • POITypes.json  — curated list of POI types (amenity/shop/craft/…)
 *   • POIFields.json — field definitions with Russian labels + value options
 *                      for all preset keys used by the above types
 *
 * Usage:
 *   node Scripts/import_presets.js
 *
 * Output:
 *   POI Scanner/Resources/POITypes.json
 *   POI Scanner/Resources/POIFields.json
 *
 * Requirements:
 *   node >= 18  (uses built-in fetch)
 */

import fs   from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const SCHEMA_BASE =
  'https://cdn.jsdelivr.net/npm/@openstreetmap/id-tagging-schema@latest/dist';

/**
 * Base keys we care about — everything else is filtered out.
 * Extend this list when you're ready to support more categories.
 */
const ALLOWED_BASE_KEYS = new Set([
  'amenity',
  'shop',
  'craft',
  'public_transport',
  'healthcare',
  'tourism',
  'entrance',
]);

/**
 * Optional manual name overrides (Russian) for specific type IDs.
 * Format: "key/value" → "Русское название"
 * Fill as needed; untranslated entries keep their English name from the schema.
 */
const NAME_OVERRIDES = {
  'amenity/cafe':               'Кафе',
  'amenity/restaurant':         'Ресторан',
  'amenity/fast_food':          'Фастфуд',
  'amenity/bar':                'Бар',
  'amenity/pub':                'Паб',
  'amenity/food_court':         'Фудкорт',
  'amenity/ice_cream':          'Мороженое',
  'amenity/pharmacy':           'Аптека',
  'amenity/hospital':           'Больница',
  'amenity/clinic':             'Клиника',
  'amenity/dentist':            'Стоматология',
  'amenity/doctors':            'Врач',
  'amenity/bank':               'Банк',
  'amenity/atm':                'Банкомат',
  'amenity/bureau_de_change':   'Обмен валюты',
  'amenity/post_office':        'Почта',
  'amenity/fuel':               'АЗС',
  'amenity/parking':            'Парковка',
  'amenity/bicycle_parking':    'Велопарковка',
  'amenity/car_wash':           'Автомойка',
  'amenity/school':             'Школа',
  'amenity/kindergarten':       'Детский сад',
  'amenity/university':         'Университет',
  'amenity/college':            'Колледж',
  'amenity/library':            'Библиотека',
  'amenity/place_of_worship':   'Место отправления культа',
  'amenity/toilets':            'Туалет',
  'amenity/telephone':          'Телефон',
  'amenity/bench':              'Скамейка',
  'amenity/waste_basket':       'Урна',
  'amenity/recycling':          'Переработка отходов',
  'amenity/drinking_water':     'Питьевая вода',
  'amenity/fountain':           'Фонтан',
  'amenity/theatre':            'Театр',
  'amenity/cinema':             'Кинотеатр',
  'amenity/nightclub':          'Ночной клуб',
  'amenity/casino':             'Казино',
  'amenity/arts_centre':        'Арт-центр',
  'amenity/community_centre':   'Общественный центр',
  'amenity/social_facility':    'Социальный объект',
  'amenity/townhall':           'Мэрия / Ратуша',
  'amenity/courthouse':         'Суд',
  'amenity/police':             'Полиция',
  'amenity/fire_station':       'Пожарная часть',
  'amenity/embassy':            'Посольство',
  'amenity/marketplace':        'Рынок',
  'amenity/car_rental':         'Прокат автомобилей',
  'amenity/bicycle_rental':     'Прокат велосипедов',
  'amenity/taxi':               'Такси',
  'amenity/charging_station':   'Зарядная станция',
  'amenity/veterinary':         'Ветеринария',
  'amenity/animal_shelter':     'Приют для животных',
  'amenity/grave_yard':         'Кладбище',
  'amenity/shelter':            'Укрытие / Навес',
  'shop/supermarket':           'Супермаркет',
  'shop/convenience':           'Продуктовый магазин',
  'shop/bakery':                'Пекарня',
  'shop/butcher':               'Мясная лавка',
  'shop/greengrocer':           'Овощная лавка',
  'shop/clothes':               'Одежда',
  'shop/shoes':                 'Обувь',
  'shop/sports':                'Спортивные товары',
  'shop/electronics':           'Электроника',
  'shop/mobile_phone':          'Мобильные телефоны',
  'shop/computer':              'Компьютеры',
  'shop/books':                 'Книги',
  'shop/gift':                  'Подарки / Сувениры',
  'shop/toys':                  'Игрушки',
  'shop/florist':               'Цветы',
  'shop/hairdresser':           'Парикмахерская',
  'shop/beauty':                'Салон красоты',
  'shop/optician':              'Оптика',
  'shop/pharmacy':              'Аптека',
  'shop/hardware':              'Хозяйственный магазин',
  'shop/furniture':             'Мебель',
  'shop/car':                   'Автосалон',
  'shop/car_parts':             'Автозапчасти',
  'shop/bicycle':               'Велосипедный магазин',
  'shop/jewelry':               'Ювелирный магазин',
  'shop/alcohol':               'Алкомаркет',
  'shop/tobacco':               'Табак',
  'shop/kiosk':                 'Киоск',
  'shop/mall':                  'Торговый центр',
  'shop/laundry':               'Прачечная',
  'shop/dry_cleaning':          'Химчистка',
  'shop/travel_agency':         'Турагентство',
  'shop/pet':                   'Зоомагазин',
  'craft/bakery':               'Пекарня (производство)',
  'craft/brewery':              'Пивоварня',
  'craft/carpenter':            'Столярная мастерская',
  'craft/electrician':          'Электрик',
  'craft/plumber':              'Сантехник',
  'craft/tailor':               'Ателье / Портной',
  'craft/shoemaker':            'Мастерская по ремонту обуви',
  'craft/watchmaker':           'Часовая мастерская',
  'craft/jeweller':             'Ювелир',
  'craft/photographer':         'Фотостудия',
  'craft/printer':              'Типография',
  'craft/repair_shop':          'Мастерская ремонта',
  'healthcare/clinic':          'Клиника',
  'healthcare/hospital':        'Больница',
  'healthcare/pharmacy':        'Аптека',
  'healthcare/dentist':         'Стоматология',
  'healthcare/physiotherapist': 'Физиотерапия',
  'healthcare/optometrist':     'Оптометрист',
  'healthcare/psychotherapist': 'Психотерапевт',
  'healthcare/laboratory':      'Медицинская лаборатория',
  'healthcare/blood_donation':  'Пункт сдачи крови',
  'healthcare/alternative':          'Альтернативная медицина',
  'healthcare/audiologist':          'Аудиолог',
  'healthcare/birthing_centre':      'Родильный центр',
  'healthcare/counselling':          'Психологическое консультирование',
  'healthcare/dialysis':             'Диализный центр',
  'healthcare/hospice':              'Хоспис',
  'healthcare/midwife':              'Акушерка',
  'healthcare/occupational_therapist': 'Эрготерапевт',
  'healthcare/podiatrist':           'Подолог',
  'healthcare/rehabilitation':       'Реабилитационный центр',
  'healthcare/sample_collection':    'Пункт забора анализов',
  'healthcare/speech_therapist':     'Логопед',
  'public_transport/stop_position': 'Остановка (узел)',
  'public_transport/platform':      'Платформа / Остановка',
  'public_transport/station':       'Станция',
  // tourism
  'tourism/hotel':              'Отель',
  'tourism/hostel':             'Хостел',
  'tourism/motel':              'Мотель',
  'tourism/guest_house':        'Гостевой дом',
  'tourism/apartment':          'Апартаменты',
  'tourism/camp_site':          'Кемпинг',
  'tourism/caravan_site':       'Кемпинг для автодомов',
  'tourism/chalet':             'Шале',
  'tourism/alpine_hut':         'Горный приют',
  'tourism/wilderness_hut':     'Хижина',
  'tourism/attraction':         'Достопримечательность',
  'tourism/museum':             'Музей',
  'tourism/gallery':            'Галерея',
  'tourism/artwork':            'Арт-объект',
  'tourism/viewpoint':          'Видовая точка',
  'tourism/zoo':                'Зоопарк',
  'tourism/theme_park':         'Тематический парк',
  'tourism/aquarium':           'Аквариум',
  'tourism/information':        'Информационный пункт',
  'tourism/picnic_site':        'Место для пикника',
  // entrance
  'entrance':                   'Вход',
  'entrance/staircase':         'Подъезд',
  'entrance/main':              'Главный вход',
  'entrance/shop':              'Вход в магазин',
  'entrance/emergency':         'Аварийный выход',
  'entrance/emergency_ward_entrance': 'Скорая / Приёмный покой',
};

/**
 * Fields that are globally useful for any POI type.
 * They will be appended to every preset's fields list (if not already present).
 */
const UNIVERSAL_EXTRA_FIELDS = ['opening_hours', 'phone', 'website'];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function fetchJSON(url) {
  console.log(`  Fetching ${url}`);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return res.json();
}

/** Returns true if the preset's primary tag matches one of our allowed base keys. */
function isAllowed(preset) {
  if (!preset.tags) return false;
  const keys = Object.keys(preset.tags);
  if (keys.length === 0) return false;
  return ALLOWED_BASE_KEYS.has(keys[0]);
}

/** Extracts the base key (first tag key) of a preset. */
function baseKey(preset) {
  return Object.keys(preset.tags)[0];
}

/** Extracts the value for the base key. */
function baseValue(preset) {
  return preset.tags[baseKey(preset)];
}

/**
 * Resolves `fields` / `moreFields` arrays from a preset.
 * Each element is either a plain field ID string or "{presetID}" reference.
 * For "{presetID}" references we recursively expand that preset's fields.
 */
function resolveFields(arr, presetsRaw, depth = 0) {
  if (!Array.isArray(arr) || depth > 3) return [];
  const result = [];
  for (const f of arr) {
    if (typeof f !== 'string') continue;
    if (f.startsWith('{') && f.endsWith('}')) {
      // Preset reference — expand its fields (strip { } and leading @)
      const refId = f.slice(1, -1).replace(/^@/, '');
      const refPreset = presetsRaw[refId];
      if (refPreset) {
        result.push(...resolveFields(refPreset.fields, presetsRaw, depth + 1));
        result.push(...resolveFields(refPreset.moreFields, presetsRaw, depth + 1));
      }
    } else {
      result.push(f.replace(/^#/, '')); // strip leading # if any
    }
  }
  return result;
}

/**
 * Converts a field definition into the key tag it controls, if available.
 * Falls back to the field ID as a rough approximation.
 */
function fieldToKey(fieldID, fields) {
  const def = fields[fieldID];
  if (!def) return fieldID;
  if (def.key)  return def.key;
  if (def.keys) return def.keys[0]; // multiCombo — use first key
  return fieldID;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  console.log('=== POI Scanner — Preset Importer ===\n');

  // 1. Download raw data
  console.log('1. Downloading schema...');
  const [presetsRaw, fieldsRaw, ruTranslation] = await Promise.all([
    fetchJSON(`${SCHEMA_BASE}/presets.min.json`),
    fetchJSON(`${SCHEMA_BASE}/fields.min.json`),
    fetchJSON(`${SCHEMA_BASE}/translations/ru.min.json`),
  ]);
  const ruFields = ruTranslation?.ru?.presets?.fields ?? {};
  console.log(`   Presets: ${Object.keys(presetsRaw).length}`);
  console.log(`   Fields:  ${Object.keys(fieldsRaw).length}`);
  console.log(`   RU field translations: ${Object.keys(ruFields).length}\n`);

  // 2. Filter
  console.log('2. Filtering to allowed base keys:', [...ALLOWED_BASE_KEYS].join(', '));
  const filtered = Object.entries(presetsRaw).filter(([id, p]) => {
    if (!isAllowed(p))        return false;  // wrong base key
    if (p.searchable === false) return false; // hidden/internal preset
    if (p.suggestion === true)  return false; // name-suggestion-index brand
    if (p.replacement)          return false; // deprecated
    // Drop wildcard presets (e.g. healthcare/*)
    const tagVals = Object.values(p.tags || {});
    if (tagVals.some(v => v === '*' || v === '')) return false;
    // Skip presets that require a second defining tag (too specific for our picker)
    // e.g. amenity/fast_food/burger  →  tags = { amenity: fast_food, cuisine: burger }
    // We keep them if they only have ONE tag.
    const tagCount = Object.keys(p.tags || {}).length;
    if (tagCount > 1)           return false;
    return true;
  });
  console.log(`   Kept: ${filtered.length} presets\n`);

  // 3. Build output
  console.log('3. Building POITypes.json...');
  const types = filtered.map(([id, p]) => {
    const key   = baseKey(p);
    const value = baseValue(p);
    const overrideKey = `${key}/${value}`;

    // Name: prefer manual override → English name from schema
    const name = NAME_OVERRIDES[overrideKey] ?? p.name ?? overrideKey;

    // Search terms: schema `terms` + `aliases` (lowercased, deduplicated)
    const terms = [
      ...(p.terms   ?? []),
      ...(p.aliases ?? []),
    ].map(t => t.toLowerCase()).filter((t, i, a) => a.indexOf(t) === i);

    // Fields: main + moreFields, resolved to tag keys, deduplicated
    const rawFields = [
      ...resolveFields(p.fields, presetsRaw),
      ...resolveFields(p.moreFields, presetsRaw),
    ];
    const fieldKeys = rawFields
      .map(fid => fieldToKey(fid, fieldsRaw))
      .filter(k => k && k !== key && k !== 'name'); // drop the type key itself and name
    
    // Append universal extra fields if not already present
    // (skip for entrance= — входы не нуждаются в часах/телефоне/сайте)
    if (key !== 'entrance') {
      for (const extra of UNIVERSAL_EXTRA_FIELDS) {
        if (!fieldKeys.includes(extra)) fieldKeys.push(extra);
      }
    }

    // Deduplicate while preserving order
    const presets = [...new Set(fieldKeys)];

    return { id: overrideKey, key, value, name, terms, presets };
  });

  // Sort: by key, then by name
  types.sort((a, b) => {
    if (a.key !== b.key) return a.key.localeCompare(b.key);
    return a.name.localeCompare(b.name, 'ru');
  });

  // 4. Build POIFields.json
  // Collect all unique preset keys referenced by our types
  console.log('4. Building POIFields.json...');

  // Field input type → app-level inputType string
  // check / defaultCheck  → "check"   (boolean yes/no)
  // combo / radio         → "select"  (fixed single value)
  // semiCombo             → "semiCombo" (free text + suggestions, semicolon-separated)
  // multiCombo            → "multiCombo" (boolean sub-keys e.g. fuel:diesel)
  // text / localized      → "text"
  // number                → "number"
  // url                   → "url"
  // tel                   → "tel"
  // opening_hours         → "openingHours"
  // everything else       → "text"
  const TYPE_MAP = {
    check: 'check', defaultCheck: 'check',
    combo: 'select', radio: 'select',
    semiCombo: 'semiCombo',
    multiCombo: 'multiCombo',
    manyCombo: 'multiCombo',
    text: 'text', localized: 'text', textarea: 'text',
    number: 'number',
    url: 'url',
    tel: 'tel',
    email: 'email',
  };

  // Build a reverse index: tagKey (as used in presets) → { fieldID, rawDef, ruDef }
  // This correctly handles cases where fieldID ≠ tagKey,
  // e.g. "fuel/fuel_multi" whose def.key is "fuel:".
  const tagKeyToField = new Map();
  for (const [id, raw] of Object.entries(fieldsRaw)) {
    const tagKey = raw.key ?? (raw.keys ? raw.keys[0] : null) ?? id;
    if (!tagKeyToField.has(tagKey)) {
      tagKeyToField.set(tagKey, { fieldID: id, raw, ru: ruFields[id] ?? {} });
    }
  }

  const allPresetKeys = new Set(types.flatMap(t => t.presets));
  const fields = [];

  for (const tagKey of [...allPresetKeys].sort()) {
    // Skip virtual group-alias keys
    if (tagKey === 'addr') continue;

    const entry = tagKeyToField.get(tagKey);
    if (!entry) continue; // no schema entry — skip (will fall back to free text)

    const { fieldID, raw, ru } = entry;

    // Use tagKey as osmKey so Swift can look up by the exact key from the presets list
    const osmKey = tagKey;

    // inputType
    let inputType = TYPE_MAP[raw.type] ?? 'text';
    // Special-case opening_hours field
    if (fieldID === 'opening_hours' || osmKey === 'opening_hours') inputType = 'openingHours';

    // Label (Russian preferred, fall back to English field label or fieldID)
    // ru.label может быть объектом { title: "...", description: "..." } — берём title
    // Если ru.label — это строка вида "{fieldID}" (нерасширенный template-reference
    // из схемы), считаем перевод отсутствующим и берём английский лейбл.
    const rawLabelRu = ru.label ?? null;
    const rawLabelEn = raw.label ?? fieldID;
    function resolveLabel(raw) {
      if (raw === null || raw === undefined) return null;
      if (typeof raw === 'string') return raw.startsWith('{') ? null : raw;
      if (typeof raw === 'object') return raw.title ?? raw.description ?? null;
      return String(raw);
    }
    const label = resolveLabel(rawLabelRu)
      ?? resolveLabel(rawLabelEn)
      ?? fieldID;

    // Options: array of { value, label } — only for select / semiCombo / multiCombo
    let options = [];
    if (['select', 'semiCombo', 'multiCombo'].includes(inputType)) {
      // raw.options is an array of value strings
      const rawOpts = raw.options ?? [];
      // ru.options is { value: "RU label" } or { value: { title: "RU label" } }
      const ruOpts = ru.options ?? {};
      options = rawOpts.map(v => {
        const ruVal = ruOpts[v];
        let lbl;
        if (typeof ruVal === 'string') {
          lbl = ruVal;
        } else if (typeof ruVal === 'object' && ruVal !== null) {
          lbl = ruVal.title ?? ruVal.description ?? v;
        } else {
          lbl = v;
        }
        return { value: v, label: lbl };
      });
    }

    // For multiCombo, record the key prefix (e.g. "fuel:" for fuel:diesel)
    const keyPrefix = (raw.type === 'multiCombo' || raw.type === 'manyCombo')
      ? (raw.key ?? fieldID)
      : null;

    const fieldEntry = {
      id: fieldID,
      osmKey,
      inputType,
      label,
      ...(options.length > 0 && { options }),
      ...(keyPrefix && { keyPrefix }),
    };
    fields.push(fieldEntry);
  }

  // Collect all group-alias pseudo-keys: multiCombo fields whose osmKey ends in ":"
  // These appear in presets[] as e.g. "payment:" and must be treated as group references
  // in the app (not as real OSM tag keys with a value).
  const groupAliasKeys = [...new Set(
    fields
      .filter(f => f.inputType === 'multiCombo' && f.osmKey.endsWith(':'))
      .map(f => f.osmKey)
  )].sort();

  console.log(`   Group alias keys (${groupAliasKeys.length}): ${groupAliasKeys.join(', ')}\n`);

  // 5. Write outputs
  const __dirname = path.dirname(fileURLToPath(import.meta.url));
  const outDir = path.join(__dirname, '..', 'POI Scanner', 'Resources');
  fs.mkdirSync(outDir, { recursive: true });

  // POITypes.json
  const typesOut = path.join(outDir, 'POITypes.json');
  const typesOutput = {
    _generated: new Date().toISOString(),
    _source: 'https://github.com/openstreetmap/id-tagging-schema',
    types,
  };
  fs.writeFileSync(typesOut, JSON.stringify(typesOutput, null, 2), 'utf8');
  console.log(`✅  Written ${types.length} types to:\n   ${typesOut}\n`);

  // POIFields.json
  const fieldsOut = path.join(outDir, 'POIFields.json');
  const fieldsOutput = {
    _generated: new Date().toISOString(),
    _source: 'https://github.com/openstreetmap/id-tagging-schema',
    // groupAliasKeys: multiCombo-поля, чей osmKey оканчивается на ":" —
    // это псевдонимы групп, а не реальные OSM-ключи с одиночным значением.
    // Приложение использует этот список в namedGroupPresetKeys(), чтобы
    // не рендерить их как обычные tag-строки.
    groupAliasKeys,
    fields,
  };
  fs.writeFileSync(fieldsOut, JSON.stringify(fieldsOutput, null, 2), 'utf8');
  console.log(`✅  Written ${fields.length} fields to:\n   ${fieldsOut}\n`);

  // 6. Summary by base key
  const counts = {};
  for (const t of types) counts[t.key] = (counts[t.key] ?? 0) + 1;
  console.log('Summary by base key:');
  for (const [k, n] of Object.entries(counts)) console.log(`   ${k}: ${n}`);
}

main().catch(err => {
  console.error('\n❌  Error:', err.message);
  process.exit(1);
});
