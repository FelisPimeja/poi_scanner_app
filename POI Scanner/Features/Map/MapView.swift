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
struct FloorPickerView: View {
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

    // Undo / Redo
    @State private var undoStack: [[String: String]] = []
    @State private var redoStack: [[String: String]] = []
    @State private var snapshotTask: Task<Void, Never>? = nil

    // Редактор координат
    @State private var showCoordinatePicker = false

    private var canUndo: Bool { undoStack.count >= 2 }
    private var canRedo: Bool { !redoStack.isEmpty }

    /// Планирует снимок текущих тегов через 0.6 с (дебаунс).
    /// Вызывается при каждом изменении `poi.tags`.
    private func scheduleSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            guard let tags = poi?.tags, tags != undoStack.last else { return }
            undoStack.append(tags)
            redoStack.removeAll()
        }
    }

    private func undo() {
        guard undoStack.count >= 2 else { return }
        let current = undoStack.removeLast()
        redoStack.append(current)
        poi?.tags = undoStack.last ?? [:]
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(next)
        poi?.tags = next
    }

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

    /// Ключи, которые всегда показываются как плейсхолдеры в edit-режиме,
    /// даже если тег отсутствует у POI.
    private let essentialPlaceholders: [OSMTagDefinition.TagGroup: [String]] = [
        .hours:    ["opening_hours"],
        .address:  ["addr:street", "addr:housenumber", "addr:city", "addr:postcode"],
        .contact:  ["phone", "website", "email"],
        .payment:  ["payment:cash", "payment:visa", "payment:mastercard",
                    "payment:mir", "payment:apple_pay", "payment:sbp"],
        .building: ["building"],
        .other:    ["wheelchair", "description"],
    ]

    /// True если ключ входит в essentialPlaceholders (для любой группы).
    private func isEssentialKey(_ key: String) -> Bool {
        essentialPlaceholders.values.contains { $0.contains(key) }
    }

    /// Свайп-действие для строки тега:
    /// - essential-ключи → «Очистить» (удаляет значение, плейсхолдер остаётся)
    /// - прочие          → «Удалить»  (полностью убирает строку)
    @ViewBuilder
    private func swipeDeleteAction(forKey key: String) -> some View {
        if isEssentialKey(key) {
            Button {
                poi?.tags.removeValue(forKey: key)
                poi?.fieldStatus.removeValue(forKey: key)
            } label: {
                Label("Очистить", systemImage: "xmark.circle")
            }
            .tint(.orange)
        } else {
            Button(role: .destructive) {
                poi?.tags.removeValue(forKey: key)
                poi?.fieldStatus.removeValue(forKey: key)
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }

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
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onChange(of: poi?.tags) { _, _ in
                // Дебаунс-снимок после каждого изменения тегов
                scheduleSnapshot()
            }
            .alert("Ошибка загрузки", isPresented: $showUploadError) {
                Button("Скопировать") {
                    UIPasteboard.general.string = uploadError
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(uploadError ?? "Неизвестная ошибка")
            }
            .sheet(isPresented: $showCoordinatePicker) {
                let coord = CLLocationCoordinate2D(
                    latitude: poi?.coordinate.latitude ?? node.latitude,
                    longitude: poi?.coordinate.longitude ?? node.longitude
                )
                let floor = poi?.tags["level"].flatMap(Int.init) ?? 0
                CoordinatePickerView(
                    initialCoordinate: coord,
                    initialFloor: floor,
                    onConfirm: { newCoord in
                        poi?.coordinate = POI.Coordinate(newCoord)
                        showCoordinatePicker = false
                    },
                    onCancel: { showCoordinatePicker = false }
                )
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
        } else if !isEditable && tags.isEmpty {
            Section { Text("Нет тегов").foregroundStyle(.secondary) }
        } else {
            // Распределяем теги по группам
            let grouped = groupedEntries(from: tags)

            // Карта + координаты — только в Simplified edit-режиме
            if isEditable {
                locationPreviewSection
            }

            ForEach(OSMTagDefinition.TagGroup.allCases, id: \.self) { group in
                let entries = grouped[group] ?? []
                // Ключи из essentialPlaceholders, которых нет у POI (только edit-режим)
                let absentKeys: [String] = isEditable
                    ? (essentialPlaceholders[group] ?? []).filter { poi?.tags[$0] == nil }
                    : []

                if !entries.isEmpty || !absentKeys.isEmpty {
                    if group == .name && !entries.isEmpty {
                        CollapsibleNameSection(
                            entries: entries,
                            isEditable: isEditable,
                            tagRow: { key, value, isPrimary in
                                tagRow(for: key, value: value, isEditable: isEditable, isPrimary: isPrimary)
                                    .swipeActions(edge: .trailing) {
                                        if isEditable { swipeDeleteAction(forKey: key) }
                                    }
                            }
                        )
                    } else if group == .brand && !entries.isEmpty {
                        CollapsibleBrandSection(
                            entries: entries,
                            isEditable: isEditable,
                            tagRow: { key, value in
                                tagRow(for: key, value: value, isEditable: isEditable)
                                    .swipeActions(edge: .trailing) {
                                        if isEditable { swipeDeleteAction(forKey: key) }
                                    }
                            }
                        )
                    } else if group == .legal && !entries.isEmpty {
                        CollapsibleLegalSection(
                            entries: entries,
                            isEditable: isEditable,
                            tagRow: { key, value in
                                tagRow(for: key, value: value, isEditable: isEditable)
                                    .swipeActions(edge: .trailing) {
                                        if isEditable { swipeDeleteAction(forKey: key) }
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
                                       forceIcon: index == 0 && absentKeys.isEmpty ? "house" : nil,
                                       hideIcon: index > 0 || !absentKeys.isEmpty)
                                    .swipeActions(edge: .trailing) {
                                        swipeDeleteAction(forKey: item.key)
                                    }
                            }
                            // Плейсхолдеры для отсутствующих ключей адреса
                            ForEach(Array(absentKeys.enumerated()), id: \.element) { index, key in
                                tagRow(for: key, value: "", isEditable: true,
                                       forceIcon: index == 0 && entries.isEmpty ? "house" : nil,
                                       hideIcon: !(index == 0 && entries.isEmpty))
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
                                        if isEditable { swipeDeleteAction(forKey: item.key) }
                                    }
                            }
                            // Плейсхолдеры для отсутствующих ключей группы
                            if isEditable {
                                ForEach(absentKeys, id: \.self) { key in
                                    tagRow(for: key, value: "", isEditable: true)
                                }
                            }
                        }
                    }
                }
            }
        }

        // Техническая информация — всегда read-only, сворачиваемая секция
        TechInfoSection(node: node)

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

    // MARK: - Мини-карта с координатами (только Simplified edit)

    /// Секция с превью карты и строкой координат в формате DMS.
    /// Карта — только отображение, строка координат — навигация в CoordinatePickerView.
    @ViewBuilder
    private var locationPreviewSection: some View {
        let lat = poi?.coordinate.latitude  ?? node.latitude
        let lon = poi?.coordinate.longitude ?? node.longitude
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let canEdit = node.type == .node

        Section {
            // Mini-map (read-only, полная ширина) — MapLibre с тем же стилем
            LocationPreviewMapView(coordinate: coord)
                .frame(height: 148)
                .listRowInsets(EdgeInsets())
                .clipShape(Rectangle())

            // Строка координат
            HStack(spacing: 10) {
                Image(uiImage: LocationPreviewMapView.Coordinator.renderPin(
                    color: canEdit ? .systemBlue : .systemGray,
                    size: CGSize(width: 18, height: 20)
                ))
                .frame(width: 24, alignment: .center)
                Text(dmsString(lat: lat, lon: lon))
                    .font(.body)
                    .foregroundStyle(canEdit ? Color.accentColor : Color.primary)
                Spacer()
                if canEdit {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if canEdit { showCoordinatePicker = true }
            }
        }
    }

    /// Конвертирует десятичные градусы в строку формата «55°49′27.84″N  37°37′23.51″E».
    private func dmsString(lat: Double, lon: Double) -> String {
        func parts(_ deg: Double) -> (d: Int, m: Int, s: Double) {
            let a = abs(deg)
            let d = Int(a)
            let m = Int((a - Double(d)) * 60)
            let s = ((a - Double(d)) * 60 - Double(m)) * 60
            return (d, m, s)
        }
        let (ld, lm, ls) = parts(lat)
        let (nd, nm, ns) = parts(lon)
        let latDir = lat >= 0 ? "N" : "S"
        let lonDir = lon >= 0 ? "E" : "W"
        return String(format: "%d°%d′%.2f″%@  %d°%d′%.2f″%@",
                      ld, lm, ls, latDir, nd, nm, ns, lonDir)
    }

    /// Строит одну строку тега — read-only или editable в зависимости от флага.
    @ViewBuilder
    private func tagRow(for key: String, value: String, isEditable: Bool,                        forceIcon: String? = nil, hideIcon: Bool = false,
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
            } else if OSMTags.isBuildingKey(key) {
                group = .building
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
        if OSMTags.isNameKey(key)     { return .name }
        if OSMTags.isBrandKey(key)    { return .brand }
        if OSMTags.isLegalKey(key)    { return .legal }
        if OSMTags.isPaymentKey(key)  { return .payment }
        if OSMTags.isContactKey(key)  { return .contact }
        if OSMTags.isAddressKey(key)  { return .address }
        if OSMTags.isBuildingKey(key) { return .building }
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
        ToolbarItem(placement: .topBarLeading) {
            if isEditing {
                HStack(spacing: 16) {
                    Button {
                        poi = nil
                        undoStack = []
                        redoStack = []
                        snapshotTask?.cancel()
                        isEditing = false
                    } label: {
                        Image(systemName: "xmark")
                            .fontWeight(.semibold)
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
                    undoStack = [p.tags]
                    redoStack = []
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
                    HStack(spacing: 0) {
                        tagRow(primary.key, primary.value)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { isExpanded.toggle() } }
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
                    HStack(spacing: 0) {
                        tagRow(primary.key, primary.value)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { isExpanded.toggle() } }
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

    /// Строит массив отформатированных адресов.
    /// Если какое-либо поле содержит несколько значений через «;»,
    /// формируется отдельная строка для каждого слота (по аналогии
    /// с остальными тегами в OSMTagRow).
    private var formattedAddresses: [String] {
        let dict = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        let handledKeys = Set(Self.addressOrder.map { $0.key })

        // Для каждого ключа разбиваем значение по «;» → получаем слоты.
        // slotCount — максимальное число слотов среди всех присутствующих ключей.
        var slottedValues: [(prefix: String, slots: [String])] = []
        for (key, prefix) in Self.addressOrder {
            guard let raw = dict[key], !raw.isEmpty else { continue }
            let slots = raw.split(separator: ";", omittingEmptySubsequences: true)
                          .map { $0.trimmingCharacters(in: .whitespaces) }
            slottedValues.append((prefix, slots))
        }
        // Нераспознанные addr:* ключи — в конец (без префикса)
        for entry in entries where !handledKeys.contains(entry.key) && !entry.value.isEmpty {
            let slots = entry.value.split(separator: ";", omittingEmptySubsequences: true)
                                   .map { $0.trimmingCharacters(in: .whitespaces) }
            slottedValues.append(("", slots))
        }

        guard !slottedValues.isEmpty else { return [] }

        let slotCount = slottedValues.map { $0.slots.count }.max() ?? 1
        var result: [String] = []
        for i in 0..<slotCount {
            var parts: [String] = []
            for (prefix, slots) in slottedValues {
                // Если у данного поля меньше слотов — берём последний
                let val = i < slots.count ? slots[i] : slots.last ?? ""
                if !val.isEmpty { parts.append(prefix + val) }
            }
            let line = parts.joined(separator: ", ")
            if !line.isEmpty { result.append(line) }
        }
        return result
    }

    var body: some View {
        Section(header: Text("Адрес")) {
            HStack(spacing: 10) {
                Image(systemName: "house")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(formattedAddresses.isEmpty ? [""] : formattedAddresses, id: \.self) { line in
                        Text(line)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
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
                // Строка-заголовок с шевроном
                if let primary = primaryEntry {
                    HStack(spacing: 0) {
                        tagRow(primary.key, primary.value, true)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { isExpanded.toggle() } }
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

// MARK: - TechInfoSection

/// Секция «Техническая информация» — сворачиваемая, всегда read-only.
/// Первичная строка: иконка info.circle + тип+id в формате «n123456789».
/// Вторичные строки: версия, широта, долгота.
private struct TechInfoSection: View {
    let node: OSMNode
    @State private var isExpanded = false

    /// Буква-префикс типа: node→n, way→w, relation→r
    private var typePrefix: String {
        switch node.type {
        case .node:     return "n"
        case .way:      return "w"
        case .relation: return "r"
        }
    }

    /// Первичное значение: «n123456789»
    private var osmRef: String { "\(typePrefix)\(node.id)" }

    /// Ссылка на страницу объекта на openstreetmap.org
    private var osmURL: URL? {
        let typeName: String
        switch node.type {
        case .node:     typeName = "node"
        case .way:      typeName = "way"
        case .relation: typeName = "relation"
        }
        return URL(string: "https://www.openstreetmap.org/\(typeName)/\(node.id)")
    }

    var body: some View {
        Section(header: Text("Техническая информация")) {
            // Внешний HStack — тап по пустому месту сворачивает/разворачивает.
            // Link внутри имеет приоритет над родительским .onTapGesture и открывает URL.
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .center)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OSM ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let url = osmURL {
                            Link(destination: url) {
                                Text(osmRef)
                                    .font(.body)
                                    .foregroundStyle(.blue)
                            }
                        } else {
                            Text(osmRef)
                                .font(.body)
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                withAnimation { isExpanded.toggle() }
            })

            if isExpanded {
                OSMTagRow(tagKey: "version", readOnlyValue: String(node.version))
                OSMTagRow(tagKey: "lat", readOnlyValue: String(format: "%.6f", node.latitude))
                OSMTagRow(tagKey: "lon", readOnlyValue: String(format: "%.6f", node.longitude))
            }
        }
    }
}

// MARK: - LocationPreviewMapView

/// Лёгкая read-only карта MapLibre для превью местоположения POI.
/// Использует тот же MapTiler стиль что и основная карта.
/// Жесты отключены — карта нетапабельна.
struct LocationPreviewMapView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    /// Дополнительные маркеры кандидатов-дублей: (координата, цвет, индекс цвета)
    var extraMarkers: [(coordinate: CLLocationCoordinate2D, color: UIColor, colorIndex: Int)] = []

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView()
        mapView.styleURL = MapStyle.mapTiler
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.showsUserLocation = false
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.allowsTilting = false
        mapView.attributionButton.isHidden = true
        mapView.logoView.isHidden = true
        mapView.compassView.isHidden = true

        mapView.setCenter(coordinate, zoomLevel: 17, animated: false)

        // Маркер
        let annotation = MLNPointAnnotation()
        annotation.coordinate = coordinate
        mapView.addAnnotation(annotation)
        mapView.delegate = context.coordinator

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        // Обновляем центр и маркер при изменении координаты
        mapView.setCenter(coordinate, zoomLevel: 17, animated: false)
        if let existing = mapView.annotations {
            mapView.removeAnnotations(existing)
        }
        let annotation = MLNPointAnnotation()
        annotation.coordinate = coordinate
        mapView.addAnnotation(annotation)

        // Маркеры кандидатов-дублей
        for marker in extraMarkers {
            let ann = DuplicateMarkerAnnotation(
                coordinate: marker.coordinate,
                markerColor: marker.color,
                colorIndex: marker.colorIndex
            )
            mapView.addAnnotation(ann)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            // Маркер кандидата-дубля
            if let dup = annotation as? DuplicateMarkerAnnotation {
                let reuseId = "dup_\(dup.colorIndex % DuplicateCandidate.palette.count)"
                if let existing = mapView.dequeueReusableAnnotationImage(withIdentifier: reuseId) {
                    return existing
                }
                return MLNAnnotationImage(
                    image: Self.renderPin(color: dup.markerColor),
                    reuseIdentifier: reuseId
                )
            }
            let reuseId = "preview_pin"
            if let existing = mapView.dequeueReusableAnnotationImage(withIdentifier: reuseId) {
                return existing
            }
            return MLNAnnotationImage(
                image: Self.renderPin(color: .systemBlue),
                reuseIdentifier: reuseId
            )
        }

        /// Рисует пин заданного цвета с белой точкой внутри.
        /// `size` — итоговый размер изображения (по умолчанию 28×30 для карты).
        static func renderPin(color: UIColor, size: CGSize = CGSize(width: 28, height: 30)) -> UIImage {
            return UIGraphicsImageRenderer(size: size).image { _ in
                let ctx = UIGraphicsGetCurrentContext()!
                let s: CGFloat = size.width / 24.0
                ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3,
                              color: UIColor.black.withAlphaComponent(0.3).cgColor)
                let path = UIBezierPath()
                path.move(to:     CGPoint(x: 12*s, y:  1*s))
                path.addCurve(to: CGPoint(x:  3*s, y: 10*s),
                              controlPoint1: CGPoint(x:  7.03*s, y:  1*s),
                              controlPoint2: CGPoint(x:  3*s,    y:  5.03*s))
                path.addCurve(to: CGPoint(x: 12*s, y: 23*s),
                              controlPoint1: CGPoint(x:  3*s,    y: 16.75*s),
                              controlPoint2: CGPoint(x: 12*s,    y: 23*s))
                path.addCurve(to: CGPoint(x: 21*s, y: 10*s),
                              controlPoint1: CGPoint(x: 12*s,    y: 23*s),
                              controlPoint2: CGPoint(x: 21*s,    y: 16.75*s))
                path.addCurve(to: CGPoint(x: 12*s, y:  1*s),
                              controlPoint1: CGPoint(x: 21*s,    y:  5.03*s),
                              controlPoint2: CGPoint(x: 16.97*s, y:  1*s))
                path.close()
                color.setFill()
                path.fill()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor.white.withAlphaComponent(0.5).setStroke()
                path.lineWidth = 0.75
                path.stroke()
                let cx = 12 * s, cy = 10 * s, r = 3.5 * s
                UIColor.white.setFill()
                UIBezierPath(ovalIn: CGRect(x: cx-r, y: cy-r, width: r*2, height: r*2)).fill()
            }
        }
    }
}

// MARK: - DuplicateMarkerAnnotation

/// Аннотация для маркера кандидата-дубля на превью-карте.
final class DuplicateMarkerAnnotation: MLNPointAnnotation {
    let markerColor: UIColor
    let colorIndex: Int
    init(coordinate: CLLocationCoordinate2D, markerColor: UIColor, colorIndex: Int) {
        self.markerColor = markerColor
        self.colorIndex  = colorIndex
        super.init()
        self.coordinate = coordinate
    }
    required init?(coder: NSCoder) { nil }
}

