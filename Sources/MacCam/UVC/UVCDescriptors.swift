import Foundation

// Pure-Foundation parsing of UVC descriptors (no IOKit), so it can be unit-tested anywhere.

/// A vendor-specific Extension Unit found in the descriptors.
struct UVCExtensionUnit: Hashable, Identifiable {
    let unitID: UInt8
    let guid: UUID
    let numControls: Int
    let controlsBitmap: UInt64
    var id: UInt8 { unitID }
}

/// Everything learned from parsing the Video Control interface descriptors.
struct UVCTopology {
    var uvcVersion: UInt16 = 0
    var cameraTerminalID: UInt8?
    var cameraControls: UInt64 = 0
    var processingUnitID: UInt8?
    var processingControls: UInt64 = 0
    var extensionUnits: [UVCExtensionUnit] = []
    var rawDescriptor: [UInt8] = []

    var versionString: String {
        guard uvcVersion != 0 else { return "unknown" }
        return String(format: "%d.%d%d", (uvcVersion >> 8) & 0xFF, (uvcVersion >> 4) & 0xF, uvcVersion & 0xF)
    }
}

enum UVCDescriptorParser {
    /// Walks a full USB configuration descriptor and extracts the Video Control topology
    /// (camera terminal, processing unit, extension units) of the given interface.
    static func parse(_ bytes: [UInt8], interfaceNumber: UInt8) -> UVCTopology {
        var topo = UVCTopology()
        var offset = 0
        var inTargetVC = false
        var vcBytes: [UInt8] = []

        while offset + 2 <= bytes.count {
            let length = Int(bytes[offset])
            guard length >= 2, offset + length <= bytes.count else { break }
            let type = bytes[offset + 1]
            let d = Array(bytes[offset..<(offset + length)])

            if type == 0x04, length >= 9 { // INTERFACE descriptor
                inTargetVC = d[2] == interfaceNumber && d[5] == 0x0E && d[6] == 0x01
            } else if type == 0x24, inTargetVC, length >= 3 { // CS_INTERFACE
                vcBytes += d
                switch d[2] {
                case 0x01 where length >= 5: // VC_HEADER
                    topo.uvcVersion = UInt16(d.uint(at: 3, size: 2))
                case 0x02 where length >= 15: // VC_INPUT_TERMINAL
                    let terminalType = d.uint(at: 4, size: 2)
                    if terminalType == 0x0201 { // ITT_CAMERA
                        topo.cameraTerminalID = d[3]
                        let size = Int(d[14])
                        topo.cameraControls = d.uint(at: 15, size: min(size, 8))
                    }
                case 0x05 where length >= 8: // VC_PROCESSING_UNIT
                    topo.processingUnitID = d[3]
                    let size = Int(d[7])
                    topo.processingControls = d.uint(at: 8, size: min(size, 8))
                case 0x06 where length >= 24: // VC_EXTENSION_UNIT
                    let guidBytes = Array(d[4..<20])
                    let numControls = Int(d[20])
                    let nrInPins = Int(d[21])
                    let sizeOffset = 22 + nrInPins
                    var bitmap: UInt64 = 0
                    if sizeOffset < length {
                        let controlSize = Int(d[sizeOffset])
                        bitmap = d.uint(at: sizeOffset + 1, size: min(controlSize, 8))
                    }
                    topo.extensionUnits.append(UVCExtensionUnit(
                        unitID: d[3], guid: uvcGUID(guidBytes), numControls: numControls, controlsBitmap: bitmap))
                default:
                    break
                }
            }
            offset += length
        }
        topo.rawDescriptor = vcBytes
        return topo
    }

    /// USB GUIDs are stored with the first three fields little-endian.
    static func uvcGUID(_ b: [UInt8]) -> UUID {
        let o: [UInt8] = [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + Array(b[8..<16])
        return UUID(uuid: (o[0], o[1], o[2], o[3], o[4], o[5], o[6], o[7],
                           o[8], o[9], o[10], o[11], o[12], o[13], o[14], o[15]))
    }
}

// MARK: - Little-endian helpers

extension Array where Element == UInt8 {
    func uint(at offset: Int, size: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<size where offset + i < count {
            v |= UInt64(self[offset + i]) << (8 * UInt64(i))
        }
        return v
    }

    func int(at offset: Int, size: Int, signed: Bool) -> Int {
        let raw = uint(at: offset, size: size)
        guard signed, size < 8 else { return Int(truncatingIfNeeded: raw) }
        let signBit: UInt64 = 1 << (UInt64(size) * 8 - 1)
        if raw & signBit != 0 {
            let mask: UInt64 = (1 << (UInt64(size) * 8)) - 1
            return -Int((~raw & mask) + 1)
        }
        return Int(raw)
    }

    mutating func put(_ value: Int, at offset: Int, size: Int) {
        let raw = UInt64(bitPattern: Int64(value))
        for i in 0..<size where offset + i < count {
            self[offset + i] = UInt8(truncatingIfNeeded: raw >> (8 * UInt64(i)))
        }
    }

    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
