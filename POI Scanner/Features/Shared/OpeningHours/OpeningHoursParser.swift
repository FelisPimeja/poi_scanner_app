import Foundation

// MARK: - Domain model

enum OHWeekday: Int, CaseIterable, Identifiable, Hashable {
    case mo = 0, tu, we, th, fr, sa, su
    var id: Int { rawValue }

    var shortName: String {
        AppSettings.shared.language == .ru
            ? ["Пн","Вт","Ср","Чт","Пт","Сб","Вс"][rawValue]
            : ["Mo","Tu","We","Th","Fr","Sa","Su"][rawValue]
    }
    var osmCode: String { ["Mo","Tu","We","Th","Fr","Sa","Su"][rawValue] }
}

struct OHTime: Equatable, Hashable {
    var hour: Int    // 0…24
    var minute: Int  // 0, 5, 10 … 55

    var string: String { String(format: "%02d:%02d", hour, minute) }

    static let midnight   = OHTime(hour: 0,  minute: 0)
    static let endOfDay   = OHTime(hour: 24, minute: 0)
    static let defaultOpen  = OHTime(hour: 9,  minute: 0)
    static let defaultClose = OHTime(hour: 18, minute: 0)

    /// All valid minute values (steps of 5)
    static let minuteValues = stride(from: 0, through: 55, by: 5).map { $0 }
    /// All valid hour values 0…24
    static let hourValues = Array(0...24)
}

struct OHBreak: Identifiable, Hashable {
    var id = UUID()
    var from: OHTime
    var to:   OHTime
}

struct OHSchedule: Identifiable {
    var id = UUID()
    var days:     Set<OHWeekday>
    var isAllDay: Bool
    var open:     OHTime
    var close:    OHTime
    var breaks:   [OHBreak]
}

// MARK: - Parser / Serializer

struct OpeningHoursParser {

    // MARK: Parse

    /// Returns (schedules, isAdvanced).
    /// isAdvanced=true when value can't be represented in the visual editor.
    static func parse(_ value: String) -> (schedules: [OHSchedule], isAdvanced: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ([], false) }

        if trimmed == "24/7" {
            return ([OHSchedule(days: Set(OHWeekday.allCases),
                                isAllDay: true,
                                open: .midnight, close: .endOfDay,
                                breaks: [])], false)
        }

        var schedules: [OHSchedule] = []
        let rules = trimmed.components(separatedBy: ";")
                           .map { $0.trimmingCharacters(in: .whitespaces) }
                           .filter { !$0.isEmpty }

        for rule in rules {
            guard let s = parseRule(rule) else { return ([], true) }
            schedules.append(s)
        }
        return (schedules, schedules.isEmpty)
    }

    private static func parseRule(_ rule: String) -> OHSchedule? {
        // Split "Mo-Fr 09:00-18:00" into day-part and time-part
        let spaceIdx = rule.firstIndex(of: " ")
        let dayStr  = spaceIdx.map { String(rule[rule.startIndex..<$0]) } ?? rule
        let timeStr = spaceIdx.map { String(rule[rule.index(after: $0)...]) }

        guard let days = parseDays(dayStr) else { return nil }

        // No time part or explicit 24/7 → all day
        if timeStr == nil || timeStr == "24/7" {
            return OHSchedule(days: days, isAllDay: true,
                              open: .midnight, close: .endOfDay, breaks: [])
        }
        guard let timeStr else { return nil }

        // Split multiple intervals by comma: "09:00-13:00,14:00-18:00"
        let intervals = timeStr.components(separatedBy: ",")
                               .map { $0.trimmingCharacters(in: .whitespaces) }

        if intervals.count == 1 {
            guard let (t1, t2) = parseTimeRange(intervals[0]) else { return nil }
            let isAllDay = (t1 == .midnight && t2 == .endOfDay)
            return OHSchedule(days: days, isAllDay: isAllDay, open: t1, close: t2, breaks: [])
        }

        // Multiple intervals → single open/close with breaks as gaps
        guard let (firstOpen, _)    = parseTimeRange(intervals.first!),
              let (_, lastClose)    = parseTimeRange(intervals.last!)  else { return nil }

        var breaks: [OHBreak] = []
        for i in 0..<(intervals.count - 1) {
            guard let (_, intervalEnd)   = parseTimeRange(intervals[i]),
                  let (nextStart, _)     = parseTimeRange(intervals[i+1]) else { return nil }
            breaks.append(OHBreak(from: intervalEnd, to: nextStart))
        }
        return OHSchedule(days: days, isAllDay: false,
                          open: firstOpen, close: lastClose, breaks: breaks)
    }

    private static func parseDays(_ str: String) -> Set<OHWeekday>? {
        var result: Set<OHWeekday> = []
        for part in str.components(separatedBy: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.contains("-") {
                let lr = t.components(separatedBy: "-")
                guard lr.count == 2,
                      let s = weekday(lr[0]), let e = weekday(lr[1]),
                      s.rawValue <= e.rawValue else { return nil }
                for i in s.rawValue...e.rawValue {
                    guard let wd = OHWeekday(rawValue: i) else { break }
                    result.insert(wd)
                }
            } else {
                guard let wd = weekday(t) else { return nil }
                result.insert(wd)
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func weekday(_ s: String) -> OHWeekday? {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "mo": return .mo; case "tu": return .tu; case "we": return .we
        case "th": return .th; case "fr": return .fr; case "sa": return .sa
        case "su": return .su; default: return nil
        }
    }

    private static func parseTimeRange(_ s: String) -> (OHTime, OHTime)? {
        // Handle "HH:MM-HH:MM" — careful: "24:00" is valid closing time
        // Find the dash that separates open from close (skip first char to avoid negative hour)
        guard let dashIdx = s.dropFirst(4).firstIndex(of: "-") else { return nil }
        let realDash = s.index(dashIdx, offsetBy: 0)
        // Actually: split on "-" but the range might be "09:00-18:00"
        // Use regex-free approach: times are always 5 chars HH:MM
        let parts = s.components(separatedBy: "-")
        guard parts.count == 2,
              let t1 = parseTime(parts[0]),
              let t2 = parseTime(parts[1]) else { return nil }
        return (t1, t2)
    }

    private static func parseTime(_ s: String) -> OHTime? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let p = t.components(separatedBy: ":")
        guard p.count == 2,
              let h = Int(p[0]), let m = Int(p[1]),
              h >= 0, h <= 24, m >= 0, m < 60 else { return nil }
        return OHTime(hour: h, minute: m)
    }

    // MARK: Serialize

    static func serialize(_ schedules: [OHSchedule]) -> String {
        if schedules.count == 1,
           let s = schedules.first,
           s.isAllDay,
           s.days == Set(OHWeekday.allCases) { return "24/7" }

        return schedules.map { serializeSchedule($0) }.joined(separator: "; ")
    }

    private static func serializeSchedule(_ s: OHSchedule) -> String {
        let dayStr = serializeDays(s.days)
        if s.isAllDay { return "\(dayStr) 00:00-24:00" }
        if s.breaks.isEmpty { return "\(dayStr) \(s.open.string)-\(s.close.string)" }

        var intervals: [String] = []
        var cur = s.open
        for b in s.breaks {
            intervals.append("\(cur.string)-\(b.from.string)")
            cur = b.to
        }
        intervals.append("\(cur.string)-\(s.close.string)")
        return "\(dayStr) \(intervals.joined(separator: ","))"
    }

    static func serializeDays(_ days: Set<OHWeekday>) -> String {
        let sorted = OHWeekday.allCases.filter { days.contains($0) }
        guard !sorted.isEmpty else { return "" }

        // Group consecutive days
        var groups: [[OHWeekday]] = [[sorted[0]]]
        for i in 1..<sorted.count {
            if sorted[i].rawValue == groups.last!.last!.rawValue + 1 {
                groups[groups.count - 1].append(sorted[i])
            } else {
                groups.append([sorted[i]])
            }
        }
        return groups.map { g in
            if g.count == 1 { return g[0].osmCode }
            if g.count == 2 { return "\(g[0].osmCode),\(g[1].osmCode)" }
            return "\(g.first!.osmCode)-\(g.last!.osmCode)"
        }.joined(separator: ",")
    }
}
