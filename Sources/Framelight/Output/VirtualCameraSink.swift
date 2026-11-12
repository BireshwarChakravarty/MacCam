import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo

/// Feeds processed frames into the Framelight camera extension's sink stream.
/// Zoom, Meet, Teams, OBS etc. then see them on "Framelight Camera".
final class VirtualCameraSink: @unchecked Sendable {
    enum Status: Equatable {
        case off
        case notInstalled
        case streaming
        case failed(String)
    }

    private let lock = NSLock()
    private var deviceID: CMIOObjectID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var formatDescription: CMFormatDescription?
    private(set) var status: Status = .off

    var isConnected: Bool { lock.locked { queue != nil } }

    @discardableResult
    func connect() -> Status {
        return lock.locked { () -> Status in
            if queue != nil { return status }
            guard let device = Self.findDevice() else {
                status = .notInstalled
                return status
            }
            guard let sink = Self.sinkStream(of: device) else {
                status = .failed("The virtual camera has no input stream.")
                return status
            }
            var unmanaged: Unmanaged<CMSimpleQueue>?
            let err = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanaged)
            guard err == noErr, let q = unmanaged?.takeRetainedValue() else {
                status = .failed("Couldn't open the virtual camera queue (\(err)).")
                return status
            }
            let startErr = CMIODeviceStartStream(device, sink)
            guard startErr == noErr else {
                status = .failed("Couldn't start the virtual camera stream (\(startErr)).")
                return status
            }
            deviceID = device
            streamID = sink
            queue = q
            status = .streaming
            return status
        }
    }

    func disconnect() {
        lock.locked {
            if queue != nil {
                CMIODeviceStopStream(deviceID, streamID)
            }
            queue = nil
            deviceID = 0
            streamID = 0
            status = .off
        }
    }

    func send(_ pixelBuffer: CVPixelBuffer) {
        lock.locked {
            guard let queue else { return }
            guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }

            if formatDescription == nil
                || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
                var fd: CMFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                             formatDescriptionOut: &fd)
                formatDescription = fd
            }
            guard let formatDescription else { return }

            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: VirtualCameraConfig.frameRate),
                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                decodeTimeStamp: .invalid)
            var sampleBuffer: CMSampleBuffer?
            CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
                                               makeDataReadyCallback: nil, refcon: nil,
                                               formatDescription: formatDescription, sampleTiming: &timing,
                                               sampleBufferOut: &sampleBuffer)
            guard let sampleBuffer else { return }
            let element = Unmanaged.passRetained(sampleBuffer).toOpaque()
            if CMSimpleQueueEnqueue(queue, element: UnsafeRawPointer(element)) != noErr {
                Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
            }
        }
    }

    // MARK: CMIO lookups

    private static func address<S: BinaryInteger>(_ selector: S) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(truncatingIfNeeded: selector),
                                  mScope: CMIOObjectPropertyScope(truncatingIfNeeded: kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(0))
    }

    private static func objectIDs<S: BinaryInteger>(of object: CMIOObjectID, selector: S) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func findDevice() -> CMIOObjectID? {
        let system = CMIOObjectID(truncatingIfNeeded: kCMIOObjectSystemObject)
        for device in objectIDs(of: system, selector: kCMIOHardwarePropertyDevices) {
            var addr = address(kCMIODevicePropertyDeviceUID)
            var uid: Unmanaged<CFString>?
            var used: UInt32 = 0
            let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &uid) == noErr,
                  let value = uid?.takeUnretainedValue() as String? else { continue }
            if value.caseInsensitiveCompare(VirtualCameraConfig.deviceUUID.uuidString) == .orderedSame {
                return device
            }
        }
        return nil
    }

    private static func sinkStream(of device: CMIOObjectID) -> CMIOStreamID? {
        let streams = objectIDs(of: device, selector: kCMIODevicePropertyStreams)
        for stream in streams {
            var addr = address(kCMIOStreamPropertyDirection)
            var direction: UInt32 = 0
            var used: UInt32 = 0
            if CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &direction) == noErr,
               direction == 1 {
                return stream
            }
        }
        // The extension registers its sink stream second.
        return streams.count >= 2 ? streams[1] : nil
    }
}
