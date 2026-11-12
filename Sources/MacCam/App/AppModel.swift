import Foundation
import AVFoundation
import AppKit
import Combine
import UniformTypeIdentifiers

/// Thread-safe holder for the most recent processed frame, read by the Metal preview.
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var generation = 0

    func put(_ b: CVPixelBuffer) { lock.locked { buffer = b; generation &+= 1 } }
    func take(after gen: Int) -> (CVPixelBuffer, Int)? {
        lock.locked { () -> (CVPixelBuffer, Int)? in
            guard let buffer, generation != gen else { return nil }
            return (buffer, generation)
        }
    }
    var latest: CVPixelBuffer? { lock.locked { buffer } }
}

@MainActor
final class AppModel: ObservableObject {
    let camera = CameraManager()
    let processor = FrameProcessor()
    let frames = FrameStore()
    let recorder = Recorder()
    let virtualCamera = VirtualCameraSink()
    let installer = ExtensionInstaller()
    let presets = PresetStore()

    @Published private(set) var controls = UVCControlStore(device: nil)
    @Published private(set) var uvcDevices: [UVCDevice] = []
    @Published var settings: ProcessingSettings {
        didSet {
            guard settings != oldValue else { return }
            processor.settings = settings
            saveSettings()
        }
    }

    @Published var histogram: [[Float]] = []
    @Published var stats: FrameProcessor.FrameStats?
    @Published var showHistogram = true
    @Published var showGrid = false
    @Published var showFramingOverlay = false
    @Published private(set) var isRecording = false
    @Published private(set) var virtualCameraStatus: VirtualCameraSink.Status = .off
    @Published var toast: String?

    @Published var autoRestoreOnConnect: Bool = UserDefaults.standard.object(forKey: "autoRestore") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRestoreOnConnect, forKey: "autoRestore") }
    }
    @Published var recordHEVC: Bool = UserDefaults.standard.bool(forKey: "recordHEVC") {
        didSet { UserDefaults.standard.set(recordHEVC, forKey: "recordHEVC") }
    }

    private var cancellables = Set<AnyCancellable>()
    private var reconnectTimer: Timer?

    init() {
        if let data = UserDefaults.standard.data(forKey: "processingSettings"),
           let saved = try? JSONDecoder().decode(ProcessingSettings.self, from: data) {
            settings = saved
        } else {
            settings = ProcessingSettings()
        }
        processor.settings = settings
        wirePipeline()

        camera.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        // Forward nested object changes so views observing AppModel refresh.
        camera.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        installer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    private func wirePipeline() {
        let processor = processor, frames = frames, recorder = recorder, virtualCamera = virtualCamera
        camera.sampleHandler = { sample in processor.process(sample) }
        processor.onFrame = { buffer, time in
            frames.put(buffer)
            recorder.append(buffer, time: time)
        }
        processor.onVirtualCameraFrame = { buffer, _ in virtualCamera.send(buffer) }
        processor.onHistogram = { [weak self] h in
            DispatchQueue.main.async { self?.histogram = h }
        }
        processor.onStats = { [weak self] s in
            DispatchQueue.main.async { self?.stats = s }
        }
    }

    // MARK: Startup & devices

    func start() async {
        guard await camera.requestAccess() else { return }
        camera.refreshDevices()
        uvcDevices = UVCDevice.discoverAll()
        let lastID = UserDefaults.standard.string(forKey: "lastCamera")
        if let device = camera.devices.first(where: { $0.uniqueID == lastID }) ?? camera.preferredDevice {
            await select(device)
        }
        if UserDefaults.standard.bool(forKey: "virtualCameraOn") {
            setVirtualCamera(true)
        }
    }

    func select(_ device: AVCaptureDevice) async {
        UserDefaults.standard.set(device.uniqueID, forKey: "lastCamera")
        camera.select(device, preferredFormatID: UserDefaults.standard.string(forKey: "format.\(device.uniqueID)"))

        controls.invalidate()
        if uvcDevices.isEmpty { uvcDevices = UVCDevice.discoverAll() }
        let uvc = matchUVC(for: device)
        let store = UVCControlStore(device: uvc)
        controls = store
        await store.load()
        if autoRestoreOnConnect { store.restoreSaved() }
    }

    func selectFormat(_ option: CaptureFormatOption) {
        guard let device = camera.activeDevice else { return }
        UserDefaults.standard.set(option.id, forKey: "format.\(device.uniqueID)")
        camera.selectFormat(option)
    }

    private func matchUVC(for device: AVCaptureDevice) -> UVCDevice? {
        if let identity = USBCameraIdentity(uniqueID: device.uniqueID) {
            if let exact = uvcDevices.first(where: { $0.locationID == identity.locationID }) { return exact }
            if let ids = uvcDevices.first(where: { $0.vendorID == identity.vendorID && $0.productID == identity.productID }) {
                return ids
            }
        }
        if let named = uvcDevices.first(where: { $0.name == device.localizedName }) { return named }
        // Built-in FaceTime cameras aren't UVC; only fall back when it's clearly an external camera.
        if device.localizedName.localizedCaseInsensitiveContains("FaceTime") { return nil }
        return uvcDevices.count == 1 ? uvcDevices.first : nil
    }

    private func devicesChanged() {
        uvcDevices = UVCDevice.discoverAll()
        // Camera came back (e.g. replugged) → reselect it, which re-applies its saved settings.
        let lastID = UserDefaults.standard.string(forKey: "lastCamera")
        if camera.activeDevice == nil || controls.device == nil,
           let device = camera.devices.first(where: { $0.uniqueID == lastID }) ?? camera.preferredDevice {
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000) // let the camera finish enumerating
                await select(device)
                if autoRestoreOnConnect, controls.savedValues != nil { flash("Restored your settings on \(device.localizedName)") }
            }
        }
    }

    func reloadControls() async {
        uvcDevices = UVCDevice.discoverAll()
        if let device = camera.activeDevice { await select(device) }
    }

    // MARK: Presets

    func apply(_ preset: Preset) {
        var s = preset.software
        // Keep the user's output size and background image choice unless the preset sets them.
        s.outputResolution = settings.outputResolution
        if s.backgroundImagePath == nil { s.backgroundImagePath = settings.backgroundImagePath }
        settings = s
        if !preset.hardware.isEmpty { controls.apply(preset.hardware) }
        flash("Applied “\(preset.name)”")
    }

    func saveCurrentAsPreset(named name: String) {
        presets.add(name: name, hardware: controls.snapshot(), software: settings)
        flash("Saved “\(name)”")
    }

    func resetSoftware() {
        var s = ProcessingSettings()
        s.outputResolution = settings.outputResolution
        settings = s
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "processingSettings")
        }
    }

    // MARK: Virtual camera

    func setVirtualCamera(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "virtualCameraOn")
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        if on {
            virtualCameraStatus = virtualCamera.connect()
            processor.virtualCameraEnabled = virtualCameraStatus == .streaming
            if virtualCameraStatus != .streaming {
                // Keep trying: the extension may still be activating.
                reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.virtualCameraStatus = self.virtualCamera.connect()
                        if self.virtualCameraStatus == .streaming {
                            self.processor.virtualCameraEnabled = true
                            self.reconnectTimer?.invalidate()
                        }
                    }
                }
            }
        } else {
            processor.virtualCameraEnabled = false
            virtualCamera.disconnect()
            virtualCameraStatus = .off
        }
    }

    var virtualCameraOn: Bool { UserDefaults.standard.bool(forKey: "virtualCameraOn") }

    // MARK: Capture

    /// Saves the current processed frame as a full-quality PNG.
    func snapshot() {
        guard let buffer = frames.latest, let cg = processor.cgImage(from: buffer) else {
            flash("No frame to capture yet")
            return
        }
        let url = Self.captureFolder().appendingPathComponent("MacCam \(Self.timestamp()).png")
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            flash("Saved photo to Pictures/MacCam")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop { [weak self] url in
                DispatchQueue.main.async {
                    self?.isRecording = false
                    if let url {
                        self?.flash("Saved video to Movies/MacCam")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        } else {
            let url = Self.movieFolder().appendingPathComponent("MacCam \(Self.timestamp()).mov")
            do {
                try recorder.start(url: url, size: settings.outputResolution.size, hevc: recordHEVC)
                isRecording = true
            } catch {
                flash("Recording failed: \(error.localizedDescription)")
            }
        }
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.backgroundImagePath = url.path
            settings.backgroundMode = .image
        }
    }

    func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == message { toast = nil }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    private static func captureFolder() -> URL {
        folder(.picturesDirectory)
    }

    private static func movieFolder() -> URL {
        folder(.moviesDirectory)
    }

    private static func folder(_ dir: FileManager.SearchPathDirectory) -> URL {
        let url = FileManager.default.urls(for: dir, in: .userDomainMask)[0].appendingPathComponent("MacCam", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
