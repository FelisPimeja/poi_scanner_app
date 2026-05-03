import SwiftUI
import MapLibre
import CoreLocation
import UIKit

// MARK: - ValidationView
// Редактор тегов POI с цветовой индикацией источника данных

struct ValidationView: View {
    @State var poi: POI
    let sourceImage: UIImage?
    var onSave: ((POI) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    private let authService = OSMAuthService.shared
    @State private var showImagePreview = false
    @State private var showCoordinatePicker = false
    @State private var isSaving = false
    @State private var isUploading = false
    @State private var uploadError: String? = nil
    @State private var showUploadError = false

    // Поиск дублей
    @State private var duplicates: [DuplicateCandidate] = []
    @State private var isCheckingDuplicates = false
    @State private var selectedDuplicate: DuplicateCandidate? = nil
    @State private var isMergeMode = false
    @State private var diffEntries: [TagDiffEntry] = []
    @State private var mergePlaceholderTags: [String: String] = [:]
    @State private var originalExtractedTags: [String: String] = [:]
    @State private var originalCoordinate: POI.Coordinate? = nil

    // Источник координаты (может меняться при ручной правке)
    @State private var coordinateSource: CoordinateSource

    // Теги для отображения в редакторе (приоритетные сначала)
    init(poi: POI, sourceImage: UIImage?, onSave: ((POI) -> Void)? = nil) {
        var poi = poi
        // Если addr:city не заполнен — подставляем последний известный город
        let savedCity = AppSettings.shared.lastCity
        if poi.tags["addr:city"] == nil, !savedCity.isEmpty {
            poi.tags["addr:city"] = savedCity
        }
        _poi = State(initialValue: poi)
        self.sourceImage = sourceImage
        self.onSave = onSave
        _coordinateSource = State(initialValue: poi.coordinateSource)
    }

    private let priorityKeys = [
        "name", "amenity", "shop", "office",
        "addr:street", "addr:housenumber", "addr:city", "addr:postcode",
        "phone", "website", "opening_hours",
        "ref:INN", "ref:OGRN"
    ]

    private var sortedTags: [(key: String, value: String)] {
        let allKeys = Set(poi.tags.keys).union(priorityKeys.filter { poi.tags[$0] != nil })
        return allKeys
            .sorted { a, b in
                let ai = priorityKeys.firstIndex(of: a) ?? 999
                let bi = priorityKeys.firstIndex(of: b) ?? 999
                return ai == bi ? a < b : ai < bi
            }
            .compactMap { key in
                poi.tags[key].map { (key: key, value: $0) }
            }
    }

    var body: some View {
        NavigationStack {
            List {
                // Фото превью
                if let image = sourceImage {
                    Section {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .onTapGesture { showImagePreview = true }
                    }
                }

                // Карта + координаты + кандидаты
                locationSection

                if isMergeMode {
                    mergeDiffSection
                } else {
                    // Теги
                    Section {
                        ForEach(sortedTags, id: \.key) { item in
                            OSMTagRow(
                                tagKey: item.key,
                                editableValue: Binding(
                                    get: { poi.tags[item.key] ?? "" },
                                    set: { newVal in
                                        poi.tags[item.key] = newVal.isEmpty ? nil : newVal
                                        poi.fieldStatus[item.key] = .confirmed
                                    }
                                ),
                                status: poi.fieldStatus[item.key] ?? .manual
                            )
                            .listRowSeparator(.hidden)
                        }
                    }

                    // Добавить тег
                    Section {
                        AddTagRow { key, value in
                            poi.tags[key] = value
                            poi.fieldStatus[key] = .manual
                        }
                    }
                }
            }
            .navigationTitle(poi.tags["name"] ?? "Новый POI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Загрузить в OSM
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
                    // Сохранить локально
                    Button {
                        save()
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
            .alert("Ошибка загрузки", isPresented: $showUploadError) {
                Button("Скопировать") {
                    UIPasteboard.general.string = uploadError
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(uploadError ?? "Неизвестная ошибка")
            }
            .fullScreenCover(isPresented: $showImagePreview) {
                if let image = sourceImage {
                    ImagePreviewView(image: image)
                }
            }
            .sheet(isPresented: $showCoordinatePicker) {
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
            .task {
                // Фоновая проверка дублей
                guard poi.osmNodeId == nil else { return }  // только для новых POI
                isCheckingDuplicates = true
                do {
                    duplicates = try await DuplicateChecker.shared
                        .findDuplicates(near: poi, radiusMeters: searchRadiusMeters)
                } catch {
                    // Ошибка сети — молча игнорируем, не блокируем UI
                }
                isCheckingDuplicates = false
            }
            .onChange(of: poi.coordinate) { _, _ in
                // Повторный поиск дублей после ручной корректировки координат
                guard poi.osmNodeId == nil else { return }
                // Выходим из режима слияния — старый кандидат может быть уже неактуален
                if isMergeMode {
                    isMergeMode = false
                    selectedDuplicate = nil
                    diffEntries = []
                    mergePlaceholderTags = [:]
                }
                duplicates = []
                isCheckingDuplicates = true
                let radius = searchRadiusMeters
                Task {
                    do {
                        let found = try await DuplicateChecker.shared.findDuplicates(near: poi, radiusMeters: radius)
                        duplicates = found
                    } catch {}
                    isCheckingDuplicates = false
                }
            }
        }
    }

    // MARK: - Location section

    private var candidatesWithColors: [(candidate: DuplicateCandidate, color: UIColor)] {
        duplicates.enumerated().map { (i, c) in
            (c, DuplicateCandidate.palette[i % DuplicateCandidate.palette.count])
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        let lat = poi.coordinate.latitude
        let lon = poi.coordinate.longitude
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let extraMarkers = candidatesWithColors.enumerated().map { (i, item) in
            (coordinate: CLLocationCoordinate2D(
                latitude: item.candidate.node.latitude,
                longitude: item.candidate.node.longitude
            ), color: item.color, colorIndex: i)
        }

        Section {
            LocationPreviewMapView(
                coordinate: coord,
                extraMarkers: extraMarkers,
                accuracyMeters: searchRadiusMeters
            )
                .frame(height: 148)
                .listRowInsets(EdgeInsets())
                .clipShape(Rectangle())
                .contentShape(Rectangle())
                .onTapGesture { showCoordinatePicker = true }

            HStack(spacing: 10) {
                Image(uiImage: LocationPreviewMapView.Coordinator.renderPin(
                    color: .systemBlue, size: CGSize(width: 20, height: 22), shadow: false))
                    .frame(width: 24, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dmsString(lat: lat, lon: lon))
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                    Text(sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Радиобаттон — всегда "выбран" когда активна строка координат (не merge-режим)
                Image(systemName: isMergeMode ? "circle" : "record.circle")
                    .foregroundStyle(isMergeMode ? Color.secondary : Color.accentColor)
                    .font(.title3)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isMergeMode {
                    // Возврат к созданию нового — отменяем merge
                    withAnimation {
                        isMergeMode = false
                        selectedDuplicate = nil
                        poi.tags = originalExtractedTags
                        if let orig = originalCoordinate { poi.coordinate = orig }
                    }
                } else {
                    showCoordinatePicker = true
                }
            }

            // Поиск / результаты дублей
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

    // MARK: - Merge sections

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
                    }
                }
            }
        }

        // Плейсхолдеры — основные теги, отсутствующие в обоих источниках
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
                            set: { newVal in
                                // Сохраняем пустую строку пока идёт ввод — иначе строка
                                // исчезает сразу при тапе (TextField временно пуст).
                                // nil выставляем только если ключ явно удалён снаружи.
                                mergePlaceholderTags[key] = newVal
                            }
                        ),
                        status: .manual
                    )
                    .listRowSeparator(.hidden)
                }
            }
        }
    }

    // MARK: - Merge helpers

    private func applyMerge(with candidate: DuplicateCandidate? = nil) {
        let resolved = candidate ?? selectedDuplicate
        guard let resolved else { return }
        selectedDuplicate = resolved
        originalExtractedTags = poi.tags
        originalCoordinate    = poi.coordinate
        // Переключаемся на существующий OSM-узел
        poi.osmNodeId  = resolved.node.id
        poi.osmVersion = resolved.node.version
        poi.osmType    = .node
        poi.coordinate = POI.Coordinate(
            latitude: resolved.node.latitude,
            longitude: resolved.node.longitude
        )
        diffEntries = TagDiffEntry.build(
            osmTags: resolved.node.tags,
            extractedTags: originalExtractedTags
        )
        // Плейсхолдеры: основные теги, отсутствующие в обоих источниках
        // Учитываем псевдонимы contact: чтобы phone/contact:phone не дублировались
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
        withAnimation { isMergeMode = true }
    }

    private func syncMergedTags() {
        guard isMergeMode else { return }
        var merged: [String: String] = [:]
        for entry in diffEntries {
            if let val = entry.resolvedValue {
                merged[entry.key] = val
            }
        }
        // Плейсхолдеры: включаем только непустые
        for (key, value) in mergePlaceholderTags where !value.isEmpty {
            merged[key] = value
        }
        poi.tags = merged
    }

    /// Сохраняет addr:city в AppSettings, если тег заполнен.
    private func persistCity() {
        if let city = poi.tags["addr:city"], !city.isEmpty {
            AppSettings.shared.lastCity = city
        }
    }

    /// Проставляет check_date только если пользователь его не редактировал вручную.
    /// Источник из фото → дата съёмки; иначе → сегодня.
    private func applyCheckDate() {
        // Если пользователь явно выставил значение вручную — не перезаписываем
        if poi.fieldStatus["check_date"] == .confirmed { return }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let date: Date
        switch coordinateSource {
        case .photo:
            date = poi.photoDate ?? Date()
        default:
            date = Date()
        }
        poi.tags["check_date"] = fmt.string(from: date)
        poi.fieldStatus["check_date"] = .confirmed
    }

    private func dmsString(lat: Double, lon: Double) -> String {
        String(format: "%.4f°,  %.4f°", lat, lon)
    }

    // MARK: - Accuracy helpers

    /// Точность в метрах для текущего источника координат (photo или gps).
    private var accuracyForSearch: Double? {
        switch coordinateSource {
        case .photo:  return poi.photoAccuracy
        case .gps:    return poi.gpsAccuracy
        default:      return nil
        }
    }

    /// Радиус поиска дублей: 1.5× точности, округлённый вверх до кратного 50м. Минимум 50м.
    private var searchRadiusMeters: Double {
        guard let acc = accuracyForSearch, acc > 0 else { return 50 }
        return max(50, min(1000, ceil(acc * 1.5 / 50) * 50))
    }

    /// Точность, показываемая пользователю — округлена до кратного 50м.
    private var displayAccuracyMeters: Int? {
        guard let acc = accuracyForSearch, acc > 0 else { return nil }
        return Int(ceil(acc / 50) * 50)
    }

    /// Подпись источника координат с указанием погрешности, если известна.
    private var sourceLabel: String {
        let base = coordinateSource.label
        guard let meters = displayAccuracyMeters else { return base }
        return "\(base), погрешность ~\(meters)м"
    }

    private var legendHeader: some View {
        HStack(spacing: 16) {
            ForEach(FieldStatus.allCases, id: \.self) { status in
                Label(status.label, systemImage: "circle.fill")
                    .foregroundStyle(status.color)
                    .font(.caption2)
            }
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }

    /// Возвращает ключевое окно для ASWebAuthenticationSession.
    /// keyWindow имеет приоритет над windows.first — иначе iOS может вернуть
    /// фоновое/оверлейное окно, что вызывает presentationContextNotProvided (error 2).
    private func presentationAnchor() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .compactMap { scene -> UIWindow? in scene.keyWindow ?? scene.windows.first }
            .first
    }

    private func save() {
        syncMergedTags()
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
        syncMergedTags()
        applyCheckDate()
        persistCity()
        // Авторизуемся при необходимости
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
        uploading.status = .uploading
        onSave?(uploading)

        do {
            let uploaded = try await OSMAPIService.shared.upload(poi: poi)
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
}

// MARK: - MergeTagRow

struct MergeTagRow: View {
    @Binding var entry: TagDiffEntry

    var body: some View {
        switch entry.kind {
        case .conflict: conflictView
        case .newTag:   newTagView
        case .osmOnly:  osmOnlyView
        case .same:     sameView
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

            checkboxOption(
                label: entry.osmValue ?? "—",
                badge: "OSM",
                badgeColor: .secondary,
                isChecked: osmChecked,
                action: { toggleOSM() }
            )
            checkboxOption(
                label: entry.extractedValue ?? "—",
                badge: "Новое",
                badgeColor: .blue,
                isChecked: extChecked,
                action: { toggleExtracted() }
            )
        }
        .padding(.vertical, 4)
    }

    private func toggleOSM() {
        switch entry.resolution {
        case .useOSM:       entry.resolution = .useExtracted   // снять ОSM → оставить только Новое
        case .useExtracted: entry.resolution = .both           // добавить OSM → оба
        case .both:         entry.resolution = .useExtracted   // снять OSM → только Новое
        default:            entry.resolution = .useOSM
        }
    }

    private func toggleExtracted() {
        switch entry.resolution {
        case .useExtracted: entry.resolution = .useOSM         // снять Новое → только OSM
        case .useOSM:       entry.resolution = .both           // добавить Новое → оба
        case .both:         entry.resolution = .useOSM         // снять Новое → только OSM
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

    // MARK: Новый тег — радио-включить/исключить + OSMTagRow для редактирования

    private var newTagView: some View {
        HStack(alignment: .center, spacing: 10) {
            // Радио: включить / исключить
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if entry.resolution == .keepOSM {
                        // Восстанавливаем: если текст менялся — custom, иначе extracted
                        entry.resolution = entry.customEditText == (entry.extractedValue ?? "")
                            ? .useExtracted
                            : .custom(entry.customEditText)
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

            // Полноценный OSMTagRow — использует словари, редактор часов и пр.
            OSMTagRow(
                tagKey: entry.key,
                editableValue: Binding(
                    get: { entry.customEditText },
                    set: { newVal in
                        entry.customEditText = newVal
                        entry.resolution = newVal.isEmpty
                            ? .keepOSM
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
                    entry.resolution = newVal == (entry.osmValue ?? "")
                        ? .keepOSM
                        : .custom(newVal)
                }
            ),
            status: .confirmed
        )
    }

    // MARK: Совпадающий тег — read-only, просто показываем значение

    private var sameView: some View {
        OSMTagRow(
            tagKey: entry.key,
            readOnlyValue: entry.osmValue,
            editableValue: nil,
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

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 6.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let newScale = min(maxScale, max(minScale, lastScale * value))
                                    scale = newScale
                                }
                                .onEnded { value in
                                    lastScale = scale
                                    // Если вернулись к минимуму — сбрасываем смещение
                                    if scale <= minScale {
                                        withAnimation(.spring()) { offset = .zero }
                                        lastOffset = .zero
                                    }
                                },
                            DragGesture()
                                .onChanged { value in
                                    guard scale > minScale else { return }
                                    offset = CGSize(
                                        width:  lastOffset.width  + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            if scale > minScale {
                                scale = minScale
                                lastScale = minScale
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 3.0
                                lastScale = 3.0
                            }
                        }
                    }
            }

            // Кнопка закрытия
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.5))
            }
            .padding(.top, 56)
            .padding(.trailing, 20)
        }
        .statusBarHidden(true)
        .ignoresSafeArea()
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
