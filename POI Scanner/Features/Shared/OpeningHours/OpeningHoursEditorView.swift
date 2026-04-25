import SwiftUI

// MARK: - Opening Hours Editor (main view)

/// Визуальный редактор opening_hours.
/// Встраивается в OSMTagRow вместо обычного TextField когда inputType == .openingHours.
struct OpeningHoursEditorView: View {
    @Binding var value: String

    @State private var schedules:    [OHSchedule] = []
    @State private var isAdvanced:   Bool = false
    @State private var rawText:      String = ""

    var body: some View {
        Group {
            if isAdvanced {
                advancedModeRow
            } else {
                visualEditor
            }
        }
        .onAppear { load() }
        .onChange(of: value) { _, newVal in
            // Если значение изменилось снаружи — перезагружаем
            let current = isAdvanced ? rawText : OpeningHoursParser.serialize(schedules)
            if newVal != current { load() }
        }
    }

    // MARK: Visual editor

    private var visualEditor: some View {
        VStack(spacing: 0) {
            ForEach($schedules) { $schedule in
                OHScheduleBlock(
                    schedule: $schedule,
                    canDelete: schedules.count > 1,
                    onDelete: { remove(schedule) }
                )
                .onChange(of: schedule) { _, _ in sync() }
            }

            // Add schedule
            Button {
                schedules.append(OHSchedule(
                    days: [],
                    isAllDay: false,
                    open: .defaultOpen,
                    close: .defaultClose,
                    breaks: []
                ))
                sync()
            } label: {
                Label("Добавить расписание", systemImage: "plus")
                    .font(.body)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Divider().padding(.vertical, 4)

            // Advanced mode toggle
            Button {
                rawText = value
                isAdvanced = true
            } label: {
                HStack {
                    Text("Расширенный режим")
                        .foregroundStyle(.blue)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    // MARK: Advanced mode

    private var advancedModeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Расширенный режим")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Визуальный") {
                    let (parsed, adv) = OpeningHoursParser.parse(rawText)
                    if adv || parsed.isEmpty {
                        // Can't switch back — keep advanced
                    } else {
                        schedules  = parsed
                        isAdvanced = false
                        sync()
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
            }
            TextField("Mo-Fr 09:00-18:00", text: $rawText)
                .font(.body)
                .onChange(of: rawText) { _, v in value = v }
        }
    }

    // MARK: Helpers

    private func load() {
        let (parsed, adv) = OpeningHoursParser.parse(value)
        if adv {
            rawText    = value
            isAdvanced = true
        } else {
            schedules  = parsed.isEmpty
                ? [OHSchedule(days: [], isAllDay: false,
                              open: .defaultOpen, close: .defaultClose, breaks: [])]
                : parsed
            isAdvanced = false
        }
    }

    private func sync() {
        value = OpeningHoursParser.serialize(schedules)
    }

    private func remove(_ s: OHSchedule) {
        schedules.removeAll { $0.id == s.id }
        sync()
    }
}

// MARK: - One schedule block

private struct OHScheduleBlock: View {
    @Binding var schedule: OHSchedule
    let canDelete: Bool
    let onDelete: () -> Void

    @State private var expandedBreakId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            // Day checkboxes
            OHDayPickerRow(selectedDays: $schedule.days)
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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(OHWeekday.allCases) { day in
                let selected = selectedDays.contains(day)
                VStack(spacing: 4) {
                    Text(day.shortName)
                        .font(.caption)
                        .foregroundStyle(selected ? .primary : .secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(selected ? Color.blue : Color.secondary.opacity(0.4), lineWidth: 1.5)
                            .frame(width: 24, height: 24)
                        if selected {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue)
                                .frame(width: 24, height: 24)
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .onTapGesture {
                        if selected { selectedDays.remove(day) }
                        else        { selectedDays.insert(day) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Time range row (Open / Close)

private struct OHTimeRangeRow: View {
    @Binding var open:  OHTime
    @Binding var close: OHTime

    @State private var expandedSide: Side? = nil

    enum Side { case open, close }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Open
                timeButton(label: "Открыт", time: open, side: .open)
                Divider().frame(height: 44)
                // Close
                timeButton(label: "Закрыт", time: close, side: .close)
            }
            .frame(height: 52)

            if expandedSide == .open {
                OHWheelPicker(time: $open)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if expandedSide == .close {
                OHWheelPicker(time: $close)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: expandedSide)
    }

    private func timeButton(label: String, time: OHTime, side: Side) -> some View {
        Button {
            expandedSide = (expandedSide == side) ? nil : side
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(time.string)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
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
