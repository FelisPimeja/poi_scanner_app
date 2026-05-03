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

        // Sheet: просмотр информации о существующей ноде
        .sheet(item: $viewModel.selectedNode) { node in
            OSMNodeInfoView(
                initialNode: node,
                viewModel: viewModel,
                onSave: { updatedPOI in
                    viewModel.saveDraftPOI(updatedPOI)
                    viewModel.selectedNode = nil
                },
                onClose: {
                    viewModel.selectedNode = nil
                }
            )
        }

        // Sheet: CaptureView для нового POI
        .sheet(isPresented: $viewModel.isAddingPOI) {
            CaptureView(
                onCapture: { image, coord, acc, date in
                    viewModel.isAddingPOI = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        extractionItemForNew = IdentifiableImage(image: image, coordinate: coord,
                                                                 accuracy: acc, captureDate: date)
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
                    photoAccuracy: wrapper.accuracy,
                    photoDate: wrapper.captureDate,
                    onSave: { savedPOI in
                        viewModel.saveDraftPOI(savedPOI)
                        viewModel.centerOn(coordinate: CLLocationCoordinate2D(
                            latitude: savedPOI.coordinate.latitude,
                            longitude: savedPOI.coordinate.longitude
                        ))
                    }
                )
            }
            .presentationDetents([.large])
            .onAppear { viewModel.pendingPOICoordinate = wrapper.coordinate }
            .onDisappear { viewModel.pendingPOICoordinate = nil }
        }

        // Sheet: редактирование черновика POI (тап на оранжевый маркер)
        .sheet(item: $viewModel.selectedDraftPOI) { draft in
            NavigationStack {
                POIEditorView(
                    poi: draft,
                    mode: .new(sourceImage: nil),
                    onSave: { updatedPOI in
                        viewModel.updateDraftPOI(updatedPOI)
                    }
                )
            }
            .presentationDetents([.large])
        }

        // Sheet: ручное добавление нового POI (Пропустить из CaptureView)
        .sheet(item: $manualPOIForNew) { emptyPOI in
            NavigationStack {
                POIEditorView(
                    poi: emptyPOI,
                    mode: .new(sourceImage: nil),
                    onSave: { savedPOI in
                        viewModel.saveDraftPOI(savedPOI)
                        viewModel.centerOn(coordinate: CLLocationCoordinate2D(
                            latitude: savedPOI.coordinate.latitude,
                            longitude: savedPOI.coordinate.longitude
                        ))
                    }
                )
            }
            .presentationDetents([.large])
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

// MARK: - IdentifiableImage (для .sheet(item:))

// MARK: - IdentifiableImage (для .sheet(item:))

struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let coordinate: CLLocationCoordinate2D?   // GPS из фото, зашит в момент создания
    let accuracy: Double?                     // горизонтальная погрешность GPS из EXIF (метры)
    let captureDate: Date?                    // дата съёмки из EXIF
}

// MARK: - TagPair (модель строки в Tags-режиме)

struct TagPair: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

// MARK: - TagPairRow

struct TagPairRow: View {
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
struct CollapsibleLegalSection<Row: View>: View {
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
struct CollapsibleBrandSection<Row: View>: View {
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

// MARK: - CollapsibleNameSection

/// Секция «Название»:
/// • По умолчанию свёрнута — показывает только главный name-тег + шеврон.
/// • Разворачивается → все name-теги без дополнительного отступа.
/// • Главный тег: первый из OSMTags.nameKeys, присутствующий в entries.
/// • Языковые варианты (key:lang) показываются сразу под своим базовым ключом
///   с отступом и названием языка вместо полного ключа.
struct CollapsibleNameSection<Row: View>: View {
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

    // MARK: Language grouping

    /// Группирует entries: возвращает список (baseKey, baseEntry?, [langEntry])
    /// baseKey — ключ до «:», langEntries — ключи с «:lang» постфиксом того же базового ключа.
    private struct KeyGroup {
        let baseKey: String
        let baseEntry: (key: String, value: String)?
        let langEntries: [(key: String, value: String)]
    }

    private var keyGroups: [KeyGroup] {
        // Порядок базовых ключей сохраняем по первому появлению
        var order: [String] = []
        var bases: [String: (key: String, value: String)] = [:]
        var langs: [String: [(key: String, value: String)]] = [:]

        // Базовые ключи, которые сами содержат «:» — разбиваем по последнему двоеточию
        let compoundBases: [String] = ["was:name", "official_name", "old_name", "alt_name", "short_name"]

        for entry in entries {
            // Ищем совпадение с составным базовым ключом (например was:name:ru)
            var matched = false
            for compound in compoundBases {
                let prefix = compound + ":"
                if entry.key.hasPrefix(prefix) {
                    let langCode = String(entry.key.dropFirst(prefix.count))
                    let isLang = langCode.count >= 2 && langCode.count <= 5
                        && langCode.allSatisfy({ $0.isLetter || $0 == "-" })
                    if isLang {
                        if !order.contains(compound) { order.append(compound) }
                        langs[compound, default: []].append(entry)
                        matched = true
                        break
                    }
                }
                if entry.key == compound {
                    if !order.contains(compound) { order.append(compound) }
                    bases[compound] = entry
                    matched = true
                    break
                }
            }
            if matched { continue }

            let parts = entry.key.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let base = String(parts[0])
                let langCode = String(parts[1])
                // Считаем postfix языковым, если это 2–5 букв (ISO 639)
                let isLang = langCode.count >= 2 && langCode.count <= 5
                    && langCode.allSatisfy({ $0.isLetter || $0 == "-" })
                if isLang {
                    if !order.contains(base) { order.append(base) }
                    langs[base, default: []].append(entry)
                    continue
                }
            }
            // Базовый ключ без языкового постфикса
            let base = entry.key
            if !order.contains(base) { order.append(base) }
            bases[base] = entry
        }

        return order.map { base in
            KeyGroup(baseKey: base, baseEntry: bases[base], langEntries: langs[base] ?? [])
        }
    }

    /// Возвращает человекочитаемое название языка по коду.
    private func languageName(for code: String) -> String {
        let locale = Locale(identifier: "ru")
        return locale.localizedString(forLanguageCode: code)
            ?? code.uppercased()
    }

    var body: some View {
        Section {
            let groups = keyGroups
            let hasSecondary = groups.count > 1
                || (groups.first?.langEntries.isEmpty == false)

            if !hasSecondary {
                // Только один ключ без языковых вариантов
                if let primary = primaryEntry {
                    tagRow(primary.key, primary.value, true)
                }
            } else {
                // Строка-заголовок с шевроном (главный тег)
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
                    // Рендерим все группы: базовый ключ + его языковые варианты
                    ForEach(groups, id: \.baseKey) { group in
                        // Базовый ключ (если не главный — уже показан выше)
                        if let baseEntry = group.baseEntry, baseEntry.key != primaryEntry?.key {
                            tagRow(baseEntry.key, baseEntry.value, false)
                        }
                        // Языковые варианты с отступом (включая языки главного ключа)
                        ForEach(group.langEntries, id: \.key) { lang in
                            let parts = lang.key.split(separator: ":", maxSplits: 1)
                            let langCode = parts.count == 2 ? String(parts[1]) : lang.key
                            let isLast = group.langEntries.last?.key == lang.key
                                && groups.last?.baseKey == group.baseKey
                            LangTagRow(
                                langName: languageName(for: langCode),
                                osmKey: lang.key,
                                value: lang.value,
                                isLast: isLast
                            )
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
        } header: {
            if isEditable { Text("Название") }
        }
    }
}

// MARK: - LangTagRow

/// Строка языкового варианта: небольшой отступ слева, название языка (caption) + значение.
private struct LangTagRow: View {
    let langName: String
    let osmKey: String
    let value: String
    var isLast: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // Спейсер шире, чем leadingIndicator якорных строк (24pt) — создаёт визуальную вложенность
            Color.clear.frame(width: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("– \(langName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 0)
        .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: isLast ? 11 : 3, trailing: 16))
    }
}

// MARK: - TechInfoSection

/// Секция «Техническая информация» — сворачиваемая, всегда read-only.
/// Первичная строка: иконка info.circle + тип+id в формате «n123456789».
/// Вторичные строки: версия (→ История), координаты центра.
struct TechInfoSection: View {
    let node: OSMNode
    @State private var isExpanded = false
    @State private var showHistory = false

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

    /// Координаты в формате "55.7558, 37.6173"
    private var coordString: String {
        String(format: "%.4f, %.4f", node.latitude, node.longitude)
    }

    var body: some View {
        Section(header: Text("Техническая информация")) {
            // ── OSM ID (сворачивающаяся строка) ──────────────────────
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
                // ── Версия → История ──────────────────────────────────
                Button {
                    showHistory = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Версия")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(node.version))
                                .font(.body)
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .fullScreenCover(isPresented: $showHistory) {
                    OSMNodeHistoryScreen(nodeID: node.id, nodeType: node.type)
                }

                // ── Координаты центра ─────────────────────────────────
                HStack(spacing: 10) {
                    Image(systemName: "location")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .center)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Координаты центра")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(coordString)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
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
    /// Минимальный радиус видимой области в метрах (например, из погрешности GPS).
    /// Nil = авто по маркерам или zoom 17 если маркеров нет.
    var accuracyMeters: Double? = nil

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

        applyCamera(to: mapView, animated: false)

        // Маркер
        let annotation = MLNPointAnnotation()
        annotation.coordinate = coordinate
        mapView.addAnnotation(annotation)
        mapView.delegate = context.coordinator

        return mapView
    }

    // MARK: - Camera

    /// Вычисляет bbox по всем точкам (POI + кандидаты) с учётом минимального радиуса точности.
    /// При отсутствии кандидатов и точности — устанавливает zoom 17.
    private func applyCamera(to mapView: MLNMapView, animated: Bool) {
        let allCoords = [coordinate] + extraMarkers.map(\.coordinate)

        // Минимальный отступ в градусах от точности (accuracyMeters → °)
        // 1° широты ≈ 111 000 м
        let minDeltaDeg = (accuracyMeters ?? 0) / 111_000.0

        if allCoords.count == 1 && minDeltaDeg == 0 {
            // Нет кандидатов и нет заданной точности — фиксированный zoom
            mapView.setCenter(coordinate, zoomLevel: 17, animated: animated)
            return
        }

        // cameraThatFitsCoordinateBounds требует ненулевой фрейм карты.
        // Если view ещё не разложена (makeUIView до layout) — падаем на разумный zoom.
        guard mapView.frame.width > 0 && mapView.frame.height > 0 else {
            mapView.setCenter(coordinate, zoomLevel: 15, animated: animated)
            return
        }

        var minLat = allCoords.map(\.latitude).min()!
        var maxLat = allCoords.map(\.latitude).max()!
        var minLon = allCoords.map(\.longitude).min()!
        var maxLon = allCoords.map(\.longitude).max()!

        // Расширяем bbox до минимального радиуса точности
        let center = coordinate
        minLat = min(minLat, center.latitude  - minDeltaDeg)
        maxLat = max(maxLat, center.latitude  + minDeltaDeg)
        // longitude degrees per meter зависит от широты
        let lonDeg = minDeltaDeg / max(cos(center.latitude * .pi / 180), 0.01)
        minLon = min(minLon, center.longitude - lonDeg)
        maxLon = max(maxLon, center.longitude + lonDeg)

        // Добавляем padding 25% чтобы пины не упирались в края
        let latPad = (maxLat - minLat) * 0.25
        let lonPad = (maxLon - minLon) * 0.25
        let sw = CLLocationCoordinate2D(latitude:  minLat - latPad, longitude: minLon - lonPad)
        let ne = CLLocationCoordinate2D(latitude:  maxLat + latPad, longitude: maxLon + lonPad)
        let bounds = MLNCoordinateBounds(sw: sw, ne: ne)

        let insets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let camera = mapView.cameraThatFitsCoordinateBounds(bounds, edgePadding: insets)
        // Ограничиваем диапазон зума: altitude ~600м ≈ zoom 15, ~150м ≈ zoom 17.
        // cameraThatFits может вернуть слишком широкий охват — зажимаем высоту.
        camera.altitude = min(max(camera.altitude, 150), 600)
        mapView.setCamera(camera, animated: animated)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.parent = self
        // Обновляем центр/bbox и маркеры при изменении координаты или кандидатов
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

        applyCamera(to: mapView, animated: true)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: LocationPreviewMapView

        init(parent: LocationPreviewMapView) { self.parent = parent }

        // После загрузки стиля фрейм уже установлен — пересчитываем bbox корректно.
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            parent.applyCamera(to: mapView, animated: false)
        }

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
        /// `shadow` — рисовать ли тень (отключать для inline UI).
        static func renderPin(color: UIColor, size: CGSize = CGSize(width: 28, height: 30), shadow: Bool = true) -> UIImage {
            return UIGraphicsImageRenderer(size: size).image { _ in
                let ctx = UIGraphicsGetCurrentContext()!
                let s: CGFloat = size.width / 24.0
                if shadow {
                    ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3,
                                  color: UIColor.black.withAlphaComponent(0.3).cgColor)
                }
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
                if shadow { ctx.setShadow(offset: .zero, blur: 0, color: nil) }
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

