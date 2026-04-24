import SwiftUI

// MARK: - OSMTagRow
// Единый компонент отображения тега OSM в обоих контекстах:
//   • карточка ноды (read-only)  → иконка в .secondary
//   • редактор POI (editable)    → иконка окрашена в цвет статуса;
//                                   если иконки нет — цветная точка (legacy)

struct OSMTagRow: View {
    let tagKey: String

    /// Только для read-only режима
    var readOnlyValue: String? = nil

    /// Для режима редактирования
    var editableValue: Binding<String>? = nil
    var status: FieldStatus? = nil

    private var definition: OSMTagDefinition? { OSMTags.definition(for: tagKey) }

    /// Человекочитаемая метка (из каталога или сам ключ)
    private var label: String { definition?.label ?? tagKey }

    /// SF Symbol для этого ключа (из каталога)
    private var icon: String? { definition?.icon }

    var body: some View {
        HStack(spacing: 10) {
            leadingIndicator
            tagContent
        }
        .padding(.vertical, 2)
    }

    // MARK: Leading indicator

    /// В режиме редактирования:
    ///   - иконка есть → иконка цвета статуса
    ///   - иконки нет  → цветная точка статуса
    /// В режиме просмотра:
    ///   - иконка есть → иконка .secondary
    ///   - иконки нет  → пустой резервированный блок (выравнивание по сетке)
    @ViewBuilder
    private var leadingIndicator: some View {
        if let iconName = icon {
            Image(systemName: iconName)
                .font(.body)
                .foregroundStyle(status.map(\.color) ?? Color.secondary)
                .frame(width: 24, alignment: .center)
        } else if let status {
            // нет иконки, но есть статус → точка
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundStyle(status.color)
                .frame(width: 24, alignment: .center)
        } else {
            // read-only без иконки → пустой блок той же ширины для выравнивания
            Color.clear
                .frame(width: 24, height: 1)
        }
    }

    // MARK: Tag content

    @ViewBuilder
    private var tagContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let binding = editableValue {
                TextField(tagKey, text: binding)
                    .font(.body)
            } else {
                Text(readOnlyValue ?? "")
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
    }
}
