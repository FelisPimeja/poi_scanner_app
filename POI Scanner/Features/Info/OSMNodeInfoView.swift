import SwiftUI
import CoreLocation

// MARK: - OSMNodeInfoView
//
// Экран просмотра информации о существующем OSM-объекте.
// Открывается при тапе на маркер на карте (.medium detent).
// Кнопка «Карандаш» разворачивает sheet до .large и переходит
// к POIEditorView внутри того же NavigationStack — без нового листа.

struct OSMNodeInfoView: View {

    let initialNode: OSMNode
    @ObservedObject var viewModel: MapViewModel
    var onSave: ((POI) -> Void)? = nil
    let onClose: () -> Void

    /// Актуальная нода: обновляется после загрузки полных деталей.
    private var node: OSMNode { viewModel.selectedNodeDetails ?? initialNode }
    private var isLoadingDetails: Bool { viewModel.isLoadingDetails }

    @State private var isEditing = false
    @State private var selectedDetent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            List {
                tagListSection
            }
            .navigationTitle(nodeTypeLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(isPresented: $isEditing) {
                POIEditorView(
                    poi: node.toPOI(),
                    mode: .edit(node: node, viewModel: viewModel),
                    onSave: onSave
                )
            }
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
    }

    // MARK: - Tag list (read-only)

    @ViewBuilder
    private var tagListSection: some View {
        if isLoadingDetails {
            Section {
                HStack {
                    ProgressView()
                    Text("Загружаем теги…")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
            }
        } else if node.tags.isEmpty {
            Section {
                Text("Нет тегов").foregroundStyle(.secondary)
            }
        } else {
            let grouped = groupedEntries(from: node.tags)

            ForEach(OSMTagDefinition.TagGroup.allCases, id: \.self) { group in
                let entries = grouped[group] ?? []
                if !entries.isEmpty {
                    if group == .type {
                        Section(header: Text("Основные")) {
                            ForEach(entries, id: \.key) { item in
                                OSMTagRow(tagKey: item.key, readOnlyValue: item.value)
                            }
                        }
                    } else if group == .name {
                        CollapsibleNameSection(
                            entries: entries,
                            isEditable: false,
                            tagRow: { key, value, isPrimary in
                                OSMTagRow(tagKey: key, readOnlyValue: value, hideIcon: true, isPrimary: isPrimary)
                            }
                        )
                    } else if group == .brand {
                        CollapsibleBrandSection(
                            entries: entries,
                            isEditable: false,
                            tagRow: { key, value in
                                OSMTagRow(tagKey: key, readOnlyValue: value)
                            }
                        )
                    } else if group == .legal {
                        CollapsibleLegalSection(
                            entries: entries,
                            isEditable: false,
                            tagRow: { key, value in
                                OSMTagRow(tagKey: key, readOnlyValue: value)
                            }
                        )
                    } else if group == .payment {
                        PaymentTagSection(entries: entries)
                    } else if group == .address {
                        AddressTagSection(entries: entries)
                    } else {
                        Section(header: Text(group.rawValue)) {
                            ForEach(entries, id: \.key) { item in
                                OSMTagRow(tagKey: item.key, readOnlyValue: item.value)
                            }
                        }
                    }
                }
            }
        }

        TechInfoSection(node: node)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                onClose()
            } label: {
                Image(systemName: "chevron.down")
                    .fontWeight(.semibold)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                selectedDetent = .large
                // Небольшая задержка даёт sheet время раскрыться до .large
                // перед тем как NavigationStack пушит следующий экран.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    isEditing = true
                }
            } label: {
                Image(systemName: "pencil")
            }
            .disabled(isLoadingDetails)
        }
    }

    // MARK: - Helpers

    private var nodeTypeLabel: String {
        let primaryKeys = ["amenity", "shop", "tourism", "office",
                           "leisure", "craft", "healthcare", "emergency"]
        for key in primaryKeys {
            guard let value = node.tags[key] else { continue }
            // Берём человекочитаемый label из определений, иначе raw value
            if let label = OSMTags.definition(for: "\(key)=\(value)")?.label
                ?? OSMTags.definition(for: value)?.label {
                return label
            }
            // Фоллбэк: capitalise первой буквы value
            return value.prefix(1).uppercased() + value.dropFirst().replacingOccurrences(of: "_", with: " ")
        }
        return node.type == .way ? "Путь" : node.type == .relation ? "Отношение" : "Объект"
    }

    private func groupedEntries(from tags: [String: String])
        -> [OSMTagDefinition.TagGroup: [(key: String, value: String)]] {
        var result: [OSMTagDefinition.TagGroup: [(key: String, value: String)]] = [:]
        for key in tags.keys.sorted(by: groupSortKey) {
            guard let value = tags[key] else { continue }
            if key == "type" && value == "multipolygon" { continue }
            result[resolvedGroup(for: key), default: []].append((key: key, value: value))
        }
        return result
    }

    private let priorityKeys = [
        "name", "amenity", "shop", "office", "tourism",
        "addr:street", "addr:housenumber", "addr:city", "addr:postcode",
        "phone", "contact:phone", "website", "contact:website",
        "email", "contact:email", "opening_hours"
    ]

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

    private let baseTypeKeys: Set<String> = ["amenity", "shop", "craft", "public_transport", "healthcare", "tourism"]

    /// Ключи из пресетов активного типа, которые должны показываться в «Основных»
    /// (не входят в именованные группы — fuel/diet/payment/…).
    private var presetPrimaryKeys: Set<String> {
        let namedGroupPrefixes = POIFieldRegistry.shared.groupAliasKeys  // "fuel:", "diet:", …
        var keys = Set<String>()
        for baseKey in baseTypeKeys {
            guard let value = node.tags[baseKey], !value.isEmpty else { continue }
            guard let typeDef = POITypeRegistry.shared.find(key: baseKey, value: value) else { continue }
            for presetKey in typeDef.presets {
                // Пропускаем ключи именованных групп (prefix-match)
                let isNamed = namedGroupPrefixes.contains { presetKey.hasPrefix($0) }
                if !isNamed && !baseTypeKeys.contains(presetKey) {
                    keys.insert(presetKey)
                }
            }
        }
        return keys
    }

    private func resolvedGroup(for key: String) -> OSMTagDefinition.TagGroup {
        if baseTypeKeys.contains(key)        { return .type }
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
        if OSMTags.isAddressKey(key)         { return .address }
        if OSMTags.isBuildingKey(key)        { return .building }
        if presetPrimaryKeys.contains(key)   { return .type }
        return OSMTags.definition(for: key)?.group ?? .other
    }
}

// MARK: - PaymentTagSection (read-only)

struct PaymentTagSection: View {
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
            Image(systemName: "checkmark").foregroundStyle(.green)
        case "no":
            Image(systemName: "xmark").foregroundStyle(.red)
        default:
            Text(value).font(.body).foregroundStyle(.secondary)
        }
    }
}

// MARK: - AddressTagSection (read-only)

struct AddressTagSection: View {
    let entries: [(key: String, value: String)]

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

    private var formattedAddresses: [String] {
        let dict = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        let handledKeys = Set(Self.addressOrder.map { $0.key })

        var slottedValues: [(prefix: String, slots: [String])] = []
        for (key, prefix) in Self.addressOrder {
            guard let raw = dict[key], !raw.isEmpty else { continue }
            let slots = raw.split(separator: ";", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            slottedValues.append((prefix, slots))
        }
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
                        Text(line).font(.body).textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
