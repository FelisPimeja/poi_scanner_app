import SwiftUI
import PhotosUI
import AVFoundation
import Photos

// MARK: - CaptureView
// Выбор фото из галереи или камеры. Возвращает UIImage через onCapture.

struct CaptureView: View {
    let onCapture: (UIImage, CLLocationCoordinate2D?, Double?, Date?) -> Void
    let onSkip: (() -> Void)?          // «Пропустить фото» — для редактирования без OCR

    @Environment(\.dismiss) private var dismiss

    @State private var selectedItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var isLoading = false
    @State private var cameraPermissionDenied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 72))
                    .foregroundStyle(.secondary)

                Text("Добавить фото вывески")
                    .font(.title2.weight(.semibold))

                Text("Приложение извлечёт название, адрес, телефон и другие данные автоматически")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                VStack(spacing: 12) {
                    // Камера
                    Button {
                        requestCameraAndOpen()
                    } label: {
                        Label("Снять фото", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    // Галерея
                    PhotosPicker(
                        selection: $selectedItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label("Выбрать из галереи", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .task {
                        // Запрашиваем доступ к Photos заранее — нужен для PHAsset.location
                        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    }

                    // Пропустить
                    if let onSkip {
                        Button {
                            onSkip()
                        } label: {
                            Text("Пропустить, заполнить вручную")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
            .overlay {
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.white)
                            Text("Обрабатываем фото…")
                                .foregroundStyle(.white)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .alert("Нет доступа к камере", isPresented: $cameraPermissionDenied) {
                Button("Открыть Настройки") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Разрешите доступ к камере в Настройках → Конфиденциальность")
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPickerView(
                    onCapture: { image, coord, acc, date in
                        showCamera = false
                        handleImage(image, coordinate: coord, accuracy: acc, captureDate: date)
                    },
                    onCancel: {
                        showCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            .onChange(of: selectedItem) { _, item in
                guard let item else { return }
                Task { await loadPickerItem(item) }
            }
        }
    }

    // MARK: - Private

    private func requestCameraAndOpen() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            // Камера физически недоступна (симулятор или устройство без камеры)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { showCamera = true }
                    else { cameraPermissionDenied = true }
                }
            }
        default:
            cameraPermissionDenied = true
        }
    }

    private func loadPickerItem(_ item: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }

        // Диагностика
        print("[GPS] itemIdentifier: \(item.itemIdentifier ?? "nil")")
        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        print("[GPS] Photos authorization: \(authStatus.rawValue) (0=notDetermined,1=restricted,2=denied,3=authorized,4=limited)")

        var coord: CLLocationCoordinate2D? = nil
        var accuracy: Double? = nil
        var captureDate: Date? = nil
        if let assetId = item.itemIdentifier {
            coord = await phAssetCoordinate(assetIdentifier: assetId)
        } else {
            print("[GPS] itemIdentifier отсутствует — PHAsset недоступен")
        }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }

        if coord == nil {
            if let result = PhotoMetadataService.gpsResult(from: data) {
                coord = result.coordinate
                accuracy = result.horizontalAccuracy
                print("[GPS] EXIF из Data: \(result.coordinate.latitude), \(result.coordinate.longitude), accuracy: \(accuracy.map { String($0) } ?? "nil")")
            } else {
                print("[GPS] EXIF из Data: не найден")
            }
        }
        captureDate = PhotoMetadataService.captureDate(from: data)

        handleImage(image, coordinate: coord, accuracy: accuracy, captureDate: captureDate)
    }

    private func phAssetCoordinate(assetIdentifier: String) async -> CLLocationCoordinate2D? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        print("[GPS] requestAuthorization result: \(status.rawValue)")
        guard status == .authorized || status == .limited else {
            print("[GPS] нет разрешения на Photos")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
            print("[GPS] PHAsset.fetchAssets count: \(fetchResult.count)")
            guard let asset = fetchResult.firstObject else {
                continuation.resume(returning: nil)
                return
            }
            print("[GPS] asset.location: \(String(describing: asset.location))")
            guard let loc = asset.location else {
                continuation.resume(returning: nil)
                return
            }
            let coord = loc.coordinate
            print("[GPS] coord: \(coord.latitude), \(coord.longitude), valid: \(CLLocationCoordinate2DIsValid(coord))")
            guard CLLocationCoordinate2DIsValid(coord),
                  coord.latitude != 0 || coord.longitude != 0 else {
                continuation.resume(returning: nil)
                return
            }
            continuation.resume(returning: coord)
        }
    }

    private func handleImage(_ image: UIImage, coordinate: CLLocationCoordinate2D? = nil,
                             accuracy: Double? = nil, captureDate: Date? = nil) {
        dismiss()
        onCapture(image, coordinate, accuracy, captureDate)
    }
}

// MARK: - CameraPickerView (UIImagePickerController wrapper)

struct CameraPickerView: UIViewControllerRepresentable {
    let onCapture: (UIImage, CLLocationCoordinate2D?, Double?, Date?) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onCancel: onCancel) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage, CLLocationCoordinate2D?, Double?, Date?) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage, CLLocationCoordinate2D?, Double?, Date?) -> Void,
             onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { return }
            let result = PhotoMetadataService.gpsResult(fromCameraInfo: info)
            let coord = result?.coordinate
            let accuracy = result?.horizontalAccuracy
            let captureDate = PhotoMetadataService.captureDate(fromCameraInfo: info)
            if let coord {
                print("[EXIF] координаты из камеры: \(coord.latitude), \(coord.longitude), accuracy: \(accuracy.map { String($0) } ?? "nil")")
            } else {
                print("[EXIF] GPS в снимке камеры не найден")
            }
            DispatchQueue.main.async { self.onCapture(image, coord, accuracy, captureDate) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            DispatchQueue.main.async { self.onCancel() }
        }
    }
}
