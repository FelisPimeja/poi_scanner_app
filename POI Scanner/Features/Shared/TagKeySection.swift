import SwiftUI

// MARK: - TagKeySection
// Блок одного OSM-ключа в редакторе: заголовок + все значения + кнопка «+».
// Используется вместо одиночного OSMTagRow когда редактор работает через POIEditViewModel.
//
// Специализированные ключи (opening_hours) рендерятся через специальный виджет.

struct TagKeySection: View {
    let tagKey: String
    @Binding var group: TagValueGroup

    /// Переопределить иконку (например для адресных строк).
    var forceIcon: String? = nil
    /// Скрыть иконку (для строк 2…N в адресном блоке).
    var hideIcon: Bool = false

    private var definition: OSMTagDefinition? { OSMTags.definition(for: tagKey) }
    private var poiField: POIField? { POIFieldRegistry.shared.field(forOSMKey: tagKey) }

    private var icon: String? { forceIcon ?? definition?.icon }

    private var label: String {
        OSMTagRow.labelFor(tagKey)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leadingIndicator

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                valuesBlock
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Leading indicator

    @ViewBuilder
    private var leadingIndicator: some View {
        if hideIcon {
            Color.clear.frame(width: 24)
        } else if let iconName = icon {
            Image(systemName: iconName)
                .font(.body)
                .foregroundStyle(group.needsReview ? Color.orange : Color.secondary)
                .frame(width: 24, alignment: .center)
        } else {
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundStyle(group.needsReview ? Color.orange : Color.secondary)
                .frame(width: 24, alignment: .center)
        }
    }

    // MARK: - Values block

    @ViewBuilder
    private var valuesBlock: some View {
        if isOpeningHours {
            openingHoursBlock
        } else {
            TagValueGroupRows(tagKey: tagKey, group: $group)

            // Кнопка добавить новое значение
            Button {
                group.values.append(TagValue(value: "", source: .osm, isAccepted: true))
            } label: {
                Label("Добавить", systemImage: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    // MARK: - Opening hours special case

    private var isOpeningHours: Bool { tagKey == "opening_hours" }

    @ViewBuilder
    private var openingHoursBlock: some View {
        // Все значения показываем как строки (без inline-редактора).
        // Каждое значение имеет стрелку → переход в OpeningHoursEditorScreen.
        ForEach(group.values) { tagValue in
            HStack {
                Text(tagValue.value.isEmpty ? "—" : tagValue.value)
                    .font(.body)
                    .foregroundStyle(colorFor(tagValue))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !tagValue.source.isOSM {
                    Image(systemName: tagValue.source.iconName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func colorFor(_ v: TagValue) -> Color {
        switch v.confidenceLevel {
        case .baseline: return .primary
        case .high:     return .green
        case .medium:   return .orange
        case .low:      return .red
        }
    }
}

// MARK: - OSMTagRow label helper (статический)
// Чтобы не дублировать логику вычисления метки — выносим в расширение OSMTagRow.

extension OSMTagRow {
    /// Возвращает человекочитаемую метку для ключа (без создания View-инстанса).
    static func labelFor(_ tagKey: String) -> String {
        if let field = POIFieldRegistry.shared.field(forOSMKey: tagKey) { return field.label }
        if let def   = OSMTags.definition(for: tagKey)                  { return def.label }
        if let (parentField, suffix) = POIFieldRegistry.shared.field(forSubKey: tagKey) {
            let localSuffix: String
            if let opt = parentField.options.first(where: { $0.value == suffix }) {
                localSuffix = opt.label
            } else {
                localSuffix = OSMValueLocalizations.label(for: suffix, key: tagKey)
            }
            return "\(parentField.label) (\(localSuffix))"
        }
        return localizedNameLabel(for: tagKey)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    List {
        TagKeySection(
            tagKey: "phone",
            group: .constant(TagValueGroup(key: "phone", values: [
                TagValue(value: "+7 (800) 505-48-14", source: .osm),
                TagValue(value: "+7 (926) 555-00-11", source: .ocr(imageRegion: nil), confidence: 0.82, isAccepted: false),
                TagValue(value: "+7 (916) 777-88-99", source: .web(url: URL(string: "https://example.ru")!), confidence: 0.45, isAccepted: false),
            ]))
        )
        TagKeySection(
            tagKey: "opening_hours",
            group: .constant(TagValueGroup(key: "opening_hours", values: [
                TagValue(value: "Mo-Su 10:00-20:00", source: .osm),
                TagValue(value: "Mo-Su 11:00-23:00", source: .ocr(imageRegion: nil), confidence: 0.78, isAccepted: false),
            ]))
        )
    }
}
#endif
