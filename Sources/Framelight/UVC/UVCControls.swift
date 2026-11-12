import Foundation

enum UVCUnitKind: String, Codable {
    case cameraTerminal
    case processingUnit
}

enum UVCControlGroup: String, CaseIterable, Identifiable {
    case image = "Image"
    case color = "Color & White Balance"
    case exposure = "Exposure & Light"
    case lens = "Focus & Zoom"
    case ptz = "Pan / Tilt / Roll"
    case advanced = "Advanced"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .image: return "camera.filters"
        case .color: return "thermometer.sun"
        case .exposure: return "sun.max"
        case .lens: return "scope"
        case .ptz: return "arrow.up.and.down.and.arrow.left.and.right"
        case .advanced: return "gearshape.2"
        }
    }
}

enum UVCControlKind: Hashable {
    /// Continuous value with GET_MIN/GET_MAX/GET_RES.
    case range
    /// On/off (1 byte).
    case toggle
    /// Fixed list of choices.
    case menu([UVCMenuOption])
    /// CT_AE_MODE: bitmap of modes, the supported set comes from GET_RES.
    case aeMode
}

struct UVCMenuOption: Hashable, Identifiable {
    let value: Int
    let label: String
    var id: Int { value }
}

struct UVCControlDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let unit: UVCUnitKind
    let selector: UInt8
    /// Bit index in the bmControls bitmap of the unit descriptor.
    let bit: Int
    /// Total wLength of the request.
    let length: Int
    /// For composite controls (pan+tilt, WB blue+red) the slice of the payload this control owns.
    let fieldOffset: Int
    let fieldSize: Int
    let signed: Bool
    let kind: UVCControlKind
    let group: UVCControlGroup
    /// The automatic-mode control that, when active, takes over this control.
    let autoControlID: String?
    let valueUnit: String?
    let help: String

    init(_ id: String, _ name: String, _ unit: UVCUnitKind, selector: UInt8, bit: Int, length: Int,
         fieldOffset: Int = 0, fieldSize: Int? = nil, signed: Bool = false, kind: UVCControlKind = .range,
         group: UVCControlGroup, auto: String? = nil, valueUnit: String? = nil, help: String = "") {
        self.id = id
        self.name = name
        self.unit = unit
        self.selector = selector
        self.bit = bit
        self.length = length
        self.fieldOffset = fieldOffset
        self.fieldSize = fieldSize ?? length
        self.signed = signed
        self.kind = kind
        self.group = group
        self.autoControlID = auto
        self.valueUnit = valueUnit
        self.help = help
    }

    var isComposite: Bool { fieldSize < length }

    /// Controls that switch a camera between automatic and manual behaviour.
    var isAutoSwitch: Bool {
        id == "ct.aeMode" || (kind == .toggle && id.hasSuffix("Auto"))
    }
}

enum AEMode {
    static let manual = 1
    static let auto = 2
    static let shutterPriority = 4
    static let aperturePriority = 8

    static func label(_ v: Int) -> String {
        switch v {
        case manual: return "Manual"
        case auto: return "Auto"
        case shutterPriority: return "Shutter Priority"
        case aperturePriority: return "Auto (Aperture Priority)"
        default: return "Mode \(v)"
        }
    }

    /// Modes in which the exposure time is chosen by the camera.
    static func exposureIsAutomatic(_ v: Int) -> Bool { v == auto || v == aperturePriority }
}

enum UVCCatalog {
    static let all: [UVCControlDefinition] = [
        // MARK: Processing Unit — image
        .init("pu.brightness", "Brightness", .processingUnit, selector: 0x02, bit: 0, length: 2, signed: true, group: .image,
              help: "Sensor-level brightness offset."),
        .init("pu.contrast", "Contrast", .processingUnit, selector: 0x03, bit: 1, length: 2, group: .image, auto: "pu.contrastAuto"),
        .init("pu.contrastAuto", "Auto Contrast", .processingUnit, selector: 0x13, bit: 18, length: 1, kind: .toggle, group: .image),
        .init("pu.sharpness", "Sharpness", .processingUnit, selector: 0x08, bit: 4, length: 2, group: .image,
              help: "In-camera sharpening. Lower values look more natural at 4K."),
        .init("pu.gamma", "Gamma", .processingUnit, selector: 0x09, bit: 5, length: 2, group: .image,
              help: "Mid-tone curve. Higher values lift shadows."),

        // MARK: Processing Unit — color
        .init("pu.wbTempAuto", "Auto White Balance", .processingUnit, selector: 0x0B, bit: 12, length: 1, kind: .toggle, group: .color),
        .init("pu.wbTemp", "Color Temperature", .processingUnit, selector: 0x0A, bit: 6, length: 2, group: .color,
              auto: "pu.wbTempAuto", valueUnit: "K", help: "Lower = warmer light compensation, higher = cooler."),
        .init("pu.wbComponentAuto", "Auto WB Components", .processingUnit, selector: 0x0D, bit: 13, length: 1, kind: .toggle, group: .color),
        .init("pu.wbBlue", "WB Blue Gain", .processingUnit, selector: 0x0C, bit: 7, length: 4, fieldOffset: 0, fieldSize: 2,
              group: .color, auto: "pu.wbComponentAuto"),
        .init("pu.wbRed", "WB Red Gain", .processingUnit, selector: 0x0C, bit: 7, length: 4, fieldOffset: 2, fieldSize: 2,
              group: .color, auto: "pu.wbComponentAuto"),
        .init("pu.saturation", "Saturation", .processingUnit, selector: 0x07, bit: 3, length: 2, group: .color),
        .init("pu.hueAuto", "Auto Hue", .processingUnit, selector: 0x10, bit: 11, length: 1, kind: .toggle, group: .color),
        .init("pu.hue", "Hue", .processingUnit, selector: 0x06, bit: 2, length: 2, signed: true, group: .color, auto: "pu.hueAuto"),

        // MARK: Exposure
        .init("ct.aeMode", "Exposure Mode", .cameraTerminal, selector: 0x02, bit: 1, length: 1, kind: .aeMode, group: .exposure),
        .init("ct.exposureTime", "Exposure Time", .cameraTerminal, selector: 0x04, bit: 3, length: 4, group: .exposure,
              auto: "ct.aeMode", valueUnit: "×100µs",
              help: "Shutter time in 100 µs steps. 333 ≈ 1/30 s. Shorter = less motion blur but darker."),
        .init("ct.aePriority", "Allow Frame-Rate Drop in Low Light", .cameraTerminal, selector: 0x03, bit: 2, length: 1,
              kind: .toggle, group: .exposure,
              help: "When on, auto exposure may lower the frame rate to brighten dim scenes."),
        .init("pu.gain", "Gain (ISO)", .processingUnit, selector: 0x04, bit: 9, length: 2, group: .exposure,
              help: "Sensor amplification. Raises brightness at the cost of noise."),
        .init("pu.backlight", "Backlight Compensation", .processingUnit, selector: 0x01, bit: 8, length: 2, group: .exposure,
              help: "Brightens a subject in front of a window or bright background (WDR/HDR-like)."),
        .init("ct.iris", "Iris", .cameraTerminal, selector: 0x09, bit: 7, length: 2, group: .exposure, auto: "ct.aeMode"),

        // MARK: Lens
        .init("ct.focusAuto", "Auto Focus", .cameraTerminal, selector: 0x08, bit: 17, length: 1, kind: .toggle, group: .lens),
        .init("ct.focus", "Focus", .cameraTerminal, selector: 0x06, bit: 5, length: 2, group: .lens, auto: "ct.focusAuto",
              help: "Lock focus manually to stop hunting when you move."),
        .init("ct.zoom", "Hardware Zoom", .cameraTerminal, selector: 0x0B, bit: 9, length: 2, group: .lens),
        .init("pu.digitalMultiplier", "In-Camera Digital Zoom", .processingUnit, selector: 0x0E, bit: 14, length: 2, group: .lens),

        // MARK: PTZ
        .init("ct.pan", "Pan", .cameraTerminal, selector: 0x0D, bit: 11, length: 8, fieldOffset: 0, fieldSize: 4, signed: true,
              group: .ptz, valueUnit: "arc-sec"),
        .init("ct.tilt", "Tilt", .cameraTerminal, selector: 0x0D, bit: 11, length: 8, fieldOffset: 4, fieldSize: 4, signed: true,
              group: .ptz, valueUnit: "arc-sec"),
        .init("ct.roll", "Roll", .cameraTerminal, selector: 0x0F, bit: 13, length: 2, signed: true, group: .ptz, valueUnit: "°"),

        // MARK: Advanced
        .init("pu.powerLine", "Anti-Flicker (Power Line)", .processingUnit, selector: 0x05, bit: 10, length: 1,
              kind: .menu([.init(value: 0, label: "Off"), .init(value: 1, label: "50 Hz"),
                           .init(value: 2, label: "60 Hz"), .init(value: 3, label: "Auto")]),
              group: .advanced,
              help: "Match your mains frequency to remove banding under LED/tube lights (50 Hz in India, Europe, most of Asia; 60 Hz in the Americas)."),
        .init("ct.privacy", "Privacy Shutter", .cameraTerminal, selector: 0x11, bit: 18, length: 1, kind: .toggle, group: .advanced),
        .init("ct.scanningMode", "Interlaced Scanning", .cameraTerminal, selector: 0x01, bit: 0, length: 1, kind: .toggle, group: .advanced),
    ]

    static let byID: [String: UVCControlDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
