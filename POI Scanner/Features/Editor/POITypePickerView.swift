import SwiftUI

// MARK: - POITypePickerView

/// Экран поиска и выбора типа POI из справочника.
///
/// Открывается как `navigationDestination` или `sheet` поверх редактора.
/// При выборе вызывает `onSelect(POIType)` и закрывается.
struct POITypePickerView: View {

    var onSelect: (POIType) -> Void

    @Environment(\.dismiss) private var dismiss

    private let registry = POITypeRegistry.shared

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    // MARK: - Body

    var body: some View {
        List {
            if filteredTypes.isEmpty {
                emptyState
            } else {
                ForEach(filteredTypes) { type in
                    typeRow(type)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Тип места")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { dismiss() }
            }
        }
    }

    // MARK: - Filtered data

    private var filteredTypes: [POIType] {
        registry.search(query)
    }

    // MARK: - Row

    @ViewBuilder
    private func typeRow(_ type: POIType) -> some View {
        Button {
            onSelect(type)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                // Иконка базового ключа
                Image(systemName: iconName(for: type.key))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.name)
                        .foregroundStyle(.primary)
                    Text("\(type.key)=\(type.value)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Ничего не найдено")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private func iconName(for key: String) -> String {
        switch key {
        case "amenity":          return "fork.knife"
        case "shop":             return "cart"
        case "craft":            return "wrench.and.screwdriver"
        case "public_transport": return "bus"
        case "healthcare":       return "cross.case"
        default:                 return "tag"
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        POITypePickerView { type in
            print("Selected: \(type.id)")
        }
    }
}
