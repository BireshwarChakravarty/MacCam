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
    case color = "Studio Color"
    case image = "Image"
    var id: String { rawValue }
}

enum Look: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case cinematic = "Cinematic"
    case warmFilm = "Warm Film"
    case chrome = "Chrome"
    case fade = "Fade"
    case instant = "Instant"
    case process = "Process"
    case transfer = "Transfer"
    case mono = "Mono"
    case noir = "Noir"
    case tonal = "Tonal"
    var id: String { rawValue }
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
/// All of it is applied to the preview, recordings and the virtual camera.
struct ProcessingSettings: Codable, Equatable {
    // Framing ("Center Stage")
    var autoFraming = false
    var framingSubject: FramingSubject = .upperBody
    var framingTightness = 0.5      // 0 = wide, 1 = tight
    var framingSpeed = 0.5          // 0 = slow & cinematic, 1 = snappy
    var maxZoom = 2.5               // limit so a 4K sensor never upsamples a 1080p output too far
    var digitalZoom = 1.0           // manual zoom when auto framing is off
    var panX = 0.0                  // -1...1
    var panY = 0.0                  // -1...1

    // Orientation
    var mirror = false
    var flipVertical = false

    // Colour & tone
    var warmth = 0.0                // -100...100 (software white balance on top of hardware)
    var tint = 0.0                  // -100...100
    var exposure = 0.0              // EV, -2...2
    var brightness = 0.0            // -0.3...0.3
    var contrast = 1.0              // 0.5...1.5
    var saturation = 1.0            // 0...2
    var vibrance = 0.0              // -1...1
    var highlights = 1.0            // 0...1 (1 = untouched)
    var shadows = 0.0               // 0...1 lift
    var sharpen = 0.0               // 0...1
    var denoise = 0.0               // 0...1
    var vignette = 0.0              // 0...1
    var look: Look = .none
    var lookIntensity = 1.0

    // Background
    var backgroundMode: BackgroundMode = .none
    var backgroundBlur = 0.6        // 0...1
    var backgroundColorHex = "#1E2430"
    var backgroundImagePath: String?

    // Output
    var outputResolution: OutputResolution = .hd1080

    static let `default` = ProcessingSettings()

    var isColorNeutral: Bool {
        warmth == 0 && tint == 0 && exposure == 0 && brightness == 0 && contrast == 1 && saturation == 1
            && vibrance == 0 && highlights == 1 && shadows == 0 && sharpen == 0 && denoise == 0
            && vignette == 0 && look == .none
    }
}
