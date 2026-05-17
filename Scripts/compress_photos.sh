#!/usr/bin/env bash
# compress_photos.sh
#
# Сжимает тестовые фото для POI Scanner:
#   - HEIC → JPEG (max 1500px по длинной стороне, качество 80%)
#   - JPEG/PNG крупнее порога → перепаковываются на месте
#   - Оригинальные HEIC удаляются после успешной конвертации
#
# Использование:
#   ./Scripts/compress_photos.sh [папка]
#
#   По умолчанию — "POI ScannerTests/Fixtures/Photos" относительно корня проекта.
#   Можно передать любую папку с фото, например при добавлении новых снимков:
#   ./Scripts/compress_photos.sh ~/Downloads/new_poi_photos
#
# Требования: macOS + sips (встроен)

set -euo pipefail

# ── Параметры сжатия ─────────────────────────────────────────────────────────
MAX_PX=1500          # максимальный размер по длинной стороне
JPEG_QUALITY=80      # качество JPEG (0–100)
SIZE_THRESHOLD_KB=500  # JPEG/PNG файлы меньше этого порога не трогаем

# ── Целевая папка ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DEFAULT_DIR="$PROJECT_ROOT/POI ScannerTests/Fixtures/Photos"

TARGET_DIR="${1:-$DEFAULT_DIR}"

if [ ! -d "$TARGET_DIR" ]; then
    echo "Ошибка: папка не найдена: $TARGET_DIR" >&2
    exit 1
fi

echo "Папка: $TARGET_DIR"
echo "Настройки: max ${MAX_PX}px, JPEG ${JPEG_QUALITY}%, порог перепаковки ${SIZE_THRESHOLD_KB} КБ"
echo ""

# ── Счётчики ──────────────────────────────────────────────────────────────────
converted=0
recompressed=0
skipped=0
errors=0
saved_bytes=0

# ── HEIC → JPEG ───────────────────────────────────────────────────────────────
heic_files=( "$TARGET_DIR"/*.HEIC "$TARGET_DIR"/*.heic )
heic_count=0
for f in "${heic_files[@]}"; do
    [ -f "$f" ] && heic_count=$((heic_count + 1))
done

if [ "$heic_count" -gt 0 ]; then
    echo "Конвертация HEIC → JPEG ($heic_count файлов)..."
    for f in "${heic_files[@]}"; do
        [ -f "$f" ] || continue
        base="${f%.*}"
        out="${base}.jpg"
        orig_size=$(stat -f%z "$f")

        if sips -s format jpeg -s formatOptions "$JPEG_QUALITY" -Z "$MAX_PX" "$f" --out "$out" > /dev/null 2>&1; then
            new_size=$(stat -f%z "$out")
            saved_bytes=$((saved_bytes + orig_size - new_size))
            rm "$f"
            converted=$((converted + 1))
            if [ $((converted % 50)) -eq 0 ]; then
                echo "  $converted / $heic_count..."
            fi
        else
            echo "  ОШИБКА: $f" >&2
            errors=$((errors + 1))
        fi
    done
    echo "  Готово: $converted HEIC сконвертировано"
    echo ""
fi

# ── JPEG / PNG — перепаковка если крупнее порога ──────────────────────────────
jpeg_files=( "$TARGET_DIR"/*.jpg "$TARGET_DIR"/*.JPG "$TARGET_DIR"/*.jpeg "$TARGET_DIR"/*.JPEG )
png_files=( "$TARGET_DIR"/*.png "$TARGET_DIR"/*.PNG )
all_raster=( "${jpeg_files[@]}" "${png_files[@]}" )

raster_count=0
for f in "${all_raster[@]}"; do
    [ -f "$f" ] && raster_count=$((raster_count + 1))
done

if [ "$raster_count" -gt 0 ]; then
    echo "Проверка JPEG/PNG ($raster_count файлов, порог ${SIZE_THRESHOLD_KB} КБ)..."
    for f in "${all_raster[@]}"; do
        [ -f "$f" ] || continue
        orig_size=$(stat -f%z "$f")
        threshold_bytes=$((SIZE_THRESHOLD_KB * 1024))

        if [ "$orig_size" -le "$threshold_bytes" ]; then
            skipped=$((skipped + 1))
            continue
        fi

        tmp="${f}.tmp.jpg"
        if sips -s format jpeg -s formatOptions "$JPEG_QUALITY" -Z "$MAX_PX" "$f" --out "$tmp" > /dev/null 2>&1; then
            new_size=$(stat -f%z "$tmp")
            if [ "$new_size" -lt "$orig_size" ]; then
                saved_bytes=$((saved_bytes + orig_size - new_size))
                mv "$tmp" "$f"
                recompressed=$((recompressed + 1))
            else
                rm "$tmp"
                skipped=$((skipped + 1))
            fi
        else
            rm -f "$tmp"
            echo "  ОШИБКА: $f" >&2
            errors=$((errors + 1))
        fi
    done
    echo "  Перепаковано: $recompressed, пропущено: $skipped"
    echo ""
fi

# ── Итог ──────────────────────────────────────────────────────────────────────
saved_mb=$(echo "scale=1; $saved_bytes / 1048576" | bc)
total_after=$(du -sh "$TARGET_DIR" | cut -f1)

echo "═══════════════════════════════════"
echo "Конвертировано HEIC:  $converted"
echo "Перепаковано JPEG:    $recompressed"
echo "Пропущено (мелкие):   $skipped"
[ "$errors" -gt 0 ] && echo "Ошибок:               $errors"
echo "Сэкономлено:          ${saved_mb} МБ"
echo "Итого в папке:        $total_after"
echo "═══════════════════════════════════"

if [ "$errors" -gt 0 ]; then
    echo ""
    echo "Были ошибки. Проверь файлы выше."
    exit 1
fi

echo ""
echo "Готово. Если использовался OCR-кэш (ocr_cache.json), его нужно пересобрать:"
echo "  Запусти тест testBuildOCRCache в VisionServiceTests"
