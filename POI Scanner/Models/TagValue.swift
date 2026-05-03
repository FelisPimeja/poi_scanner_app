import Foundation
import CoreGraphics

// MARK: - TagSource
// Источник значения тега — откуда оно пришло.

enum TagSource: Equatable {

    /// Существующее значение из базы OSM.
    case osm

    /// Распознано через OCR с фотографии.
    /// `imageRegion` — нормализованный прямоугольник (0…1) фрагмента фото,
    /// из которого взято значение (для будущего попапа-подсветки).
    case ocr(imageRegion: CGRect?)

    /// Декодировано из QR-кода.
    /// `raw` — сырая строка QR.
    case qr(raw: String)

    /// Извлечено из веб-страницы.
    case web(url: URL)

    // MARK: - Helpers

    /// Краткое название источника для отображения в UI.
    var displayName: String {
        switch self {
        case .osm:       return "OSM"
        case .ocr:       return "Фото"
        case .qr:        return "QR"
        case .web(let u): return u.host ?? "Сайт"
        }
    }

    /// SF Symbol для иконки источника.
    var iconName: String {
        switch self {
        case .osm:  return "map"
        case .ocr:  return "camera"
        case .qr:   return "qrcode"
        case .web:  return "globe"
        }
    }

    /// Является ли источником OSM (базовое значение, не требует подтверждения).
    var isOSM: Bool {
        if case .osm = self { return true }
        return false
    }
}

// MARK: - TagValue
// Одно значение одного OSM-тега с метаданными об источнике.

struct TagValue: Identifiable, Equatable {

    let id: UUID

    /// Само значение (OSM-строка, например "+7 495 123-45-67").
    var value: String

    /// Источник значения.
    var source: TagSource

    /// Уверенность в правильности значения (0…1).
    /// `nil` — для OSM-значений (baseline, доверяем по умолчанию).
    var confidence: Double?

    /// Включено ли значение в итоговый результат.
    /// OSM-значения включены по умолчанию; кандидаты — нет (ждут решения пользователя).
    var isAccepted: Bool

    // MARK: - Init

    init(
        id: UUID = UUID(),
        value: String,
        source: TagSource,
        confidence: Double? = nil,
        isAccepted: Bool? = nil
    ) {
        self.id         = id
        self.value      = value
        self.source     = source
        self.confidence = confidence
        // По умолчанию: OSM-значения принимаются сразу, кандидаты — нет.
        self.isAccepted = isAccepted ?? source.isOSM
    }

    // MARK: - Computed

    /// Требует ли значение явного решения пользователя.
    var needsDecision: Bool { !source.isOSM && !isAccepted }

    /// Уровень уверенности для цветовой индикации.
    var confidenceLevel: ConfidenceLevel {
        guard let c = confidence else { return .baseline }
        switch c {
        case 0.75...: return .high
        case 0.50...: return .medium
        default:      return .low
        }
    }
}

// MARK: - ConfidenceLevel
// Уровень уверенности — определяет цвет значения в UI.

enum ConfidenceLevel {
    case baseline   // OSM-значение — чёрный/primary цвет
    case high       // зелёный
    case medium     // оранжевый
    case low        // красный / розовый
}

// MARK: - TagValueGroup
// Все значения одного OSM-ключа, сгруппированные для редактора.

struct TagValueGroup: Identifiable {

    /// OSM-ключ (например "phone", "opening_hours").
    let key: String

    /// Все значения: OSM-baseline + кандидаты из всех источников.
    /// Порядок имеет значение — определяет очерёдность записи в OSM.
    var values: [TagValue]

    var id: String { key }

    // MARK: - Computed

    /// Есть ли хотя бы один кандидат, ожидающий решения.
    var needsReview: Bool {
        values.contains { $0.needsDecision }
    }

    /// Значения, принятые для записи в OSM.
    var acceptedValues: [String] {
        values.filter(\.isAccepted).map(\.value)
    }

    /// Итоговая строка OSM-тега (значения через "; ").
    var osmValue: String {
        acceptedValues.joined(separator: "; ")
    }

    // MARK: - Mutations

    /// Добавляет кандидата, если такого значения ещё нет.
    mutating func addCandidate(_ candidate: TagValue) {
        guard !values.contains(where: { $0.value == candidate.value }) else { return }
        values.append(candidate)
    }

    /// Применяет набор кандидатов из внешнего источника.
    mutating func applySource(
        values newValues: [String],
        source: TagSource,
        confidence: Double
    ) {
        for v in newValues {
            addCandidate(TagValue(value: v, source: source, confidence: confidence))
        }
    }
}
