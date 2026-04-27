import SwiftUI
import MapLibre
import CoreLocation

// MARK: - EditorMode

/// Режим работы редактора: добавление нового POI или редактирование существующего.
enum EditorMode {
    /// Новый POI: показываем поиск дублей, source label, photo accuracy, превью фото.
    case new(sourceImage: UIImage?)
    /// Редактирование существующего OSM-объекта: TechInfo, спиннер загрузки деталей.
    case edit(node: OSMNode, viewModel: MapViewModel)
}

// MARK: - POIEditorView

/// Универсальный экран редактирования POI.
///
/// Режим `new`  — добавление: поиск дублей, merge, source label, фото.
/// Режим `edit` — редактирование OSMNode: TechInfo, загрузка деталей, detent.
///
/// Undo/Redo и version check активны в обоих режимах.
struct POIEditorView: View {

    // MARK: - Init params

    @State var poi: POI
    let mode: EditorMode
    var onSave: ((POI) -> Void)? = nil

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss
    private let authService = OSMAuthService.shared

    // MARK: - Editor state

    @State private var editTab: EditTab = .simplified
    @State private var tagPairs: [TagPair] = []

    // MARK: - Coordinate

    @State private var coordinateSource: CoordinateSource
    @State private var showCoordinatePicker = false

    // MARK: - Upload / Save

    @State private var isUploading = false
    @State private var isSaving = false
    @State private var uploadError: String? = nil
    @State private var showUploadError = false

    // MARK: - Undo / Redo

    @State private var undoStack: [[String: String]] = []
    @State private var redoStack: [[String: String]] = []
    @State private var snapshotTask: Task<Void, Never>? = nil

    // Merge-режим: отдельные стеки для (diffEntries + placeholders)
    private struct MergeSnapshot: Equatable {
        var diffEntries: [TagDiffEntry]
        var placeholders: [String: String]
    }
    @State private var mergeUndoStack: [MergeSnapshot] = []
    @State private var mergeRedoStack: [MergeSnapshot] = []

    private var canUndo: Bool {
        isMergeMode ? mergeUndoStack.count >= 2 : undoStack.count >= 2
    }
    private var canRedo: Bool {
        isMergeMode ? !mergeRedoStack.isEmpty : !redoStack.isEmpty
    }

    // MARK: - Duplicate search (new mode only)

    @State private var duplicates: [DuplicateCandidate] = []
    @State private var isCheckingDuplicates = false
    @State private var selectedDuplicate: DuplicateCandidate? = nil
    @State private var isMergeMode = false
    @State private var diffEntries: [TagDiffEntry] = []
    @State private var mergePlaceholderTags: [String: String] = [:]
    @State private var originalExtractedTags: [String: String] = [:]
    @State private var originalCoordinate: POI.Coordinate? = nil

    // MARK: - Type picker

    @State private var showTypePicker = false

    // MARK: - Image preview

    @State private var showImagePreview = false

    // MARK: - Computed helpers

    private var isNewMode: Bool {
        if case .new = mode { return true }
        return false
    }

    private var sourceImage: UIImage? {
        if case .new(let img) = mode { return img }
        return nil
    }

    private var editNode: OSMNode? {
        if case .edit(let node, _) = mode { return node }
        return nil
    }

    private var editViewModel: MapViewModel? {
        if case .edit(_, let vm) = mode { return vm }
        return nil
    }

    /// Актуальная нода для просмотра в edit-режиме (обновляется после загрузки деталей).
    private var currentNode: OSMNode? {
        editViewModel?.selectedNodeDetails ?? editNode
    }

    private var isLoadingDetails: Bool {
        editViewModel?.isLoadingDetails ?? false
    }

    // MARK: - Init

    init(poi: POI, mode: EditorMode, onSave: ((POI) -> Void)? = nil) {
        var p = poi
        // Подставляем lastCity если addr:city не заполнен (только для нового POI)
        if case .new = mode {
            let savedCity = AppSettings.shared.lastCity
            if p.tags["addr:city"] == nil, !savedCity.isEmpty {
                p.tags["addr:city"] = savedCity
            }
        }
        _poi = State(initialValue: p)
        self.mode = mode
        self.onSave = onSave
        _coordinateSource = State(initialValue: p.coordinateSource)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            mainContent
        }
    }

    // Вынесено из body — компилятор Swift не справлялся с длинной цепочкой
    // в одном выражении; разбито на два отдельных @ViewBuilder свойства.
    @ViewBuilder
    private var mainContent: some View {
        contentStack
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onChange(of: poi.tags) { _, _ in scheduleSnapshot() }
            .sheet(isPresented: $showImagePreview) {
                if let img = sourceImage { ImagePreviewView(image: img) }
            }
            .sheet(isPresented: $showCoordinatePicker) { coordinatePickerSheet }
            .sheet(isPresented: $showTypePicker) {
                NavigationStack {
                    POITypePickerView { selectedType in
                        applyPOIType(selectedType)
                    }
                }
            }
            .task { await onAppearTask() }
            .onChange(of: poi.coordinate) { _, _ in onCoordinateChange() }
            .onChange(of: activeTypeKeys) { _, _ in scheduleTypeBasedDuplicateSearch() }
            .onChange(of: diffEntries) { _, v in onDiffEntriesChange(v) }
            .onChange(of: mergePlaceholderTags) { _, v in onPlaceholdersChange(v) }
            .alert("Ошибка загрузки", isPresented: $showUploadError) {
                Button("Скопировать") { UIPasteboard.general.string = uploadError }
                Button("OK", role: .cancel) {}
            } message: {
                Text(uploadError ?? "Неизвестная ошибка")
            }
    }

    private var navigationTitle: String {
        poi.tags["name"] ?? (isNewMode ? "Новый POI" : "POI")
    }

    @ViewBuilder
    private var contentStack: some View {
        VStack(spacing: 0) {
            Picker("Режим", selection: $editTab) {
                ForEach(EditTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemGroupedBackground))

            List {
                if editTab == .simplified {
                    simplifiedContent
                } else {
                    tagsContent
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: editTab) { _, newTab in
                if newTab == .tags { syncPairsFromTags() }
                if newTab == .simplified { syncTagsFromPairs() }
            }
        }
    }

    @ViewBuilder
    private var coordinatePickerSheet: some View {
        let coord = CLLocationCoordinate2D(
            latitude: poi.coordinate.latitude,
            longitude: poi.coordinate.longitude
        )
        let floor = poi.tags["level"].flatMap(Int.init) ?? 0
        CoordinatePickerView(
            initialCoordinate: coord,
            initialFloor: floor,
            onConfirm: { newCoord in
                poi.coordinate = POI.Coordinate(newCoord)
                coordinateSource = .manual
                showCoordinatePicker = false
            },
            onCancel: { showCoordinatePicker = false }
        )
    }

    private func onAppearTask() async {
        // Pre-populate essential placeholder keys со значением "".
        // Предотвращает структурное изменение ForEach при вводе первого символа.
        for keys in essentialPlaceholders.values {
            for key in keys where poi.tags[key] == nil {
                poi.tags[key] = ""
            }
        }
        undoStack = [poi.tags]
        guard isNewMode, poi.osmNodeId == nil else { return }
        await runDuplicateSearch()
    }

    private func onCoordinateChange() {
        guard isNewMode, poi.osmNodeId == nil else { return }
        cancelMergeIfActive()
        duplicates = []
        isCheckingDuplicates = true
        let radius = searchRadiusMeters
        Task {
            do {
                let found = try await DuplicateChecker.shared
                    .findDuplicates(near: poi, radiusMeters: radius)
                duplicates = found
            } catch {}
            isCheckingDuplicates = false
        }
    }

    private func onDiffEntriesChange(_ newEntries: [TagDiffEntry]) {
        guard isMergeMode else { return }
        let snap = MergeSnapshot(diffEntries: newEntries, placeholders: mergePlaceholderTags)
        guard snap != mergeUndoStack.last else { return }
        mergeUndoStack.append(snap)
        mergeRedoStack.removeAll()
    }

    private func onPlaceholdersChange(_ newPlaceholders: [String: String]) {
        guard isMergeMode else { return }
        let snap = MergeSnapshot(diffEntries: diffEntries, placeholders: newPlaceholders)
        guard snap != mergeUndoStack.last else { return }
        mergeUndoStack.append(snap)
        mergeRedoStack.removeAll()
    }

    // MARK: - Simplified tab content

    @ViewBuilder
    private var simplifiedContent: some View {
        // Фото превью (только новый режим)
        if let img = sourceImage {
            Section {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { showImagePreview = true }
            }
        }

        // Карта + координаты (скрываем для way/relation в edit-режиме)
        let isEditingNonNode = editNode != nil && editNode?.type != .node
        if !isEditingNonNode {
            locationSection
        }

        if isMergeMode {
            mergeDiffSection
        } else {
            typeSection
            tagGroupSections
            addTagSection
        }

        // Техническая информация (только edit-режим)
        if let node = currentNode {
            TechInfoSection(node: node)
        }
    }

    // MARK: - Raw tags tab content

    @ViewBuilder
    private var tagsContent: some View {
        Section {
            ForEach(tagPairs.indices, id: \.self) { i in
                TagPairRow(
                    pair: $tagPairs[i],
                    onDelete: { deleteTagPair(at: i) }
                )
            }
        }
        addTagSection
    }

    // MARK: - Location section

    @ViewBuilder
    private var locationSection: some View {
        let lat = poi.coordinate.latitude
        let lon = poi.coordinate.longitude
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let canEditCoord = editNode == nil || editNode?.type == .node
        let extraMarkers: [(coordinate: CLLocationCoordinate2D, color: UIColor, colorIndex: Int)] =
            isNewMode ? candidatesWithColors.enumerated().map { (i, item) in
                (coordinate: CLLocationCoordinate2D(
                    latitude: item.candidate.node.latitude,
                    longitude: item.candidate.node.longitude
                ), color: item.color, colorIndex: i)
            } : []

        Section {
            LocationPreviewMapView(
                coordinate: coord,
                extraMarkers: extraMarkers,
                accuracyMeters: isNewMode ? searchRadiusMeters : nil
            )
            .frame(height: 148)
            .listRowInsets(EdgeInsets())
            .clipShape(Rectangle())
            .contentShape(Rectangle())
            .onTapGesture { if canEditCoord { showCoordinatePicker = true } }

            // Строка координат
            HStack(spacing: 10) {
                Image(uiImage: LocationPreviewMapView.Coordinator.renderPin(
                    color: canEditCoord ? .systemBlue : .systemGray,
                    size: CGSize(width: 20, height: 22),
                    shadow: false
                ))
                .frame(width: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    Text(dmsString(lat: lat, lon: lon))
                        .font(.body)
                        .foregroundStyle(canEditCoord ? Color.accentColor : Color.primary)
                    if isNewMode {
                        Text(sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                if isNewMode {
                    Image(systemName: isMergeMode ? "circle" : "record.circle")
                        .foregroundStyle(isMergeMode ? Color.secondary : Color.accentColor)
                        .font(.title3)
                } else if canEditCoord {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isMergeMode {
                    cancelMerge()
                } else if canEditCoord {
                    showCoordinatePicker = true
                }
            }

            // Поиск / результаты дублей (только new mode)
            if isNewMode {
                if isCheckingDuplicates && duplicates.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.8)
                        Text("Поиск похожих мест…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if !duplicates.isEmpty {
                    duplicateCandidatesView
                }
            }
        }
    }

    // MARK: - Duplicate candidates

    private var candidatesWithColors: [(candidate: DuplicateCandidate, color: UIColor)] {
        duplicates.enumerated().map { (i, c) in
            (c, DuplicateCandidate.palette[i % DuplicateCandidate.palette.count])
        }
    }

    @ViewBuilder
    private var duplicateCandidatesView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Найдены похожие места поблизости:")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach(Array(candidatesWithColors.enumerated()), id: \.element.candidate.id) { index, item in
                let isSelected = selectedDuplicate?.id == item.candidate.id
                Button {
                    applyMerge(with: item.candidate)
                } label: {
                    HStack(spacing: 10) {
                        Image(uiImage: LocationPreviewMapView.Coordinator.renderPin(
                            color: item.color,
                            size: CGSize(width: 22, height: 24),
                            shadow: false
                        ))
                        .frame(width: 28, alignment: .center)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.candidate.displayName)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(String(format: "%.0f м", item.candidate.distance))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: isSelected ? "record.circle" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .font(.title3)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Merge diff section

    @ViewBuilder
    private var mergeDiffSection: some View {
        if let candidate = selectedDuplicate {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Обновление: \(candidate.displayName)")
                            .font(.subheadline.weight(.medium))
                        Text(String(format: "OSM ID: %lld · %.0f м",
                                    candidate.node.id, candidate.distance))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        let conflicts = diffEntries.filter { $0.kind == .conflict }
        let newTags   = diffEntries.filter { $0.kind == .newTag }
        let osmOnly   = diffEntries.filter { $0.kind == .osmOnly }

        if !conflicts.isEmpty {
            Section(header: Text("Конфликты")) {
                ForEach($diffEntries) { $entry in
                    if entry.kind == .conflict {
                        MergeTagRow(entry: $entry)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button {
                                    entry.resolution = .useOSM
                                } label: {
                                    Label("Оставить OSM", systemImage: "xmark.circle")
                                }
                                .tint(.orange)
                            }
                    }
                }
            }
        }
        if !newTags.isEmpty {
            Section(header: Text("Новые теги")) {
                ForEach($diffEntries) { $entry in
                    if entry.kind == .newTag {
                        MergeTagRow(entry: $entry)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button {
                                    entry.resolution = .keepOSM
                                } label: {
                                    Label("Не добавлять", systemImage: "xmark.circle")
                                }
                                .tint(.orange)
                            }
                    }
                }
            }
        }
        if !osmOnly.isEmpty {
            Section(header: Text("Теги OSM (сохраняются)")) {
                ForEach($diffEntries) { $entry in
                    if entry.kind == .osmOnly {
                        MergeTagRow(entry: $entry)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button {
                                    entry.resolution = .custom("")
                                    entry.customEditText = ""
                                } label: {
                                    Label("Очистить", systemImage: "xmark.circle")
                                }
                                .tint(.orange)
                            }
                    }
                }
            }
        }

        // Плейсхолдеры: основные теги, отсутствующие в обоих источниках
        let placeholderKeys = mergePlaceholderTags.keys.sorted { a, b in
            let order = ["name", "opening_hours", "phone", "website",
                         "addr:street", "addr:housenumber", "addr:city"]
            let ai = order.firstIndex(of: a) ?? 999
            let bi = order.firstIndex(of: b) ?? 999
            return ai == bi ? a < b : ai < bi
        }
        if !placeholderKeys.isEmpty {
            Section(header: Text("Дополнить")) {
                ForEach(placeholderKeys, id: \.self) { key in
                    OSMTagRow(
                        tagKey: key,
                        editableValue: Binding(
                            get: { mergePlaceholderTags[key] ?? "" },
                            set: { mergePlaceholderTags[key] = $0 }
                        ),
                        status: .manual
                    )
                    .listRowSeparator(.hidden)
                }
            }
        }
    }

    // MARK: - Type section

    /// Базовые ключи типа в порядке приоритета отображения.
    private let baseTypeKeys = ["amenity", "shop", "craft", "public_transport", "healthcare"]

    /// Снапшот текущих значений базовых ключей — используется в onChange для детектирования смены типа.
    private var activeTypeKeys: [String: String] {
        Dictionary(uniqueKeysWithValues: baseTypeKeys.compactMap { key in
            guard let val = poi.tags[key], !val.isEmpty else { return nil }
            return (key, val)
        })
    }

    /// Возвращает список заданных «типовых» ключей из текущих тегов.
    private var activeTypeEntries: [(key: String, value: String)] {
        baseTypeKeys.compactMap { key in
            guard let val = poi.tags[key], !val.isEmpty else { return nil }
            return (key: key, value: val)
        }
    }

    @ViewBuilder
    private var typeSection: some View {
        Section(header: Text("Тип")) {
            // Строки для каждого уже заданного базового ключа
            ForEach(activeTypeEntries, id: \.key) { entry in
                typeRow(key: entry.key, value: entry.value)
                    .swipeActions(edge: .trailing) {
                        Button {
                            poi.tags[entry.key] = ""
                            poi.fieldStatus[entry.key] = .manual
                        } label: {
                            Label("Сбросить", systemImage: "xmark.circle")
                        }
                        .tint(.orange)
                    }
            }

            // Плейсхолдер «Добавить тип» — всегда видим
            Button {
                showTypePicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tag")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .center)

                    Text(activeTypeEntries.isEmpty ? "Выбрать тип места" : "Добавить ещё тип")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Строка для уже выбранного базового ключа — позволяет менять значение через стандартный tagRow.
    @ViewBuilder
    private func typeRow(key: String, value: String) -> some View {
        let icon: String = {
            switch key {
            case "amenity":          return "fork.knife"
            case "shop":             return "cart"
            case "craft":            return "wrench.and.screwdriver"
            case "public_transport": return "bus"
            case "healthcare":       return "cross.case"
            default:                 return "tag"
            }
        }()
        tagRow(for: key, value: value, forceIcon: icon)
    }

    // MARK: - Apply type

    /// Применяет выбранный тип: ставит тег и добавляет пустые плейсхолдеры пресетов.
    private func applyPOIType(_ type: POIType) {
        // Устанавливаем базовый тег
        poi.tags[type.key] = type.value
        poi.fieldStatus[type.key] = .manual

        // Добавляем пустые плейсхолдеры для рекомендуемых ключей,
        // если они ещё не заданы
        for presetKey in type.presets {
            if poi.tags[presetKey] == nil {
                poi.tags[presetKey] = ""
            }
        }

        // Перезапускаем поиск дублей — тип изменился
        scheduleTypeBasedDuplicateSearch()
    }

    /// Перезапускает поиск дублей при смене базового ключа типа (только new mode, не merge).
    private func scheduleTypeBasedDuplicateSearch() {
        guard isNewMode, poi.osmNodeId == nil, !isMergeMode else { return }
        cancelMergeIfActive()
        duplicates = []
        Task { await runDuplicateSearch() }
    }

    // MARK: - Tag group sections (simplified mode, non-merge)

    // Приоритетные ключи для сортировки внутри группы
    private let priorityKeys = [
        "name", "amenity", "shop", "office", "tourism",
        "addr:street", "addr:housenumber", "addr:city", "addr:postcode",
        "phone", "contact:phone",
        "website", "contact:website",
        "email", "contact:email",
        "opening_hours"
    ]

    private let essentialPlaceholders: [OSMTagDefinition.TagGroup: [String]] = [
        .hours:    ["opening_hours"],
        .address:  ["addr:street", "addr:housenumber", "addr:city", "addr:postcode"],
        .contact:  ["phone", "website", "email"],
        .payment:  ["payment:cash", "payment:visa", "payment:mastercard",
                    "payment:mir", "payment:apple_pay", "payment:sbp"],
        .building: ["building"],
        .other:    ["wheelchair", "description"],
    ]

    private func isEssentialKey(_ key: String) -> Bool {
        essentialPlaceholders.values.contains { $0.contains(key) }
    }

    @ViewBuilder
    private var tagGroupSections: some View {
        let grouped = groupedEntries(from: poi.tags)

        ForEach(OSMTagDefinition.TagGroup.allCases, id: \.self) { group in
            let entries = grouped[group] ?? []
            let absentKeys = (essentialPlaceholders[group] ?? [])
                .filter { poi.tags[$0] == nil }

            if !entries.isEmpty || !absentKeys.isEmpty {
                if group == .name && !entries.isEmpty {
                    CollapsibleNameSection(
                        entries: entries,
                        isEditable: true,
                        tagRow: { key, value, isPrimary in
                            tagRow(for: key, value: value, isPrimary: isPrimary)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: key) }
                        }
                    )
                } else if group == .brand && !entries.isEmpty {
                    CollapsibleBrandSection(
                        entries: entries,
                        isEditable: true,
                        tagRow: { key, value in
                            tagRow(for: key, value: value)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: key) }
                        }
                    )
                } else if group == .legal && !entries.isEmpty {
                    CollapsibleLegalSection(
                        entries: entries,
                        isEditable: true,
                        tagRow: { key, value in
                            tagRow(for: key, value: value)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: key) }
                        }
                    )
                } else if group == .address {
                    Section(header: Text("Адрес")) {
                        ForEach(Array(entries.enumerated()), id: \.element.key) { idx, item in
                            tagRow(for: item.key, value: item.value,
                                   forceIcon: idx == 0 && absentKeys.isEmpty ? "house" : nil,
                                   hideIcon: idx > 0 || !absentKeys.isEmpty)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: item.key) }
                        }
                        ForEach(Array(absentKeys.enumerated()), id: \.element) { idx, key in
                            tagRow(for: key, value: "",
                                   forceIcon: idx == 0 && entries.isEmpty ? "house" : nil,
                                   hideIcon: !(idx == 0 && entries.isEmpty))
                        }
                    }
                } else if group == .hours {
                    Section(header: Text(group.rawValue)) {
                        ForEach(entries, id: \.key) { item in
                            tagRow(for: item.key, value: item.value)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: item.key) }
                        }
                        ForEach(absentKeys, id: \.self) { key in
                            tagRow(for: key, value: "")
                        }
                    }
                } else {
                    Section(header: Text(group.rawValue)) {
                        ForEach(entries, id: \.key) { item in
                            tagRow(for: item.key, value: item.value)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: item.key) }
                        }
                        ForEach(absentKeys, id: \.self) { key in
                            tagRow(for: key, value: "")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var addTagSection: some View {
        Section {
            AddTagRow { key, value in
                if editTab == .tags {
                    tagPairs.append(TagPair(key: key, value: value))
                    syncTagsFromPairs()
                } else {
                    poi.tags[key] = value
                    poi.fieldStatus[key] = .manual
                }
            }
        }
    }

    // MARK: - Tag row builder

    @ViewBuilder
    private func tagRow(for key: String, value: String,
                        forceIcon: String? = nil,
                        hideIcon: Bool = false,
                        isPrimary: Bool = false) -> some View {
        OSMTagRow(
            tagKey: key,
            editableValue: Binding(
                get: { poi.tags[key] ?? "" },
                set: { newVal in
                    // Всегда сохраняем строку (даже ""), не удаляем ключ —
                    // это стабилизирует идентичность строк в ForEach и
                    // предотвращает потерю фокуса клавиатуры.
                    // Пустые значения убираются в stripEmptyTags() перед сохранением.
                    poi.tags[key] = newVal
                    poi.fieldStatus[key] = .confirmed
                    if isMergeMode { syncMergedTags() }
                }
            ),
            status: poi.fieldStatus[key] ?? .manual,
            forceIcon: forceIcon,
            hideIcon: hideIcon,
            isPrimary: isPrimary
        )
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func swipeDeleteAction(forKey key: String) -> some View {
        Button {
            poi.tags[key] = ""
            poi.fieldStatus[key] = .manual
        } label: {
            Label("Очистить", systemImage: "xmark.circle")
        }
        .tint(.orange)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 16) {
                // В new-режиме — кнопка закрытия; в edit-режиме её заменяет
                // системная кнопка «Назад» NavigationStack.
                if isNewMode {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .fontWeight(.semibold)
                    }
                }
                Button { undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!canUndo || isUploading)
                Button { redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!canRedo || isUploading)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await uploadToOSM() }
            } label: {
                if isUploading {
                    ProgressView()
                } else {
                    Image(systemName: authService.isAuthenticated
                          ? "arrow.up.circle.fill"
                          : "arrow.up.circle")
                }
            }
            .disabled(isUploading || isSaving)
            .tint(.blue)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                saveLocally()
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .disabled(isSaving || isUploading)
        }
    }

    // MARK: - Actions: Save / Upload

    private func saveLocally() {
        if editTab == .tags { syncTagsFromPairs() }
        syncMergedTags()
        stripEmptyTags()
        applyCheckDate()
        persistCity()
        isSaving = true
        var saved = poi
        saved.status = .validated
        onSave?(saved)
        dismiss()
    }

    @MainActor
    private func uploadToOSM() async {
        if editTab == .tags { syncTagsFromPairs() }
        syncMergedTags()
        stripEmptyTags()
        applyCheckDate()
        persistCity()

        if !authService.isAuthenticated {
            guard let anchor = presentationAnchor() else {
                uploadError = "Не удалось найти окно приложения для авторизации"
                showUploadError = true
                return
            }
            do {
                try await authService.signIn(presentationAnchor: anchor)
            } catch {
                uploadError = error.localizedDescription
                showUploadError = true
                return
            }
        }

        isUploading = true
        var uploading = poi

        // Version check: если selectedNodeDetails загружен и содержит более свежую версию —
        // берём её. Актуально и для merge (poi.osmNodeId = id кандидата), и для edit.
        if let vm = editViewModel,
           let details = vm.selectedNodeDetails,
           details.id == uploading.osmNodeId,
           let current = uploading.osmVersion,
           details.version > current {
            uploading.osmVersion = details.version
            uploading.osmType = details.type
        }

        uploading.status = .uploading
        onSave?(uploading)

        do {
            let uploaded = try await OSMAPIService.shared.upload(poi: uploading)
            onSave?(uploaded)
            dismiss()
        } catch {
            uploadError = error.localizedDescription
            showUploadError = true
            var failed = poi
            failed.status = .failed
            onSave?(failed)
        }
        isUploading = false
    }

    private func presentationAnchor() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0.keyWindow ?? $0.windows.first }
            .first
    }

    // MARK: - Actions: check_date / city

    private func applyCheckDate() {
        if poi.fieldStatus["check_date"] == .confirmed { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let date: Date
        switch coordinateSource {
        case .photo: date = poi.photoDate ?? Date()
        default:     date = Date()
        }
        poi.tags["check_date"] = fmt.string(from: date)
        poi.fieldStatus["check_date"] = .confirmed
    }

    private func persistCity() {
        if let city = poi.tags["addr:city"], !city.isEmpty {
            AppSettings.shared.lastCity = city
        }
    }

    /// Убираем теги с пустым значением (оставленные после «Очистить»)
    /// перед отправкой/сохранением.
    private func stripEmptyTags() {
        let emptyKeys = poi.tags.filter { $0.value.isEmpty }.map(\.key)
        for key in emptyKeys {
            poi.tags.removeValue(forKey: key)
            poi.fieldStatus.removeValue(forKey: key)
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    // MARK: - Undo / Redo

    private func scheduleSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            guard poi.tags != undoStack.last else { return }
            undoStack.append(poi.tags)
            redoStack.removeAll()
        }
    }

    private func undo() {
        if isMergeMode {
            guard mergeUndoStack.count >= 2 else { return }
            let current = mergeUndoStack.removeLast()
            mergeRedoStack.append(current)
            let snap = mergeUndoStack.last!
            diffEntries = snap.diffEntries
            mergePlaceholderTags = snap.placeholders
            syncMergedTags()
        } else {
            guard undoStack.count >= 2 else { return }
            let current = undoStack.removeLast()
            redoStack.append(current)
            poi.tags = undoStack.last ?? [:]
        }
    }

    private func redo() {
        if isMergeMode {
            guard let snap = mergeRedoStack.popLast() else { return }
            mergeUndoStack.append(snap)
            diffEntries = snap.diffEntries
            mergePlaceholderTags = snap.placeholders
            syncMergedTags()
        } else {
            guard let next = redoStack.popLast() else { return }
            undoStack.append(next)
            poi.tags = next
        }
    }

    // MARK: - Tag pairs sync (Tags tab)

    private func syncTagsFromPairs() {
        var newTags: [String: String] = [:]
        for pair in tagPairs where !pair.key.isEmpty {
            newTags[pair.key] = pair.value
        }
        poi.tags = newTags
    }

    private func syncPairsFromTags() {
        tagPairs = poi.tags.keys.sorted()
            .map { TagPair(key: $0, value: poi.tags[$0] ?? "") }
    }

    private func deleteTagPair(at index: Int) {
        tagPairs.remove(at: index)
        syncTagsFromPairs()
    }

    // MARK: - Merge helpers

    private func runDuplicateSearch() async {
        isCheckingDuplicates = true
        do {
            duplicates = try await DuplicateChecker.shared
                .findDuplicates(near: poi, radiusMeters: searchRadiusMeters)
        } catch {}
        isCheckingDuplicates = false
    }

    private func applyMerge(with candidate: DuplicateCandidate) {
        selectedDuplicate = candidate
        // Фильтруем пустые значения — они были добавлены pre-populate'ом
        // и не являются реальными данными из фото/OCR.
        originalExtractedTags = poi.tags.filter { !$0.value.isEmpty }
        originalCoordinate    = poi.coordinate

        // Берём идентификаторы кандидата — нужны для upload
        poi.osmNodeId  = candidate.node.id
        poi.osmVersion = candidate.node.version
        poi.osmType    = candidate.node.type   // сохраняем реальный тип: node/way/relation
        poi.coordinate = POI.Coordinate(
            latitude: candidate.node.latitude,
            longitude: candidate.node.longitude
        )

        diffEntries = TagDiffEntry.build(
            osmTags: candidate.node.tags,
            extractedTags: originalExtractedTags
        )

        // Плейсхолдеры: важные теги, отсутствующие в обоих источниках
        let coveredKeys = Set(diffEntries.map(\.key))
        let aliasExpanded: Set<String> = Set(coveredKeys.flatMap { k -> [String] in
            var a = [k]
            if k.hasPrefix("contact:") { a.append(String(k.dropFirst(8))) }
            else { a.append("contact:" + k) }
            return a
        })
        let essentialKeys = ["name", "opening_hours", "phone", "website",
                             "addr:street", "addr:housenumber", "addr:city"]
        mergePlaceholderTags = [:]
        for key in essentialKeys where !aliasExpanded.contains(key) {
            mergePlaceholderTags[key] = ""
        }

        syncMergedTags()
        // Инициализируем merge undo-стек начальным состоянием
        mergeUndoStack = [MergeSnapshot(diffEntries: diffEntries, placeholders: mergePlaceholderTags)]
        mergeRedoStack = []
        withAnimation { isMergeMode = true }
    }

    private func cancelMerge() {
        withAnimation {
            isMergeMode = false
            selectedDuplicate = nil
            // Восстанавливаем теги из снимка (без пустышек),
            // затем доливаем плейсхолдеры чтобы поля остались видны.
            var restored = originalExtractedTags
            for keys in essentialPlaceholders.values {
                for key in keys where restored[key] == nil {
                    restored[key] = ""
                }
            }
            poi.tags = restored
            if let orig = originalCoordinate { poi.coordinate = orig }
        }
        mergeUndoStack = []
        mergeRedoStack = []
    }

    private func cancelMergeIfActive() {
        if isMergeMode { cancelMerge() }
        selectedDuplicate = nil
        diffEntries = []
        mergePlaceholderTags = [:]
    }

    private func syncMergedTags() {
        guard isMergeMode else { return }
        var merged: [String: String] = [:]
        for entry in diffEntries {
            if let val = entry.resolvedValue { merged[entry.key] = val }
        }
        for (key, value) in mergePlaceholderTags where !value.isEmpty {
            merged[key] = value
        }
        poi.tags = merged
    }

    // MARK: - Accuracy / source label helpers

    private var accuracyForSearch: Double? {
        switch coordinateSource {
        case .photo: return poi.photoAccuracy
        case .gps:   return poi.gpsAccuracy
        default:     return nil
        }
    }

    private var searchRadiusMeters: Double {
        guard let acc = accuracyForSearch, acc > 0 else { return 50 }
        return max(50, min(1000, ceil(acc * 1.5 / 50) * 50))
    }

    private var displayAccuracyMeters: Int? {
        guard let acc = accuracyForSearch, acc > 0 else { return nil }
        return Int(ceil(acc / 50) * 50)
    }

    private var sourceLabel: String {
        let base = coordinateSource.label
        guard let meters = displayAccuracyMeters else { return base }
        return "\(base), погрешность ~\(meters)м"
    }

    // MARK: - Tag grouping

    private func groupedEntries(from tags: [String: String])
        -> [OSMTagDefinition.TagGroup: [(key: String, value: String)]] {
        var result: [OSMTagDefinition.TagGroup: [(key: String, value: String)]] = [:]
        for key in tags.keys.sorted(by: groupSortKey) {
            guard let value = tags[key] else { continue }
            if key == "type" && value == "multipolygon" { continue }
            // Базовые ключи типа рендерятся в typeSection — пропускаем здесь
            if baseTypeKeys.contains(key) { continue }
            result[resolvedGroup(for: key), default: []].append((key: key, value: value))
        }
        return result
    }

    private func groupSortKey(_ a: String, _ b: String) -> Bool {
        let groupOrder = OSMTagDefinition.TagGroup.allCases
        let ga = resolvedGroup(for: a)
        let gb = resolvedGroup(for: b)
        let gi = groupOrder.firstIndex(of: ga) ?? 999
        let gj = groupOrder.firstIndex(of: gb) ?? 999
        if gi != gj { return gi < gj }
        let ai = priorityKeys.firstIndex(of: a) ?? 999
        let bi = priorityKeys.firstIndex(of: b) ?? 999
        return ai == bi ? a < b : ai < bi
    }

    private func resolvedGroup(for key: String) -> OSMTagDefinition.TagGroup {
        if OSMTags.isNameKey(key)     { return .name }
        if OSMTags.isBrandKey(key)    { return .brand }
        if OSMTags.isLegalKey(key)    { return .legal }
        if OSMTags.isPaymentKey(key)  { return .payment }
        if OSMTags.isContactKey(key)  { return .contact }
        if OSMTags.isAddressKey(key)  { return .address }
        if OSMTags.isBuildingKey(key) { return .building }
        return OSMTags.definition(for: key)?.group ?? .other
    }

    private func dmsString(lat: Double, lon: Double) -> String {
        String(format: "%.4f°,  %.4f°", lat, lon)
    }
}

// MARK: - EditTab

private enum EditTab: String, CaseIterable {
    case simplified = "Форма"
    case tags       = "Теги"
}

// MARK: - MergeTagRow

struct MergeTagRow: View {
    @Binding var entry: TagDiffEntry

    var body: some View {
        switch entry.kind {
        case .conflict: conflictView
        case .newTag:   newTagView
        case .osmOnly:  osmOnlyView
        case .same:     EmptyView()
        }
    }

    // MARK: Конфликт — чекбоксы (можно выбрать оба → запись через «;»)

    private var conflictView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(OSMTags.definition(for: entry.key)?.label ?? entry.key)
                .font(.caption)
                .foregroundStyle(.secondary)

            let osmChecked = entry.resolution == .useOSM || entry.resolution == .both
            let extChecked = entry.resolution == .useExtracted || entry.resolution == .both

            checkboxOption(label: entry.osmValue ?? "—", badge: "OSM",
                           badgeColor: .secondary, isChecked: osmChecked) { toggleOSM() }
            checkboxOption(label: entry.extractedValue ?? "—", badge: "Новое",
                           badgeColor: .blue, isChecked: extChecked) { toggleExtracted() }
        }
        .padding(.vertical, 4)
    }

    private func toggleOSM() {
        switch entry.resolution {
        case .useOSM:       entry.resolution = .useExtracted
        case .useExtracted: entry.resolution = .both
        case .both:         entry.resolution = .useExtracted
        default:            entry.resolution = .useOSM
        }
    }

    private func toggleExtracted() {
        switch entry.resolution {
        case .useExtracted: entry.resolution = .useOSM
        case .useOSM:       entry.resolution = .both
        case .both:         entry.resolution = .useOSM
        default:            entry.resolution = .useExtracted
        }
    }

    @ViewBuilder
    private func checkboxOption(label: String, badge: String, badgeColor: Color,
                                isChecked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                    .font(.title3)
                Text(label)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer()
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(badgeColor)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Новый тег — радио + OSMTagRow

    private var newTagView: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if entry.resolution == .keepOSM {
                        entry.resolution = entry.customEditText == (entry.extractedValue ?? "")
                            ? .useExtracted : .custom(entry.customEditText)
                    } else {
                        entry.resolution = .keepOSM
                    }
                }
            } label: {
                Image(systemName: entry.resolution == .keepOSM ? "circle" : "record.circle")
                    .foregroundStyle(entry.resolution == .keepOSM ? Color.secondary : Color.accentColor)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            OSMTagRow(
                tagKey: entry.key,
                editableValue: Binding(
                    get: { entry.customEditText },
                    set: { newVal in
                        entry.customEditText = newVal
                        entry.resolution = newVal.isEmpty ? .keepOSM
                            : (newVal == (entry.extractedValue ?? "") ? .useExtracted : .custom(newVal))
                    }
                ),
                status: .extracted,
                hideIcon: true
            )
            .opacity(entry.resolution == .keepOSM ? 0.4 : 1)
            .allowsHitTesting(entry.resolution != .keepOSM)
        }
    }

    // MARK: Тег только в OSM — редактируемый

    private var osmOnlyView: some View {
        OSMTagRow(
            tagKey: entry.key,
            editableValue: Binding(
                get: { entry.customEditText },
                set: { newVal in
                    entry.customEditText = newVal
                    entry.resolution = newVal == (entry.osmValue ?? "") ? .keepOSM : .custom(newVal)
                }
            ),
            status: .confirmed
        )
    }
}

// MARK: - AddTagRow

struct AddTagRow: View {
    let onAdd: (String, String) -> Void

    @State private var key = ""
    @State private var value = ""
    @FocusState private var focusedField: Field?

    enum Field { case key, value }

    var body: some View {
        HStack {
            TextField("ключ", text: $key)
                .focused($focusedField, equals: .key)
                .font(.body.monospaced())
                .frame(maxWidth: 120)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()

            Text("=")
                .foregroundStyle(.secondary)

            TextField("значение", text: $value)
                .focused($focusedField, equals: .value)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()

            Button {
                guard !key.isEmpty, !value.isEmpty else { return }
                onAdd(key, value)
                key = ""; value = ""
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
            }
            .disabled(key.isEmpty || value.isEmpty)
        }
    }
}

// MARK: - ImagePreviewView

struct ImagePreviewView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .ignoresSafeArea(edges: .bottom)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - FieldStatus extensions

extension FieldStatus: CaseIterable {
    public static var allCases: [FieldStatus] = [.extracted, .suggested, .confirmed, .manual]

    var label: String {
        switch self {
        case .extracted: "OCR"
        case .suggested: "Предложено"
        case .confirmed: "Проверено"
        case .manual:    "Вручную"
        }
    }

    var color: Color {
        switch self {
        case .extracted: .yellow
        case .suggested: .blue
        case .confirmed: .green
        case .manual:    .gray
        }
    }
}
