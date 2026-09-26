import Foundation
import Combine

@MainActor
final class VCamModel: ObservableObject {
    enum SourceType: String, Codable {
        case realCamera
        case video
        case image
    }

    enum MediaKind: String, Codable {
        case image
        case video
    }

    struct MediaSlot: Codable, Identifiable, Equatable {
        let id: Int
        let kind: MediaKind
        let path: String

        var url: URL {
            URL(fileURLWithPath: path)
        }
    }

    private struct HelperStatus: Codable {
        let state: String
        let detail: String
        let updatedAt: TimeInterval
    }

    private struct SharedConfiguration: Codable {
        var isEnabled = false
        var sourceType = SourceType.realCamera
        var selectedVideoPath: String?
        var selectedImagePath: String?
        var isPaused = false
        var isLoopEnabled = true
        var playbackSpeed = 1.0
        var rotationDegrees: Double?
        var isMirrored: Bool?
        var zoom: Double?
        var offsetX: Double?
        var offsetY: Double?
        var lightEnabled: Bool?
        var lightIntensity: Double?
        var enabledApplications: [String]?
        var mediaSlots: [MediaSlot]?
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var sourceType: SourceType = .realCamera
    @Published private(set) var selectedVideoURL: URL?
    @Published private(set) var selectedImageURL: URL?
    @Published private(set) var isPaused = false
    @Published private(set) var isLoopEnabled = true
    @Published private(set) var playbackSpeed = 1.0
    @Published private(set) var rotationDegrees = 0.0
    @Published private(set) var isMirrored = false
    @Published private(set) var zoom = 1.0
    @Published private(set) var offsetX = 0.0
    @Published private(set) var offsetY = 0.0
    @Published private(set) var lightEnabled = false
    @Published private(set) var lightIntensity = 0.5
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var enabledApplications: [String] = []
    @Published private(set) var mediaSlots: [MediaSlot] = []
    @Published private(set) var helperState = "Unknown"
    @Published private(set) var helperDetail = "No helper status yet"

    private let fileManager = FileManager.default
    private let notificationName = "com.aech.vcam.configuration-changed" as CFString

    private var sharedDirectoryURL: URL {
        let jailbreakURL = URL(fileURLWithPath: "/var/mobile/Library/Application Support/VCam", isDirectory: true)
        let jailbreakParent = jailbreakURL.deletingLastPathComponent()

        if fileManager.isWritableFile(atPath: jailbreakParent.path) {
            return jailbreakURL
        }

        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VCam", isDirectory: true)
    }

    private var configurationURL: URL {
        sharedDirectoryURL.appendingPathComponent("configuration.json")
    }

    private var helperStatusURL: URL {
        sharedDirectoryURL.appendingPathComponent("helper-status.json")
    }

    init() {
        load()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        persistAndNotify()
    }

    func toggleEnabled() {
        setEnabled(!isEnabled)
    }

    func useRealCamera() {
        sourceType = .realCamera
        isPaused = false
        persistAndNotify()
    }

    func importImageData(_ data: Data, slot: Int) throws -> URL {
        try prepareSharedDirectory()
        let destination = sharedDirectoryURL.appendingPathComponent("source-\(slot).jpg")
        try data.write(to: destination, options: .atomic)
        updateMediaSlot(id: slot, kind: .image, url: destination)
        useImage(destination)
        return destination
    }

    func importVideo(from sourceURL: URL, slot: Int) async throws -> URL {
        let directoryURL = sharedDirectoryURL
        let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destination = directoryURL.appendingPathComponent("source-\(slot).\(fileExtension)")

        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
        }.value

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        updateMediaSlot(id: slot, kind: .video, url: destination)
        useVideo(destination)
        return destination
    }

    func useSlot(_ slot: MediaSlot) {
        switch slot.kind {
        case .image:
            useImage(slot.url)
        case .video:
            useVideo(slot.url)
        }
    }

    func removeMediaSlot(id: Int) {
        guard let slot = mediaSlots.first(where: { $0.id == id }) else { return }
        try? fileManager.removeItem(at: slot.url)
        mediaSlots.removeAll { $0.id == id }
        persistAndNotify()
    }

    func setEnabledApplications(_ bundleIdentifiers: [String]) {
        enabledApplications = Array(Set(bundleIdentifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "com.aech.vcam" })).sorted()
        persistAndNotify()
    }

    func refreshDiagnostics() {
        guard let data = try? Data(contentsOf: helperStatusURL),
              let status = try? JSONDecoder().decode(HelperStatus.self, from: data) else {
            helperState = "Unavailable"
            helperDetail = "VCamMediaBridge has not reported status"
            return
        }

        let age = Date().timeIntervalSince1970 - status.updatedAt
        helperState = age < 10 ? status.state.capitalized : "Stale"
        helperDetail = age < 10 ? status.detail : "Last helper update was \(Int(age)) seconds ago"
    }

    func useVideo(_ url: URL) {
        selectedVideoURL = url
        sourceType = .video
        isPaused = false
        persistAndNotify()
    }

    func useImage(_ url: URL) {
        selectedImageURL = url
        sourceType = .image
        isPaused = false
        persistAndNotify()
    }

    func togglePause() {
        guard sourceType == .video else { return }
        isPaused.toggle()
        persistAndNotify()
    }

    func toggleLoop() {
        isLoopEnabled.toggle()
        persistAndNotify()
    }

    func setPlaybackSpeed(_ speed: Double) {
        guard [0.5, 1.0, 2.0].contains(speed) else { return }
        playbackSpeed = speed
        persistAndNotify()
    }

    func setSpeed(_ speed: Double) {
        setPlaybackSpeed(speed)
    }

    func setTransform(
        rotationDegrees: Double,
        isMirrored: Bool,
        zoom: Double,
        offsetX: Double,
        offsetY: Double
    ) {
        self.rotationDegrees = rotationDegrees
        self.isMirrored = isMirrored
        self.zoom = min(max(zoom, 1), 8)
        self.offsetX = min(max(offsetX, -1), 1)
        self.offsetY = min(max(offsetY, -1), 1)
        persistAndNotify()
    }

    func setLighting(enabled: Bool, intensity: Double) {
        lightEnabled = enabled
        lightIntensity = min(max(intensity, 0), 1)
        persistAndNotify()
    }

    func clearError() {
        lastErrorMessage = nil
    }

    private func persistAndNotify() {
        do {
            try prepareSharedDirectory()
            let configuration = SharedConfiguration(
                isEnabled: isEnabled,
                sourceType: sourceType,
                selectedVideoPath: selectedVideoURL?.path,
                selectedImagePath: selectedImageURL?.path,
                isPaused: isPaused,
                isLoopEnabled: isLoopEnabled,
                playbackSpeed: playbackSpeed,
                rotationDegrees: rotationDegrees,
                isMirrored: isMirrored,
                zoom: zoom,
                offsetX: offsetX,
                offsetY: offsetY,
                lightEnabled: lightEnabled,
                lightIntensity: lightIntensity,
                enabledApplications: enabledApplications,
                mediaSlots: mediaSlots
            )
            let data = try JSONEncoder().encode(configuration)
            try data.write(to: configurationURL, options: .atomic)
            lastErrorMessage = nil
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(notificationName),
                nil,
                nil,
                true
            )
        } catch {
            lastErrorMessage = "Unable to save the shared VCam configuration."
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(SharedConfiguration.self, from: data) else {
            return
        }

        isEnabled = configuration.isEnabled
        sourceType = configuration.sourceType
        selectedVideoURL = configuration.selectedVideoPath.map(URL.init(fileURLWithPath:))
        selectedImageURL = configuration.selectedImagePath.map(URL.init(fileURLWithPath:))
        isPaused = configuration.isPaused
        isLoopEnabled = configuration.isLoopEnabled
        playbackSpeed = configuration.playbackSpeed
        rotationDegrees = configuration.rotationDegrees ?? 0
        isMirrored = configuration.isMirrored ?? false
        zoom = configuration.zoom ?? 1
        offsetX = configuration.offsetX ?? 0
        offsetY = configuration.offsetY ?? 0
        lightEnabled = configuration.lightEnabled ?? false
        lightIntensity = configuration.lightIntensity ?? 0.5
        enabledApplications = configuration.enabledApplications ?? []
        mediaSlots = (configuration.mediaSlots ?? []).filter {
            fileManager.fileExists(atPath: $0.path)
        }
        refreshDiagnostics()
    }

    private func prepareSharedDirectory() throws {
        try fileManager.createDirectory(
            at: sharedDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
    }

    private func updateMediaSlot(id: Int, kind: MediaKind, url: URL) {
        mediaSlots.removeAll { $0.id == id }
        mediaSlots.append(MediaSlot(id: id, kind: kind, path: url.path))
        mediaSlots.sort { $0.id < $1.id }
    }
}
