import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum FramingSubject: String, Codable, CaseIterable, Identifiable {
    case face = "Face"
    case upperBody = "Upper Body"
    case group = "Everyone"
    var id: String { rawValue }
}

enum BackgroundMode: String, Codable, CaseIterable, Identifiable {
    case none = "Off"
    case blur = "Blur"
    case studioLight = "Studio Light"
    case color = "Color"
    case image = "Image"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .none: return "circle.slash"
        case .blur: return "camera.aperture"
        case .studioLight: return "light.max"
        case .color: return "paintpalette"
        case .image: return "photo"
        }
    }
}

enum OutputResolution: String, Codable, CaseIterable, Identifiable {
    case hd720 = "720p"
    case hd1080 = "1080p"
    case qhd1440 = "1440p"
    case uhd2160 = "4K"
    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .hd720: return CGSize(width: 1280, height: 720)
        case .hd1080: return CGSize(width: 1920, height: 1080)
        case .qhd1440: return CGSize(width: 2560, height: 1440)
        case .uhd2160: return CGSize(width: 3840, height: 2160)
        }
    }
}

/// Everything the software pipeline does on top of the camera hardware.
/// Applied to the preview, photos, recordings and the virtual camera.
struct ProcessingSettings: Codable, Equatable {
    // Framing ("Center Stage")
    var autoFraming = false
    var framingSubject: FramingSubject = .upperBody
    var framingTightness = 0.5      // 0 = wide, 1 = tight
    var framingSpeed = 0.5          // 0 = slow & cinematic, 1 = snappy
    var maxZoom = 2.5
    var digitalZoom = 1.0           // manual zoom when auto framing is off
    var panX = 0.0                  // -1...1
    var panY = 0.0                  // -1...1

    // Orientation
    var mirror = false
    var flipVertical = false

    // Light & colour
    var autoLight = true            // face-metered exposure, only when the face is under/over-exposed
    var naturalSkin = true          // white balance nudged by the skin tone line
    var exposure = 0.0              // EV, -2...2
    var warmth = 0.0                // -100...100  (±1500 K)
    var tint = 0.0                  // -100...100  (green ↔ magenta)
    var contrast = 1.0              // 0.75...1.3
    var saturation = 1.0            // 0...1.6, skin-protected
    var vibrance = 0.0              // -1...1
    var highlights = 1.0            // 0.4...1 (1 = untouched)
    var shadows = 0.0               // 0...0.8 lift

    // Look
    var look: LookStyle = .natural
    var lookIntensity = 1.0

    // Detail
    var denoise = 0.35              // motion-adaptive temporal noise reduction
    var sharpen = 0.0               // 0...1, fine luminance detail
    var vignette = 0.0              // 0...1, subtle

    // Background
    var backgroundMode: BackgroundMode = .none
    var backgroundStrength = 0.6    // 0...1
    var backgroundColorHex = "#2A3140"
    var backgroundImagePath: String?

    // Output
    var outputResolution: OutputResolution = .hd1080

    // View
    var compare = false             // split before/after in the preview (never sent to other apps)

    static let `default` = ProcessingSettings()

    /// Kelvin offset shown in the UI for the warmth slider.
    var warmthKelvin: Int { Int((warmth * 15).rounded()) }

    /// The grade baked into the LUT: look at its intensity, then the user's adjustments.
    var grade: Grade {
        look.base.scaled(lookIntensity).adjusted(contrast: contrast, saturation: saturation, vibrance: vibrance)
    }

    func grade(for look: LookStyle) -> Grade {
        look.base.scaled(lookIntensity).adjusted(contrast: contrast, saturation: saturation, vibrance: vibrance)
    }
}
