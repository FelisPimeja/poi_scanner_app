import SwiftUI

/// Полноэкранный экран редактора часов работы.
/// Открывается из OSMTagRow при тапе на строку opening_hours в edit-режиме.
struct OpeningHoursEditorScreen: View {
    @Binding var value: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                OpeningHoursEditorView(value: $value)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .navigationTitle("Часы работы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
