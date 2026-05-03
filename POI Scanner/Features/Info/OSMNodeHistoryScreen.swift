import SwiftUI

// MARK: - OSMNodeHistoryScreen

struct OSMNodeHistoryScreen: View {
    let nodeID:   Int64
    let nodeType: OSMElementType

    @State private var versions: [OSMElementVersion] = []
    @State private var changesets: [Int64: OSMChangesetInfo] = [:]
    @State private var currentIndex = 0
    @State private var isLoading = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    // Drag-to-swipe state
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Загрузка истории…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = error {
                    ContentUnavailableView {
                        Label("Ошибка", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(err)
                    } actions: {
                        Button("Повторить") { Task { await load() } }
                    }
                } else if versions.isEmpty {
                    ContentUnavailableView("История недоступна", systemImage: "clock.arrow.circlepath")
                } else {
                    versionPage
                }
            }
            .navigationTitle("История объекта")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Version page

    private var versionPage: some View {
        let ver = versions[currentIndex]
        let cs  = changesets[ver.changeset]

        return List {
            // ── Шапка версии ───────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    // Автор → ссылка на чейнджсет
                    let csPageURL = URL(string: "https://www.openstreetmap.org/changeset/\(ver.changeset)")
                    if let url = csPageURL {
                        Link(ver.user, destination: url)
                            .font(.body.weight(.semibold))
                    } else {
                        Text(ver.user).font(.body.weight(.semibold))
                    }

                    // Чейнджсет + дата → ссылка на страницу чейнджсета
                    let dateStr = ver.timestamp.formatted(date: .abbreviated, time: .shortened)
                    let csLabel = "#\(ver.changeset) · \(dateStr)"
                    if let url = csPageURL {
                        Link(csLabel, destination: url)
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    } else {
                        Text(csLabel).font(.subheadline).foregroundStyle(.secondary)
                    }

                    // Комментарий (многострочный)
                    if let comment = cs?.comment, !comment.isEmpty {
                        Text(comment)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if cs == nil {
                        ProgressView().scaleEffect(0.75)
                    }

                    if !ver.visible {
                        Text("Объект удалён в этой версии")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
            } header: {
                versionNavigator
                    .textCase(nil)
            }

            // ── Теги ──────────────────────────────────────────────────
            if !ver.tags.isEmpty || ver.diff.changes.values.contains(.removed) {
                Section("Теги") {
                    let allKeys: [String] = {
                        var keys = Set(ver.tags.keys)
                        for (k, c) in ver.diff.changes where c == .removed { keys.insert(k) }
                        return keys.sorted()
                    }()
                    ForEach(allKeys, id: \.self) { key in
                        let value = ver.tags[key] ?? ""
                        let change = ver.diff.change(for: key)
                        TagDiffRow(key: key, value: value, change: change)
                            .listRowSeparator(.hidden)
                    }
                }
            } else if ver.visible {
                Section("Теги") {
                    Text("Теги не заданы").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { val in
                    let dx = val.translation.width
                    if dx < -50 && currentIndex > 0 {
                        withAnimation { currentIndex -= 1; fetchChangesetIfNeeded() }
                    } else if dx > 50 && currentIndex < versions.count - 1 {
                        withAnimation { currentIndex += 1; fetchChangesetIfNeeded() }
                    }
                }
        )
    }

    // MARK: - Version navigator (header)

    private var versionNavigator: some View {
        HStack {
            Button {
                if currentIndex < versions.count - 1 {
                    withAnimation { currentIndex += 1; fetchChangesetIfNeeded() }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(currentIndex < versions.count - 1 ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex >= versions.count - 1)

            Spacer()
            Text("Версия \(versions[currentIndex].version) из \(versions.first?.version ?? versions.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()

            Button {
                if currentIndex > 0 {
                    withAnimation { currentIndex -= 1; fetchChangesetIfNeeded() }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(currentIndex > 0 ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex <= 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Data loading

    private func load() async {
        isLoading = true
        error = nil
        do {
            versions = try await OSMHistoryService.shared.fetchHistory(type: nodeType, id: nodeID)
            currentIndex = 0   // Начинаем с последней версии (index 0 = newest)
            isLoading = false
            fetchChangesetIfNeeded()
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func fetchChangesetIfNeeded() {
        guard !versions.isEmpty else { return }
        let csID = versions[currentIndex].changeset
        guard changesets[csID] == nil else { return }
        Task {
            if let info = try? await OSMHistoryService.shared.changesetInfo(id: csID) {
                changesets[csID] = info
            }
        }
    }
}

// MARK: - TagDiffRow

private struct TagDiffRow: View {
    let key:    String
    let value:  String
    let change: VersionDiff.TagChange

    private var bgColor: Color {
        switch change {
        case .added:     return Color.green.opacity(0.15)
        case .modified:  return Color.yellow.opacity(0.18)
        case .removed:   return Color.red.opacity(0.15)
        case .unchanged: return Color.clear
        }
    }

    private var displayValue: String {
        if change == .removed { return "(удалён)" }
        if value.isEmpty { return "—" }
        return value.replacingOccurrences(of: ";", with: ";\n")
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(key)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                let alias = OSMTags.definition(for: key)?.label ?? key
                Text(alias == key ? key : alias)
                    .font(.subheadline)
                    .foregroundStyle(change == .removed ? .secondary : .primary)
                    .strikethrough(change == .removed, color: .secondary)
            }
            Spacer()
            Text(displayValue)
                .font(.subheadline)
                .foregroundStyle(change == .removed ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 0)
        .padding(.horizontal, 4)
        .background(bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .listRowBackground(Color.clear)
    }
}
