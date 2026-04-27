#!/usr/bin/env node
/**
 * import_presets.js
 *
 * Downloads the latest @openstreetmap/id-tagging-schema and converts
 * a curated subset of presets into POITypes.json for the POI Scanner app.
 *
 * Usage:
 *   node Scripts/import_presets.js
 *
 * Output:
 *   POI Scanner/Resources/POITypes.json
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
 * We keep only plain strings (field IDs) and ignore preset references.
 */
function resolveFields(arr) {
  if (!Array.isArray(arr)) return [];
  return arr
    .filter(f => typeof f === 'string' && !f.startsWith('{'))
    .map(f => f.replace(/^#/, '')); // strip leading # if any
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
  const [presetsRaw, fieldsRaw] = await Promise.all([
    fetchJSON(`${SCHEMA_BASE}/presets.min.json`),
    fetchJSON(`${SCHEMA_BASE}/fields.min.json`),
  ]);
  console.log(`   Presets: ${Object.keys(presetsRaw).length}`);
  console.log(`   Fields:  ${Object.keys(fieldsRaw).length}\n`);

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
      ...resolveFields(p.fields),
      ...resolveFields(p.moreFields),
    ];
    const fieldKeys = rawFields
      .map(fid => fieldToKey(fid, fieldsRaw))
      .filter(k => k && k !== key && k !== 'name'); // drop the type key itself and name
    
    // Append universal extra fields if not already present
    for (const extra of UNIVERSAL_EXTRA_FIELDS) {
      if (!fieldKeys.includes(extra)) fieldKeys.push(extra);
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

  // 4. Write output
  const __dirname = path.dirname(fileURLToPath(import.meta.url));
  const outDir  = path.join(__dirname, '..', 'POI Scanner', 'Resources');
  const outFile = path.join(outDir, 'POITypes.json');

  fs.mkdirSync(outDir, { recursive: true });

  const output = {
    _generated: new Date().toISOString(),
    _source: 'https://github.com/openstreetmap/id-tagging-schema',
    types,
  };
  fs.writeFileSync(outFile, JSON.stringify(output, null, 2), 'utf8');

  console.log(`\n✅  Written ${types.length} types to:\n   ${outFile}\n`);

  // 5. Summary by base key
  const counts = {};
  for (const t of types) counts[t.key] = (counts[t.key] ?? 0) + 1;
  console.log('Summary by base key:');
  for (const [k, n] of Object.entries(counts)) console.log(`   ${k}: ${n}`);
}

main().catch(err => {
  console.error('\n❌  Error:', err.message);
  process.exit(1);
});
