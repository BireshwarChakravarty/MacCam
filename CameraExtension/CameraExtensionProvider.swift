import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import CoreGraphics
import AppKit

// MacCam Virtual Camera
//
// One device with two streams:
//   • a SINK stream that the MacCam app pushes processed frames into, and
//   • a SOURCE stream that Zoom / Meet / Teams / OBS read from.
// When the app isn't sending, the source shows a placeholder card.

private let frameDuration = CMTime(value: 1, timescale: VirtualCameraConfig.frameRate)

// MARK: - Device

final class VirtualDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: VirtualStreamSource!
    private var sinkStream: VirtualSinkSource!

    private let formatDescription: CMFormatDescription
    private var pool: CVPixelBufferPool!
    private var placeholder: CVPixelBuffer?

    private let timerQueue = DispatchQueue(label: "maccam.extension.timer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var sinkTimer: DispatchSourceTimer?

    private let lock = NSLock()
    private var latestAppFrame: CVPixelBuffer?
    private var latestAppFrameTime: UInt64 = 0
    private var sourceStreaming = 0
    private var sinkClient: CMIOExtensionClient?

    init(localizedName: String) {
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: VirtualCameraConfig.width, height: VirtualCameraConfig.height,
                                       extensions: nil, formatDescriptionOut: &fd)
        formatDescription = fd!
        super.init()

        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: VirtualCameraConfig.deviceUUID,
                                     legacyDeviceID: VirtualCameraConfig.deviceUUID.uuidString, source: self)

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(VirtualCameraConfig.width),
            kCVPixelBufferHeightKey as String: Int(VirtualCameraConfig.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)

        let streamFormat = CMIOExtensionStreamFormat(formatDescription: formatDescription,
                                                     maxFrameDuration: frameDuration, minFrameDuration: frameDuration,
                                                     validFrameDurations: nil)
        sourceStream = VirtualStreamSource(localizedName: "\(localizedName) Output", streamID: VirtualCameraConfig.sourceStreamUUID,
                                           format: streamFormat, device: self)
        sinkStream = VirtualSinkSource(localizedName: "\(localizedName) Input", streamID: VirtualCameraConfig.sinkStreamUUID,
                                       format: streamFormat, device: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }
        placeholder = makePlaceholder()
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            props.transportType = 0x7669_7274 // 'virt' (kIOAudioDeviceTransportTypeVirtual)
        }
        if properties.contains(.deviceModel) {
            props.model = VirtualCameraConfig.model
        }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source stream (what other apps read)

    func startSourceStreaming() {
        lock.lock()
        sourceStreaming += 1
        let shouldStart = timer == nil
        lock.unlock()
        guard shouldStart else { return }

        let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        t.schedule(deadline: .now(), repeating: frameDuration.seconds, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.emitFrame() }
        timer = t
        t.resume()
    }

    func stopSourceStreaming() {
        lock.lock()
        sourceStreaming = max(0, sourceStreaming - 1)
        let shouldStop = sourceStreaming == 0
        lock.unlock()
        if shouldStop {
            timer?.cancel()
            timer = nil
        }
    }

    private func emitFrame() {
        let now = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
        lock.lock()
        // Use the app's frame if it's fresh (< 1 s old), else the placeholder.
        let fresh = latestAppFrame != nil && now &- latestAppFrameTime < 1_000_000_000
        let buffer = fresh ? latestAppFrame : placeholder
        lock.unlock()
        guard let buffer else { return }

        var timing = CMSampleTimingInfo(duration: frameDuration,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var formatForBuffer: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                     formatDescriptionOut: &formatForBuffer)
        guard let formatForBuffer else { return }
        var sampleBuffer: CMSampleBuffer?
        let err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true,
                                                     makeDataReadyCallback: nil, refcon: nil,
                                                     formatDescription: formatForBuffer, sampleTiming: &timing,
                                                     sampleBufferOut: &sampleBuffer)
        guard err == noErr, let sampleBuffer else { return }
        sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: now)
    }

    // MARK: Sink stream (what the MacCam app writes)

    func startSink(client: CMIOExtensionClient?) {
        lock.lock()
        sinkClient = client
        lock.unlock()
        guard sinkTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        t.schedule(deadline: .now(), repeating: frameDuration.seconds / 2, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.consumeFromApp() }
        sinkTimer = t
        t.resume()
    }

    func stopSink() {
        sinkTimer?.cancel()
        sinkTimer = nil
        lock.lock()
        sinkClient = nil
        latestAppFrame = nil
        lock.unlock()
    }

    private func consumeFromApp() {
        lock.lock()
        let client = sinkClient
        lock.unlock()
        guard let client else { return }

        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, error in
            guard let self, error == nil, let sampleBuffer,
                  let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let now = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
            self.lock.lock()
            self.latestAppFrame = image
            self.latestAppFrameTime = now
            self.lock.unlock()
            let output = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: now)
            self.sinkStream.stream.notifyScheduledOutputChanged(output)
        }
    }

    // MARK: Placeholder

    private func makePlaceholder() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return buffer }

        // Dark gradient card with a message.
        let colors = [CGColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1), CGColor(red: 0.16, green: 0.18, blue: 0.26, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        let title = NSAttributedString(string: "MacCam", attributes: [
            .font: NSFont.systemFont(ofSize: 96, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let subtitle = NSAttributedString(string: "Open the MacCam app to start the camera", attributes: [
            .font: NSFont.systemFont(ofSize: 40, weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.7),
        ])
        let ts = title.size(), ss = subtitle.size()
        title.draw(at: CGPoint(x: (CGFloat(width) - ts.width) / 2, y: CGFloat(height) / 2 + 10))
        subtitle.draw(at: CGPoint(x: (CGFloat(width) - ss.width) / 2, y: CGFloat(height) / 2 - ss.height - 20))
        NSGraphicsContext.restoreGraphicsState()
        return buffer
    }
}

// MARK: - Streams

final class VirtualStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: VirtualDeviceSource

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: VirtualDeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { props.frameDuration = frameDuration }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { activeFormatIndex = index }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { device.startSourceStreaming() }

    func stopStream() throws { device.stopSourceStreaming() }
}

final class VirtualSinkSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: VirtualDeviceSource
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: VirtualDeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { props.frameDuration = frameDuration }
        if properties.contains(.streamSinkBufferQueueSize) { props.sinkBufferQueueSize = 2 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { props.sinkBuffersRequiredForStartup = 1 }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { activeFormatIndex = index }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws { device.startSink(client: client) }

    func stopStream() throws { device.stopSink() }
}

// MARK: - Provider

final class VirtualProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: VirtualDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = VirtualDeviceSource(localizedName: VirtualCameraConfig.deviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            props.manufacturer = VirtualCameraConfig.manufacturer
        }
        return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
