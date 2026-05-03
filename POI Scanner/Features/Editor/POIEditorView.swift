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

    /// Сырой OCR-текст с фото (только режим new, опционально)
    var rawOCRText: String? = nil
    /// Строки из QR-кодов (только режим new)
    var qrPayloads: [String] = []
    /// Результаты веб-парсинга ссылок (только режим new)
    var webResults: [WebFetchResult] = []

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss
    private let authService = OSMAuthService.shared

    // MARK: - Editor state

    @State private var editTab: EditTab = .simplified
    @State private var tagPairs: [TagPair] = []

    // MARK: - Coordinate

    @State private var coordinateSource: CoordinateSource
    @State private var showCoordinatePicker = false
    /// Показывать блок фоллбэков координат. Включается при плохом GPS и остаётся видимым
    /// до закрытия экрана — чтобы пользователь мог переключаться между вариантами.
    @State private var showFallbacks = false
    /// Исходная «плохая» координата из GPS/фото — первый вариант в списке фоллбэков.
    @State private var originalBadCoordinate: POI.Coordinate? = nil

    // MARK: - Upload / Save

    @State private var isUploading = false
    @State private var isSaving = false
    @State private var uploadError: String? = nil
    @State private var showUploadError = false

    // MARK: - Undo / Redo

    @State private var undoStack: [[String: String]] = []
    @State private var redoStack: [[String: String]] = []
    @State private var snapshotTask: Task<Void, Never>? = nil

    // Координатный стек — отдельно от тегов, синхронно с undoStack по индексу
    @State private var coordUndoStack: [POI.Coordinate] = []
    @State private var coordRedoStack: [POI.Coordinate] = []

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

    // MARK: - New edit ViewModel (Фаза 3)
    // Параллельно со старым merge-режимом. Активируется когда есть кандидаты из внешних источников.
    @State private var editVM: POIEditViewModel? = nil

    /// True когда editVM активен и имеет хотя бы одного кандидата.
    private var useEditVM: Bool { editVM?.tagGroups.values.contains { $0.needsReview } ?? false }

    // MARK: - Type picker

    @State private var showTypePicker = false
    @State private var pendingConflictType: POIType? = nil
    /// Пресеты, добавленные автоматически при выборе типа: [baseKey: Set<presetKey>].
    /// Используются для очистки пустых плейсхолдеров при смене типа.
    @State private var appliedPresets: [String: Set<String>] = [:]

    // MARK: - Image preview

    @State private var showImagePreview = false
    @State private var showRawText = false
    @State private var showAddPhoto = false

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

    init(poi: POI, mode: EditorMode, rawOCRText: String? = nil, qrPayloads: [String] = [],
         webResults: [WebFetchResult] = [], onSave: ((POI) -> Void)? = nil) {
        let p = poi
        _poi = State(initialValue: p)
        self.mode = mode
        self.rawOCRText = rawOCRText
        self.qrPayloads = qrPayloads
        self.webResults = webResults
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
            .fullScreenCover(isPresented: $showImagePreview) {
                if let img = sourceImage { ImagePreviewView(image: img) }
            }
            .sheet(isPresented: $showRawText) {
                RawTextView(ocrText: rawOCRText, qrPayloads: qrPayloads, webResults: webResults)
            }
            .sheet(isPresented: $showAddPhoto) {
                if let vm = editVM {
                    AddPhotoFlow(
                        existingPOI: poi,
                        editVM: vm,
                        onTagsExtracted: { tags, confidence in
                            // Обновляем poi.tags для совместимости со старым undo-стеком
                            for (key, value) in tags where poi.tags[key] == nil {
                                poi.tags[key] = value
                            }
                            scheduleSnapshot()
                        }
                    )
                } else {
                    // editVM ещё не создан — создаём сейчас
                    let vm = POIEditViewModel(poi: poi)
                    AddPhotoFlow(
                        existingPOI: poi,
                        editVM: vm,
                        onTagsExtracted: { tags, confidence in
                            editVM = vm
                            for (key, value) in tags where poi.tags[key] == nil {
                                poi.tags[key] = value
                            }
                            scheduleSnapshot()
                        }
                    )
                }
            }
            .sheet(isPresented: $showCoordinatePicker) { coordinatePickerSheet }
            .sheet(isPresented: $showTypePicker) {
                NavigationStack {
                    POITypePickerView { selectedType in
                        applyPOIType(selectedType)
                    }
                }
            }
            .alert("Конфликт типов", isPresented: Binding(
                get: { pendingConflictType != nil },
                set: { if !$0 { pendingConflictType = nil } }
            )) {
                Button("Заменить") {
                    if let t = pendingConflictType { applyPOIType(t, force: true) }
                    pendingConflictType = nil
                }
                Button("Отмена", role: .cancel) { pendingConflictType = nil }
            } message: {
                if let t = pendingConflictType,
                   let existing = poi.tags[t.key], !existing.isEmpty {
                    Text("\(t.key)=\(existing) будет заменено на \(t.key)=\(t.value). Для двух разных типов создайте отдельные точки.")
                }
            }
            .task { await onAppearTask() }
            .onChange(of: poi.coordinate) { _, _ in onCoordinateChange() }
            .onChange(of: activeTypeKeys) { old, new in
                updatePresetsOnTypeChange(old: old, new: new)
                scheduleTypeBasedDuplicateSearch()
            }
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
                // Ручная расстановка всегда считается точной — сохраняем как прошлую точку
                LastPOILocationStore.save(newCoord)
                showCoordinatePicker = false
            },
            onCancel: { showCoordinatePicker = false },
            onSelectNode: { node in
                showCoordinatePicker = false
                // Даём время на dismiss sheet перед открытием merge UI
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    let candidate = DuplicateCandidate(node: node, distance: 0)
                    applyMerge(with: candidate)
                }
            }
        )
    }

    // MARK: - Coordinate fallback rows

    /// Применяет выбранные резервные координаты, пишет в undo-стек и перезапускает поиск дублей.
    private func applyFallbackCoordinate(_ coord: CLLocationCoordinate2D) {
        guard poi.coordinate.latitude != coord.latitude
           || poi.coordinate.longitude != coord.longitude else { return }
        pushCoordinateSnapshot()
        poi.coordinate = POI.Coordinate(coord)
        coordinateSource = .manual
        onCoordinateChange()
    }

    @ViewBuilder
    private var coordinateFallbackRows: some View {
        let mapCenter = MapPreferences.center
        let lastPOI   = LastPOILocationStore.last
        let currentCoord = poi.coordinate

        // «Исходная (GPS/фото)» — всегда первый вариант, если есть
        if let orig = originalBadCoordinate {
            coordinateFallbackRow(
                icon: "location.slash",
                title: coordinateSource.label,
                subtitle: dmsString(lat: orig.latitude, lon: orig.longitude),
                isSelected: currentCoord.latitude == orig.latitude
                    && currentCoord.longitude == orig.longitude,
                action: { applyFallbackCoordinate(CLLocationCoordinate2D(latitude: orig.latitude, longitude: orig.longitude)) }
            )
        }

        // «Центр карты»
        coordinateFallbackRow(
            icon: "map",
            title: "Центр карты",
            subtitle: dmsString(lat: mapCenter.latitude, lon: mapCenter.longitude),
            isSelected: currentCoord.latitude == mapCenter.latitude
                && currentCoord.longitude == mapCenter.longitude,
            action: { applyFallbackCoordinate(mapCenter) }
        )

        // «Прошлая точка» — только если есть сохранённая
        if let last = lastPOI {
            coordinateFallbackRow(
                icon: "bookmark",
                title: "Прошлая точка",
                subtitle: dmsString(lat: last.coordinate.latitude, lon: last.coordinate.longitude),
                badge: relativeTime(from: last.date),
                isSelected: currentCoord.latitude == last.coordinate.latitude
                    && currentCoord.longitude == last.coordinate.longitude,
                action: { applyFallbackCoordinate(last.coordinate) }
            )
        }
    }

    @ViewBuilder
    private func coordinateFallbackRow(
        icon: String,
        title: String,
        subtitle: String,
        badge: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 24, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        if let badge {
                            Text(badge)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
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
        coordUndoStack = [poi.coordinate]

        // Инициализируем editVM если есть внешние данные (OCR / QR / веб)
        let hasExternalData = !webResults.isEmpty
            || (rawOCRText != nil && !poi.tags.isEmpty)
            || !qrPayloads.isEmpty
        if hasExternalData {
            let vm = POIEditViewModel(poi: poi)
            vm.applyWebResults(webResults)
            // OCR-теги уже применены в poi.tags через TextParser до открытия редактора —
            // они будут загружены как .osm baseline; отдельно добавлять не нужно.
            editVM = vm
        }

        guard isNewMode, poi.osmNodeId == nil else { return }
        // Показываем фоллбэки сразу если точность плохая
        if hasCoordinateFallbacks {
            showFallbacks = true
            originalBadCoordinate = poi.coordinate
        }
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
            if useEditVM, let vm = editVM {
                tagGroupSectionsVM(vm: vm)
            } else {
                tagGroupSections
            }
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

            // Фоллбэки координат (при плохом GPS > 50 м) — остаются видимыми после выбора
            if showFallbacks {
                coordinateFallbackRows
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
        let osmOnly   = diffEntries.filter { $0.kind == .osmOnly || $0.kind == .same }

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
                    if entry.kind == .osmOnly || entry.kind == .same {
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
    private let baseTypeKeys = ["amenity", "shop", "craft", "public_transport", "healthcare", "tourism", "entrance", "office"]

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
        Section(header: Text("Основные")) {
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

            // Preset-ключи активного типа в порядке пресета, не принадлежащие именованным группам —
            // отображаются прямо в секции «Основные».
            let namedGroupKeys = namedGroupPresetKeys()
            let primaryExtras: [(key: String, value: String)] = activePresetsOrdered()
                .filter { !baseTypeKeys.contains($0) && !namedGroupKeys.contains($0) }
                .compactMap { key in
                    guard let val = poi.tags[key] else { return nil }
                    return (key: key, value: val)
                }
            ForEach(primaryExtras, id: \.key) { item in
                tagRow(for: item.key, value: item.value)
                    .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: item.key) }
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
            case "entrance":         return "door.left.hand.open"
            case "office":           return "briefcase"
            default:                 return "tag"
            }
        }()
        tagRow(for: key, value: value, forceIcon: icon)
    }

    // MARK: - Apply type

    /// Применяет выбранный тип: ставит тег.
    /// Если ключ уже занят другим значением и `force == false` — показывает алерт.
    /// Управление пресетами (добавление/удаление плейсхолдеров) происходит в onChange(of: activeTypeKeys).
    private func applyPOIType(_ type: POIType, force: Bool = false) {
        // Если ключ уже занят другим непустым значением — предупреждаем
        if !force,
           let existing = poi.tags[type.key],
           !existing.isEmpty,
           existing != type.value {
            pendingConflictType = type
            return
        }

        // Устанавливаем базовый тег — onChange(of: activeTypeKeys) подхватит смену и обновит пресеты
        poi.tags[type.key] = type.value
        poi.fieldStatus[type.key] = .manual
    }

    /// Перезапускает поиск дублей при смене базового ключа типа (только new mode, не merge).
    private func scheduleTypeBasedDuplicateSearch() {
        guard isNewMode, poi.osmNodeId == nil, !isMergeMode else { return }
        cancelMergeIfActive()
        duplicates = []
        Task { await runDuplicateSearch() }
    }

    /// true если POI создаётся вручную и не несёт достаточно данных для поиска дублей.
    /// Нет смысла делать Overpass-запрос пока не выбран тип или не введено название.
    private var isManualNewWithoutContext: Bool {
        guard isNewMode, poi.osmNodeId == nil else { return false }
        // Если POI создан из фото — данные уже извлечены, поиск имеет смысл
        guard poi.coordinateSource != .photo else { return false }
        let hasType = activeTypeEntries.contains { !$0.value.isEmpty }
        let hasName = !(poi.tags["name"] ?? "").isEmpty
        return !hasType && !hasName
    }

    /// Вызывается из onChange(of: activeTypeKeys).
    /// Для каждого базового ключа, у которого сменилось значение:
    ///   - удаляет пустые плейсхолдеры старого типа (не вошедшие в новый),
    ///   - добавляет пустые плейсхолдеры нового типа (если ключ ещё не заполнен).
    private func updatePresetsOnTypeChange(old: [String: String], new: [String: String]) {
        let registry = POITypeRegistry.shared
        let changedKeys = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }

        for baseKey in changedKeys {
            let oldVal = old[baseKey] ?? ""
            let newVal = new[baseKey] ?? ""

            let oldPresets: Set<String> = registry.find(key: baseKey, value: oldVal)
                .map { Set($0.presets) } ?? appliedPresets[baseKey] ?? []
            let newPresets: Set<String>  = registry.find(key: baseKey, value: newVal)
                .map { Set($0.presets) } ?? []

            // Удаляем пустые плейсхолдеры старого типа, которых нет в новом
            for staleKey in oldPresets.subtracting(newPresets) {
                if poi.tags[staleKey] == "" {
                    poi.tags.removeValue(forKey: staleKey)
                    poi.fieldStatus.removeValue(forKey: staleKey)
                }
            }

            // Добавляем пустые плейсхолдеры нового типа (не перезаписываем заполненные)
            for presetKey in newPresets {
                if (poi.tags[presetKey] ?? "") == "" {
                    poi.tags[presetKey] = ""
                }
            }

            // Обновляем кеш
            if newVal.isEmpty {
                appliedPresets.removeValue(forKey: baseKey)
            } else {
                appliedPresets[baseKey] = newPresets
            }
        }

        // Плейсхолдер «Название»: появляется как только выбран хоть один тип,
        // исчезает (если пустой) когда все типы сброшены.
        let hasAnyType = new.values.contains { !$0.isEmpty }
        if hasAnyType {
            // Добавляем пустой плейсхолдер только если name ещё не существует вообще
            if poi.tags["name"] == nil {
                poi.tags["name"] = ""
            }
        } else {
            // Все типы сброшены — убираем пустой плейсхолдер (заполненное имя не трогаем)
            if poi.tags["name"] == "" {
                poi.tags.removeValue(forKey: "name")
                poi.fieldStatus.removeValue(forKey: "name")
            }
        }
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

    /// Ключи-псевдонимы: если один из alias заполнен — основной placeholder не нужен.
    /// Например, если есть contact:phone — не показываем пустой phone, и наоборот.
    private let contactAliases: [String: [String]] = [
        "phone":   ["contact:phone"],
        "website": ["contact:website"],
        "email":   ["contact:email"],
        "contact:phone":   ["phone"],
        "contact:website": ["website"],
        "contact:email":   ["email"],
    ]

    /// Возвращает true если для данного ключа уже заполнен один из его псевдонимов.
    private func hasFilledAlias(for key: String) -> Bool {
        guard let aliases = contactAliases[key] else { return false }
        return aliases.contains { !(poi.tags[$0] ?? "").isEmpty }
    }

    private let essentialPlaceholders: [OSMTagDefinition.TagGroup: [String]] = [
        // Порядок ключей в массиве = порядок отображения placeholder-строк в секции
        .address:  ["addr:postcode", "addr:city", "addr:street", "addr:housenumber"],
        .entrance: ["access", "addr:flats", "entrance", "ref"],
        .contact:  ["phone", "website", "email"],
        .payment:  ["payment:cash", "payment:visa", "payment:mastercard",
                    "payment:mir", "payment:apple_pay", "payment:sbp"],
        .fuel:     ["fuel:diesel", "fuel:octane_95", "fuel:octane_92", "fuel:lpg", "fuel:cng"],
        .diet:     ["diet:vegan", "diet:vegetarian", "diet:halal"],
        .recycling: ["recycling:paper", "recycling:glass_bottles", "recycling:plastic"],
        .building: ["building"],
        .other:    ["wheelchair", "description"],
    ]

    private func isEssentialKey(_ key: String) -> Bool {
        essentialPlaceholders.values.contains { $0.contains(key) }
    }

    /// Preset-ключи активных базовых типов в том порядке, в котором они записаны в пресете.
    /// Дубликаты (при нескольких активных типах) пропускаются.
    private func activePresetsOrdered() -> [String] {
        let registry = POITypeRegistry.shared
        var seen = Set<String>()
        var result: [String] = []
        for entry in activeTypeEntries {
            for key in registry.find(key: entry.key, value: entry.value)?.presets ?? [] {
                if seen.insert(key).inserted { result.append(key) }
            }
        }
        return result
    }

    /// Объединение всех preset-ключей (неупорядоченное — для быстрых проверок).
    private func activePresetKeys() -> Set<String> {
        Set(activePresetsOrdered())
    }

    /// Ключи, принадлежащие именованным группам (addr:*, phone, website…) + "addr" как псевдоним.
    /// Используется чтобы не показывать их как отдельные строки в секции «Основные».
    private func namedGroupPresetKeys() -> Set<String> {
        // Все псевдонимы multiCombo-групп из реестра (например "payment:", "fuel:", …)
        // плюс "addr" — специальный псевдоним группы адреса в id-tagging-schema.
        POIFieldRegistry.shared.groupAliasKeys.union(
            Set(essentialPlaceholders.values.joined()).union(["addr"])
        )
    }

    /// Группа должна отображаться если:
    ///  • хотя бы один её ключ (или "addr" для .address) есть в preset-ключах активного типа, ИЛИ
    ///  • пользователь уже заполнил хотя бы один ключ этой группы.
    private func groupIsTriggered(_ group: OSMTagDefinition.TagGroup) -> Bool {
        let keys = essentialPlaceholders[group] ?? []
        if keys.isEmpty { return true } // name, brand, legal — всегда видны когда есть данные
        let presets = activePresetKeys()
        if group == .address && presets.contains("addr")      { return true }
        if group == .fuel    && presets.contains("fuel:")      { return true }
        if group == .diet      && presets.contains("diet:")    { return true }
        if group == .recycling && presets.contains("recycling:") { return true }
        return keys.contains { presets.contains($0) || !(poi.tags[$0] ?? "").isEmpty }
            || (group == .fuel      && poi.tags.contains { $0.key.hasPrefix("fuel:")      && !$0.value.isEmpty })
            || (group == .diet      && poi.tags.contains { $0.key.hasPrefix("diet:")      && !$0.value.isEmpty })
            || (group == .recycling && poi.tags.contains { $0.key.hasPrefix("recycling:") && !$0.value.isEmpty })
    }

    /// Группы в порядке появления их ключей в пресетах.
    /// "addr" отображается на .address. Группы без preset-ключей идут в конце (в порядке allCases).
    private func presetOrderedGroups() -> [OSMTagDefinition.TagGroup] {
        let ordered = activePresetsOrdered()
        var seen = Set<OSMTagDefinition.TagGroup>()
        var result: [OSMTagDefinition.TagGroup] = []

        for key in ordered {
            // "addr" — псевдоним для всей группы адреса
            if key == "addr" {
                if seen.insert(.address).inserted { result.append(.address) }
                continue
            }
            // "fuel:" — псевдоним для группы видов топлива
            if key == "fuel:" {
                if seen.insert(.fuel).inserted { result.append(.fuel) }
                continue
            }
            // Псевдонимы остальных multiCombo-групп
            if key == "diet:"            { if seen.insert(.diet).inserted           { result.append(.diet) };           continue }
            if key == "recycling:"       { if seen.insert(.recycling).inserted      { result.append(.recycling) };      continue }
            if key == "currency:"        { if seen.insert(.currency).inserted       { result.append(.currency) };       continue }
            if key == "service:bicycle:" { if seen.insert(.serviceBicycle).inserted { result.append(.serviceBicycle) }; continue }
            if key == "service:vehicle:" { if seen.insert(.serviceVehicle).inserted { result.append(.serviceVehicle) }; continue }
            for (group, keys) in essentialPlaceholders where keys.contains(key) {
                if seen.insert(group).inserted { result.append(group) }
            }
        }

        // Группы без essentialPlaceholders (name, brand, legal, other без пресетов)
        // добавляем в конце в порядке allCases
        for group in OSMTagDefinition.TagGroup.allCases {
            if seen.insert(group).inserted { result.append(group) }
        }

        return result
    }

    @ViewBuilder
    private var tagGroupSections: some View {
        let namedGroupKeys = namedGroupPresetKeys()
        // Ключи, которые рендерятся в typeSection.primaryExtras — исключаем из groupedEntries.
        let primaryExtraKeys: Set<String> = Set(
            activePresetsOrdered().filter { !baseTypeKeys.contains($0) && !namedGroupKeys.contains($0) }
        )
        let grouped = groupedEntries(from: poi.tags, excluding: primaryExtraKeys)
        // Без выбранного типа показываем только реально заполненные теги.
        let hasType = !activeTypeEntries.isEmpty

        ForEach(presetOrderedGroups(), id: \.self) { group in
            let rawEntries = grouped[group] ?? []
            let triggered = groupIsTriggered(group)
            // Плейсхолдеры (пустые строки) показываем только при выбранном типе И триггере группы
            let showPlaceholders = hasType && triggered
            let entries = showPlaceholders ? rawEntries : rawEntries.filter { !$0.value.isEmpty }
            let absentKeys = showPlaceholders
                ? (essentialPlaceholders[group] ?? []).filter {
                    poi.tags[$0] == nil && !hasFilledAlias(for: $0)
                  }
                : []

            // Скрываем записи с пустым значением, у которых заполнен псевдоним
            // (например пустой "phone" когда есть "contact:phone")
            let visibleEntries = entries.filter { item in
                item.value.isEmpty ? !hasFilledAlias(for: item.key) : true
            }

            if !visibleEntries.isEmpty || !absentKeys.isEmpty {
                if group == .name && !visibleEntries.isEmpty {
                    CollapsibleNameSection(
                        entries: visibleEntries,
                        isEditable: true,
                        tagRow: { key, value, isPrimary in
                            tagRow(for: key, value: value, isPrimary: isPrimary)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: key) }
                        }
                    )
                } else if group == .brand && !visibleEntries.isEmpty {
                    CollapsibleBrandSection(
                        entries: visibleEntries,
                        isEditable: true,
                        tagRow: { key, value in
                            tagRow(for: key, value: value)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: key) }
                        }
                    )
                } else if group == .legal && !visibleEntries.isEmpty {
                    CollapsibleLegalSection(
                        entries: visibleEntries,
                        isEditable: true,
                        tagRow: { key, value in
                            tagRow(for: key, value: value)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: key) }
                        }
                    )
                } else if group == .address {
                    Section(header: Text("Адрес")) {
                        // Фиксированный порядок: Индекс, Город, Улица, Дом
                        let orderedKeys = ["addr:postcode", "addr:city", "addr:street", "addr:housenumber"]
                        ForEach(Array(orderedKeys.enumerated()), id: \.element) { idx, key in
                            let val = poi.tags[key] ?? ""
                            // Без типа или нетриггерной группы — пропускаем пустые строки
                            if showPlaceholders || !val.isEmpty {
                                tagRow(for: key, value: val,
                                       forceIcon: idx == 0 ? "house" : nil,
                                       hideIcon: idx > 0)
                                    .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: key) }
                            }
                        }
                        // Этаж — только когда номер дома заполнен
                        let houseNumber = poi.tags["addr:housenumber"] ?? ""
                        if !houseNumber.isEmpty {
                            tagRow(for: "addr:floor", value: poi.tags["addr:floor"] ?? "", hideIcon: true)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: "addr:floor") }
                        }
                        // Остальные addr-ключи, уже заполненные пользователем (addr:unit, addr:suburb и т.д.)
                        let knownKeys = Set(["addr:postcode","addr:city","addr:street","addr:housenumber","addr:floor"])
                        ForEach(visibleEntries.filter { !knownKeys.contains($0.key) }, id: \.key) { item in
                            tagRow(for: item.key, value: item.value, hideIcon: true)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: item.key) }
                        }
                    }
                } else if group == .fuel {
                    // Фильтруем псевдоним fuel: (нет реального значения в OSM), иконка только у первой строки
                    let fuelEntries = visibleEntries.filter { !$0.key.hasSuffix(":") }
                    let fuelAbsent  = absentKeys.filter { !$0.hasSuffix(":") }
                    Section(header: Text(group.rawValue)) {
                        ForEach(Array(fuelEntries.enumerated()), id: \.element.key) { idx, item in
                            tagRow(for: item.key, value: item.value,
                                   hideIcon: idx > 0)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: item.key) }
                        }
                        ForEach(Array(fuelAbsent.enumerated()), id: \.element) { idx, key in
                            let isFirst = fuelEntries.isEmpty && idx == 0
                            tagRow(for: key, value: "", hideIcon: !isFirst)
                        }
                    }
                } else if [OSMTagDefinition.TagGroup.diet, .recycling, .currency, .serviceBicycle, .serviceVehicle].contains(group) {
                    // Все multiCombo-группы: фильтруем псевдо-ключ с двоеточием, иконка только у первой строки
                    let realEntries = visibleEntries.filter { !$0.key.hasSuffix(":") }
                    let realAbsent  = absentKeys.filter { !$0.hasSuffix(":") }
                    Section(header: Text(group.rawValue)) {
                        ForEach(Array(realEntries.enumerated()), id: \.element.key) { idx, item in
                            tagRow(for: item.key, value: item.value, hideIcon: idx > 0)
                                .swipeActions(edge: .trailing) { swipeDeleteAction(forKey: item.key) }
                        }
                        ForEach(Array(realAbsent.enumerated()), id: \.element) { idx, key in
                            let isFirst = realEntries.isEmpty && idx == 0
                            tagRow(for: key, value: "", hideIcon: !isFirst)
                        }
                    }
                } else {
                    Section(header: Text(group.rawValue)) {
                        ForEach(visibleEntries, id: \.key) { item in
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

    // MARK: - New VM-based tag group sections (Фаза 3)
    // Рендерит теги через TagKeySection — показывает все значения плоским списком,
    // включая кандидатов с цветом confidence и иконкой источника.

    @ViewBuilder
    private func tagGroupSectionsVM(vm: POIEditViewModel) -> some View {
        let groups = vm.tagGroups

        // Сортируем секции в том же порядке что и старый рендер
        ForEach(OSMTagDefinition.TagGroup.allCases, id: \.self) { group in
            let keysInGroup = groups.keys.filter {
                OSMTags.definition(for: $0)?.group == group
            }.sorted()
            let hasContent = keysInGroup.contains { !(groups[$0]?.values.isEmpty ?? true) }

            if hasContent {
                Section(header: Text(group.rawValue)) {
                    ForEach(keysInGroup, id: \.self) { key in
                        if let binding = Binding(
                            get: { vm.tagGroups[key] ?? TagValueGroup(key: key, values: []) },
                            set: { newGroup in vm.tagGroups[key] = newGroup }
                        ) {
                            TagKeySection(
                                tagKey: key,
                                group: binding,
                                hideIcon: group == .address && keysInGroup.first != key
                            )
                        }
                    }
                }
            }
        }

        // Ключи без группы в OSMTags (contact:vk и т.п.)
        let ungrouped = groups.keys.filter {
            OSMTags.definition(for: $0)?.group == nil
        }.sorted()
        if !ungrouped.isEmpty {
            Section(header: Text("Прочее")) {
                ForEach(ungrouped, id: \.self) { key in
                    if let binding = Binding(
                        get: { vm.tagGroups[key] ?? TagValueGroup(key: key, values: []) },
                        set: { newGroup in vm.tagGroups[key] = newGroup }
                    ) {
                        TagKeySection(tagKey: key, group: binding)
                    }
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
                // Кнопка просмотра сырого текста — только в new-режиме, если есть данные
                if isNewMode && (rawOCRText != nil || !qrPayloads.isEmpty) {
                    Button {
                        showRawText = true
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                }
                // Кнопка добавления фото — в edit-режиме и new-режиме (если нет исходного фото)
                if !isNewMode || sourceImage == nil {
                    Button {
                        if editVM == nil { editVM = POIEditViewModel(poi: poi) }
                        showAddPhoto = true
                    } label: {
                        Image(systemName: "camera.badge.plus")
                    }
                }
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
        // Если активна новая VM — применяем её принятые значения поверх poi.tags
        if let vm = editVM {
            let exported = vm.exportTags()
            for (key, value) in exported {
                poi.tags[key] = value
            }
        }
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
        // Если активна новая VM — применяем её принятые значения поверх poi.tags
        if let vm = editVM {
            let exported = vm.exportTags()
            for (key, value) in exported {
                poi.tags[key] = value
            }
        }
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
            // Сохраняем как «прошлую точку» при точных координатах (ручная расстановка
            // или точность GPS/фото ≤ 30 м).
            let isAccurate: Bool = {
                switch coordinateSource {
                case .manual: return true
                case .photo:  return (uploading.photoAccuracy ?? .infinity) <= 30
                case .gps:    return (uploading.gpsAccuracy   ?? .infinity) <= 30
                default:      return false
                }
            }()
            if isAccurate {
                LastPOILocationStore.save(CLLocationCoordinate2D(
                    latitude: uploaded.coordinate.latitude,
                    longitude: uploaded.coordinate.longitude
                ))
            }
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
            coordUndoStack.append(poi.coordinate)
            redoStack.removeAll()
            coordRedoStack.removeAll()
        }
    }

    /// Немедленно пушит снапшот координаты в undo-стек (без дебаунса).
    private func pushCoordinateSnapshot() {
        // Пушим и теги (текущее состояние) и координату вместе
        undoStack.append(poi.tags)
        coordUndoStack.append(poi.coordinate)
        redoStack.removeAll()
        coordRedoStack.removeAll()
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
            let currentTags = undoStack.removeLast()
            let currentCoord = coordUndoStack.count > 1 ? coordUndoStack.removeLast() : nil
            redoStack.append(currentTags)
            if let currentCoord { coordRedoStack.append(currentCoord) }
            poi.tags = undoStack.last ?? [:]
            if let prevCoord = coordUndoStack.last {
                poi.coordinate = prevCoord
                onCoordinateChange()
            }
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
            if let nextCoord = coordRedoStack.popLast() {
                coordUndoStack.append(nextCoord)
                poi.coordinate = nextCoord
                onCoordinateChange()
            }
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
        guard !isManualNewWithoutContext else { return }
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

        // Новая VM: накладываем OSM baseline из ноды, кандидаты из внешних источников сохраняются
        if let vm = editVM {
            vm.applyOSMNode(candidate.node)
        } else {
            // Если VM не была создана (нет webResults), создаём её сейчас из OSM + extractedTags
            let vm = POIEditViewModel(poi: poi)
            vm.applyWebResults(webResults)
            editVM = vm
            vm.applyOSMNode(candidate.node)
        }

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
        // Пересоздаём VM из восстановленного состояния POI
        if !webResults.isEmpty {
            let vm = POIEditViewModel(poi: poi)
            vm.applyWebResults(webResults)
            editVM = vm
        } else {
            editVM = nil
        }
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

    /// True когда точность исходных координат плохая (> 50 м) — независимо от текущего source.
    private var hasCoordinateFallbacks: Bool {
        switch coordinateSource {
        case .photo: return (poi.photoAccuracy ?? .infinity) > 50
        case .gps:   return (poi.gpsAccuracy   ?? .infinity) > 50
        default:     return false
        }
    }

    /// Относительное время прошлой точки (например «3 мин назад», «вчера»).
    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Tag grouping

    private func groupedEntries(from tags: [String: String],
                                excluding: Set<String> = [])
        -> [OSMTagDefinition.TagGroup: [(key: String, value: String)]] {
        var result: [OSMTagDefinition.TagGroup: [(key: String, value: String)]] = [:]
        for key in tags.keys.sorted(by: groupSortKey) {
            guard let value = tags[key] else { continue }
            if key == "type" && value == "multipolygon" { continue }
            // "addr" — псевдо-ключ пресетов, не является реальным тегом OSM
            if key == "addr" { continue }
            // Ключи, уже отрендеренные в typeSection.primaryExtras — пропускаем
            if excluding.contains(key) { continue }
            // Вся группа .type рендерится в typeSection — пропускаем здесь.
            // Также пропускаем базовые ключи типа (amenity, shop, healthcare…) —
            // они отображаются в typeSection независимо от resolvedGroup.
            if resolvedGroup(for: key) == .type { continue }
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
        if OSMTags.isNameKey(key)            { return .name }
        if OSMTags.isBrandKey(key)           { return .brand }
        if OSMTags.isLegalKey(key)           { return .legal }
        if OSMTags.isPaymentKey(key)         { return .payment }
        if OSMTags.isFuelKey(key)            { return .fuel }
        if OSMTags.isDietKey(key)            { return .diet }
        if OSMTags.isRecyclingKey(key)       { return .recycling }
        if OSMTags.isCurrencyKey(key)        { return .currency }
        if OSMTags.isServiceBicycleKey(key)  { return .serviceBicycle }
        if OSMTags.isServiceVehicleKey(key)  { return .serviceVehicle }
        if OSMTags.isContactKey(key)         { return .contact }
        if OSMTags.isEntranceKey(key)        { return .entrance }
        if OSMTags.isAddressKey(key)         { return .address }
        if OSMTags.isBuildingKey(key)        { return .building }
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

// MARK: - RawTextView

struct RawTextView: View {
    let ocrText: String?
    let qrPayloads: [String]
    var webResults: [WebFetchResult] = []

    @Environment(\.dismiss) private var dismiss

    private var hasAnyData: Bool {
        (ocrText != nil && !ocrText!.isEmpty) || !qrPayloads.isEmpty || !webResults.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if let text = ocrText, !text.isEmpty {
                    Section("Текст с фото") {
                        Text(text)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .listRowBackground(Color(.secondarySystemGroupedBackground))
                    }
                }

                if !qrPayloads.isEmpty {
                    Section("QR-коды") {
                        ForEach(qrPayloads, id: \.self) { payload in
                            Text(payload)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                }

                if !webResults.isEmpty {
                    Section("Данные из ссылок") {
                        ForEach(webResults) { result in
                            WebFetchResultRow(result: result)
                        }
                    }
                }

                if !hasAnyData {
                    Section {
                        Text("Нет данных")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Распознанный текст")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

// MARK: - WebFetchResultRow

private struct WebFetchResultRow: View {
    let result: WebFetchResult
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            // Теги с уверенностью
            if !result.tags.isEmpty {
                ForEach(result.tags.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .top, spacing: 6) {
                        Text(key)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 80, alignment: .leading)
                        Text(value)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let conf = result.confidence[key] {
                            Text("\(Int(conf * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
                }
            }

            // Сниппеты
            if !result.rawSnippets.isEmpty {
                Divider()
                ForEach(result.rawSnippets, id: \.self) { snippet in
                    Text(snippet)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .listRowBackground(Color(.tertiarySystemGroupedBackground))
                }
            }

            // Ошибка
            if let err = result.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.url.host ?? result.url.absoluteString)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(result.sourceTag)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !result.tags.isEmpty {
                        Text("· \(result.tags.count) тег\(tagSuffix(result.tags.count))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if result.error != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func tagSuffix(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod100 >= 11 && mod100 <= 14 { return "ов" }
        switch mod10 {
        case 1: return ""
        case 2, 3, 4: return "а"
        default: return "ов"
        }
    }
}
