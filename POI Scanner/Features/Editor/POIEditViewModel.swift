import Foundation
import SwiftUI

// MARK: - POIEditViewModel
// ViewModel редактора POI. Хранит все значения тегов в виде TagValueGroup,
// умеет принимать данные из любого источника (OSM, OCR, QR, веб).
//
// Заменяет разрозненные @State-переменные в POIEditorView
// и текущий MergeMode с TagDiffEntry.

@Observable
final class POIEditViewModel {

    // MARK: - Identity

    /// UUID редактируемого POI (nil при создании нового).
    let poiID: UUID?
    /// OSM Node ID (nil для новых объектов).
    let osmNodeID: Int64?
    let nodeType: OSMElementType?

    // MARK: - Tag groups
    // Ключ → группа значений. Это основное хранилище всех данных.

    var tagGroups: [String: TagValueGroup] = [:]

    // MARK: - Review state

    /// Есть ли хотя бы одно поле, требующее решения пользователя.
    var needsReview: Bool {
        tagGroups.values.contains(where: \.needsReview)
    }

    // MARK: - Init

    /// Создаёт ViewModel из существующего POI (entry point «сначала POI»).
    init(poi: POI) {
        self.poiID     = poi.id
        self.osmNodeID = poi.osmNodeId
        self.nodeType  = poi.osmType
        loadOSMTags(poi.tags)
    }

    /// Создаёт пустой ViewModel для нового объекта (entry point «сначала фото»).
    init() {
        self.poiID     = nil
        self.osmNodeID = nil
        self.nodeType  = nil
    }

    // MARK: - Load OSM baseline

    private func loadOSMTags(_ tags: [String: String]) {
        for (key, value) in tags {
            // Значения через "; " разбиваем на отдельные TagValue
            let parts = value
                .components(separatedBy: "; ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let tagValues = parts.map {
                TagValue(value: $0, source: .osm)
            }
            tagGroups[key] = TagValueGroup(key: key, values: tagValues)
        }
    }

    // MARK: - Apply external source

    /// Применяет данные из внешнего источника (OCR / QR / веб-парсер).
    /// Новые значения добавляются как кандидаты к существующим группам
    /// или создают новые группы.
    func applySource(tags: [String: String],
                     confidence: [String: Double],
                     source: TagSource) {
        for (key, rawValue) in tags {
            let parts = rawValue
                .components(separatedBy: "; ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let conf = confidence[key] ?? 0.5

            if tagGroups[key] != nil {
                tagGroups[key]!.applySource(values: parts, source: source, confidence: conf)
            } else {
                let candidates = parts.map {
                    TagValue(value: $0, source: source, confidence: conf)
                }
                tagGroups[key] = TagValueGroup(key: key, values: candidates)
            }
        }
    }

    // MARK: - Value mutations

    /// Принимает значение (isAccepted = true).
    func accept(_ valueID: UUID, forKey key: String) {
        tagGroups[key]?.values.mutateFirst(where: { $0.id == valueID }) {
            $0.isAccepted = true
        }
    }

    /// Отклоняет / удаляет значение.
    func reject(_ valueID: UUID, forKey key: String) {
        tagGroups[key]?.values.removeAll { $0.id == valueID }
    }

    /// Обновляет текст значения.
    func update(_ valueID: UUID, forKey key: String, newValue: String) {
        tagGroups[key]?.values.mutateFirst(where: { $0.id == valueID }) {
            $0.value = newValue
        }
    }

    /// Добавляет новое значение вручную (пустой кандидат для ввода).
    func addManualValue(forKey key: String) {
        let v = TagValue(value: "", source: .osm, isAccepted: true)
        if tagGroups[key] != nil {
            tagGroups[key]!.values.append(v)
        } else {
            tagGroups[key] = TagValueGroup(key: key, values: [v])
        }
    }

    /// Перемещает значения (drag-to-reorder).
    func moveValues(forKey key: String, from source: IndexSet, to destination: Int) {
        tagGroups[key]?.values.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Apply from WebFetchResult array

    /// Применяет массив результатов веб-парсинга (WebEnricher output).
    func applyWebResults(_ results: [WebFetchResult]) {
        for result in results where result.error == nil {
            let source = TagSource.web(url: result.url)
            applySource(tags: result.tags,
                        confidence: result.confidence,
                        source: source)
        }
    }

    /// Применяет OCR ParseResult.
    func applyOCR(tags: [String: String], confidence: [String: Double],
                  imageRegion: CGRect? = nil) {
        applySource(tags: tags,
                    confidence: confidence,
                    source: .ocr(imageRegion: imageRegion))
    }

    /// Применяет QR-данные.
    func applyQR(tags: [String: String], confidence: [String: Double], raw: String) {
        applySource(tags: tags, confidence: confidence, source: .qr(raw: raw))
    }

    // MARK: - Apply from OSM duplicate (replaces old applyMerge)

    /// Накладывает теги существующего OSM-объекта как baseline (source = .osm),
    /// а уже загруженные кандидаты остаются с их источниками.
    /// Вызывается когда пользователь выбирает дубль для обновления.
    func applyOSMNode(_ node: OSMNode) {
        // Сохраняем текущие non-osm кандидаты
        let existing = tagGroups

        // Перезагружаем OSM baseline из ноды
        tagGroups = [:]
        loadOSMTags(node.tags)

        // Возвращаем кандидатов из других источников
        for (key, group) in existing {
            let nonOSM = group.values.filter { !$0.source.isOSM }
            guard !nonOSM.isEmpty else { continue }
            let conf = nonOSM.first.map { $0.confidence ?? 0.5 } ?? 0.5
            let src  = nonOSM.first?.source ?? .ocr(imageRegion: nil)
            tagGroups[key]?.applySource(
                values: nonOSM.map(\.value),
                source: src,
                confidence: conf
            )
            // Если ключа не было в OSM ноде — создаём группу
            if tagGroups[key] == nil {
                tagGroups[key] = TagValueGroup(key: key, values: nonOSM)
            }
        }
    }

    // MARK: - Export

    /// Итоговый словарь тегов для отправки в OSM.
    /// Включает только принятые значения; ключи с пустым результатом опускаются.
    func exportTags() -> [String: String] {
        var result: [String: String] = [:]
        for (key, group) in tagGroups {
            let joined = group.osmValue
            if !joined.isEmpty {
                result[key] = joined
            }
        }
        return result
    }
}

// MARK: - Array helpers

private extension Array {
    mutating func mutateFirst(where predicate: (Element) -> Bool,
                              _ mutation: (inout Element) -> Void) {
        guard let idx = firstIndex(where: predicate) else { return }
        mutation(&self[idx])
    }
}
