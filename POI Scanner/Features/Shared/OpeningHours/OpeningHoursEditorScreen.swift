import SwiftUI

/// Полноэкранный экран редактора часов работы.
/// Открывается из OSMTagRow при тапе на строку opening_hours в edit-режиме.
struct OpeningHoursEditorScreen: View {
    @Binding var value: String
    @Environment(\.dismiss) private var dismiss

    /// Значение на момент открытия экрана — для кнопки «Отмена»
    @State private var originalValue: String = ""

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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        value = originalValue
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .onAppear {
            originalValue = value
            // Если значение пустое — записываем дефолт сразу,
            // чтобы «Готово» без каких-либо изменений тоже сохраняло его.
            if value.isEmpty {
                let defaultSchedule = OHSchedule(
                    days: Set(OHWeekday.allCases),
                    isAllDay: false,
                    open: .defaultOpen,
                    close: .defaultClose,
                    breaks: []
                )
                value = OpeningHoursParser.serialize([defaultSchedule])
            }
        }
    }
}
