import SwiftUI
import Combine
import MapLibre
import CoreLocation

// MARK: - MapViewModel

@MainActor
final class MapViewModel: ObservableObject {

    // MARK: - Published state

    @Published var osmNodes: [OSMNode] = []
    @Published var selectedNode: OSMNode?           // лёгкая версия (для sheet заголовка)
    @Published var selectedNodeDetails: OSMNode?    // полная версия с тегами (загружается отдельно)
    @Published var isLoadingDetails = false
    @Published var isAddingPOI = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var pendingPOICoordinate: CLLocationCoordinate2D?   // временный маркер нового POI
    @Published var savedDraftPOIs: [POI] = []                       // сохранённые черновики (до загрузки)
    @Published var coordinateToCenter: CLLocationCoordinate2D?      // запрос центрирования карты
    @Published var selectedDraftPOI: POI?                           // черновик, выбранный на карте

    // MARK: - Indoor state

    /// Текущий выбранный этаж (level OSM).
    @Published var selectedFloor: Int = 0

    /// Этажи, обнаруженные в текущей видимой области карты.
    @Published var availableFloors: [IndoorFloor] = []

    /// true когда zoom >= 17 и найдены indoor-данные → показываем FloorPicker.
    @Published var showIndoorControls = false

    // MARK: - Internal state

    var mapCenter: CLLocationCoordinate2D = MapPreferences.center
    var shouldCenterOnUser = false
    var currentZoomLevel: Double = MapPreferences.zoomLevel

    private let overpassService = OverpassService()
    private var lastLoadedBounds: MLNCoordinateBounds?
    private var loadTask: Task<Void, Never>?          // текущий запрос (для отмены)
    private var debounceTask: Task<Void, Never>?      // дебаунс-таймер
    private let minZoomForNodes = 15.0  // не грузим ноды при мелком масштабе

    // MARK: - Init

    init() {
        // Восстанавливаем кэш Overpass при старте.
        // Если центр карты (из MapPreferences) находится внутри сохранённого bbox — используем кэш.
        if let cached = POICache.load(for: MapPreferences.center) {
            osmNodes = cached.nodes
            lastLoadedBounds = cached.bounds
        }
    }

    // MARK: - Public API

    func centerOnUserLocation() {
        shouldCenterOnUser = true
    }

    func centerOn(coordinate: CLLocationCoordinate2D) {
        coordinateToCenter = coordinate
    }

    func saveDraftPOI(_ poi: POI) {
        savedDraftPOIs.append(poi)
    }

    func selectDraftPOI(id: UUID) {
        selectedDraftPOI = savedDraftPOIs.first { $0.id == id }
    }

    func updateDraftPOI(_ poi: POI) {
        if let idx = savedDraftPOIs.firstIndex(where: { $0.id == poi.id }) {
            savedDraftPOIs[idx] = poi
        }
    }

    /// Вызывается при тапе на маркер — сначала показываем то что есть, потом догружаем детали
    func selectNode(_ node: OSMNode) {
        selectedNode = node
        selectedNodeDetails = nil
        Task { await fetchDetails(for: node) }
    }

    private func fetchDetails(for node: OSMNode) async {
        isLoadingDetails = true
        do {
            let detailed = try await overpassService.fetchNodeDetails(id: node.id, type: node.type)
            selectedNodeDetails = detailed
            // Обновляем и в общем списке
            if let idx = osmNodes.firstIndex(where: { $0.id == node.id && $0.type == node.type }) {
                osmNodes[idx] = detailed
            }
        } catch {
            print("[Overpass] детали \(node.type.rawValue) \(node.id): \(error.localizedDescription)")
            selectedNodeDetails = node // fallback на то что есть
        }
        isLoadingDetails = false
    }

    /// Загрузить OSM ноды для видимой области (вызывается при первой загрузке стиля)
    func loadNodes(for bounds: MLNCoordinateBounds) async {
        guard shouldLoad(bounds: bounds) else { return }
        await fetchNodes(for: expandedBounds(bounds))
    }

    /// Загрузить ноды с дебаунсом 1.5с и отменой предыдущего запроса
    func loadNodesIfNeeded(for bounds: MLNCoordinateBounds) {
        guard shouldLoad(bounds: bounds), escapedCachedArea(bounds) else { return }

        debounceTask?.cancel()
        debounceTask = Task {
            // Ждём пока пользователь остановится
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }

            loadTask?.cancel()
            loadTask = Task { await self.fetchNodes(for: self.expandedBounds(bounds)) }
        }
    }

    // MARK: - Private

    private func shouldLoad(bounds: MLNCoordinateBounds) -> Bool {
        let latSpan = bounds.ne.latitude - bounds.sw.latitude
        let lonSpan = bounds.ne.longitude - bounds.sw.longitude
        // 0.05° ≈ 5.5 км — это примерно zoom 14 на iPhone.
        // Ниже этого зума POI-маркеры всё равно не читаются, запрос бессмысленен.
        let fits = latSpan < 0.05 && lonSpan < 0.05
        if !fits {
            print("[Overpass] zoom слишком мелкий (bbox lat=\(String(format:"%.4f",latSpan))° lon=\(String(format:"%.4f",lonSpan))°) — пропускаем")
        }
        return fits
    }

    /// Расширяем bbox на фиксированный отступ 0.01° (~1.1 км) в каждую сторону.
    /// Это даёт «запас» при небольшом панорамировании без риска отправить гигантский запрос.
    private func expandedBounds(_ bounds: MLNCoordinateBounds) -> MLNCoordinateBounds {
        let pad = 0.01  // ~1.1 км — достаточный запас при zoom 15-17
        let sw = CLLocationCoordinate2D(latitude:  bounds.sw.latitude  - pad,
                                        longitude: bounds.sw.longitude - pad)
        let ne = CLLocationCoordinate2D(latitude:  bounds.ne.latitude  + pad,
                                        longitude: bounds.ne.longitude + pad)
        print("[Overpass] bbox для запроса: \(String(format:"%.4f",ne.latitude-sw.latitude))°×\(String(format:"%.4f",ne.longitude-sw.longitude))° (~\(Int((ne.latitude-sw.latitude)*111))×\(Int((ne.longitude-sw.longitude)*111*cos(sw.latitude * .pi/180)))км)")
        return MLNCoordinateBounds(sw: sw, ne: ne)
    }

    /// Перезагружаем только когда видимая область вышла за пределы уже загруженного bbox
    private func escapedCachedArea(_ visible: MLNCoordinateBounds) -> Bool {
        guard let cached = lastLoadedBounds else { return true }
        // Видимый bbox полностью внутри закэшированного — запрос не нужен
        let inside = visible.sw.latitude  >= cached.sw.latitude  &&
                     visible.sw.longitude >= cached.sw.longitude &&
                     visible.ne.latitude  <= cached.ne.latitude  &&
                     visible.ne.longitude <= cached.ne.longitude
        return !inside
    }

    private func fetchNodes(for bounds: MLNCoordinateBounds) async {
        isLoading = true
        errorMessage = nil

        do {
            // Явно выходим с MainActor — сетевой запрос и JSON-парсинг на background thread
            let nodes = try await Task.detached(priority: .userInitiated) {
                try await self.overpassService.fetchNodes(in: bounds)
            }.value
            osmNodes = nodes
            lastLoadedBounds = bounds
            POICache.save(nodes: nodes, bounds: bounds)
        } catch is CancellationError {
            // отменено дебаунсом — нормально
        } catch {
            print("[Overpass] ошибка: \(error.localizedDescription)")
            errorMessage = "Ошибка загрузки данных: \(error.localizedDescription)"
        }

        isLoading = false
    }
}
