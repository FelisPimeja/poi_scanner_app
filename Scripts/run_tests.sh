#!/usr/bin/env bash
# run_tests.sh
#
# Запускает тесты POI Scanner на симуляторе iPhone 17.
#
# Использование:
#   ./Scripts/run_tests.sh [команда]
#
# Команды:
#   unit          TextParserTests + QRContentParserTests (быстро, без OCR)
#   quality       Отчёт по качеству парсинга (использует OCR-кэш, секунды)
#   quality-slow  Отчёт по качеству с живым OCR (медленно, ~5 мин)
#   generate      Генерация черновых фикстур из фото (FixtureGenerator)
#   promote       Авторазметка черновиков (DraftPromoter)
#   build-cache   Пересборка OCR-кэша (VisionServiceTests/testBuildOCRCache)
#   all           Все тесты (не включает generate/promote/build-cache)
#
# По умолчанию: quality

set -euo pipefail

SCHEME="POI Scanner"
PROJECT="POI Scanner.xcodeproj"
DESTINATION="platform=iOS Simulator,name=iPhone 17"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

CMD="${1:-quality}"

# Фильтр прогресса: показывает результаты тестов и print()-вывод, скрывает шум сборки.
# Используется когда xcpretty не установлен.
# Фильтр прогресса: показывает результаты тестов и print()-вывод, скрывает шум сборки.
# Используется когда xcpretty не установлен.
# Логика: xcodebuild build-шум — весь ASCII; test-вывод — Test Case/Suite строки (ASCII)
# + print()-строки из Swift (emoji/кириллица = non-ASCII, либо отступ + "...")
_progress_filter() {
    python3 -u -c '
import sys, re
pattern = re.compile(r"^(Test (Case|Suite)\b|   \.\.\.|Build (FAILED|succeeded))")
for line in sys.stdin:
    s = line.rstrip("\n")
    if not s:
        continue
    if ord(s[0]) > 127 or pattern.match(s):
        print(s, flush=True)
'
}

run_test() {
    local only_testing="$1"
    local xcode_args=(
        -project "$PROJECT_ROOT/$PROJECT"
        -scheme "$SCHEME"
        -destination "$DESTINATION"
        -only-testing "$only_testing"
        -testPlan "POI Scanner"
    )
    if command -v xcpretty &>/dev/null; then
        xcodebuild test "${xcode_args[@]}" | xcpretty
    else
        xcodebuild test "${xcode_args[@]}" 2>&1 | _progress_filter
    fi
}

run_all() {
    local xcode_args=(
        -project "$PROJECT_ROOT/$PROJECT"
        -scheme "$SCHEME"
        -destination "$DESTINATION"
        -testPlan "POI Scanner"
        -skip-testing "POI ScannerTests/FixtureGenerator"
        -skip-testing "POI ScannerTests/DraftPromoter"
    )
    if command -v xcpretty &>/dev/null; then
        xcodebuild test "${xcode_args[@]}" | xcpretty
    else
        xcodebuild test "${xcode_args[@]}" 2>&1 | _progress_filter
    fi
}

echo "Симулятор: $DESTINATION"
echo ""

case "$CMD" in
    unit)
        echo "▶ Unit-тесты (TextParser + QRContentParser)"
        run_test "POI ScannerTests/TextParserTests"
        run_test "POI ScannerTests/QRContentParserTests"
        ;;
    quality)
        echo "▶ Отчёт по качеству (OCR-кэш)"
        run_test "POI ScannerTests/ExtractionPipelineTests/testExtractionQualityReportFast"
        ;;
    quality-slow)
        echo "▶ Отчёт по качеству (живой OCR)"
        run_test "POI ScannerTests/ExtractionPipelineTests/testExtractionQualityReport"
        ;;
    generate)
        echo "▶ Генерация черновых фикстур из фото"
        run_test "POI ScannerTests/FixtureGenerator/testGenerateFixturesFromPhotos"
        ;;
    promote)
        echo "▶ Авторазметка черновиков → Drafts/promoted/"
        run_test "POI ScannerTests/DraftPromoter/testPromoteDraftsToExpected"
        ;;
    build-cache)
        echo "▶ Пересборка OCR-кэша"
        run_test "POI ScannerTests/VisionServiceTests/testBuildOCRCache"
        ;;
    all)
        echo "▶ Все тесты (кроме generate/promote/build-cache)"
        run_all
        ;;
    *)
        echo "Неизвестная команда: $CMD"
        echo "Доступные: unit | quality | quality-slow | generate | promote | build-cache | all"
        exit 1
        ;;
esac
