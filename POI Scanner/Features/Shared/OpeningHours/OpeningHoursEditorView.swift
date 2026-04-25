import SwiftUI

// MARK: - Opening Hours Editor (main view)

/// Визуальный редактор opening_hours.
/// Встраивается в OSMTagRow вместо обычного TextField когда inputType == .openingHours.
struct OpeningHoursEditorView: View {
    @Binding var value: String
    @State private var schedules: [OHSchedule] = []

    // MARK: Computed

    /// Дни, уже занятые хотя бы одним расписанием
    private var coveredDays: Set<OHWeekday> {
        schedules.reduce(Set()) { $0.union($1.days) }
    }

    /// Дни, для которых ещё нет расписания
    private var uncoveredDays: [OHWeekday] {
        OHWeekday.allCases.filter { !coveredDays.contains($0) }
    }

    /// Метка кнопки добавления: «+ Добавить Сб, Вс»
    private var addButtonLabel: String {
        let names = uncoveredDays.map { $0.shortName }.joined(separator: ", ")
        return "+ Добавить \(names)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach($schedules) { $schedule in
                // Дни, заблокированные для этого блока = дни во всех остальных блоках
                let disabledDays: Set<OHWeekday> = schedules
                    .filter { $0.id != schedule.id }
                    .reduce(Set()) { $0.union($1.days) }

                OHScheduleBlock(
                    schedule: $schedule,
                    disabledDays: disabledDays,
                    canDelete: schedules.count > 1,
                    onDelete: { remove(schedule) }
                )
                .onChange(of: schedule) { _, _ in sync() }
            }

            // «+ Добавить Сб, Вс» — только если есть незакрытые дни
            if !uncoveredDays.isEmpty {
                Divider()
                Button {
                    schedules.append(OHSchedule(
                        days: Set(uncoveredDays),
                        isAllDay: false,
                        open: .defaultOpen,
                        close: .defaultClose,
                        breaks: []
                    ))
                    sync()
                } label: {
                    Text(addButtonLabel)
                        .font(.body)
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { load() }
        .onChange(of: value) { _, newVal in
            if newVal != OpeningHoursParser.serialize(schedules) { load() }
        }
    }

    // MARK: Helpers

    private func load() {
        let (parsed, _) = OpeningHoursParser.parse(value)
        schedules = parsed.isEmpty
            ? [OHSchedule(days: [], isAllDay: false,
                          open: .defaultOpen, close: .defaultClose, breaks: [])]
            : parsed
    }

    private func sync() {
        value = OpeningHoursParser.serialize(schedules)
    }

    private func remove(_ s: OHSchedule) {
        schedules.removeAll { $0.id == s.id }
        if schedules.isEmpty {
            schedules = [OHSchedule(days: [], isAllDay: false,
                                    open: .defaultOpen, close: .defaultClose, breaks: [])]
        }
        sync()
    }
}

// MARK: - One schedule block

private struct OHScheduleBlock: View {
    @Binding var schedule: OHSchedule
    let disabledDays: Set<OHWeekday>
    let canDelete: Bool
    let onDelete: () -> Void

    @State private var expandedBreakId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            // Day checkboxes
            OHDayPickerRow(selectedDays: $schedule.days, disabledDays: disabledDays)
                .padding(.vertical, 8)

            Divider()

            // All-day toggle
            Toggle("Весь день (24 часа)", isOn: $schedule.isAllDay)
                .padding(.vertical, 8)

            // Time pickers (hidden when all-day)
            if !schedule.isAllDay {
                Divider()
                OHTimeRangeRow(open: $schedule.open, close: $schedule.close)
                    .padding(.vertical, 4)

                // Breaks
                ForEach($schedule.breaks) { $br in
                    Divider()
                    OHBreakRow(
                        breakPeriod: $br,
                        isExpanded: expandedBreakId == br.id,
                        onToggle: {
                            expandedBreakId = (expandedBreakId == br.id) ? nil : br.id
                        },
                        onDelete: { removeBreak(br) }
                    )
                }

                Divider()
                Button {
                    let newBr = OHBreak(
                        from: OHTime(hour: 13, minute: 0),
                        to:   OHTime(hour: 14, minute: 0)
                    )
                    schedule.breaks.append(newBr)
                } label: {
                    Text("Добавить перерыв")
                        .font(.body)
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }

            // Delete schedule
            if canDelete {
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Text("Удалить расписание")
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
    }

    private func removeBreak(_ br: OHBreak) {
        schedule.breaks.removeAll { $0.id == br.id }
        if expandedBreakId == br.id { expandedBreakId = nil }
    }
}

// MARK: - Day picker row

private struct OHDayPickerRow: View {
    @Binding var selectedDays: Set<OHWeekday>
    let disabledDays: Set<OHWeekday>

    var body: some View {
        HStack(spacing: 0) {
            ForEach(OHWeekday.allCases) { day in
                let selected = selectedDays.contains(day)
                let disabled = disabledDays.contains(day) && !selected
                VStack(spacing: 4) {
                    Text(day.shortName)
                        .font(.caption)
                        .foregroundStyle(disabled ? Color.secondary.opacity(0.35)
                                         : selected ? .primary : .secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                disabled ? Color.secondary.opacity(0.2)
                                : selected ? Color.blue : Color.secondary.opacity(0.4),
                                lineWidth: 1.5
                            )
                            .frame(width: 26, height: 26)
                        if selected {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue)
                                .frame(width: 26, height: 26)
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .onTapGesture {
                        guard !disabled else { return }
                        if selected { selectedDays.remove(day) }
                        else        { selectedDays.insert(day) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Time range row (Open / Close) — оба колёсика всегда видимы

private struct OHTimeRangeRow: View {
    @Binding var open:  OHTime
    @Binding var close: OHTime

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Открыт")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                OHWheelPicker(time: $open)
            }
            .frame(maxWidth: .infinity)

            Text("—")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(height: 120)
                .padding(.top, 22) // offset for label height above picker

            VStack(alignment: .leading, spacing: 2) {
                Text("Закрыт")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                OHWheelPicker(time: $close)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Break row

private struct OHBreakRow: View {
    @Binding var breakPeriod: OHBreak
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: onToggle) {
                    HStack {
                        Text("Перерыв")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(breakPeriod.from.string)–\(breakPeriod.to.string)")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            .padding(.vertical, 8)

            if isExpanded {
                HStack(spacing: 0) {
                    OHWheelPicker(time: $breakPeriod.from)
                    Text("—")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    OHWheelPicker(time: $breakPeriod.to)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .padding(.bottom, 4)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

// MARK: - Wheel picker (hour : minute)

private struct OHWheelPicker: View {
    @Binding var time: OHTime

    private let hours:   [Int] = Array(0...24)
    private let minutes: [Int] = stride(from: 0, through: 55, by: 5).map { $0 }

    var body: some View {
        HStack(spacing: 0) {
            // Hours
            Picker("", selection: $time.hour) {
                ForEach(hours, id: \.self) { h in
                    Text(String(format: "%02d", h)).tag(h)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 64)
            .clipped()

            Text(":")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 2)

            // Minutes (snap to nearest 5)
            Picker("", selection: Binding(
                get: { roundedMinute(time.minute) },
                set: { time.minute = $0 }
            )) {
                ForEach(minutes, id: \.self) { m in
                    Text(String(format: "%02d", m)).tag(m)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 64)
            .clipped()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }

    private func roundedMinute(_ m: Int) -> Int {
        minutes.min(by: { abs($0 - m) < abs($1 - m) }) ?? 0
    }
}

// MARK: - OHSchedule: Equatable for onChange

extension OHSchedule: Equatable {
    static func == (lhs: OHSchedule, rhs: OHSchedule) -> Bool {
        lhs.id == rhs.id &&
        lhs.days == rhs.days &&
        lhs.isAllDay == rhs.isAllDay &&
        lhs.open == rhs.open &&
        lhs.close == rhs.close &&
        lhs.breaks == rhs.breaks
    }
}
