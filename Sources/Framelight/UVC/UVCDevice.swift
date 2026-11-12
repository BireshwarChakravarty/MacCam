import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

/// UVC class-specific request codes (UVC 1.5 spec, table A-8).
enum UVCRequestCode: UInt8 {
    case setCur = 0x01
    case getCur = 0x81
    case getMin = 0x82
    case getMax = 0x83
    case getRes = 0x84
    case getLen = 0x85
    case getInfo = 0x86
    case getDef = 0x87
}

struct UVCError: Error, CustomStringConvertible {
    let code: IOReturn
    let context: String
    var description: String { String(format: "%@ failed (IOReturn 0x%08X)", context, UInt32(bitPattern: code)) }
}

/// Talks to a USB Video Class camera's Video Control interface directly over IOKit.
/// macOS exposes none of these controls itself; this is what unlocks them.
final class UVCDevice: @unchecked Sendable {
    let name: String
    let vendorID: Int
    let productID: Int
    let locationID: UInt32
    let serialNumber: String?
    let interfaceNumber: UInt8
    let topology: UVCTopology

    private let interfaceRef: USBInterfaceRef
    private let lock = NSLock()

    private init(name: String, vendorID: Int, productID: Int, locationID: UInt32, serialNumber: String?,
                 interfaceNumber: UInt8, topology: UVCTopology, interfaceRef: USBInterfaceRef) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.serialNumber = serialNumber
        self.interfaceNumber = interfaceNumber
        self.topology = topology
        self.interfaceRef = interfaceRef
    }

    deinit {
        _ = interfaceRef.pointee?.pointee.Release(interfaceRef)
    }

    var idString: String { String(format: "%04X:%04X", vendorID, productID) }

    // MARK: Discovery

    /// Finds every UVC camera (every USB interface of class Video / subclass Video Control).
    static func discoverAll() -> [UVCDevice] {
        var found: [UVCDevice] = []
        for className in ["IOUSBHostInterface", "IOUSBInterface"] {
            guard let cfMatching = IOServiceMatching(className) else { continue }
            let matching = cfMatching as NSMutableDictionary
            matching["bInterfaceClass"] = 0x0E      // CC_VIDEO
            matching["bInterfaceSubClass"] = 0x01   // SC_VIDEOCONTROL

            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                if let device = UVCDevice(interfaceService: service) {
                    found.append(device)
                }
                IOObjectRelease(service)
            }
            if !found.isEmpty { break }
        }
        return found
    }

    private convenience init?(interfaceService: io_service_t) {
        guard let deviceService = USBInterop.parent(of: interfaceService) else { return nil }
        defer { IOObjectRelease(deviceService) }

        let ifaceNumber: Int = USBInterop.property(interfaceService, "bInterfaceNumber") ?? 0
        let vendor: Int = USBInterop.property(deviceService, "idVendor") ?? 0
        let product: Int = USBInterop.property(deviceService, "idProduct") ?? 0
        let location: Int = USBInterop.property(deviceService, "locationID") ?? 0
        let name: String = USBInterop.property(deviceService, "USB Product Name")
            ?? USBInterop.property(deviceService, "kUSBProductString")
            ?? "USB Camera"
        let serial: String? = USBInterop.property(deviceService, "USB Serial Number")
            ?? USBInterop.property(deviceService, "kUSBSerialNumberString")

        guard let iface = USBInterop.queryInterface(service: interfaceService,
                                                    userClientType: USBUUID.interfaceUserClientType,
                                                    interfaceID: USBUUID.interfaceInterface,
                                                    as: IOUSBInterfaceInterface.self) else { return nil }

        let topology = UVCDevice.readTopology(deviceService: deviceService, interfaceNumber: UInt8(ifaceNumber))

        self.init(name: name, vendorID: vendor, productID: product,
                  locationID: UInt32(truncatingIfNeeded: location), serialNumber: serial,
                  interfaceNumber: UInt8(ifaceNumber), topology: topology, interfaceRef: iface)
    }

    /// Reads the configuration descriptor and parses the class-specific VC descriptors.
    private static func readTopology(deviceService: io_service_t, interfaceNumber: UInt8) -> UVCTopology {
        guard let dev = USBInterop.queryInterface(service: deviceService,
                                                  userClientType: USBUUID.deviceUserClientType,
                                                  interfaceID: USBUUID.deviceInterface,
                                                  as: IOUSBDeviceInterface.self),
              let vtable = dev.pointee?.pointee else { return UVCTopology() }
        defer { _ = vtable.Release(dev) }

        var configPtr: IOUSBConfigurationDescriptorPtr?
        guard vtable.GetConfigurationDescriptorPtr(dev, 0, &configPtr) == kIOReturnSuccess, let configPtr else {
            return UVCTopology()
        }
        let totalLength = Int(UInt16(littleEndian: configPtr.pointee.wTotalLength))
        let bytes = [UInt8](UnsafeRawBufferPointer(start: UnsafeRawPointer(configPtr), count: totalLength))
        return UVCDescriptorParser.parse(bytes, interfaceNumber: interfaceNumber)
    }

    // MARK: Control transfers

    private func transfer(_ request: UVCRequestCode, unit: UInt8, selector: UInt8, buffer: inout [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let vtable = interfaceRef.pointee?.pointee else {
            throw UVCError(code: ioReturnNotOpen, context: "USB interface")
        }

        let isSet = request == .setCur
        let length = buffer.count
        var result: IOReturn = ioReturnError
        var transferred = 0

        buffer.withUnsafeMutableBytes { raw in
            var req = IOUSBDevRequest(
                bmRequestType: isSet ? 0x21 : 0xA1, // class request to interface, OUT / IN
                bRequest: request.rawValue,
                wValue: UInt16(selector) << 8,
                wIndex: UInt16(unit) << 8 | UInt16(interfaceNumber),
                wLength: UInt16(length),
                pData: raw.baseAddress,
                wLenDone: 0)
            result = vtable.ControlRequest(interfaceRef, 0, &req)

            // Some macOS versions require the interface to be open for control requests.
            if result != kIOReturnSuccess, result != ioReturnPipeStalled {
                if vtable.USBInterfaceOpen(interfaceRef) == kIOReturnSuccess {
                    req.wLenDone = 0
                    result = vtable.ControlRequest(interfaceRef, 0, &req)
                    _ = vtable.USBInterfaceClose(interfaceRef)
                }
            }
            transferred = Int(req.wLenDone)
        }

        guard result == kIOReturnSuccess else {
            throw UVCError(code: result, context: String(format: "Request 0x%02X unit %d selector 0x%02X", request.rawValue, unit, selector))
        }
        if !isSet, transferred < length, transferred > 0 {
            for i in transferred..<length { buffer[i] = 0 }
        }
    }

    func get(_ request: UVCRequestCode, unit: UInt8, selector: UInt8, length: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: length)
        try transfer(request, unit: unit, selector: selector, buffer: &buffer)
        return buffer
    }

    func set(unit: UInt8, selector: UInt8, data: [UInt8]) throws {
        var buffer = data
        try transfer(.setCur, unit: unit, selector: selector, buffer: &buffer)
    }
}

// IOReturn codes are function-like C macros that Swift does not import.
private let ioReturnError = IOReturn(bitPattern: 0xE000_02BC)
private let ioReturnNotOpen = IOReturn(bitPattern: 0xE000_02CD)
private let ioReturnPipeStalled = IOReturn(bitPattern: 0xE000_404F)
