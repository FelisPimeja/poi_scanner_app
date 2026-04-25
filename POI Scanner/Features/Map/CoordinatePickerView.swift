import SwiftUI
import MapLibre
import CoreLocation

// MARK: - CoordinatePickerView

/// Полноэкранный редактор координат точечного POI.
/// Карта панируется — крестик остаётся в центре экрана.
/// При подтверждении возвращает координату центра карты.
struct CoordinatePickerView: View {
    let initialCoordinate: CLLocationCoordinate2D
    let initialFloor: Int
    let onConfirm: (CLLocationCoordinate2D) -> Void
    let onCancel: () -> Void

    @State private var centerCoordinate: CLLocationCoordinate2D
    @State private var selectedFloor: Int
    @State private var availableFloors: [IndoorFloor] = []
    @State private var showIndoorControls = false

    @EnvironmentObject private var settings: AppSettings

    init(
        initialCoordinate: CLLocationCoordinate2D,
        initialFloor: Int = 0,
        onConfirm: @escaping (CLLocationCoordinate2D) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialCoordinate = initialCoordinate
        self.initialFloor = initialFloor
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _centerCoordinate = State(initialValue: initialCoordinate)
        _selectedFloor = State(initialValue: initialFloor)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Карта
                CoordinatePickerMapView(
                    centerCoordinate: $centerCoordinate,
                    selectedFloor: $selectedFloor,
                    availableFloors: $availableFloors,
                    showIndoorControls: $showIndoorControls,
                    initialCoordinate: initialCoordinate,
                    initialFloor: initialFloor
                )
                .ignoresSafeArea()

                // Прицел — фиксирован в центре, карта двигается под ним
                ZStack {
                    // Горизонтальная черта
                    Rectangle()
                        .frame(width: 24, height: 1.5)
                        .foregroundStyle(.primary)
                    // Вертикальная черта
                    Rectangle()
                        .frame(width: 1.5, height: 24)
                        .foregroundStyle(.primary)
                    // Центральный кружок
                    Circle()
                        .frame(width: 5, height: 5)
                        .foregroundStyle(.primary)
                }
                .shadow(color: .black.opacity(0.35), radius: 1.5)

                // Координатная метка
                VStack {
                    Spacer()
                    Text(String(
                        format: "%.6f,  %.6f",
                        centerCoordinate.latitude,
                        centerCoordinate.longitude
                    ))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .padding(.bottom, 24)
                }

                // Переключатель этажей
                if showIndoorControls {
                    FloorPickerView(
                        floors: availableFloors,
                        selectedFloor: $selectedFloor
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 16)
                    .padding(.bottom, 64)
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("Местоположение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        onConfirm(centerCoordinate)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - CoordinatePickerMapView

private struct CoordinatePickerMapView: UIViewRepresentable {
    @Binding var centerCoordinate: CLLocationCoordinate2D
    @Binding var selectedFloor: Int
    @Binding var availableFloors: [IndoorFloor]
    @Binding var showIndoorControls: Bool
    let initialCoordinate: CLLocationCoordinate2D
    let initialFloor: Int

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView()
        mapView.styleURL = MapStyle.mapTiler
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.showsUserLocation = false
        mapView.delegate = context.coordinator
        mapView.automaticallyAdjustsContentInset = false
        mapView.attributionButton.isHidden = true
        mapView.logoView.isHidden = true

        mapView.setCenter(initialCoordinate, zoomLevel: 18, animated: false)
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let coordinator = context.coordinator

        // При смене этажа обновляем фильтр indoor-слоёв
        if coordinator.lastRenderedFloor != selectedFloor {
            coordinator.lastRenderedFloor = selectedFloor
            coordinator.updateIndoorFloorFilter(mapView: mapView, floor: selectedFloor)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            centerCoordinate: $centerCoordinate,
            selectedFloor: $selectedFloor,
            availableFloors: $availableFloors,
            showIndoorControls: $showIndoorControls,
            initialFloor: initialFloor
        )
    }
}

// MARK: - Coordinator

extension CoordinatePickerMapView {
    final class Coordinator: NSObject, MLNMapViewDelegate {
        @Binding private var centerCoordinate: CLLocationCoordinate2D
        @Binding private var selectedFloor: Int
        @Binding private var availableFloors: [IndoorFloor]
        @Binding private var showIndoorControls: Bool

        let initialFloor: Int
        var lastRenderedFloor: Int
        var mapTilerPOILayerIDs: Set<String> = []

        private var floorDetectWorkItem: DispatchWorkItem?

        // Layer IDs — зеркало констант из MapLibreView.Coordinator
        private static let indoorSourceID             = "indoor-equal"
        private static let indoorPolygonLayerID       = "indoor-polygon"
        private static let indoorAreaLineLayerID      = "indoor-area"
        private static let indoorColumnLayerID        = "indoor-column"
        private static let indoorLinesLayerID         = "indoor-lines"
        private static let indoorDoorLayerID          = "indoor-door"
        private static let indoorTransportLayerID     = "indoor-transportation"
        private static let indoorPoiRank1LayerID      = "indoor-poi-rank1"
        private static let indoorPoiRank2LayerID      = "indoor-poi-rank2"
        private static let indoorEntranceLayerID      = "indoor-entrance"
        private static let indoorNameLayerID          = "indoor-name"
        private static let indoorProbeLayerID         = "indoor-probe"
        private static let indoorTransportPoiLayerID  = "indoor-transportation-poi"

        private static let indoorInfraPoiClasses: [String] = [
            "emergency", "entrance", "toilet", "toilets", "locker",
            "information", "telephone",
            "waste_basket", "vending_machine", "bench", "photo_booth", "ticket_validator",
        ]
        private static let indoorPoiRank2Classes: [String] = [
            "waste_basket", "vending_machine", "bench", "photo_booth", "ticket_validator",
        ]
        private static let indoorFireEquipmentSubclasses: [String] = [
            "fire_extinguisher", "fire_hose", "fire_hydrant",
        ]

        init(
            centerCoordinate: Binding<CLLocationCoordinate2D>,
            selectedFloor: Binding<Int>,
            availableFloors: Binding<[IndoorFloor]>,
            showIndoorControls: Binding<Bool>,
            initialFloor: Int
        ) {
            _centerCoordinate = centerCoordinate
            _selectedFloor = selectedFloor
            _availableFloors = availableFloors
            _showIndoorControls = showIndoorControls
            self.initialFloor = initialFloor
            self.lastRenderedFloor = initialFloor
        }

        // MARK: - MLNMapViewDelegate

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            mapTilerPOILayerIDs = Set(
                style.layers.compactMap { layer -> String? in
                    guard let vl = layer as? MLNVectorStyleLayer,
                          let sl = vl.sourceLayerIdentifier,
                          sl.hasPrefix("poi") || sl == "street_furniture" else { return nil }
                    return layer.identifier
                }
            )

            setupIndoorLayers(style: style, mapView: mapView)

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.detectAvailableFloors(in: mapView)
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let center = mapView.centerCoordinate
            DispatchQueue.main.async { self.centerCoordinate = center }

            // Определяем этажи с debounce
            floorDetectWorkItem?.cancel()
            let zoom = mapView.zoomLevel
            if zoom >= 17 {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, mapView.zoomLevel >= 17 else { return }
                    self.detectAvailableFloors(in: mapView)
                }
                floorDetectWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            } else {
                floorDetectWorkItem = nil
                DispatchQueue.main.async {
                    self.availableFloors = []
                    self.showIndoorControls = false
                }
            }
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            floorDetectWorkItem?.cancel()
            floorDetectWorkItem = nil
        }

        // MARK: - Indoor layers

        private struct SpriteDescriptor: Decodable {
            let x, y, width, height: Int
            let pixelRatio: Int
        }

        private func loadIndoorSprite(into style: MLNStyle) {
            let base = "https://indoorequal.github.io/maplibre-gl-indoorequal/sprite/indoorequal@2x"
            guard let jsonURL = URL(string: "\(base).json"),
                  let pngURL  = URL(string: "\(base).png") else { return }
            Task {
                do {
                    async let jd = URLSession.shared.data(from: jsonURL).0
                    async let pd = URLSession.shared.data(from: pngURL).0
                    let (jsonData, pngData) = try await (jd, pd)
                    guard let sheet = UIImage(data: pngData),
                          let sheetCG = sheet.cgImage else { return }
                    let descs = try JSONDecoder().decode([String: SpriteDescriptor].self, from: jsonData)
                    await MainActor.run {
                        for (name, d) in descs {
                            let scale = CGFloat(d.pixelRatio > 0 ? d.pixelRatio : 2)
                            guard let crop = sheetCG.cropping(to: CGRect(
                                x: d.x, y: d.y, width: d.width, height: d.height
                            )) else { continue }
                            let img = UIImage(cgImage: crop, scale: scale, orientation: .up)
                            style.setImage(img, forName: name)
                        }
                    }
                } catch { /* silent */ }
            }
        }

        private static func makeLayer(
            def: NSDictionary,
            source: MLNSource,
            predicate: NSPredicate?
        ) -> MLNStyleLayer? {
            guard let id       = def["id"]           as? String,
                  let type     = def["type"]         as? String,
                  let srcLayer = def["source-layer"] as? String
            else { return nil }

            let paint = (def["paint"] as? NSDictionary) ?? NSDictionary()

            func expr(_ v: Any) -> NSExpression {
                guard JSONSerialization.isValidJSONObject(v),
                      let data = try? JSONSerialization.data(withJSONObject: v),
                      let obj  = try? JSONSerialization.jsonObject(with: data)
                else { return NSExpression(forConstantValue: v) }
                return NSExpression(mglJSONObject: obj)
            }

            func colorExpr(_ v: Any) -> NSExpression {
                if let hex = v as? String { return NSExpression(forConstantValue: UIColor(hex: hex)) }
                return expr(v)
            }

            switch type {
            case "fill":
                let layer = MLNFillStyleLayer(identifier: id, source: source)
                layer.sourceLayerIdentifier = srcLayer
                if let v = paint["fill-color"]   { layer.fillColor   = colorExpr(v) }
                if let v = paint["fill-opacity"]  { layer.fillOpacity = expr(v) }
                layer.predicate = predicate
                return layer

            case "line":
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.sourceLayerIdentifier = srcLayer
                if let v = paint["line-color"]   { layer.lineColor   = colorExpr(v) }
                if let v = paint["line-width"]   { layer.lineWidth   = expr(v) }
                if let v = paint["line-opacity"] { layer.lineOpacity = expr(v) }
                if let arr = paint["line-dasharray"] as? NSArray {
                    layer.lineDashPattern = NSExpression(forConstantValue: arr)
                }
                layer.predicate = predicate
                return layer

            default:
                return nil
            }
        }

        private static func predicate(forLayerID id: String, floor: String) -> NSPredicate {
            let level = NSPredicate(format: "level == %@", floor)
            switch id {
            case "indoor-polygon":
                return NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class != %@ AND class != %@", "level", "wall"), level
                ])
            case "indoor-area":
                return NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class IN %@", ["area", "corridor", "platform"]), level
                ])
            case "indoor-column":
                return NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class == %@", "column"), level
                ])
            case "indoor-lines":
                return NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class IN %@", ["room", "wall"]), level
                ])
            default:
                return level
            }
        }

        func setupIndoorLayers(style: MLNStyle, mapView: MLNMapView) {
            guard style.source(withIdentifier: Self.indoorSourceID) == nil else { return }

            let source = MLNVectorTileSource(
                identifier: Self.indoorSourceID,
                tileURLTemplates: ["https://tiles.indoorequal.org/tiles/{z}/{x}/{y}.pbf?key=\(Secrets.indoorEqualKey)"],
                options: [
                    .minimumZoomLevel: NSNumber(value: 0),
                    .maximumZoomLevel: NSNumber(value: 17)
                ]
            )
            style.addSource(source)

            let probe = MLNLineStyleLayer(identifier: Self.indoorProbeLayerID, source: source)
            probe.sourceLayerIdentifier = "area"
            probe.lineOpacity = NSExpression(forConstantValue: NSNumber(value: 0.02))
            probe.minimumZoomLevel = 17
            style.addLayer(probe)

            loadIndoorSprite(into: style)

            guard let url  = Bundle.main.url(forResource: "IndoorEqualStyle", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let defs = try? JSONSerialization.jsonObject(with: data) as? NSArray
            else { return }

            let floor = "\(initialFloor)"

            func insert(_ layer: MLNStyleLayer) {
                if let firstPOILayer = style.layers.first(where: { mapTilerPOILayerIDs.contains($0.identifier) }) {
                    style.insertLayer(layer, below: firstPOILayer)
                } else if let anchor = style.layer(withIdentifier: "com.mapbox.annotations.points") {
                    style.insertLayer(layer, below: anchor)
                } else {
                    style.addLayer(layer)
                }
            }

            // Fill-слои
            for case let def as NSDictionary in defs {
                guard let id = def["id"] as? String, (def["type"] as? String) == "fill" else { continue }
                let pred = Self.predicate(forLayerID: id, floor: floor)
                guard let layer = Self.makeLayer(def: def, source: source, predicate: pred) else { continue }
                if let minzoom = def["minzoom"] as? Float { layer.minimumZoomLevel = minzoom }
                insert(layer)
            }

            // Цветовые override-слои
            let colorDefs: [(id: String, predFormat: String, predArgs: [Any], color: UIColor)] = [
                ("indoor-polygon-private",
                 "class != %@ AND class != %@ AND (access == %@ OR access == %@)",
                 ["level", "wall", "no", "private"],
                 UIColor(red: 0.949, green: 0.945, blue: 0.941, alpha: 1)),
                ("indoor-polygon-poi",
                 "class != %@ AND class != %@ AND class != %@ AND is_poi == 1",
                 ["level", "wall", "corridor"],
                 UIColor(red: 0.831, green: 0.929, blue: 1.000, alpha: 1)),
                ("indoor-polygon-room",
                 "class == %@",
                 ["room"],
                 UIColor(red: 0.996, green: 0.996, blue: 0.886, alpha: 1)),
            ]
            for def in colorDefs {
                guard style.layer(withIdentifier: def.id) == nil else { continue }
                let layer = MLNFillStyleLayer(identifier: def.id, source: source)
                layer.sourceLayerIdentifier = "area"
                layer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: def.predFormat, argumentArray: def.predArgs),
                    NSPredicate(format: "level == %@", floor)
                ])
                layer.fillColor = NSExpression(forConstantValue: def.color)
                layer.minimumZoomLevel = 17
                insert(layer)
            }

            // Line-слои
            for case let def as NSDictionary in defs {
                guard let id = def["id"] as? String, (def["type"] as? String) == "line" else { continue }
                let pred = Self.predicate(forLayerID: id, floor: floor)
                guard let layer = Self.makeLayer(def: def, source: source, predicate: pred) else { continue }
                if let minzoom = def["minzoom"] as? Float { layer.minimumZoomLevel = minzoom }
                insert(layer)
            }

            // Двери
            let doorLayer = MLNLineStyleLayer(identifier: Self.indoorDoorLayerID, source: source)
            doorLayer.sourceLayerIdentifier = "area"
            doorLayer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "class == %@", "door"),
                NSPredicate(format: "level == %@", floor)
            ])
            doorLayer.lineColor = NSExpression(forConstantValue: UIColor.white)
            doorLayer.lineWidth = NSExpression(forConstantValue: NSNumber(value: 3.0))
            doorLayer.minimumZoomLevel = 17
            insert(doorLayer)

            // Входы
            let entranceLayer = MLNSymbolStyleLayer(identifier: Self.indoorEntranceLayerID, source: source)
            entranceLayer.sourceLayerIdentifier = "poi"
            entranceLayer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "class == %@ OR subclass == %@", "entrance", "entrance"),
                NSPredicate(format: "level == %@", floor)
            ])
            entranceLayer.iconImageName = NSExpression(forConstantValue: "indoorequal-entrance")
            entranceLayer.iconScale = NSExpression(forConstantValue: NSNumber(value: 1.0))
            entranceLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            entranceLayer.textAllowsOverlap = NSExpression(forConstantValue: true)
            entranceLayer.minimumZoomLevel = 17
            insert(entranceLayer)

            let infraClasses   = Self.indoorInfraPoiClasses
            let rank2Classes   = Self.indoorPoiRank2Classes
            let fireSubclasses = Self.indoorFireEquipmentSubclasses
            let infraRank1     = infraClasses.filter { !rank2Classes.contains($0) }

            func makePoiSymbol(id: String, pred: NSPredicate, fontSize: Float) -> MLNSymbolStyleLayer {
                let l = MLNSymbolStyleLayer(identifier: id, source: source)
                l.sourceLayerIdentifier = "poi"
                l.predicate = pred
                l.iconImageName = NSExpression(mglJSONObject: [
                    "concat", ["literal", "indoorequal-"],
                    ["coalesce", ["get", "subclass"], ["get", "class"]]
                ] as NSArray)
                l.iconScale = NSExpression(forConstantValue: NSNumber(value: 1.0))
                l.text = NSExpression(forKeyPath: "name")
                l.textFontSize = NSExpression(forConstantValue: NSNumber(value: fontSize))
                l.textAnchor = NSExpression(forConstantValue: "top")
                l.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 0.6)))
                l.maximumTextWidth = NSExpression(forConstantValue: NSNumber(value: 9))
                l.textColor = NSExpression(forConstantValue: UIColor(hex: "#666666"))
                l.textHaloColor = NSExpression(forConstantValue: UIColor.white)
                l.textHaloWidth = NSExpression(forConstantValue: NSNumber(value: 1.0))
                l.textHaloBlur = NSExpression(forConstantValue: NSNumber(value: 0.5))
                l.iconAllowsOverlap = NSExpression(forConstantValue: true)
                l.textAllowsOverlap = NSExpression(forConstantValue: true)
                l.minimumZoomLevel = (id == Self.indoorPoiRank2LayerID) ? 19 : 17
                return l
            }

            insert(makePoiSymbol(
                id: Self.indoorPoiRank1LayerID,
                pred: NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "level == %@", floor),
                    NSPredicate(format: "class IN %@", infraRank1),
                    NSPredicate(format: "NOT subclass IN %@", fireSubclasses),
                ]),
                fontSize: 12
            ))
            insert(makePoiSymbol(
                id: Self.indoorPoiRank2LayerID,
                pred: NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "level == %@", floor),
                    NSCompoundPredicate(orPredicateWithSubpredicates: [
                        NSPredicate(format: "class IN %@", rank2Classes),
                        NSPredicate(format: "subclass IN %@", fireSubclasses),
                    ]),
                ]),
                fontSize: 11
            ))

            let transPoiLayer = MLNSymbolStyleLayer(identifier: Self.indoorTransportPoiLayerID, source: source)
            transPoiLayer.sourceLayerIdentifier = "transportation"
            transPoiLayer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "class IN %@", ["steps", "elevator", "escalator"]),
                NSPredicate(format: "level == %@", floor)
            ])
            transPoiLayer.iconImageName = NSExpression(mglJSONObject: [
                "case",
                ["has", "conveying"],
                "indoorequal-escalator",
                ["concat", ["literal", "indoorequal-"], ["get", "class"]]
            ] as NSArray)
            transPoiLayer.symbolPlacement = NSExpression(forConstantValue: "line-center")
            transPoiLayer.iconRotationAlignment = NSExpression(forConstantValue: "viewport")
            transPoiLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            transPoiLayer.minimumZoomLevel = 17
            insert(transPoiLayer)

            let nameLayer = MLNSymbolStyleLayer(identifier: Self.indoorNameLayerID, source: source)
            nameLayer.sourceLayerIdentifier = "area_name"
            nameLayer.predicate = NSPredicate(format: "level == %@", floor)
            nameLayer.text = NSExpression(forKeyPath: "name")
            nameLayer.textFontSize = NSExpression(forConstantValue: NSNumber(value: 14))
            nameLayer.textColor = NSExpression(forConstantValue: UIColor(hex: "#666666"))
            nameLayer.textHaloColor = NSExpression(forConstantValue: UIColor.white)
            nameLayer.textHaloWidth = NSExpression(forConstantValue: NSNumber(value: 1.0))
            nameLayer.maximumTextWidth = NSExpression(forConstantValue: NSNumber(value: 5))
            nameLayer.textAllowsOverlap = NSExpression(forConstantValue: true)
            nameLayer.minimumZoomLevel = 17
            insert(nameLayer)
        }

        func updateIndoorFloorFilter(mapView: MLNMapView, floor: Int) {
            guard let style = mapView.style else { return }
            let rank2Classes   = Self.indoorPoiRank2Classes
            let infraClasses   = Self.indoorInfraPoiClasses
            let fireSubclasses = Self.indoorFireEquipmentSubclasses
            let infraRank1     = infraClasses.filter { !rank2Classes.contains($0) }
            let floorStr = "\(floor)"
            let floorPred = NSPredicate(format: "level == %@", floorStr)

            if let l = style.layer(withIdentifier: Self.indoorPolygonLayerID) as? MLNFillStyleLayer {
                l.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class != %@ AND class != %@", "level", "wall"), floorPred
                ])
            }
            if let l = style.layer(withIdentifier: Self.indoorColumnLayerID) as? MLNFillStyleLayer {
                l.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class == %@", "column"), floorPred
                ])
            }
            if let l = style.layer(withIdentifier: Self.indoorLinesLayerID) as? MLNLineStyleLayer {
                l.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class IN %@", ["room", "wall"]), floorPred
                ])
            }
            if let l = style.layer(withIdentifier: Self.indoorAreaLineLayerID) as? MLNLineStyleLayer {
                l.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class IN %@", ["area", "corridor", "platform"]), floorPred
                ])
            }
            (style.layer(withIdentifier: Self.indoorPoiRank1LayerID) as? MLNSymbolStyleLayer)?.predicate =
                NSCompoundPredicate(andPredicateWithSubpredicates: [
                    floorPred,
                    NSPredicate(format: "class IN %@", infraRank1),
                    NSPredicate(format: "NOT subclass IN %@", fireSubclasses),
                ])
            (style.layer(withIdentifier: Self.indoorPoiRank2LayerID) as? MLNSymbolStyleLayer)?.predicate =
                NSCompoundPredicate(andPredicateWithSubpredicates: [
                    floorPred,
                    NSCompoundPredicate(orPredicateWithSubpredicates: [
                        NSPredicate(format: "class IN %@", rank2Classes),
                        NSPredicate(format: "subclass IN %@", fireSubclasses),
                    ]),
                ])
            (style.layer(withIdentifier: Self.indoorNameLayerID) as? MLNSymbolStyleLayer)?.predicate = floorPred
            (style.layer(withIdentifier: Self.indoorTransportLayerID) as? MLNLineStyleLayer)?.predicate = floorPred
            (style.layer(withIdentifier: Self.indoorTransportPoiLayerID) as? MLNSymbolStyleLayer)?.predicate = floorPred
            (style.layer(withIdentifier: Self.indoorDoorLayerID) as? MLNLineStyleLayer)?.predicate =
                NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class == %@", "door"), floorPred
                ])
            (style.layer(withIdentifier: Self.indoorEntranceLayerID) as? MLNSymbolStyleLayer)?.predicate =
                NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class == %@ OR subclass == %@", "entrance", "entrance"), floorPred
                ])

            let colorLayerDefs: [(id: String, format: String, args: [Any])] = [
                ("indoor-polygon-private",
                 "class != %@ AND class != %@ AND (access == %@ OR access == %@)",
                 ["level", "wall", "no", "private"]),
                ("indoor-polygon-poi",
                 "class != %@ AND class != %@ AND class != %@ AND is_poi == 1",
                 ["level", "wall", "corridor"]),
                ("indoor-polygon-room", "class == %@", ["room"]),
            ]
            for def in colorLayerDefs {
                if let l = style.layer(withIdentifier: def.id) as? MLNFillStyleLayer {
                    l.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        NSPredicate(format: def.format, argumentArray: def.args),
                        floorPred
                    ])
                }
            }
        }

        func detectAvailableFloors(in mapView: MLNMapView) {
            guard mapView.style?.source(withIdentifier: Self.indoorSourceID) != nil else { return }
            let probeIDs: Set<String> = [Self.indoorProbeLayerID]
            let allFeatures = mapView.visibleFeatures(
                in: mapView.bounds,
                styleLayerIdentifiers: probeIDs
            )
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                var levels = Set<Int>()
                for feature in allFeatures {
                    guard let raw = feature.attribute(forKey: "level") else { continue }
                    if let n = raw as? NSNumber  { levels.insert(n.intValue) }
                    else if let s = raw as? String, let i = Int(s) { levels.insert(i) }
                }
                let floors = levels.sorted().map { IndoorFloor(level: $0) }
                await MainActor.run {
                    self.availableFloors = floors
                    self.showIndoorControls = !floors.isEmpty
                    if !floors.isEmpty && !floors.contains(IndoorFloor(level: self.selectedFloor)) {
                        let defaultFloor = floors.first(where: { $0.level == 0 })?.level
                            ?? floors.first?.level ?? 0
                        self.selectedFloor = defaultFloor
                        self.lastRenderedFloor = defaultFloor
                    }
                }
            }
        }
    }
}

// MARK: - UIColor hex (local, mirrors MapLibreView extension)

private extension UIColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        self.init(
            red:   CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >>  8) & 0xFF) / 255,
            blue:  CGFloat( rgb        & 0xFF) / 255,
            alpha: 1
        )
    }
}
