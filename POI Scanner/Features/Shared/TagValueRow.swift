import SwiftUI

// MARK: - TagValueRow
// Строка одного значения тега в редакторе.
// Отображает: само значение, цвет по confidence, иконку источника справа.
// Свайп влево — отклонить/удалить. Свайп вправо — принять (для кандидатов).

struct TagValueRow: View {
    let tagKey: String
    let value: TagValue

    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            valueContent
                .frame(maxWidth: .infinity, alignment: .leading)

            sourceIcon
                .padding(.leading, 8)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onReject?()
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !value.source.isOSM && !value.isAccepted {
                Button {
                    onAccept?()
                } label: {
                    Label("Принять", systemImage: "checkmark")
                }
                .tint(.green)
            }
        }
    }

    // MARK: - Value content

    @ViewBuilder
    private var valueContent: some View {
        let display = OSMTagRow.displayValue(forKey: tagKey, value: value.value)

        if let url = contactURL(for: tagKey, value: value.value) {
            Link(destination: url) {
                Text(display)
                    .font(.body)
                    .foregroundStyle(valueColor.opacity(value.isAccepted || value.source.isOSM ? 1.0 : 0.85))
                    .strikethrough(!value.isAccepted && !value.source.isOSM, color: .secondary)
            }
        } else {
            Text(display)
                .font(.body)
                .foregroundStyle(valueColor.opacity(value.isAccepted || value.source.isOSM ? 1.0 : 0.85))
                .strikethrough(!value.isAccepted && !value.source.isOSM, color: .secondary)
        }
    }

    // MARK: - Source icon

    @ViewBuilder
    private var sourceIcon: some View {
        if !value.source.isOSM {
            Image(systemName: value.source.iconName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
        }
    }

    // MARK: - Color

    private var valueColor: Color {
        switch value.confidenceLevel {
        case .baseline: return .primary
        case .high:     return .green
        case .medium:   return .orange
        case .low:      return .red
        }
    }

    // MARK: - Contact URL (упрощённая копия из OSMTagRow)

    private func contactURL(for key: String, value: String) -> URL? {
        let k = key.lowercased()
        if k == "phone" || k == "contact:phone" || k == "contact:whatsapp" {
            return URL(string: "tel:\(value.replacingOccurrences(of: " ", with: ""))")
        }
        if k == "email" || k == "contact:email" {
            return URL(string: "mailto:\(value)")
        }
        if k == "contact:telegram" {
            if value.hasPrefix("http") { return URL(string: value) }
            let u = value.hasPrefix("@") ? String(value.dropFirst()) : value
            return URL(string: "https://t.me/\(u)")
        }
        if k == "website" || k.hasPrefix("contact:") {
            return URL(string: value.hasPrefix("http") ? value : "https://\(value)")
        }
        return nil
    }
}

// MARK: - TagValueGroupRows
// Весь блок значений одного ключа: existing + кандидаты, плоским списком.
// Вставляется внутрь секции редактора вместо одиночного OSMTagRow.

struct TagValueGroupRows: View {
    let tagKey: String
    @Binding var group: TagValueGroup

    var onReorderValues: ((IndexSet, Int) -> Void)?

    var body: some View {
        ForEach(group.values) { tagValue in
            TagValueRow(
                tagKey: tagKey,
                value: tagValue,
                onAccept: {
                    if let idx = group.values.firstIndex(where: { $0.id == tagValue.id }) {
                        group.values[idx].isAccepted = true
                    }
                },
                onReject: {
                    group.values.removeAll { $0.id == tagValue.id }
                }
            )
        }
        .onMove { source, destination in
            group.values.move(fromOffsets: source, toOffset: destination)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    List {
        Section("Телефон") {
            TagValueRow(
                tagKey: "phone",
                value: TagValue(value: "+7 (800) 505-48-14", source: .osm)
            )
            TagValueRow(
                tagKey: "phone",
                value: TagValue(value: "+7 (926) 555-00-11", source: .ocr(imageRegion: nil), confidence: 0.82, isAccepted: false)
            )
            TagValueRow(
                tagKey: "phone",
                value: TagValue(value: "+7 (916) 777-88-99", source: .web(url: URL(string: "https://example.ru")!), confidence: 0.45, isAccepted: false)
            )
        }

        Section("Сайт") {
            TagValueRow(
                tagKey: "website",
                value: TagValue(value: "https://dr.sursil.ru", source: .osm)
            )
            TagValueRow(
                tagKey: "website",
                value: TagValue(value: "https://sursil.ru", source: .web(url: URL(string: "https://sursil.ru")!), confidence: 0.78)
            )
        }
    }
}
#endif
