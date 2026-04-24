import SwiftUI

// MARK: - ValidationView
// Редактор тегов POI с цветовой индикацией источника данных

struct ValidationView: View {
    @State var poi: POI
    let sourceImage: UIImage?
    var onSave: ((POI) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    private let authService = OSMAuthService.shared
    @State private var showImagePreview = false
    @State private var isSaving = false
    @State private var isUploading = false
    @State private var uploadError: String? = nil
    @State private var showUploadError = false

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
        }
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
        isSaving = true
        var saved = poi
        saved.status = .validated
        onSave?(saved)
        dismiss()
    }

    @MainActor
    private func uploadToOSM() async {
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
