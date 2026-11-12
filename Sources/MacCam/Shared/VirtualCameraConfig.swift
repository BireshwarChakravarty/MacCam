import Foundation

/// Shared between the app and the Core Media I/O camera extension.
enum VirtualCameraConfig {
    /// The extension's bundle ID is always the app's bundle ID + ".CameraExtension".
    static var extensionBundleID: String { (Bundle.main.bundleIdentifier ?? "com.maccam.app") + ".CameraExtension" }
    static let deviceName = "MacCam Virtual Camera"
    static let manufacturer = "MacCam"
    static let model = "MacCam Studio"
    /// Fixed so the app can find the extension's device and exclude it from its own camera list.
    static let deviceUUID = UUID(uuidString: "6B7D0E7A-3C51-4F7B-9B2E-5A1C7F0D4E21")!
    static let sourceStreamUUID = UUID(uuidString: "0E4C7A11-8F2B-4A7E-B6D3-2C9E5F1A7B30")!
    static let sinkStreamUUID = UUID(uuidString: "A3F1D2C4-5B6E-4F70-8192-A3B4C5D6E7F8")!
    static let width: Int32 = 1920
    static let height: Int32 = 1080
    static let frameRate: Int32 = 30
}
