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
    @State private var originalExtractedTags: [String: String] = [:]
    @State private var originalCoordinate: POI.Coordinate? = nil

    // Теги для отображения в редакторе (приоритетные сначала)
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
                    cancelMergeSection
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
            .sheet(isPresented: $showImagePreview) {
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
                        .findDuplicates(near: poi)
                } catch {
                    // Ошибка сети — молча игнорируем, не блокируем UI
                }
                isCheckingDuplicates = false
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
            LocationPreviewMapView(coordinate: coord, extraMarkers: extraMarkers)
                .frame(height: 148)
                .listRowInsets(EdgeInsets())
                .clipShape(Rectangle())

            HStack(spacing: 10) {
                Image(uiImage: LocationPreviewMapView.Coordinator.renderPin(color: .systemBlue, size: CGSize(width: 18, height: 20)))
                    .frame(width: 24, alignment: .center)
                Text(dmsString(lat: lat, lon: lon))
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { showCoordinatePicker = true }

            // Поиск / результаты дублей
            if isCheckingDuplicates && duplicates.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text("Поиск похожих мест…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if !duplicates.isEmpty && !isMergeMode {
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
                if index > 0 { Divider().padding(.leading, 22) }
                Button {
                    withAnimation { selectedDuplicate = isSelected ? nil : item.candidate }
                } label: {
                    HStack(spacing: 10) {
                        Image(uiImage: LocationPreviewMapView.Coordinator.renderPin(
                            color: item.color,
                            size: CGSize(width: 18, height: 20)
                        ))
                        .frame(width: 24, alignment: .center)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.candidate.displayName)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(String(format: "%.0f м", item.candidate.distance))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }

            if selectedDuplicate != nil {
                HStack(spacing: 8) {
                    Button { applyMerge() } label: {
                        Text("Переключиться и обновить")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        withAnimation { selectedDuplicate = nil }
                    } label: {
                        Text("+ Добавить как новое")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
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
        let osmOnly   = diffEntries.filter { $0.kind == .osmOnly }

        if !conflicts.isEmpty {
            Section(header: Text("Конфликты")) {
                ForEach($diffEntries) { $entry in
                    if entry.kind == .conflict { MergeTagRow(entry: $entry) }
                }
            }
        }
        if !newTags.isEmpty {
            Section(header: Text("Новые теги")) {
                ForEach($diffEntries) { $entry in
                    if entry.kind == .newTag { MergeTagRow(entry: $entry) }
                }
            }
        }
        if !osmOnly.isEmpty {
            Section(header: Text("Теги OSM (сохраняются)")) {
                ForEach($diffEntries) { $entry in
                    if entry.kind == .osmOnly { MergeTagRow(entry: $entry) }
                }
            }
        }
    }

    @ViewBuilder
    private var cancelMergeSection: some View {
        Section {
            Button(role: .destructive) {
                withAnimation {
                    isMergeMode = false
                    selectedDuplicate = nil
                    diffEntries = []
                    // Восстанавливаем исходные данные
                    poi.osmNodeId  = nil
                    poi.osmVersion = nil
                    poi.osmType    = nil
                    if let orig = originalCoordinate { poi.coordinate = orig }
                    poi.tags = originalExtractedTags
                }
            } label: {
                Label("Добавить как новое место", systemImage: "plus.circle")
            }
        }
    }

    // MARK: - Merge helpers

    private func applyMerge() {
        guard let candidate = selectedDuplicate else { return }
        originalExtractedTags = poi.tags
        originalCoordinate    = poi.coordinate
        // Переключаемся на существующий OSM-узел
        poi.osmNodeId  = candidate.node.id
        poi.osmVersion = candidate.node.version
        poi.osmType    = .node
        poi.coordinate = POI.Coordinate(
            latitude: candidate.node.latitude,
            longitude: candidate.node.longitude
        )
        diffEntries = TagDiffEntry.build(
            osmTags: candidate.node.tags,
            extractedTags: originalExtractedTags
        )
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
        poi.tags = merged
    }

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
        isSaving = true
        var saved = poi
        saved.status = .validated
        onSave?(saved)
        dismiss()
    }

    @MainActor
    private func uploadToOSM() async {
        syncMergedTags()
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

private struct MergeTagRow: View {
    @Binding var entry: TagDiffEntry

    var body: some View {
        switch entry.kind {
        case .conflict: conflictView
        case .newTag:   newTagView
        case .osmOnly:  osmOnlyView
        case .same:     EmptyView()
        }
    }

    // Конфликт — два варианта с радио-кнопками
    private var conflictView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(OSMTags.definition(for: entry.key)?.label ?? entry.key)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                entry.resolution = .useOSM
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: entry.resolution == .useOSM ? "circle.fill" : "circle")
                        .foregroundStyle(entry.resolution == .useOSM ? Color.accentColor : Color.secondary)
                    Text(entry.osmValue ?? "—")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("OSM")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Button {
                entry.resolution = .useExtracted
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: entry.resolution == .useExtracted ? "circle.fill" : "circle")
                        .foregroundStyle(entry.resolution == .useExtracted ? Color.accentColor : Color.secondary)
                    Text(entry.extractedValue ?? "—")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("Новое")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // Новый тег — переключатель включить/выключить
    private var newTagView: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(OSMTags.definition(for: entry.key)?.label ?? entry.key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.extractedValue ?? "")
                    .foregroundStyle(.primary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { entry.resolution == .useExtracted },
                set: { entry.resolution = $0 ? .useExtracted : .keepOSM }
            ))
            .labelsHidden()
        }
    }

    // Тег только в OSM — read-only, сохраняется
    private var osmOnlyView: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(OSMTags.definition(for: entry.key)?.label ?? entry.key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.osmValue ?? "")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("OSM")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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

private struct ImagePreviewView: View {
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
