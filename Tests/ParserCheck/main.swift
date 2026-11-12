// Standalone check for the IOKit-free UVC logic. Runs on macOS or Linux:
//   swiftc Sources/MacCam/UVC/UVCDescriptors.swift Sources/MacCam/UVC/UVCControls.swift Tests/ParserCheck/main.swift -o /tmp/parsercheck && /tmp/parsercheck
import Foundation

var failures = 0
func expect(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if !cond() { failures += 1; print("FAIL (line \(line)): \(msg)") }
}

// A configuration descriptor shaped like a typical UVC 1.1 4K webcam with a mic.
let config: [UInt8] = [
    0x09, 0x02, 0x00, 0x00, 0x04, 0x01, 0x00, 0x80, 0xFA,             // CONFIGURATION (len patched below)
    0x08, 0x0B, 0x00, 0x02, 0x0E, 0x03, 0x00, 0x02,                   // IAD video
    0x09, 0x04, 0x00, 0x00, 0x01, 0x0E, 0x01, 0x00, 0x02,             // INTERFACE 0: Video Control
    0x0D, 0x24, 0x01, 0x10, 0x01, 0x4D, 0x00, 0x00, 0x6C, 0xDC, 0x02, 0x01, 0x01, // VC_HEADER bcdUVC 1.10
    0x12, 0x24, 0x02, 0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x03, 0x2E, 0x0A, 0x02,                                      // CAMERA input terminal id 1, bm=0x020A2E
    0x0B, 0x24, 0x05, 0x02, 0x01, 0x00, 0x40, 0x02, 0x7F, 0x17, 0x00, // PROCESSING UNIT id 2, bm=0x177F
    0x1B, 0x24, 0x06, 0x04,                                            // EXTENSION UNIT id 4
          0x29, 0x42, 0x21, 0x28, 0xB2, 0x82, 0x83, 0x48, 0xAE, 0x1F, 0x5E, 0x3A, 0x1B, 0xFE, 0x0F, 0x24, // GUID
          0x08, 0x01, 0x02, 0x02, 0xFF, 0x00, 0x00,                  // numCtrls 8, 1 in pin (2), size 2, bm 0x00FF, iExt
    0x09, 0x24, 0x03, 0x03, 0x01, 0x01, 0x00, 0x04, 0x00,             // OUTPUT terminal
    0x07, 0x05, 0x83, 0x03, 0x10, 0x00, 0x06,                         // ENDPOINT interrupt
    0x05, 0x25, 0x03, 0x10, 0x00,                                      // CS_ENDPOINT
    0x09, 0x04, 0x01, 0x00, 0x00, 0x0E, 0x02, 0x00, 0x00,             // INTERFACE 1: Video Streaming
    0x0E, 0x24, 0x01, 0x01, 0x00, 0x00, 0x81, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, // VS input header (must be ignored)
    0x09, 0x04, 0x02, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00,             // INTERFACE 2: Audio Control
    0x09, 0x24, 0x01, 0x00, 0x01, 0x26, 0x00, 0x01, 0x03,             // CS AC header (must be ignored)
]
var bytes = config
bytes[2] = UInt8(bytes.count & 0xFF); bytes[3] = UInt8(bytes.count >> 8)

let topo = UVCDescriptorParser.parse(bytes, interfaceNumber: 0)
expect(topo.uvcVersion == 0x0110, "uvc version \(String(topo.uvcVersion, radix: 16))")
expect(topo.versionString == "1.10", "version string \(topo.versionString)")
expect(topo.cameraTerminalID == 1, "camera terminal id")
expect(topo.cameraControls == 0x020A2E, "camera bitmap \(String(topo.cameraControls, radix: 16))")
expect(topo.processingUnitID == 2, "processing unit id")
expect(topo.processingControls == 0x177F, "pu bitmap \(String(topo.processingControls, radix: 16))")
expect(topo.extensionUnits.count == 1, "xu count")
expect(topo.extensionUnits.first?.unitID == 4, "xu id")
expect(topo.extensionUnits.first?.controlsBitmap == 0xFF, "xu bitmap")
expect(topo.extensionUnits.first?.guid.uuidString == "28214229-82B2-4883-AE1F-5E3A1BFE0F24", "xu guid \(topo.extensionUnits.first?.guid.uuidString ?? "nil")")
expect(UVCDescriptorParser.parse(bytes, interfaceNumber: 1).cameraTerminalID == nil, "wrong interface must not match")

// Which catalogue controls does this camera advertise?
func supported(_ def: UVCControlDefinition) -> Bool {
    let bm = def.unit == .cameraTerminal ? topo.cameraControls : topo.processingControls
    return bm & (1 << UInt64(def.bit)) != 0
}
let names = UVCCatalog.all.filter(supported).map(\.id)
print("Advertised controls:", names.joined(separator: ", "))
for id in ["ct.aeMode", "ct.exposureTime", "ct.focus", "ct.focusAuto", "ct.zoom", "ct.pan", "ct.tilt",
           "pu.brightness", "pu.contrast", "pu.hue", "pu.saturation", "pu.sharpness", "pu.gamma", "pu.wbTemp",
           "pu.backlight", "pu.gain", "pu.powerLine", "pu.wbTempAuto"] {
    expect(names.contains(id), "\(id) should be advertised")
}
for id in ["ct.iris", "ct.privacy", "pu.wbBlue", "pu.contrastAuto", "pu.hueAuto"] {
    expect(!names.contains(id), "\(id) should not be advertised")
}

// Byte helpers: signed/unsigned little-endian fields, composite pan/tilt.
var pt = [UInt8](repeating: 0, count: 8)
pt.put(-36000, at: 0, size: 4)
pt.put(7200, at: 4, size: 4)
expect(pt.int(at: 0, size: 4, signed: true) == -36000, "pan signed")
expect(pt.int(at: 4, size: 4, signed: true) == 7200, "tilt")
var b2 = [UInt8](repeating: 0, count: 2)
b2.put(-64, at: 0, size: 2)
expect(b2 == [0xC0, 0xFF], "brightness -64 encoding \(b2.hexString)")
expect(b2.int(at: 0, size: 2, signed: true) == -64, "brightness decode")
expect(b2.int(at: 0, size: 2, signed: false) == 65472, "unsigned decode")
var wb = [UInt8](repeating: 0, count: 2)
wb.put(4600, at: 0, size: 2)
expect(wb.int(at: 0, size: 2, signed: false) == 4600, "wb temp")
var exp4 = [UInt8](repeating: 0, count: 4)
exp4.put(333, at: 0, size: 4)
expect(exp4 == [0x4D, 0x01, 0x00, 0x00], "exposure encoding")

// Catalogue sanity.
expect(Set(UVCCatalog.all.map(\.id)).count == UVCCatalog.all.count, "unique control ids")
for def in UVCCatalog.all where def.autoControlID != nil {
    expect(UVCCatalog.byID[def.autoControlID!] != nil, "\(def.id) auto control exists")
}
for def in UVCCatalog.all {
    expect(def.fieldOffset + def.fieldSize <= def.length, "\(def.id) field fits payload")
}
expect(UVCCatalog.byID["ct.aeMode"]!.isAutoSwitch && UVCCatalog.byID["pu.wbTempAuto"]!.isAutoSwitch, "auto switches")
expect(!UVCCatalog.byID["pu.wbTemp"]!.isAutoSwitch, "wbTemp is not auto switch")
expect(AEMode.exposureIsAutomatic(8) && !AEMode.exposureIsAutomatic(1) && !AEMode.exposureIsAutomatic(4), "AE modes")

print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
