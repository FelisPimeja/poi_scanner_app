import XCTest
@testable import POI_Scanner

// MARK: - ExtractionResultMatcher
// Кастомные assert-хелперы для сравнения результатов парсинга с эталоном

enum ExtractionResultMatcher {

    // MARK: - Основной метод валидации

    /// Проверяет ParseResult на соответствие фикстуре.
    /// Возвращает отчёт по каждому полю.
    @discardableResult
    static func validate(
        result: ParseResult,
        against fixture: TestFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> FieldReport {
        var report = FieldReport(fixtureId: fixture.id)

        for (tag, expectedValue) in fixture.expectedTags {
            let actualValue = result.tags[tag]
            let actualConfidence = result.confidence[tag] ?? 0.0
            let minConfidence = fixture.minimumConfidence[tag] ?? 0.6

            let fieldResult: FieldReport.FieldResult

            if let actual = actualValue {
                let valuesMatch = actual.lowercased() == expectedValue.lowercased()
                let confidenceOK = actualConfidence >= minConfidence

                if valuesMatch && confidenceOK {
                    fieldResult = .success(actual, actualConfidence)
                } else if !valuesMatch {
                    fieldResult = .wrongValue(expected: expectedValue, actual: actual)
                    XCTFail(
                        "[\(fixture.id)] Тег '\(tag)': ожидалось '\(expectedValue)', получено '\(actual)'",
                        file: file, line: line
                    )
                } else {
                    fieldResult = .lowConfidence(value: actual, confidence: actualConfidence, minimum: minConfidence)
                    XCTFail(
                        "[\(fixture.id)] Тег '\(tag)': confidence \(String(format: "%.2f", actualConfidence)) < minimum \(minConfidence)",
                        file: file, line: line
                    )
                }
            } else {
                fieldResult = .missing(expectedValue)
                XCTFail(
                    "[\(fixture.id)] Тег '\(tag)' не найден. Ожидалось: '\(expectedValue)'",
                    file: file, line: line
                )
            }

            report.fields[tag] = fieldResult
        }

        // Опциональные теги — не падаем, только логируем
        for tag in fixture.optionalTags {
            if let value = result.tags[tag] {
                report.optionalFound[tag] = value
            }
        }

        return report
    }
}

// MARK: - FieldReport

struct FieldReport {
    let fixtureId: String
    var fields: [String: FieldResult] = [:]
    var optionalFound: [String: String] = [:]

    enum FieldResult {
        case success(String, Double)
        case wrongValue(expected: String, actual: String)
        case lowConfidence(value: String, confidence: Double, minimum: Double)
        case missing(String)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    var successCount: Int { fields.values.filter(\.isSuccess).count }
    var totalCount: Int { fields.count }
    var score: Double { totalCount > 0 ? Double(successCount) / Double(totalCount) : 0 }
}

// MARK: - Quality Report (для всех фикстур)

struct QualityReport {
    var fixtureReports: [FieldReport] = []

    /// Процент успешного извлечения по каждому тегу
    var tagScores: [String: Double] {
        var successes: [String: Int] = [:]
        var totals: [String: Int] = [:]

        for report in fixtureReports {
            for (tag, result) in report.fields {
                totals[tag, default: 0] += 1
                if result.isSuccess { successes[tag, default: 0] += 1 }
            }
        }

        return totals.mapValues { total in
            let success = successes[totals.keys.first(where: { totals[$0] == total }) ?? ""] ?? 0
            return Double(success) / Double(total)
        }
    }

    var overallScore: Double {
        let total = fixtureReports.reduce(0) { $0 + $1.totalCount }
        let success = fixtureReports.reduce(0) { $0 + $1.successCount }
        guard total > 0 else { return 0 }
        return Double(success) / Double(total)
    }

    func printSummary() {
        print("\n📊 Отчёт качества извлечения OCR")
        print("=" * 40)

        // По тегам
        var allTags: [String: (success: Int, total: Int)] = [:]
        for report in fixtureReports {
            for (tag, result) in report.fields {
                allTags[tag, default: (0, 0)].total += 1
                if result.isSuccess { allTags[tag]!.success += 1 }
            }
        }

        let sorted = allTags.sorted { $0.value.total > $1.value.total }
        for (tag, counts) in sorted {
            let pct = Int(Double(counts.success) / Double(counts.total) * 100)
            let icon = pct >= 80 ? "✅" : pct >= 60 ? "⚠️" : "❌"
            let bar = String(repeating: "█", count: pct / 10) + String(repeating: "░", count: 10 - pct / 10)
            print("\(icon) \(tag.padding(toLength: 20, withPad: " ", startingAt: 0)) \(bar) \(counts.success)/\(counts.total) (\(pct)%)")
        }

        print("=" * 40)
        print("Всего фикстур: \(fixtureReports.count)")
        print("Общий скор: \(Int(overallScore * 100))%\n")
    }

    /// Печатает детальный разбор провалов по конкретному тегу.
    /// Использование: qualityReport.printFailures(for: "ref:INN")
    func printFailures(for tag: String) {
        var rows: [(id: String, result: FieldReport.FieldResult)] = []
        for report in fixtureReports {
            if let result = report.fields[tag] {
                rows.append((report.fixtureId, result))
            }
        }

        let failures = rows.filter { !$0.result.isSuccess }
        let successes = rows.filter { $0.result.isSuccess }

        print("\n🔍 Детали по тегу: \(tag)  [\(successes.count)/\(rows.count) успешно]")
        print("-" * 60)

        for (id, result) in failures.sorted(by: { $0.id < $1.id }) {
            switch result {
            case .missing(let expected):
                print("❌ \(id.padding(toLength: 14, withPad: " ", startingAt: 0)) MISSING    ожидалось: \"\(expected)\"")
            case .wrongValue(let expected, let actual):
                print("🔀 \(id.padding(toLength: 14, withPad: " ", startingAt: 0)) WRONG      ожидалось: \"\(expected)\"  получено: \"\(actual)\"")
            case .lowConfidence(let value, let conf, let minimum):
                print("🔅 \(id.padding(toLength: 14, withPad: " ", startingAt: 0)) LOW CONF   \"\(value)\"  conf=\(String(format: "%.2f", conf)) < min=\(minimum)")
            case .success:
                break
            }
        }
        print("-" * 60 + "\n")
    }
}

private extension String {
    static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}
