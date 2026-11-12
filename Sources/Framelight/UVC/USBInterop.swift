import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

/// The IOUSBLib UUID constants are C macros that Swift cannot import, so they
/// are re-declared here byte-for-byte from IOUSBLib.h / IOCFPlugIn.h.
enum USBUUID {
    static let deviceUserClientType: CFUUID = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
        0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)

    static let interfaceUserClientType: CFUUID = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4,
        0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)

    static let cfPlugInInterface: CFUUID = CFUUIDGetConstantUUIDWithBytes(
        nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
        0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)

    static let deviceInterface: CFUUID = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4,
        0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)

    static let interfaceInterface: CFUUID = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x73, 0xC9, 0x7A, 0xE8, 0x9E, 0xF3, 0x11, 0xD4,
        0xB1, 0xD0, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
}

typealias USBDeviceRef = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>
typealias USBInterfaceRef = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>
typealias PlugInRef = UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>

enum USBInterop {
    /// Creates a CFPlugIn for an IOService and queries it for the requested COM interface.
    static func queryInterface<T>(service: io_service_t,
                                  userClientType: CFUUID,
                                  interfaceID: CFUUID,
                                  as type: T.Type) -> UnsafeMutablePointer<UnsafeMutablePointer<T>?>? {
        var plugIn: PlugInRef?
        var score: Int32 = 0
        let kr = IOCreatePlugInInterfaceForService(service, userClientType, USBUUID.cfPlugInInterface, &plugIn, &score)
        guard kr == KERN_SUCCESS, let plugIn, let vtable = plugIn.pointee?.pointee else { return nil }
        defer { _ = vtable.Release(plugIn) }

        var raw: LPVOID?
        let hr = vtable.QueryInterface(plugIn, CFUUIDGetUUIDBytes(interfaceID), &raw)
        guard hr == 0, let raw else { return nil }
        return raw.assumingMemoryBound(to: UnsafeMutablePointer<T>?.self)
    }

    static func property<T>(_ service: io_registry_entry_t, _ key: String) -> T? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return value.takeRetainedValue() as? T
    }

    static func parent(of service: io_registry_entry_t) -> io_registry_entry_t? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { return nil }
        return parent
    }
}
