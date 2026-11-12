import Foundation
import AVFoundation
import Combine
import QuartzCore

struct CaptureFormatOption: Identifiable, Hashable {
    let id: String
    let index: Int
    let width: Int
    let height: Int
    let maxFPS: Double
    let codec: String

    var label: String {
        let fps = maxFPS.rounded() == maxFPS ? String(Int(maxFPS)) : String(format: "%.2f", maxFPS)
        return "\(width)×\(height) · \(fps) fps · \(codec)"
    }

    var pixels: Int { width * height }
}

/// Parses AVFoundation's USB camera uniqueID ("0x" + locationID + vendorID + productID).
struct USBCameraIdentity {
    let locationID: UInt32
    let vendorID: Int
    let productID: Int

    init?(uniqueID: String) {
        var hex = uniqueID.lowercased()
        guard hex.hasPrefix("0x") else { return nil }
        hex.removeFirst(2)
        guard hex.count == 16, hex.allSatisfy(\.isHexDigit) else { return nil }
        let chars = Array(hex)
        guard let loc = UInt32(String(chars[0..<8]), radix: 16),
              let vid = Int(String(chars[8..<12]), radix: 16),
              let pid = Int(String(chars[12..<16]), radix: 16) else { return nil }
        locationID = loc
        vendorID = vid
        productID = pid
    }
}

/// Owns the AVCaptureSession: device list, format selection, and frame delivery.
final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var activeDevice: AVCaptureDevice?
    @Published private(set) var formats: [CaptureFormatOption] = []
    @Published private(set) var activeFormatID: String?
    @Published private(set) var isRunning = false
    @Published private(set) var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var errorMessage: String?
    @Published private(set) var measuredFPS: Double = 0

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "framelight.session")
    private let videoQueue = DispatchQueue(label: "framelight.video", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var observers: [NSObjectProtocol] = []
    private var fpsCounter = 0
    private var fpsWindowStart = CACurrentMediaTime()

    /// Called on the video queue for every captured frame.
    var sampleHandler: ((CMSampleBuffer) -> Void)?
    /// Called on the main queue when a camera is plugged in or removed.
    var onDevicesChanged: (() -> Void)?

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }

        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDevices()
                self?.onDevicesChanged?()
            })
        }
        refreshDevices()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func requestAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        await MainActor.run { self.authorization = AVCaptureDevice.authorizationStatus(for: .video) }
        return granted
    }

    func refreshDevices() {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        let discovered = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        // Never offer our own virtual camera as a source (it would feed back into itself).
        devices = discovered.filter { $0.uniqueID.uppercased() != VirtualCameraConfig.deviceUUID.uuidString.uppercased() }
            .filter { !$0.localizedName.contains(VirtualCameraConfig.deviceName) }
        if let active = activeDevice, !devices.contains(where: { $0.uniqueID == active.uniqueID }) {
            stop()
            activeDevice = nil
        }
    }

    /// Prefers external USB cameras (like the Kreo Owl) over the built-in one.
    var preferredDevice: AVCaptureDevice? {
        devices.first { USBCameraIdentity(uniqueID: $0.uniqueID) != nil } ?? devices.first
    }

    func select(_ device: AVCaptureDevice, preferredFormatID: String? = nil) {
        activeDevice = device
        formats = Self.formatOptions(for: device)
        let chosen = formats.first { $0.id == preferredFormatID } ?? Self.bestDefault(formats)
        sessionQueue.async { [weak self] in
            self?.configure(device: device, format: chosen)
        }
    }

    func selectFormat(_ option: CaptureFormatOption) {
        guard let device = activeDevice else { return }
        sessionQueue.async { [weak self] in
            self?.configure(device: device, format: option)
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning, self.input != nil else { return }
            self.session.startRunning()
            let running = self.session.isRunning
            DispatchQueue.main.async { self.isRunning = running }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func configure(device: AVCaptureDevice, format: CaptureFormatOption?) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if input?.device.uniqueID != device.uniqueID {
            if let input { session.removeInput(input) }
            input = nil
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(newInput) else { throw CameraError("The camera can't be added to the session.") }
                session.addInput(newInput)
                input = newInput
            } catch {
                publishError("Couldn't open \(device.localizedName): \(error.localizedDescription)")
                return
            }
        }

        if let format, format.index < device.formats.count {
            do {
                try device.lockForConfiguration()
                let f = device.formats[format.index]
                device.activeFormat = f
                if let range = f.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                    device.activeVideoMinFrameDuration = range.minFrameDuration
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.activeFormatID = format.id }
            } catch {
                publishError("Couldn't set format: \(error.localizedDescription)")
            }
        }

        DispatchQueue.main.async { self.errorMessage = nil }
        // Runs after this configuration block finishes (same serial queue).
        start()
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { self.errorMessage = message }
    }

    static func formatOptions(for device: AVCaptureDevice) -> [CaptureFormatOption] {
        var seen = Set<String>()
        var options: [CaptureFormatOption] = []
        for (i, f) in device.formats.enumerated() {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let codec = fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription))
            let id = "\(dims.width)x\(dims.height)@\(Int(fps.rounded()))-\(codec)"
            guard seen.insert(id).inserted else { continue }
            options.append(CaptureFormatOption(id: id, index: i, width: Int(dims.width), height: Int(dims.height),
                                               maxFPS: fps, codec: codec))
        }
        return options.sorted { ($0.pixels, $0.maxFPS) > ($1.pixels, $1.maxFPS) }
    }

    /// Highest resolution that still runs at ~30 fps.
    static func bestDefault(_ options: [CaptureFormatOption]) -> CaptureFormatOption? {
        options.first { $0.maxFPS >= 29 } ?? options.first
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_JPEG_OpenDML, kCMVideoCodecType_JPEG: return "MJPEG"
        case kCVPixelFormatType_422YpCbCr8_yuvs, kCVPixelFormatType_422YpCbCr8: return "YUY2"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "NV12"
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
            let s = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
            return s.isEmpty ? "RAW" : s
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        sampleHandler?(sampleBuffer)

        fpsCounter += 1
        let now = CACurrentMediaTime()
        if now - fpsWindowStart >= 1 {
            let fps = Double(fpsCounter) / (now - fpsWindowStart)
            fpsCounter = 0
            fpsWindowStart = now
            DispatchQueue.main.async { self.measuredFPS = fps }
        }
    }
}

struct CameraError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
