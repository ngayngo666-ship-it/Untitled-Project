@preconcurrency import AVFoundation
import Combine
import Foundation

struct CameraSource: Identifiable, Hashable {
    let id: String
    let name: String
    let position: AVCaptureDevice.Position
}

private enum CameraSessionError: Error {
    case cannotAddInput
    case configurationFailed
    case zoomFailed
    case torchFailed
}

private final class CameraSessionManager: @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.aech.vcam.camera-session")
    private var activeInput: AVCaptureDeviceInput?
    private var isConfigured = false

    func configure(
        with device: AVCaptureDevice,
        completion: @escaping @MainActor @Sendable (Result<Bool, CameraSessionError>) -> Void
    ) {
        queue.async { [self] in
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            session.sessionPreset = .high
            let previousInput = activeInput

            if let previousInput {
                session.removeInput(previousInput)
            }

            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(newInput) else {
                    restore(previousInput)
                    Task { @MainActor in completion(.failure(.cannotAddInput)) }
                    return
                }

                session.addInput(newInput)
                activeInput = newInput
                isConfigured = true
                Task { @MainActor in completion(.success(device.hasTorch)) }
            } catch {
                restore(previousInput)
                Task { @MainActor in completion(.failure(.configurationFailed)) }
            }
        }
    }

    func start(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard isConfigured else {
                Task { @MainActor in completion(false) }
                return
            }

            if !session.isRunning {
                session.startRunning()
            }
            let isRunning = session.isRunning
            Task { @MainActor in completion(isRunning) }
        }
    }

    func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [self] in
            disableTorchIfPossible()
            if session.isRunning {
                session.stopRunning()
            }
            Task { @MainActor in completion() }
        }
    }

    func pause(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard session.isRunning else {
                Task { @MainActor in completion(false) }
                return
            }

            session.stopRunning()
            Task { @MainActor in completion(true) }
        }
    }

    func setZoom(
        _ value: Double,
        completion: @escaping @MainActor @Sendable (Result<Double, CameraSessionError>) -> Void
    ) {
        queue.async { [self] in
            guard let device = activeInput?.device else { return }
            let upperBound = min(device.activeFormat.videoMaxZoomFactor, 3)
            let clampedValue = max(1, min(CGFloat(value), upperBound))

            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clampedValue
                device.unlockForConfiguration()
                let updatedZoom = Double(clampedValue)
                Task { @MainActor in completion(.success(updatedZoom)) }
            } catch {
                Task { @MainActor in completion(.failure(.zoomFailed)) }
            }
        }
    }

    func setTorch(
        enabled: Bool,
        level: Double,
        completion: @escaping @MainActor @Sendable (Result<Bool, CameraSessionError>) -> Void
    ) {
        queue.async { [self] in
            guard let device = activeInput?.device, device.hasTorch else {
                Task { @MainActor in completion(.success(false)) }
                return
            }

            do {
                try device.lockForConfiguration()
                if enabled {
                    let clampedLevel = Float(max(0.01, min(level, 1)))
                    try device.setTorchModeOn(level: clampedLevel)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
                Task { @MainActor in completion(.success(enabled)) }
            } catch {
                Task { @MainActor in completion(.failure(.torchFailed)) }
            }
        }
    }

    private func restore(_ input: AVCaptureDeviceInput?) {
        guard let input, session.canAddInput(input) else {
            activeInput = nil
            isConfigured = false
            return
        }

        session.addInput(input)
        activeInput = input
        isConfigured = true
    }

    private func disableTorchIfPossible() {
        guard let device = activeInput?.device, device.hasTorch else { return }

        do {
            try device.lockForConfiguration()
            device.torchMode = .off
            device.unlockForConfiguration()
        } catch {
            // Stopping the session should continue even if the torch cannot be changed.
        }
    }
}

@MainActor
final class CameraModel: ObservableObject {
    enum AuthorizationState {
        case unknown
        case authorized
        case denied
        case unavailable
    }

    @Published private(set) var authorizationState: AuthorizationState = .unknown
    @Published private(set) var sources: [CameraSource] = []
    @Published private(set) var selectedSourceID: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var zoom: Double = 1
    @Published private(set) var isTorchEnabled = false
    @Published private(set) var canUseTorch = false

    private let sessionManager = CameraSessionManager()

    var session: AVCaptureSession {
        sessionManager.session
    }

    func prepare() async {
        discoverSources()

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationState = .authorized
        case .notDetermined:
            authorizationState = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        case .denied, .restricted:
            authorizationState = .denied
        @unknown default:
            authorizationState = .denied
        }

        guard authorizationState == .authorized else { return }
        guard let device = preferredDevice() else {
            authorizationState = .unavailable
            return
        }

        configureSession(with: device, shouldStart: true)
    }

    func start() {
        sessionManager.start { [weak self] running in
            guard let self else { return }
            self.isRunning = running
            self.isPaused = false
        }
    }

    func stop() {
        sessionManager.stop { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.isPaused = false
            self.isTorchEnabled = false
        }
    }

    func toggleRunning() {
        isRunning ? stop() : start()
    }

    func togglePause() {
        if isRunning {
            sessionManager.pause { [weak self] didPause in
                guard let self, didPause else { return }
                self.isRunning = false
                self.isPaused = true
            }
        } else {
            start()
        }
    }

    func selectSource(id: String) {
        guard let device = availableDevices().first(where: { $0.uniqueID == id }) else { return }
        configureSession(with: device, shouldStart: true)
    }

    func cycleCamera() {
        guard !sources.isEmpty else { return }
        let currentIndex = sources.firstIndex(where: { $0.id == selectedSourceID }) ?? -1
        let nextIndex = (currentIndex + 1) % sources.count
        selectSource(id: sources[nextIndex].id)
    }

    func setZoom(_ value: Double) {
        sessionManager.setZoom(value) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let updatedZoom):
                self.zoom = updatedZoom
            case .failure:
                self.errorMessage = "Unable to change camera zoom."
            }
        }
    }

    func setTorch(enabled: Bool, level: Double) {
        sessionManager.setTorch(enabled: enabled, level: level) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let isEnabled):
                self.isTorchEnabled = isEnabled
            case .failure:
                self.errorMessage = "Unable to control the camera light."
                self.isTorchEnabled = false
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func configureSession(with device: AVCaptureDevice, shouldStart: Bool) {
        sessionManager.configure(with: device) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let hasTorch):
                self.selectedSourceID = device.uniqueID
                self.canUseTorch = hasTorch
                self.zoom = 1
                self.isTorchEnabled = false
                self.errorMessage = nil
                if shouldStart {
                    self.start()
                }
            case .failure(.cannotAddInput):
                self.errorMessage = "The selected camera cannot be used."
            case .failure:
                self.errorMessage = "Unable to configure the selected camera."
            }
        }
    }

    private func discoverSources() {
        let devices = availableDevices()
        sources = devices.map {
            CameraSource(id: $0.uniqueID, name: sourceName(for: $0), position: $0.position)
        }
    }

    private func preferredDevice() -> AVCaptureDevice? {
        let devices = availableDevices()
        return devices.first(where: { $0.position == .front }) ?? devices.first
    }

    private func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private func sourceName(for device: AVCaptureDevice) -> String {
        switch device.position {
        case .front:
            return "Front Camera"
        case .back:
            return "Back Camera"
        default:
            return device.localizedName
        }
    }
}
