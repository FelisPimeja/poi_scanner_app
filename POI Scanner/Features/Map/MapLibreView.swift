import SwiftUI
import MapLibre
import CoreLocation

// MARK: - MapLibreView
// UIViewRepresentable обёртка над MLNMapView

struct MapLibreView: UIViewRepresentable {
    @ObservedObject var viewModel: MapViewModel

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView()
        mapView.styleURL = MapStyle.mapTiler
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.showsUserLocation = true
        mapView.delegate = context.coordinator
        mapView.automaticallyAdjustsContentInset = true

        // Тап по MapTiler vector POI (symbol-слои из Streets стиля)
        let poiTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePOITap(_:))
        )
        poiTap.delegate = context.coordinator
        mapView.addGestureRecognizer(poiTap)

        // Начальная позиция — восстанавливаем из UserDefaults (или Москва по умолчанию)
        mapView.setCenter(
            MapPreferences.center,
            zoomLevel: MapPreferences.zoomLevel,
            animated: false
        )

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let coordinator = context.coordinator

        // Центрирование на пользователе по запросу
        if viewModel.shouldCenterOnUser, let location = mapView.userLocation?.location {
            mapView.setCenter(location.coordinate, zoomLevel: 15, animated: true)
            DispatchQueue.main.async { viewModel.shouldCenterOnUser = false }
        }

        // Центрирование на запрошенной координате (например, после сохранения POI)
        if let coord = viewModel.coordinateToCenter {
            mapView.setCenter(coord, zoomLevel: max(mapView.zoomLevel, 17), animated: true)
            DispatchQueue.main.async { viewModel.coordinateToCenter = nil }
        }

        // Временный маркер нового POI и черновики — всегда дёшево
        coordinator.updatePendingMarker(on: mapView, coordinate: viewModel.pendingPOICoordinate)
        coordinator.updateDraftMarkers(on: mapView, pois: viewModel.savedDraftPOIs)

        // Indoor floor switch: определяем ПЕРВЫМ, до updateAnnotations.
        // При смене этажа оба тяжёлых вызова (updateIndoorFloorFilter + updateAnnotations)
        // откладываем на следующую итерацию run loop — так updateUIView возвращается мгновенно
        // и gesture recognizer не получает timeout.
        if viewModel.showIndoorControls,
           coordinator.lastRenderedFloor != viewModel.selectedFloor {
            let floor = viewModel.selectedFloor
            let nodes = viewModel.osmNodes
            coordinator.lastRenderedFloor = floor  // сразу — защита от повторного входа

            coordinator.floorApplyWorkItem?.cancel()
            let work = DispatchWorkItem { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.updateIndoorFloorFilter(mapView: mapView, floor: floor)
                coordinator.updateAnnotations(on: mapView, nodes: nodes, indoorFloor: floor)
            }
            coordinator.floorApplyWorkItem = work
            DispatchQueue.main.async(execute: work)
        } else {
            // Этаж не менялся — обновляем аннотации синхронно (guard-exit если не изменились)
            coordinator.updateAnnotations(
                on: mapView,
                nodes: viewModel.osmNodes,
                indoorFloor: viewModel.showIndoorControls ? viewModel.selectedFloor : nil
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }
}

// MARK: - Coordinator

extension MapLibreView {
    final class Coordinator: NSObject, MLNMapViewDelegate {
        let viewModel: MapViewModel
        private var currentAnnotations: [MLNPointAnnotation] = []
        private var pendingAnnotation: PendingPOIAnnotation?
        private var draftAnnotations: [DraftPOIAnnotation] = []

        // Трекинг для инкрементального обновления аннотаций
        private var lastRenderedNodeIDs: [Int64] = []
        private var lastRenderedIndoorFloor: Int? = nil  // nil = indoor выключен

        // Throttle для detectAvailableFloors — отменяем предыдущий pending вызов
        private var floorDetectWorkItem: DispatchWorkItem?
        // Debounce для смены этажа — откладываем тяжёлые операции после render pass
        fileprivate var floorApplyWorkItem: DispatchWorkItem?

        // Indoor: идентификаторы слоёв
        private static let indoorSourceID          = "indoor-equal"
        // area source layer
        private static let indoorPolygonLayerID    = "indoor-polygon"
        private static let indoorAreaLineLayerID   = "indoor-area"
        private static let indoorColumnLayerID     = "indoor-column"
        private static let indoorLinesLayerID      = "indoor-lines"
        private static let indoorDoorLayerID       = "indoor-door"
        // transportation source layer
        private static let indoorTransportLayerID  = "indoor-transportation"
        // poi source layer
        private static let indoorPoiRank1LayerID   = "indoor-poi-rank1"
        private static let indoorPoiRank2LayerID   = "indoor-poi-rank2"
        private static let indoorEntranceLayerID   = "indoor-entrance"
        // area_name source layer
        private static let indoorNameLayerID       = "indoor-name"

        private static let indoorProbeLayerID         = "indoor-probe"
        private static let indoorTransportPoiLayerID  = "indoor-transportation-poi"

        // Устаревшие ID (оставлены для обратной совместимости, не используются)
        private static let indoorAreaLayerID   = "indoor-area-fill"
        private static let indoorWallLayerID   = "indoor-wall-line"
        private static let indoorLabelLayerID  = "indoor-area-label"
        private static let indoorPoiLayerID    = "indoor-poi-label"

        /// Классы POI из source-layer "poi", которые отображаются в indoor-режиме.
        /// Amenity/shop исключены — они загружаются отдельно через Overpass.
        /// Оставляем только инфраструктурные объекты безопасности и навигации.
        /// Классы (поле `class` в тайлах IndoorEqual), показываемые в indoor-режиме.
        /// Пожарное оборудование тегируется в OSM как emergency=fire_extinguisher/hose/hydrant,
        /// поэтому в тайлах имеет class="emergency", subclass="fire_extinguisher" и т.д.
        private static let indoorInfraPoiClasses: [String] = [
            // Экстренные службы (class = "emergency" для всего emergency=*)
            "emergency",
            // Навигация / сервис
            "entrance", "toilet", "toilets", "locker",
            "information", "telephone",
            // Мелкий сервис (rank2 — показываются от zoom 19)
            "waste_basket", "vending_machine", "bench", "photo_booth", "ticket_validator",
        ]

        /// Классы (по полю `class`), отображаемые только с zoom 19 (rank2).
        private static let indoorPoiRank2Classes: [String] = [
            "waste_basket", "vending_machine", "bench", "photo_booth", "ticket_validator",
        ]

        /// Subclass-значения пожарного оборудования — показываются только с zoom 19.
        /// Их class в тайлах = "emergency", поэтому фильтруем отдельно по subclass.
        private static let indoorFireEquipmentSubclasses: [String] = [
            "fire_extinguisher", "fire_hose", "fire_hydrant",
        ]

        /// Последний этаж, применённый к фильтру слоёв (позволяет избежать лишних вызовов).
        var lastRenderedFloor: Int = 0

        /// Идентификаторы style-слоёв MapTiler Streets, которые рисуют POI символы.
        /// Заполняется в didFinishLoading style путём инспекции style.layers.
        var mapTilerPOILayerIDs: Set<String> = []

        init(viewModel: MapViewModel) {
            self.viewModel = viewModel
        }

        // MARK: - Аннотации

        func updateAnnotations(on mapView: MLNMapView, nodes: [OSMNode], indoorFloor: Int?) {
            let newNodeIDs = nodes.map(\.id)
            // Перерисовываем только если изменились ноды или состояние indoor-фильтра
            guard newNodeIDs != lastRenderedNodeIDs || indoorFloor != lastRenderedIndoorFloor else { return }
            lastRenderedNodeIDs = newNodeIDs
            lastRenderedIndoorFloor = indoorFloor

            mapView.removeAnnotations(currentAnnotations)

            // Если активен indoor-режим — фильтруем ноды по тегу level.
            // Нода без тега level (уличный POI) показывается на всех этажах.
            let visibleNodes: [OSMNode]
            if let floor = indoorFloor {
                let floorStr = "\(floor)"
                visibleNodes = nodes.filter { node in
                    guard let levelTag = node.tags["level"] else { return true }
                    // level может быть "1", "1;2", "-1" и т.д.
                    return levelTag
                        .split(separator: ";")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .contains(floorStr)
                }
            } else {
                visibleNodes = nodes
            }

            currentAnnotations = visibleNodes.map { node in
                let annotation = OSMNodeAnnotation(node: node)
                annotation.coordinate = CLLocationCoordinate2D(latitude: node.latitude, longitude: node.longitude)
                annotation.title = node.tags["name"] ?? "OSM #\(node.id)"
                annotation.subtitle = node.tags["amenity"] ?? node.tags["shop"] ?? node.tags["office"]
                return annotation
            }
            mapView.addAnnotations(currentAnnotations)
            // viewFor: вызывается лениво — запускаем фильтр после следующего render pass.
            DispatchQueue.main.async { [weak self] in
                self?.applyClutterFilter(on: mapView)
            }
        }

        func updatePendingMarker(on mapView: MLNMapView, coordinate: CLLocationCoordinate2D?) {
            if let existing = pendingAnnotation {
                mapView.removeAnnotation(existing)
                pendingAnnotation = nil
            }
            guard let coord = coordinate else { return }
            let annotation = PendingPOIAnnotation()
            annotation.coordinate = coord
            annotation.title = "Новый POI"
            annotation.subtitle = "GPS из фото"
            mapView.addAnnotation(annotation)
            pendingAnnotation = annotation
        }

        func updateDraftMarkers(on mapView: MLNMapView, pois: [POI]) {
            // Добавляем только новые — уже отрисованные не трогаем
            let existingIds = Set(draftAnnotations.map { $0.poiID })
            for poi in pois where !existingIds.contains(poi.id) {
                let coord = CLLocationCoordinate2D(
                    latitude: poi.coordinate.latitude,
                    longitude: poi.coordinate.longitude
                )
                let annotation = DraftPOIAnnotation(poiID: poi.id)
                annotation.coordinate = coord
                annotation.title = poi.tags["name"] ?? "Новый POI"
                annotation.subtitle = "Черновик"
                mapView.addAnnotation(annotation)
                draftAnnotations.append(annotation)
            }
        }

        // MARK: - MapTiler POI tap

        /// Обрабатывает тап по MapTiler vector-tile POI символам.
        /// Находит ближайший POI в радиусе 22pt, строит синтетический OSMNode
        /// и открывает detail sheet. Если у фичи есть OSM id — Overpass
        /// догружает полные теги автоматически через selectNode.
        @objc func handlePOITap(_ sender: UITapGestureRecognizer) {
            guard sender.state == .ended,
                  let mapView = sender.view as? MLNMapView,
                  !mapTilerPOILayerIDs.isEmpty else { return }

            let pt = sender.location(in: mapView)
            // Небольшой hit area 44×44pt вокруг тапа
            let hitRect = CGRect(x: pt.x - 22, y: pt.y - 22, width: 44, height: 44)
            let features = mapView.visibleFeatures(in: hitRect,
                                                   styleLayerIdentifiers: mapTilerPOILayerIDs)
            guard let feature = features.first else { return }

            // Координата
            guard let shape = feature as? MLNShape else { return }
            let coord = shape.coordinate

            // Атрибуты фичи
            let attrs = feature.attributes
            let name   = attrs["name"]     as? String
            let cls    = attrs["class"]    as? String ?? ""
            let sub    = attrs["subclass"] as? String ?? ""

            // OSM id — MapTiler Planet кодирует id как (osmID * 10 + typeCode):
            //   typeCode 0 = node, 2 = way, 4 = relation
            // Декодируем: osmID = encodedID / 10, type = encodedID % 10
            let osmID: Int64
            let osmType: OSMElementType
            if let num = feature.identifier as? NSNumber {
                let encoded = num.int64Value
                osmID = encoded / 10
                switch encoded % 10 {
                case 1:  osmType = .way
                case 4:  osmType = .relation
                default: osmType = .node
                }
            } else {
                osmID = 0
                osmType = .node
            }
            print("[MapTiler] тап: encodedID=\(feature.identifier ?? "nil") → osmID=\(osmID) type=\(osmType.rawValue)")

            // Собираем минимальные теги для отображения заголовка и категории в sheet
            var tags: [String: String] = [:]
            if let name { tags["name"] = name }
            tags.merge(mapTilerAttrsToOSMTags(cls: cls, sub: sub)) { _, new in new }

            let node = OSMNode(
                id: osmID,
                type: osmType,
                latitude: coord.latitude,
                longitude: coord.longitude,
                tags: tags,
                version: 1
            )

            // selectNode открывает sheet и асинхронно тянет полные теги из Overpass по id
            Task { @MainActor [weak self] in
                self?.viewModel.selectNode(node)
            }
        }

        /// Конвертирует MapTiler Planet class/subclass в ближайшие OSM теги.
        /// Точность достаточна для первоначального отображения — полные теги придут из Overpass.
        private func mapTilerAttrsToOSMTags(cls: String, sub: String) -> [String: String] {
            let v = sub.isEmpty ? cls : sub
            guard !v.isEmpty else { return [:] }

            let shopValues: Set<String> = [
                "supermarket", "convenience", "bakery", "butcher", "clothes", "shoes",
                "electronics", "hardware", "pharmacy", "beauty", "hairdresser", "florist",
                "pet", "books", "toys", "sports", "jewelry", "stationery", "optician",
                "mobile_phone", "department_store", "mall", "wholesale", "greengrocer",
                "newsagent", "confectionery", "alcohol", "bicycle", "car",
            ]
            let tourismValues: Set<String> = [
                "hotel", "hostel", "motel", "guest_house", "apartment", "camp_site",
                "museum", "gallery", "attraction", "viewpoint", "zoo", "castle",
                "theme_park", "aquarium",
            ]
            let leisureValues: Set<String> = [
                "sports_centre", "stadium", "swimming_pool", "fitness_centre", "golf_course",
                "playground", "park", "pitch", "track", "ice_rink", "marina",
                "water_park", "miniature_golf",
            ]

            if shopValues.contains(v) || shopValues.contains(cls) {
                return ["shop": v]
            } else if tourismValues.contains(v) || tourismValues.contains(cls) {
                return ["tourism": v]
            } else if leisureValues.contains(v) || leisureValues.contains(cls) {
                return ["leisure": v]
            } else {
                return ["amenity": v]
            }
        }

        // MARK: - MLNMapViewDelegate

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            // Стиль загружен — можно запросить ноды для текущего bbox
            let bounds = mapView.visibleCoordinateBounds
            Task { await viewModel.loadNodes(for: bounds) }

            // Собираем идентификаторы style-слоёв, которые рендерят MapTiler POI из source-layers poi_*
            // (используются в handlePOITap для запроса visibleFeatures)
            mapTilerPOILayerIDs = Set(
                style.layers.compactMap { layer -> String? in
                    guard let vl = layer as? MLNVectorStyleLayer,
                          let sl = vl.sourceLayerIdentifier,
                          sl.hasPrefix("poi") || sl == "street_furniture" else { return nil }
                    return layer.identifier
                }
            )
            print("[MapTiler] POI style layers: \(mapTilerPOILayerIDs.count) шт.")

            // Подключаем indoor-слои поверх базового стиля
            setupIndoorLayers(style: style, mapView: mapView)

            // Детектируем этажи после небольшой задержки — тайлы ещё грузятся
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.detectAvailableFloors(in: mapView)
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            handleRegionChange(mapView)
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            // Не мутируем @Published во время активного жеста — это вызывает
            // SwiftUI re-render на каждый frame и блокирует gesture recognizer.
            // mapCenter обновится в handleRegionChange после остановки.
            // Отменяем отложенный detectAvailableFloors — он не должен срабатывать
            // пока жест активен (visibleFeatures синхронен и блокирует main thread).
            floorDetectWorkItem?.cancel()
            floorDetectWorkItem = nil
        }

        private func handleRegionChange(_ mapView: MLNMapView) {
            let center = mapView.centerCoordinate
            let zoom = mapView.zoomLevel
            let bounds = mapView.visibleCoordinateBounds

            // Мутации @Published — в одном батче после окончания жеста
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.mapCenter = center
                self.viewModel.currentZoomLevel = zoom
            }

            // UserDefaults — в фоне, не блокируем main thread
            DispatchQueue.global(qos: .utility).async {
                MapPreferences.save(center: center, zoom: zoom)
            }

            viewModel.loadNodesIfNeeded(for: bounds)

            // Обновляем пины и применяем вытеснение при смене zoom.
            applyClutterFilter(on: mapView)

            // Детектируем indoor этажи при достаточном zoom — debounce 0.8s.
            floorDetectWorkItem?.cancel()
            if zoom >= 17 {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, mapView.zoomLevel >= 17 else { return }
                    self.detectAvailableFloors(in: mapView)
                }
                floorDetectWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            } else {
                floorDetectWorkItem = nil
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel.availableFloors = []
                    self?.viewModel.showIndoorControls = false
                }
            }
        }

        // MARK: - Indoor layers

        // Дескриптор одной иконки в sprite JSON
        private struct SpriteDescriptor: Decodable {
            let x, y, width, height: Int
            let pixelRatio: Int
        }

        /// Загружает sprite-лист IndoorEqual и регистрирует все иконки в стиле.
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
                } catch {
                    // sprite load failed silently
                }
            }
        }

        // MARK: - Indoor style JSON loader

        /// Создаёт MLNStyleLayer из GL-JSON словаря.
        /// paint/layout свойства передаются через NSExpression(mglJSONObject:) —
        /// JSON-парсер возвращает чистые Foundation-типы, которые MapLibre корректно сериализует.
        private static func makeLayer(
            def: NSDictionary,
            source: MLNSource,
            predicate: NSPredicate?
        ) -> MLNStyleLayer? {
            guard let id       = def["id"]           as? String,
                  let type     = def["type"]         as? String,
                  let srcLayer = def["source-layer"] as? String
            else { return nil }

            let paint  = (def["paint"]  as? NSDictionary) ?? NSDictionary()
            _ = (def["layout"] as? NSDictionary) ?? NSDictionary()

            // Round-trip через JSONSerialization гарантирует, что объект попадает
            // в NSExpression(mglJSONObject:) как чистый NSArray/NSNumber/NSString,
            // а не как Swift-экзистенциал, который MapLibre не умеет распаковывать.
            func expr(_ v: Any) -> NSExpression {
                guard JSONSerialization.isValidJSONObject(v),
                      let data = try? JSONSerialization.data(withJSONObject: v),
                      let obj  = try? JSONSerialization.jsonObject(with: data)
                else {
                    // Простые скалярные типы (String, NSNumber) — передаём напрямую
                    return NSExpression(forConstantValue: v)
                }
                return NSExpression(mglJSONObject: obj)
            }

            // Цветовые свойства MapLibre НЕ принимают строки — нужен UIColor.
            // Если значение — строка "#rrggbb", конвертируем. Если выражение (массив) —
            // используем обычный expr(), т.к. MapLibre сам парсит цвета внутри expressions.
            func colorExpr(_ v: Any) -> NSExpression {
                if let hex = v as? String {
                    return NSExpression(forConstantValue: UIColor(hex: hex))
                }
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
                if let v = paint["line-color"]    { layer.lineColor   = colorExpr(v) }
                if let v = paint["line-width"]     { layer.lineWidth   = expr(v) }
                if let v = paint["line-opacity"]   { layer.lineOpacity = expr(v) }
                // lineDashPattern принимает NSExpression(forConstantValue: NSArray of NSNumber),
                // а не GL-expression — передаём массив напрямую.
                if let arr = paint["line-dasharray"] as? NSArray {
                    layer.lineDashPattern = NSExpression(forConstantValue: arr)
                }
                layer.predicate = predicate
                return layer

            // Symbol-слои НЕ строятся из JSON — только в Swift (см. setupIndoorLayers).
            // MapLibre iOS требует UIColor/NSValue/NSNumber напрямую, не строковые GL expressions.
            default:
                return nil
            }
        }

        /// Predicate для каждого слоя = class-фильтр (из layers.js) + level-фильтр.
        private static func predicate(forLayerID id: String, floor: String) -> NSPredicate {
            let level = NSPredicate(format: "level == %@", floor)
            switch id {
            case "indoor-polygon":
                // Оригинал: $type == "Polygon" AND class != "level"
                // wall-фичи в тайлах — LineString-сегменты, fill на них даёт артефакты.
                // Исключаем явно, т.к. MapLibre iOS NSPredicate не поддерживает $type.
                return NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class != %@ AND class != %@", "level", "wall"), level
                ])            case "indoor-area":
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
            case "indoor-transportation", "indoor-transportation-poi":
                return level
            case "indoor-poi-rank1":
                let rank2 = ["waste_basket", "information", "vending_machine",
                             "bench", "photo_booth", "ticket_validator"]
                return NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "NOT class IN %@", rank2), level
                ])
            case "indoor-poi-rank2":
                let rank2 = ["waste_basket", "information", "vending_machine",
                             "bench", "photo_booth", "ticket_validator"]
                return NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class IN %@", rank2), level
                ])
            case "indoor-name":
                return level
            default:
                return level
            }
        }

        /// Добавляет источник IndoorEqual и стилевые слои из IndoorEqualStyle.json.
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

            // Probe-слой без level-фильтра — для detectAvailableFloors.
            // Line вместо fill, чтобы не давать артефактов заливки на wall-фичах.
            let probe = MLNLineStyleLayer(identifier: Self.indoorProbeLayerID, source: source)
            probe.sourceLayerIdentifier = "area"
            probe.lineOpacity = NSExpression(forConstantValue: NSNumber(value: 0.02))
            probe.minimumZoomLevel = 17
            style.addLayer(probe)

            // Загружаем sprite (async, не блокирует)
            loadIndoorSprite(into: style)

            // Загружаем слои из JSON
            guard let url  = Bundle.main.url(forResource: "IndoorEqualStyle", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  // Важно: НЕ кастить к [[String:Any]] — Swift бриджует NSArray→Array<Any>,
                  // что ломает NSExpression(mglJSONObject:). Оставляем как NSArray/NSDictionary.
                  let defs = try? JSONSerialization.jsonObject(with: data) as? NSArray
            else {
                return
            }

            let floor = "\(viewModel.selectedFloor)"

            func insert(_ layer: MLNStyleLayer) {
                if let anchor = style.layer(withIdentifier: "com.mapbox.annotations.points") {
                    style.insertLayer(layer, below: anchor)
                } else {
                    style.addLayer(layer)
                }
            }

            // Проход 1: только fill-слои (polygon, column)
            for case let def as NSDictionary in defs {
                guard let id = def["id"] as? String,
                      (def["type"] as? String) == "fill" else { continue }
                let pred = Self.predicate(forLayerID: id, floor: floor)
                guard let layer = Self.makeLayer(def: def, source: source, predicate: pred) else { continue }
                if let minzoom = def["minzoom"] as? Float { layer.minimumZoomLevel = minzoom }
                insert(layer)
            }

            // Цветовые override-слои для polygon (поверх базовых fills, под стенами).
            // Используем отдельные слои с предикатами вместо GL case-expression,
            // т.к. MapLibre iOS не поддерживает ["in", value, ["literal",[...]]] в mglJSONObject.
            let colorDefs: [(id: String, predFormat: String, predArgs: [Any], color: UIColor)] = [
                ("indoor-polygon-private", "class != %@ AND class != %@ AND (access == %@ OR access == %@)",
                 ["level", "wall", "no", "private"],  UIColor(red: 0.949, green: 0.945, blue: 0.941, alpha: 1)),
                ("indoor-polygon-poi",     "class != %@ AND class != %@ AND class != %@ AND is_poi == 1",
                 ["level", "wall", "corridor"],        UIColor(red: 0.831, green: 0.929, blue: 1.000, alpha: 1)),
                ("indoor-polygon-room",    "class == %@",
                 ["room"],                    UIColor(red: 0.996, green: 0.996, blue: 0.886, alpha: 1)),
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

            // Проход 2: line-слои (area, lines, transportation) — поверх всех fills
            for case let def as NSDictionary in defs {
                guard let id = def["id"] as? String,
                      (def["type"] as? String) == "line" else { continue }
                let pred = Self.predicate(forLayerID: id, floor: floor)
                guard let layer = Self.makeLayer(def: def, source: source, predicate: pred) else { continue }
                if let minzoom = def["minzoom"] as? Float { layer.minimumZoomLevel = minzoom }
                insert(layer)
            }

            // Symbol-слои строятся в Swift напрямую — MapLibre iOS требует UIColor/NSNumber,
            // а не строковые GL-expressions для text-color, text-size, text-offset и т.п.

            // Двери: белая линия поверх стен — визуализирует проёмы
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

            // Входы: иконка indoorequal-entrance из poi source-layer
            let entranceLayer = MLNSymbolStyleLayer(identifier: Self.indoorEntranceLayerID, source: source)
            entranceLayer.sourceLayerIdentifier = "poi"
            entranceLayer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "class == %@ OR subclass == %@", "entrance", "entrance"),
                NSPredicate(format: "level == %@", floor)
            ])
            entranceLayer.iconImageName = NSExpression(forConstantValue: "indoorequal-entrance")
            entranceLayer.iconScale = NSExpression(forConstantValue: NSNumber(value: 1.0))
            entranceLayer.minimumZoomLevel = 17
            insert(entranceLayer)

            let infraClasses   = Self.indoorInfraPoiClasses
            let rank2Classes   = Self.indoorPoiRank2Classes
            let fireSubclasses = Self.indoorFireEquipmentSubclasses
            // rank1 = всё из infraClasses, кроме rank2 по class и кроме пожарного оборудования по subclass
            let infraRank1     = infraClasses.filter { !rank2Classes.contains($0) }

            func makePoiSymbol(id: String, pred: NSPredicate, fontSize: Float) -> MLNSymbolStyleLayer {
                let l = MLNSymbolStyleLayer(identifier: id, source: source)
                l.sourceLayerIdentifier = "poi"
                l.predicate = pred
                // icon: coalesce(indoorequal-{subclass}, indoorequal-{class})
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
                l.minimumZoomLevel = (id == Self.indoorPoiRank2LayerID) ? 19 : 17
                return l
            }

            // Rank1 (zoom 17): infraClasses минус rank2ByClass, и исключаем пожарное оборудование по subclass
            insert(makePoiSymbol(
                id: Self.indoorPoiRank1LayerID,
                pred: NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "level == %@", floor),
                    NSPredicate(format: "class IN %@", infraRank1),
                    NSPredicate(format: "NOT subclass IN %@", fireSubclasses),
                ]),
                fontSize: 12
            ))
            // Rank2 (zoom 19): мелкий сервис (по class) + пожарное оборудование (по subclass)
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
            // icon: "indoorequal-escalator" если has "conveying", иначе "indoorequal-{class}"
            transPoiLayer.iconImageName = NSExpression(mglJSONObject: [
                "case",
                ["has", "conveying"],
                "indoorequal-escalator",
                ["concat", ["literal", "indoorequal-"], ["get", "class"]]
            ] as NSArray)
            transPoiLayer.symbolPlacement = NSExpression(forConstantValue: "line-center")
            transPoiLayer.iconRotationAlignment = NSExpression(forConstantValue: "viewport")
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
            nameLayer.minimumZoomLevel = 17
            insert(nameLayer)
        }

        /// Обновляет фильтр всех indoor-слоёв по выбранному этажу.
        func updateIndoorFloorFilter(mapView: MLNMapView, floor: Int) {
            guard let style = mapView.style else { return }
            let rank2Classes   = Self.indoorPoiRank2Classes
            let infraClasses   = Self.indoorInfraPoiClasses
            let fireSubclasses = Self.indoorFireEquipmentSubclasses
            let infraRank1     = infraClasses.filter { !rank2Classes.contains($0) }
            // level в тайлах IndoorEqual хранится как String ("0", "-1", "1" и т.д.)
            let floorStr = "\(floor)"
            let floorPred = NSPredicate(format: "level == %@", floorStr)

            if let layer = style.layer(withIdentifier: Self.indoorPolygonLayerID) as? MLNFillStyleLayer {
                layer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class != %@ AND class != %@", "level", "wall"), floorPred
                ])
            }
            if let layer = style.layer(withIdentifier: Self.indoorColumnLayerID) as? MLNFillStyleLayer {
                layer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class == %@", "column"), floorPred
                ])
            }
            if let layer = style.layer(withIdentifier: Self.indoorLinesLayerID) as? MLNLineStyleLayer {
                layer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "class IN %@", ["room", "wall"]), floorPred
                ])
            }
            if let layer = style.layer(withIdentifier: Self.indoorAreaLineLayerID) as? MLNLineStyleLayer {
                layer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
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

            // Цветовые override-слои
            let colorLayerDefs: [(id: String, format: String, args: [Any])] = [
                ("indoor-polygon-private", "class != %@ AND class != %@ AND (access == %@ OR access == %@)", ["level", "wall", "no", "private"]),
                ("indoor-polygon-poi",     "class != %@ AND class != %@ AND class != %@ AND is_poi == 1",    ["level", "wall", "corridor"]),
                ("indoor-polygon-room",    "class == %@",                                                    ["room"]),
            ]
            for def in colorLayerDefs {
                if let layer = style.layer(withIdentifier: def.id) as? MLNFillStyleLayer {
                    layer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        NSPredicate(format: def.format, argumentArray: def.args),
                        floorPred
                    ])
                }
            }
        }

        /// Детектирует доступные этажи через точечные запросы по всем слоям.
        /// area и poi оба имеют поле level — собираем уникальные значения.
        func detectAvailableFloors(in mapView: MLNMapView) {
            guard mapView.style?.source(withIdentifier: Self.indoorSourceID) != nil else { return }

            // visibleFeatures — синхронный вызов MapLibre, блокирует main thread.
            // Чтобы не вызывать freeze: получаем фичи на main thread, но немедленно
            // уходим в фон для обработки (sort, map) и возвращаемся на main только
            // для финального обновления @Published. Сам вызов visibleFeatures быстрее
            // если ограничить область — используем центральную четверть экрана
            // (indoor здания занимает весь экран при zoom >= 17, центр всегда внутри).
            let probeIDs: Set<String> = [Self.indoorProbeLayerID]
            let allFeatures = mapView.visibleFeatures(
                in: mapView.bounds,
                styleLayerIdentifiers: probeIDs
            )

            // Обработка результата — в фоне, не блокирует UI
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                var levels = Set<Int>()
                for feature in allFeatures {
                    guard let raw = feature.attribute(forKey: "level") else { continue }
                    if let n = raw as? NSNumber { levels.insert(n.intValue) }
                    else if let s = raw as? String, let i = Int(s) { levels.insert(i) }
                }
                let floors = levels.sorted().map { IndoorFloor(level: $0) }

                await MainActor.run {
                    self.viewModel.availableFloors = floors
                    self.viewModel.showIndoorControls = !floors.isEmpty
                    if !floors.isEmpty && !floors.contains(IndoorFloor(level: self.viewModel.selectedFloor)) {
                        let defaultFloor = floors.first(where: { $0.level == 0 })?.level
                            ?? floors.first?.level ?? 0
                        self.viewModel.selectedFloor = defaultFloor
                        self.lastRenderedFloor = defaultFloor
                        self.updateIndoorFloorFilter(mapView: mapView, floor: defaultFloor)
                    } else if !floors.isEmpty {
                        let floor = self.viewModel.selectedFloor
                        self.lastRenderedFloor = floor
                        self.updateIndoorFloorFilter(mapView: mapView, floor: floor)
                    }
                }
            }
        }

        // MARK: - Clutter filter

        /// Скрывает перекрывающиеся пины. Работает в экранных координатах:
        /// для каждой аннотации вычисляем rect пина и проверяем пересечение
        /// с уже принятыми. При перекрытии побеждает аннотация с бо́льшим priority;
        /// при равном — та, что была добавлена раньше (порядок итерации).
        func applyClutterFilter(on mapView: MLNMapView) {
            guard let allAnnotations = mapView.annotations else { return }
            let zoom = mapView.zoomLevel

            // Собираем только OSM-аннотации, сортируем по убыванию приоритета.
            let sorted = allAnnotations
                .compactMap { $0 as? OSMNodeAnnotation }
                .sorted { OSMNodeCategory.of($0.node).priority > OSMNodeCategory.of($1.node).priority }

            // Отступ вокруг пина — минимальный зазор между соседями.
            let padding: CGFloat = 4
            var accepted: [CGRect] = []

            for ann in sorted {
                guard let view = mapView.view(for: ann) as? OSMNodeAnnotationView else { continue }
                let category = OSMNodeCategory.of(ann.node)

                // Сначала применяем zoom-visibility через configure (обновляет frame).
                view.configure(category: category, zoom: zoom)

                // Если скрыт по zoom — не участвует в фильтре.
                guard !view.isHidden else { continue }

                // Экранная точка кончика пина → вычитаем centerOffset чтобы получить центр вью.
                let tip = mapView.convert(ann.coordinate, toPointTo: mapView)
                let cx = tip.x - view.centerOffset.dx
                let cy = tip.y - view.centerOffset.dy
                let w = view.bounds.width
                let h = view.bounds.height
                let rect = CGRect(
                    x: cx - w / 2 - padding,
                    y: cy - h / 2 - padding,
                    width:  w + padding * 2,
                    height: h + padding * 2
                )

                let overlaps = accepted.contains { $0.intersects(rect) }
                view.isHidden = overlaps
                if !overlaps { accepted.append(rect) }
            }
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)
            if let osmAnnotation = annotation as? OSMNodeAnnotation {
                viewModel.selectNode(osmAnnotation.node)
            } else if let draftAnnotation = annotation as? DraftPOIAnnotation {
                viewModel.selectDraftPOI(id: draftAnnotation.poiID)
            }
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let osmAnnotation = annotation as? OSMNodeAnnotation else { return nil }
            // MLNAnnotationView — UIKit-вью, рендерится ПОВЕРХ всех GL style-слоёв.
            // В отличие от MLNAnnotationImage (symbol в GL-стеке), не может оказаться под indoor.
            let reuseID = "osm_node_view"
            let view: OSMNodeAnnotationView
            if let existing = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? OSMNodeAnnotationView {
                view = existing
            } else {
                view = OSMNodeAnnotationView(reuseIdentifier: reuseID)
            }
            let category = OSMNodeCategory.of(osmAnnotation.node)
            // configure задаёт размер/цвет и скрывает маркер если zoom < minZoom.
            // ВАЖНО: возвращаем view (не nil) даже когда она скрыта —
            // иначе MLN fallback-ает на imageFor: и рисует дефолтный красный пин.
            view.configure(category: category, zoom: mapView.zoomLevel)
            return view
        }

        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            // OSMNodeAnnotation рендерится через viewFor (MLNAnnotationView) — здесь не обрабатываем.
            if annotation is PendingPOIAnnotation {
                let reuseId = "pending_poi"
                if let existing = mapView.dequeueReusableAnnotationImage(withIdentifier: reuseId) {
                    return existing
                }
                return MLNAnnotationImage(image: Self.markerImage(color: .systemGreen, systemName: "plus"), reuseIdentifier: reuseId)
            }

            if annotation is DraftPOIAnnotation {
                let reuseId = "draft_poi"
                if let existing = mapView.dequeueReusableAnnotationImage(withIdentifier: reuseId) {
                    return existing
                }
                return MLNAnnotationImage(image: Self.markerImage(color: .systemOrange, systemName: "star.fill"), reuseIdentifier: reuseId)
            }

            return nil
        }

        /// Рисует круглый цветной маркер с SF Symbol внутри через Core Graphics.
        /// MLNAnnotationImage не поддерживает SF Symbol напрямую — нужен UIImage из UIGraphicsImageRenderer.
        private static func markerImage(color: UIColor, systemName: String) -> UIImage {
            let size = CGSize(width: 36, height: 36)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                // Круглая плашка
                color.setFill()
                UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
                // Белая обводка
                UIColor.white.setStroke()
                let ring = UIBezierPath(ovalIn: CGRect(x: 1.5, y: 1.5, width: size.width - 3, height: size.height - 3))
                ring.lineWidth = 2
                ring.stroke()
                // SF Symbol белого цвета
                let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
                if let symbol = UIImage(systemName: systemName, withConfiguration: config)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) {
                    let x = (size.width  - symbol.size.width)  / 2
                    let y = (size.height - symbol.size.height) / 2
                    symbol.draw(at: CGPoint(x: x, y: y))
                }
            }
        }
    }
}

// MARK: - OSMNodeAnnotationView

/// UIKit-вью маркер для OSM нод из Overpass.
/// zoom < 16  → маленький пин (÷1.5) без иконки, с белым кружком внутри.
/// zoom ≥ 16  → полный пин с белым SF Symbol иконкой.
final class OSMNodeAnnotationView: MLNAnnotationView {
    private let imageView = UIImageView()

    // Полный размер: SVG viewBox 24×24 → 28pt ширина.
    private static let fullScale:   CGFloat = 28.0 / 24.0
    private static let fullWidth:   CGFloat = 28
    private static let fullHeight:  CGFloat = 30
    // Маленький размер: в 1.5 раза меньше полного.
    private static let smallScale:  CGFloat = fullScale  / 1.5
    private static let smallWidth:  CGFloat = fullWidth  / 1.5
    private static let smallHeight: CGFloat = fullHeight / 1.5

    // Кеш: два варианта на категорию.
    private static var fullCache:  [OSMNodeCategory: UIImage] = [:]
    private static var smallCache: [OSMNodeCategory: UIImage] = [:]

    // Порог зума для переключения стиля.
    private static let iconZoomThreshold: Double = 16

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        // Начальный frame — полный размер; centerOffset устанавливается в configure.
        frame = CGRect(x: 0, y: 0, width: Self.fullWidth, height: Self.fullHeight)
        imageView.frame = bounds
        imageView.contentMode = .center   // не растягиваем — меняем frame вью
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { nil }

    func configure(category: OSMNodeCategory, zoom: Double) {
        isHidden = zoom < category.minZoom
        let useSmall = zoom < Self.iconZoomThreshold

        let w = useSmall ? Self.smallWidth  : Self.fullWidth
        let h = useSmall ? Self.smallHeight : Self.fullHeight
        let s = useSmall ? Self.smallScale  : Self.fullScale

        // Кончик пина (SVG y=23) должен указывать на координату.
        let tipY = 23.0 * s
        frame = CGRect(x: 0, y: 0, width: w, height: h)
        imageView.frame = bounds
        centerOffset = CGVector(dx: 0, dy: -(tipY - h / 2))

        let cache = useSmall ? Self.smallCache : Self.fullCache
        if let cached = cache[category] {
            imageView.image = cached
        } else {
            let img = Self.renderPin(category: category, small: useSmall)
            if useSmall { Self.smallCache[category] = img }
            else        { Self.fullCache[category]  = img }
            imageView.image = img
        }
    }

    // MARK: - Rendering

    private static func renderPin(category: OSMNodeCategory, small: Bool) -> UIImage {
        let s = small ? smallScale : fullScale
        let w = small ? smallWidth : fullWidth
        let h = small ? smallHeight : fullHeight
        let size = CGSize(width: w, height: h)

        return UIGraphicsImageRenderer(size: size).image { _ in
            let ctx = UIGraphicsGetCurrentContext()!

            // Тень
            ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3,
                          color: UIColor.black.withAlphaComponent(0.30).cgColor)

            // Заливка пина
            let path = pinBezierPath(scale: s)
            category.pinColor.setFill()
            path.fill()

            ctx.setShadow(offset: .zero, blur: 0, color: nil)

            // Белая обводка
            UIColor.white.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 0.75
            path.stroke()

            // Центр круглой части пина: SVG (12, 10) → (12s, 10s)
            let cx = 12 * s
            let cy = 10 * s

            if small {
                // Маленький вариант: белый кружок внутри
                let r: CGFloat = 2.8 * s
                let dot = UIBezierPath(ovalIn: CGRect(x: cx - r, y: cy - r,
                                                     width: r * 2, height: r * 2))
                UIColor.white.setFill()
                dot.fill()
            } else {
                // Полный вариант: белый SF Symbol
                let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                if let sym = UIImage(systemName: category.sfSymbol, withConfiguration: config)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) {
                    sym.draw(at: CGPoint(x: cx - sym.size.width  / 2,
                                        y: cy - sym.size.height / 2))
                }
            }
        }
    }

    /// Bezier-путь формы пина (SVG viewBox 24×24), масштабированный коэффициентом `s`.
    private static func pinBezierPath(scale s: CGFloat) -> UIBezierPath {
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
        return path
    }
}

// MARK: - OSMNodeCategory

enum OSMNodeCategory: Hashable {
    case food           // кафе, рестораны, бары
    case shopping       // магазины, супермаркеты
    case health         // больницы, аптеки, врачи
    case finance        // банки, банкоматы
    case accommodation  // гостиницы, хостелы
    case education      // школы, университеты, библиотеки
    case transport      // парковки, заправки, остановки
    case culture        // музеи, театры, кино
    case religion       // церкви, мечети, храмы
    case nature         // парки, сады, природные объекты
    case sports         // спортивные объекты
    case service        // офисы, почта, мастерские
    case minor          // мелкие объекты (скамейки, урны…)
    case organization   // прочие POI

    var minZoom: Double { self == .minor ? 19 : 15 }

    /// Приоритет при вытеснении: чем выше — тем важнее, показывается при перекрытии.
    var priority: Int {
        switch self {
        case .health:        return 10
        case .food:          return 9
        case .shopping:      return 8
        case .transport:     return 7
        case .finance:       return 6
        case .education:     return 6
        case .accommodation: return 6
        case .culture:       return 5
        case .religion:      return 5
        case .sports:        return 5
        case .nature:        return 4
        case .service:       return 3
        case .organization:  return 2
        case .minor:         return 1
        }
    }

    var pinColor: UIColor {
        let gray = UIColor(red: 0.62, green: 0.62, blue: 0.64, alpha: 1)
        switch self {
        case .food:          return UIColor(red: 0.93, green: 0.38, blue: 0.18, alpha: 1) // оранжевый
        case .shopping:      return UIColor(red: 0.56, green: 0.27, blue: 0.80, alpha: 1) // фиолетовый
        case .health:        return UIColor(red: 0.86, green: 0.18, blue: 0.21, alpha: 1) // красный
        case .finance:       return gray
        case .accommodation: return gray
        case .education:     return gray
        case .transport:     return UIColor(red: 0.20, green: 0.45, blue: 0.72, alpha: 1) // синий
        case .culture:       return UIColor(red: 0.78, green: 0.42, blue: 0.08, alpha: 1) // тёмно-оранжевый
        case .religion:      return UIColor(red: 0.58, green: 0.44, blue: 0.28, alpha: 1) // коричневый
        case .nature:        return UIColor(red: 0.26, green: 0.63, blue: 0.28, alpha: 1) // зелёный
        case .sports:        return UIColor(red: 0.20, green: 0.45, blue: 0.72, alpha: 1) // синий
        case .service:       return gray
        case .minor:         return gray
        case .organization:  return UIColor(red: 0.20, green: 0.45, blue: 0.72, alpha: 1) // синий
        }
    }

    var sfSymbol: String {
        switch self {
        case .food:          return "fork.knife"
        case .shopping:      return "bag.fill"
        case .health:        return "cross.fill"
        case .finance:       return "banknote.fill"
        case .accommodation: return "bed.double.fill"
        case .education:     return "graduationcap.fill"
        case .transport:     return "bus.fill"
        case .culture:       return "theatermasks.fill"
        case .religion:      return "building.columns.fill"
        case .nature:        return "leaf.fill"
        case .sports:        return "sportscourt.fill"
        case .service:       return "wrench.and.screwdriver.fill"
        case .minor:         return "circle.fill"
        case .organization:  return "mappin.circle.fill"
        }
    }

    /// Классифицирует ноду Overpass по её тегам.
    static func of(_ node: OSMNode) -> OSMNodeCategory {
        if let amenity  = node.tags["amenity"]  { return byAmenity(amenity) }
        if node.tags["shop"]     != nil          { return .shopping }
        if node.tags["office"]   != nil          { return .service }
        if let tourism = node.tags["tourism"] {
            if tourism == "artwork" || tourism == "information" { return .minor }
            return .culture
        }
        if node.tags["historic"] != nil          { return .culture }
        if let leisure = node.tags["leisure"]    { return byLeisure(leisure) }
        if node.tags["natural"]  != nil          { return .nature }
        if node.tags["man_made"] != nil          { return .service }
        if node.tags["power"]    != nil          { return .minor }
        if node.tags["barrier"]  != nil          { return .minor }
        if let highway = node.tags["highway"],
           highway == "street_lamp" || highway == "crossing" { return .minor }
        return .organization
    }

    private static func byLeisure(_ leisure: String) -> OSMNodeCategory {
        switch leisure {
        case "sports_centre", "stadium", "swimming_pool", "golf_course",
             "ice_rink", "track", "pitch", "fitness_centre",
             "fitness_station", "slipway", "horse_riding", "miniature_golf":
            return .sports
        case "playground", "picnic_table":
            return .service
        default:
            // park, garden, marina, water_park, beach_resort, dog_park, nature_reserve…
            return .nature
        }
    }

    private static func byAmenity(_ amenity: String) -> OSMNodeCategory {
        switch amenity {
        case "restaurant", "cafe", "bar", "pub", "fast_food",
             "food_court", "ice_cream", "biergarten", "canteen", "bbq":
            return .food
        case "bank", "atm", "bureau_de_change", "payment_terminal":
            return .finance
        case "pharmacy", "hospital", "clinic", "doctors", "dentist",
             "veterinary", "first_aid", "nursing_home":
            return .health
        case "school", "university", "college", "kindergarten",
             "language_school", "music_school", "driving_school", "library":
            return .education
        case "bus_station", "parking", "fuel", "car_wash", "car_rental",
             "bicycle_rental", "taxi", "ferry_terminal", "charging_station":
            return .transport
        case "theatre", "cinema", "arts_centre", "nightclub", "casino",
             "gambling", "social_club", "community_centre":
            return .culture
        case "place_of_worship", "monastery":
            return .religion
        case "hotel", "hostel", "guest_house", "motel", "chalet":
            return .accommodation
        case "post_office", "police", "fire_station", "embassy",
             "courthouse", "townhall":
            return .service
        case "bench", "waste_basket", "waste_disposal", "recycling",
             "fountain", "drinking_water", "clock", "vending_machine",
             "photo_booth", "ticket_validator", "bicycle_parking",
             "motorcycle_parking", "parking_space", "parking_entrance",
             "post_box", "telephone", "surveillance",
             "fire_hydrant", "fire_extinguisher":
            return .minor
        default:
            return .organization
        }
    }
}

// MARK: - OSMNodeAnnotation

final class OSMNodeAnnotation: MLNPointAnnotation {
    let node: OSMNode

    init(node: OSMNode) {
        self.node = node
        super.init()
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - PendingPOIAnnotation

final class PendingPOIAnnotation: MLNPointAnnotation {
    override init() { super.init() }
    required init?(coder: NSCoder) { nil }
}

// MARK: - DraftPOIAnnotation

final class DraftPOIAnnotation: MLNPointAnnotation {
    let poiID: UUID
    init(poiID: UUID) {
        self.poiID = poiID
        super.init()
    }
    required init?(coder: NSCoder) { nil }
}

// MARK: - UIColor hex initializer

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

// MARK: - Coordinator + UIGestureRecognizerDelegate

extension MapLibreView.Coordinator: UIGestureRecognizerDelegate {
    /// Разрешаем одновременную работу нашего POI-тапа со встроенными жестами MapLibre
    /// (выбор аннотации, двойной тап для зума и т.п.)
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }
}

// MARK: - MapStyle

enum MapStyle {
    /// MapTiler Streets — требует API ключ (хранится в Secrets.swift, не в git)
    static let mapTiler = URL(string: "https://api.maptiler.com/maps/streets/style.json?key=\(Secrets.mapTilerKey)")!

    /// OpenFreeMap — резерв без ключа (для CI / если нет Secrets.swift)
    static let openFreeMap = URL(string: "https://tiles.openfreemap.org/styles/liberty")!

    /// Protomaps — локальный офлайн pmtiles (для будущего)
    // static let protomapsLocal = URL(fileURLWithPath: Bundle.main.path(forResource: "map", ofType: "pmtiles")!)
}
