import Foundation

// MARK: - IndoorFloor

/// Один этаж здания, представленный значением OSM-тега `level`.
/// Уровень 0 = первый этаж (земля), отрицательные = подземные, положительные = надземные.
struct IndoorFloor: Identifiable, Hashable, Comparable {
    let level: Int

    var id: Int { level }

    /// Читаемая метка в формате EN: "G" для 0, "+N" для положительных, "N" для отрицательных.
    var label: String { labelFor(language: .en) }

    /// Читаемая метка с учётом языка:
    /// - EN: 0→"G", 1→"+1", -1→"-1"
    /// - RU: подземные без изменений (0→"-1"... нет), 0→"1", 1→"2"; подземные: -1→"-1", -2→"-2"
    ///   В России нет понятия ground floor, поэтому level 0 = 1-й этаж, level N = (N+1)-й этаж.
    func labelFor(language: AppLanguage) -> String {
        switch language {
        case .en:
            switch level {
            case 0:    return "G"
            case 1...: return "+\(level)"
            default:   return "\(level)"
            }
        case .ru:
            if level >= 0 {
                return "\(level + 1)"   // 0→1, 1→2, 2→3 ...
            } else {
                return "\(level)"       // -1→-1, -2→-2 (подземные без изменений)
            }
        }
    }

    static func < (lhs: IndoorFloor, rhs: IndoorFloor) -> Bool {
        lhs.level < rhs.level
    }
}
