import SwiftUI
import MapLibre
import CoreLocation

// MARK: - MapView

struct MapView: View {
    @StateObject private var viewModel = MapViewModel()

    // Флоу добавления нового POI
    @State private var extractionItemForNew: IdentifiableImage?         // стабильный item для sheet
    @State private var manualPOIForNew: POI?                            // skip → сразу ValidationView

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MapLibreView(viewModel: viewModel)
                .ignoresSafeArea()

            // Индикатор загрузки Overpass
            if viewModel.isLoading {
                ProgressView()
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 60)
                    .allowsHitTesting(false)
            }

            // Ошибка Overpass
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 60)
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
            }

            // Indoor: переключатель этажей (левый край)
            if viewModel.showIndoorControls {
                FloorPickerView(
                    floors: viewModel.availableFloors,
                    selectedFloor: $viewModel.selectedFloor
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 16)
                .padding(.bottom, 40)
            }

            VStack(spacing: 12) {
                AddPOIButton { viewModel.isAddingPOI = true }
                LocationButton { viewModel.centerOnUserLocation() }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 40)

            // Zoom badge — левее кнопки "i" MapLibre (которая ~60pt от правого края)
            Text(String(format: "z%.1f", viewModel.currentZoomLevel))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 66)
                .padding(.bottom, 8)
                .allowsHitTesting(false)
        }

        // Sheet: информация о существующей ноде
        .sheet(item: $viewModel.selectedNode) { node in
            OSMNodeSheet(
                initialNode: node,
                viewModel: viewModel,
                onSave: { updatedPOI in
                    viewModel.saveDraftPOI(updatedPOI)
                    viewModel.selectedNode = nil
                }
            ) {
                viewModel.selectedNode = nil
            }
        }

        // Sheet: CaptureView для нового POI
        .sheet(isPresented: $viewModel.isAddingPOI) {
            CaptureView(
                onCapture: { image, coord in
                    viewModel.isAddingPOI = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        // Координата зашита прямо в item — нет гонки со State
                        extractionItemForNew = IdentifiableImage(image: image, coordinate: coord)
                    }
                },
                onSkip: {
                    viewModel.isAddingPOI = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let coord = viewModel.mapCenter
                        manualPOIForNew = POI(coordinate: .init(latitude: coord.latitude, longitude: coord.longitude))
                    }
                }
            )
        }

        // Sheet: ExtractionView для нового POI
        .sheet(item: $extractionItemForNew) { wrapper in
            let coord = wrapper.coordinate ?? viewModel.mapCenter
            NavigationStack {
                ExtractionView(
                    image: wrapper.image,
                    coordinate: coord,
                    coordinateFromPhoto: wrapper.coordinate != nil,
                    onSave: { savedPOI in
                        viewModel.saveDraftPOI(savedPOI)
                        viewModel.centerOn(coordinate: CLLocationCoordinate2D(
                            latitude: savedPOI.coordinate.latitude,
                            longitude: savedPOI.coordinate.longitude
                        ))
                    }
                )
            }
            .onAppear { viewModel.pendingPOICoordinate = wrapper.coordinate }
            .onDisappear { viewModel.pendingPOICoordinate = nil }
        }

        // Sheet: редактирование черновика POI (тап на оранжевый маркер)
        .sheet(item: $viewModel.selectedDraftPOI) { draft in
            NavigationStack {
                ValidationView(
                    poi: draft,
                    sourceImage: nil,
                    onSave: { updatedPOI in
                        viewModel.updateDraftPOI(updatedPOI)
                    }
                )
            }
        }

        // Sheet: ручное добавление нового POI (Пропустить из CaptureView)
        .sheet(item: $manualPOIForNew) { emptyPOI in
            NavigationStack {
                ValidationView(
                    poi: emptyPOI,
                    sourceImage: nil,
                    onSave: { savedPOI in
                        viewModel.saveDraftPOI(savedPOI)
                        viewModel.centerOn(coordinate: CLLocationCoordinate2D(
                            latitude: savedPOI.coordinate.latitude,
                            longitude: savedPOI.coordinate.longitude
                        ))
                    }
                )
            }
        }
    }
}

// MARK: - FloorPickerView

/// Вертикальный переключатель этажей (стиль indoor map).
/// Этажи отображаются снизу вверх: самый нижний уровень — внизу,
/// самый верхний — наверху, как в реальном здании.
private struct FloorPickerView: View {
    let floors: [IndoorFloor]
    @Binding var selectedFloor: Int
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            ForEach(floors.sorted().reversed()) { floor in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedFloor = floor.level
                    }
                } label: {
                    Text(floor.labelFor(language: settings.language))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(width: 42, height: 40)
                        .foregroundStyle(selectedFloor == floor.level ? .white : .primary)
                        .background(
                            selectedFloor == floor.level
                                ? Color.accentColor
                                : Color(.systemBackground).opacity(0.92)
                        )
                }
                .buttonStyle(.plain)

                if floor != floors.sorted().reversed().last {
                    Divider()
                        .frame(width: 42)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(.systemGray4), lineWidth: 0.5)
        )
        .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
    }
}

// MARK: - AddPOIButton

private struct AddPOIButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(width: 50, height: 50)
                .background(.regularMaterial)
                .clipShape(Circle())
                .shadow(radius: 4)
        }
    }
}

// MARK: - LocationButton

private struct LocationButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "location.fill")
                .font(.title2)
                .frame(width: 50, height: 50)
                .background(.regularMaterial)
                .clipShape(Circle())
                .shadow(radius: 4)
        }
    }
}

// MARK: - OSMNodeSheet

private struct OSMNodeSheet: View {
    /// Нода, с которой открылся шит (может быть без деталей — version: 1).
    /// Используется как fallback пока грузится selectedNodeDetails.
    let initialNode: OSMNode
    @ObservedObject var viewModel: MapViewModel
    var onSave: ((POI) -> Void)? = nil
    let onClose: () -> Void

    /// Актуальная нода: selectedNodeDetails если уже загружен, иначе initialNode.
    /// Т.к. viewModel — @ObservedObject, при обновлении selectedNodeDetails
    /// SwiftUI перестраивает шит и передаёт свежую версию с правильным version.
    private var node: OSMNode { viewModel.selectedNodeDetails ?? initialNode }
    private var isLoadingDetails: Bool { viewModel.isLoadingDetails }

    // Режим отображения
    @State private var isEditing = false
    @State private var editMode: EditTab = .simplified
    @State private var poi: POI? = nil          // POI для редактирования, создаётся при входе в режим
    @State private var tagPairs: [TagPair] = [] // плоский массив для Tags-режима

    // Состояние загрузки
    @State private var isUploading = false
    @State private var uploadError: String? = nil
    @State private var showUploadError = false
    private let authService = OSMAuthService.shared

    enum EditTab: String, CaseIterable {
        case simplified = "Форма"
        case tags       = "Теги"
    }

    // Приоритетные ключи для Simplified-режима
    private let priorityKeys = [
        "name", "amenity", "shop", "office", "tourism",
        "addr:street", "addr:housenumber", "addr:city",
        // Контакты: телефон → сайт → email → прочее
        "phone", "contact:phone",
        "website", "contact:website",
        "email", "contact:email",
        "opening_hours"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented control — только в режиме редактирования
                if isEditing {
                    Picker("Режим", selection: $editMode) {
                        ForEach(EditTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.systemGroupedBackground))
                }

                List {
                    if !isEditing {
                        // ── Режим просмотра ──
                        tagListSection(isEditable: false)
                    } else if editMode == .simplified {
                        // ── Simplified редактор (тот же компонент, isEditable: true) ──
                        tagListSection(isEditable: true)
                    } else {
                        // ── Raw Tags редактор ──
                        tagsSection
                    }
                }
                .onChange(of: editMode) { _, newTab in
                    // Simplified → Tags: строим пары из актуальных тегов POI
                    if newTab == .tags { syncPairsFromTags() }
                    // Tags → Simplified: применяем пары обратно в POI
                    if newTab == .simplified { syncTagsFromPairs() }
                }
            }
            .navigationTitle(node.tags["name"] ?? "OSM нода #\(node.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .alert("Ошибка загрузки", isPresented: $showUploadError) {
                Button("Скопировать") {
                    UIPasteboard.general.string = uploadError
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(uploadError ?? "Неизвестная ошибка")
            }
        }
        .presentationDetents([.medium, .large], selection: Binding(
            get: { isEditing ? .large : .medium },
            set: { _ in }  // пользователь может тянуть вручную, но не переключаем обратно
        ))
    }

    // MARK: - Секции

    /// Единый список тегов — один компонент для просмотра (isEditable: false)
    /// и Simplified-редактора (isEditable: true).
    ///
    /// Теги группируются по `TagGroup` в порядке `CaseIterable`.
    /// Неизвестные ключи (не в каталоге) попадают в секцию «Прочее».
    /// Координаты вынесены в отдельную финальную секцию (всегда read-only).
    @ViewBuilder
    private func tagListSection(isEditable: Bool) -> some View {
        let tags = isEditable ? (poi?.tags ?? [:]) : node.tags

        // Спиннер — только в режиме просмотра, пока теги загружаются
        if !isEditable && isLoadingDetails {
            Section {
                HStack {
                    ProgressView()
                    Text("Загружаем теги…")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
            }
        } else if tags.isEmpty {
            Section { Text("Нет тегов").foregroundStyle(.secondary) }
        } else {
            // Распределяем теги по группам
            let grouped = groupedEntries(from: tags)

            ForEach(OSMTagDefinition.TagGroup.allCases, id: \.self) { group in
                if let entries = grouped[group], !entries.isEmpty {
                    if group == .name {
                        CollapsibleNameSection(
                            entries: entries,
                            isEditable: isEditable,
                            tagRow: { key, value, isPrimary in
                                tagRow(for: key, value: value, isEditable: isEditable, isPrimary: isPrimary)
                                    .swipeActions(edge: .trailing) {
                                        if isEditable {
                                            Button(role: .destructive) {
                                                poi?.tags.removeValue(forKey: key)
                                                poi?.fieldStatus.removeValue(forKey: key)
                                            } label: { Label("Удалить", systemImage: "trash") }
                                        }
                                    }
                            }
                        )
                    } else if group == .brand {
                        CollapsibleBrandSection(
                            entries: entries,
                            isEditable: isEditable,
                            tagRow: { key, value in
                                tagRow(for: key, value: value, isEditable: isEditable)
                                    .swipeActions(edge: .trailing) {
                                        if isEditable {
                                            Button(role: .destructive) {
                                                poi?.tags.removeValue(forKey: key)
                                                poi?.fieldStatus.removeValue(forKey: key)
                                            } label: { Label("Удалить", systemImage: "trash") }
                                        }
                                    }
                            }
                        )
                    } else if group == .legal {
                        CollapsibleLegalSection(
                            entries: entries,
                            isEditable: isEditable,
                            tagRow: { key, value in
                                tagRow(for: key, value: value, isEditable: isEditable)
                                    .swipeActions(edge: .trailing) {
                                        if isEditable {
                                            Button(role: .destructive) {
                                                poi?.tags.removeValue(forKey: key)
                                                poi?.fieldStatus.removeValue(forKey: key)
                                            } label: { Label("Удалить", systemImage: "trash") }
                                        }
                                    }
                            }
                        )
                    } else if group == .payment && !isEditable {
                        PaymentTagSection(entries: entries)
                    } else if group == .address && !isEditable {
                        AddressTagSection(entries: entries)
                    } else if group == .address && isEditable {
                        // Редактирование адреса: иконка только у первой строки + свайп-удаление
                        Section(header: Text("Адрес")) {
                            ForEach(Array(entries.enumerated()), id: \.element.key) { index, item in
                                tagRow(for: item.key, value: item.value, isEditable: true,
                                       forceIcon: index == 0 ? "house" : nil,
                                       hideIcon: index > 0)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            poi?.tags.removeValue(forKey: item.key)
                                            poi?.fieldStatus.removeValue(forKey: item.key)
                                        } label: { Label("Удалить", systemImage: "trash") }
                                    }
                            }
                        }
                    } else if group == .hours && !isEditable {
                        Section {
                            ForEach(entries, id: \.key) { item in
                                tagRow(for: item.key, value: item.value, isEditable: false)
                            }
                        }
                    } else {
                        Section(header: Text(group.rawValue)) {
                            ForEach(entries, id: \.key) { item in
                                tagRow(for: item.key, value: item.value, isEditable: isEditable)
                                    .swipeActions(edge: .trailing) {
                                        if isEditable {
                                            Button(role: .destructive) {
                                                poi?.tags.removeValue(forKey: item.key)
                                                poi?.fieldStatus.removeValue(forKey: item.key)
                                            } label: { Label("Удалить", systemImage: "trash") }
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }

        // Координаты и тип геометрии — всегда отдельной секцией, только для чтения
        Section {
            let typeLabel: String = {
                switch node.type {
                case .node:     return AppSettings.shared.language == .ru ? "Точка (node)" : "Node"
                case .way:      return AppSettings.shared.language == .ru ? "Линия/полигон (way)" : "Way"
                case .relation: return AppSettings.shared.language == .ru ? "Отношение (relation)" : "Relation"
                }
            }()
            OSMTagRow(tagKey: "type", readOnlyValue: typeLabel)
            OSMTagRow(tagKey: "id",      readOnlyValue: String(node.id))
            OSMTagRow(tagKey: "version", readOnlyValue: String(node.version))
            OSMTagRow(tagKey: "lat", readOnlyValue: String(format: "%.6f", node.latitude))
            OSMTagRow(tagKey: "lon", readOnlyValue: String(format: "%.6f", node.longitude))
        }

        // Строка добавления нового тега — только в режиме редактирования
        if isEditable {
            Section {
                AddTagRow { key, value in
                    self.poi?.tags[key] = value
                    self.poi?.fieldStatus[key] = .manual
                }
            }
        }
    }

    /// Строит одну строку тега — read-only или editable в зависимости от флага.
    @ViewBuilder
    private func tagRow(for key: String, value: String, isEditable: Bool,
                        forceIcon: String? = nil, hideIcon: Bool = false,
                        isPrimary: Bool = false) -> some View {
        if isEditable {
            OSMTagRow(
                tagKey: key,
                editableValue: Binding(
                    get: { self.poi?.tags[key] ?? "" },
                    set: { newVal in
                        self.poi?.tags[key] = newVal.isEmpty ? nil : newVal
                        self.poi?.fieldStatus[key] = .confirmed
                    }
                ),
                status: poi?.fieldStatus[key] ?? .manual,
                forceIcon: forceIcon,
                hideIcon: hideIcon,
                isPrimary: isPrimary
            )
        } else {
            OSMTagRow(tagKey: key, readOnlyValue: value, forceIcon: forceIcon, hideIcon: hideIcon, isPrimary: isPrimary)
        }
    }

    /// Группирует теги по `TagGroup`.
    /// Ключи из каталога → в свою группу; неизвестные → `.other`.
    /// Все name-ключи (name:*, old_name, alt_name и т.д.) → `.name`.
    /// Порядок внутри группы: приоритетные ключи вперёд, остальные по алфавиту.
    private func groupedEntries(from tags: [String: String]) -> [OSMTagDefinition.TagGroup: [(key: String, value: String)]] {
        var result: [OSMTagDefinition.TagGroup: [(key: String, value: String)]] = [:]
        for key in tags.keys.sorted(by: groupSortKey) {
            guard let value = tags[key] else { continue }
            // Фильтруем служебный type=multipolygon — тип геометрии уже отображается отдельно
            if key == "type" && value == "multipolygon" { continue }
            let group: OSMTagDefinition.TagGroup
            if OSMTags.isNameKey(key) {
                group = .name
            } else if OSMTags.isBrandKey(key) {
                group = .brand
            } else if OSMTags.isLegalKey(key) {
                group = .legal
            } else if OSMTags.isPaymentKey(key) {
                group = .payment
            } else if OSMTags.isContactKey(key) {
                group = .contact
            } else if OSMTags.isAddressKey(key) {
                group = .address
            } else {
                group = OSMTags.definition(for: key)?.group ?? .other
            }
            result[group, default: []].append((key: key, value: value))
        }
        return result
    }

    /// Компаратор: сначала по индексу группы в `TagGroup.allCases`,
    /// внутри группы — приоритетные ключи вперёд, остальные по алфавиту.
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

    /// Определяет группу ключа с учётом prefix-правил (contact:*, payment:* и т.д.)
    private func resolvedGroup(for key: String) -> OSMTagDefinition.TagGroup {
        if OSMTags.isNameKey(key)    { return .name }
        if OSMTags.isBrandKey(key)   { return .brand }
        if OSMTags.isLegalKey(key)   { return .legal }
        if OSMTags.isPaymentKey(key) { return .payment }
        if OSMTags.isContactKey(key) { return .contact }
        if OSMTags.isAddressKey(key) { return .address }
        return OSMTags.definition(for: key)?.group ?? .other
    }

    @ViewBuilder
    private var tagsSection: some View {
        if poi != nil {
            Section {
                ForEach(tagPairs.indices, id: \.self) { i in
                    TagPairRow(
                        pair: $tagPairs[i],
                        onDelete: { deleteTag(at: i) }
                    )
                }
            }
            Section {
                AddTagRow { key, value in
                    tagPairs.append(TagPair(key: key, value: value))
                    syncTagsFromPairs()
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if isEditing {
                Button {
                    poi = nil
                    isEditing = false
                } label: {
                    Image(systemName: "xmark")
                        .fontWeight(.semibold)
                }
            } else {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "chevron.down")
                        .fontWeight(.semibold)
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if isEditing {
                // Загрузить в OSM
                Button {
                    Task { await upload() }
                } label: {
                    if isUploading {
                        ProgressView()
                    } else {
                        Image(systemName: authService.isAuthenticated
                              ? "arrow.up.circle.fill"
                              : "arrow.up.circle")
                    }
                }
                .disabled(isUploading)
            } else {
                Button {
                    let p = node.toPOI()
                    poi = p
                    tagPairs = p.tags.keys.sorted().map { TagPair(key: $0, value: p.tags[$0] ?? "") }
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .disabled(isLoadingDetails)
            }
        }
        if isEditing {
            ToolbarItem(placement: .confirmationAction) {
                // Сохранить локально
                Button {
                    saveLocally()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(isUploading)
            }
        }
    }

    // MARK: - Tag pairs sync

    /// Пары → poi.tags (вызывается при изменении ключа/значения в Tags-режиме)
    private func syncTagsFromPairs() {
        guard poi != nil else { return }
        var newTags: [String: String] = [:]
        for pair in tagPairs where !pair.key.isEmpty {
            newTags[pair.key] = pair.value
        }
        poi?.tags = newTags
    }

    /// poi.tags → пары (вызывается при переключении на Tags-вкладку)
    private func syncPairsFromTags() {
        guard let p = poi else { return }
        tagPairs = p.tags.keys.sorted().map { TagPair(key: $0, value: p.tags[$0] ?? "") }
    }

    private func deleteTag(at index: Int) {
        tagPairs.remove(at: index)
        syncTagsFromPairs()
    }

    // MARK: - Actions

    private func saveLocally() {
        if editMode == .tags { syncTagsFromPairs() }
        guard var p = poi else { return }
        p.status = .validated
        onSave?(p)
        onClose()
    }

    @MainActor
    private func upload() async {
        if editMode == .tags { syncTagsFromPairs() }
        guard var p = poi else { return }

        // Последняя защита от version mismatch: если selectedNodeDetails загружен
        // и содержит более актуальную версию — берём её. Это страховка на случай
        // если poi был создан до окончания загрузки деталей (гонка).
        if let details = viewModel.selectedNodeDetails,
           details.id == p.osmNodeId,
           let serverVersion = p.osmVersion, details.version > serverVersion {
            p.osmVersion = details.version
            p.osmType = details.type
        }

        print("[Upload] 🚀 poi.osmNodeId=\(String(describing: p.osmNodeId)) osmVersion=\(String(describing: p.osmVersion)) osmType=\(String(describing: p.osmType?.rawValue))")
        print("[Upload] 📋 selectedNodeDetails: id=\(String(describing: viewModel.selectedNodeDetails?.id)) version=\(String(describing: viewModel.selectedNodeDetails?.version))")
        print("[Upload] 🏷 tags=\(p.tags)")

        if !authService.isAuthenticated {
            guard let anchor = presentationAnchor() else { return }
            do {
                try await authService.signIn(presentationAnchor: anchor)
            } catch {
                uploadError = error.localizedDescription
                showUploadError = true
                return
            }
        }

        isUploading = true
        do {
            let uploaded = try await OSMAPIService.shared.upload(poi: p)
            onSave?(uploaded)
            onClose()
        } catch {
            uploadError = error.localizedDescription
            showUploadError = true
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
}

// MARK: - IdentifiableImage (для .sheet(item:))

struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let coordinate: CLLocationCoordinate2D?   // GPS из фото, зашит в момент создания
}

// MARK: - TagPair (модель строки в Tags-режиме)

struct TagPair: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

// MARK: - TagPairRow

private struct TagPairRow: View {
    @Binding var pair: TagPair
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Ключ
            HStack {
                Text("key")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
                TextField("key", text: $pair.key)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.primary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Divider()

            // Значение
            HStack {
                Text("value")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
                TextField("value", text: $pair.value)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.sentences)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { onDelete() } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }
}

// MARK: - CollapsibleLegalSection

/// Секция «Юридические данные» — сворачиваемая.
/// Главный тег: operator, если есть; иначе первый ref:*.
private struct CollapsibleLegalSection<Row: View>: View {
    let entries: [(key: String, value: String)]
    let isEditable: Bool
    let tagRow: (String, String) -> Row

    @State private var isExpanded = false

    private var primaryEntry: (key: String, value: String)? {
        for key in OSMTags.legalPrimaryKeys {
            if let entry = entries.first(where: { $0.key == key }) { return entry }
        }
        return entries.first
    }

    private var secondaryEntries: [(key: String, value: String)] {
        guard let primary = primaryEntry else { return entries }
        return entries.filter { $0.key != primary.key }
    }

    var body: some View {
        Section {
            if secondaryEntries.isEmpty {
                if let primary = primaryEntry {
                    tagRow(primary.key, primary.value)
                }
            } else {
                if let primary = primaryEntry {
                    Button {
                        withAnimation { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 0) {
                            tagRow(primary.key, primary.value)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if isExpanded {
                    ForEach(secondaryEntries, id: \.key) { item in
                        tagRow(item.key, item.value)
                    }
                }
            }
        }
    }
}

// MARK: - CollapsibleBrandSection

/// Секция «Бренд» аналогична CollapsibleNameSection.
/// Главный тег: первый из brandPrimaryKeys (brand → operator → network),
/// иначе первый в списке. Остальные — под DisclosureGroup.
private struct CollapsibleBrandSection<Row: View>: View {
    let entries: [(key: String, value: String)]
    let isEditable: Bool
    let tagRow: (String, String) -> Row

    @State private var isExpanded = false

    private var primaryEntry: (key: String, value: String)? {
        for key in OSMTags.brandPrimaryKeys {
            if let entry = entries.first(where: { $0.key == key }) { return entry }
        }
        return entries.first
    }

    private var secondaryEntries: [(key: String, value: String)] {
        guard let primary = primaryEntry else { return entries }
        return entries.filter { $0.key != primary.key }
    }

    var body: some View {
        Section(header: isEditable ? Text("Бренд") : Text("")) {
            if secondaryEntries.isEmpty {
                if let primary = primaryEntry {
                    tagRow(primary.key, primary.value)
                }
            } else {
                if let primary = primaryEntry {
                    Button {
                        withAnimation { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 0) {
                            tagRow(primary.key, primary.value)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if isExpanded {
                    ForEach(secondaryEntries, id: \.key) { item in
                        tagRow(item.key, item.value)
                    }
                }
            }
        }
    }
}

// MARK: - PaymentTagSection

/// Секция «Способы оплаты» — компактная: показывает иконку кредитки
/// только у первой строки, у остальных — отступ без иконки.
/// Значения yes/no заменяются на чекмарк/крестик.
private struct PaymentTagSection: View {
    let entries: [(key: String, value: String)]

    var body: some View {
        Section(header: Text("Способы оплаты")) {
            ForEach(Array(entries.enumerated()), id: \.element.key) { index, item in
                HStack(spacing: 10) {
                    if index == 0 {
                        Image(systemName: "creditcard")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .center)
                    } else {
                        Color.clear.frame(width: 24, height: 1)
                    }
                    Text(OSMTags.definition(for: item.key)?.label ?? item.key)
                        .font(.body)
                    Spacer()
                    paymentValueView(item.value)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func paymentValueView(_ value: String) -> some View {
        switch value.lowercased() {
        case "yes":
            Image(systemName: "checkmark")
                .foregroundStyle(.green)
        case "no":
            Image(systemName: "xmark")
                .foregroundStyle(.red)
        default:
            Text(value)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AddressTagSection

/// Секция «Адрес» в режиме просмотра.
/// Показывает адрес одной строкой в формате:
/// «Страна, Индекс, Город, Улица, д. X, эт. Y, кв. Z»
/// Иконка house — только слева от этой строки.
private struct AddressTagSection: View {
    let entries: [(key: String, value: String)]

    /// Порядок ключей и префиксы для форматирования
    private static let addressOrder: [(key: String, prefix: String)] = [
        ("addr:country",      ""),
        ("addr:postcode",     ""),
        ("addr:city",         ""),
        ("addr:place",        ""),
        ("addr:suburb",       ""),
        ("addr:street",       ""),
        ("addr:housenumber",  "д.\u{00A0}"),
        ("addr:floor",        "эт.\u{00A0}"),
        ("addr:unit",         "кв.\u{00A0}"),
        ("addr2:street",      ""),
        ("addr2:housenumber", "д.\u{00A0}"),
    ]

    private var formattedAddress: String {
        let dict = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        var parts: [String] = []
        let handledKeys = Set(Self.addressOrder.map { $0.key })
        for (key, prefix) in Self.addressOrder {
            if let val = dict[key], !val.isEmpty {
                parts.append(prefix + val)
            }
        }
        // Нераспознанные addr:* ключи — в конец
        for entry in entries where !handledKeys.contains(entry.key) && !entry.value.isEmpty {
            parts.append(entry.value)
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Section(header: Text("Адрес")) {
            HStack(spacing: 10) {
                Image(systemName: "house")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .center)
                Text(formattedAddress)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - CollapsibleNameSection

/// Секция «Название»:
/// • По умолчанию свёрнута — показывает только главный name-тег + шеврон.
/// • Разворачивается → все name-теги без дополнительного отступа.
/// • Главный тег: первый из OSMTags.nameKeys, присутствующий в entries.
private struct CollapsibleNameSection<Row: View>: View {
    let entries: [(key: String, value: String)]
    let isEditable: Bool
    /// (key, value, isPrimary) → Row
    let tagRow: (String, String, Bool) -> Row

    @State private var isExpanded = false

    /// Главный тег — первый из приоритетного порядка nameKeys, иначе первый.
    private var primaryEntry: (key: String, value: String)? {
        for key in OSMTags.nameKeys {
            if let entry = entries.first(where: { $0.key == key }) { return entry }
        }
        return entries.first
    }

    /// Остальные теги (кроме главного).
    private var secondaryEntries: [(key: String, value: String)] {
        guard let primary = primaryEntry else { return entries }
        return entries.filter { $0.key != primary.key }
    }

    var body: some View {
        Section {
            if secondaryEntries.isEmpty {
                if let primary = primaryEntry {
                    tagRow(primary.key, primary.value, true)
                }
            } else {
                // Строка-заголовок с шевроном — без DisclosureGroup, чтобы не добавлять отступ
                if let primary = primaryEntry {
                    Button {
                        withAnimation { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 0) {
                            tagRow(primary.key, primary.value, true)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if isExpanded {
                    ForEach(secondaryEntries, id: \.key) { item in
                        tagRow(item.key, item.value, false)
                    }
                }
            }
        } header: {
            if isEditable { Text("Название") }
        }
    }
}

