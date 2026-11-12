import Foundation
import SystemExtensions

/// Installs / removes the bundled Core Media I/O camera extension.
final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var message: String?
    @Published private(set) var isWorking = false

    /// The extension only exists in builds made with the Xcode project (see README).
    var isBundled: Bool {
        let dir = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.contains { $0.hasSuffix(".systemextension") }
    }

    func install() {
        submit(OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: VirtualCameraConfig.extensionBundleID, queue: .main))
    }

    func uninstall() {
        submit(OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: VirtualCameraConfig.extensionBundleID, queue: .main))
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        guard isBundled else {
            message = "This build doesn't include the virtual camera. Build with the Xcode project (see README)."
            return
        }
        isWorking = true
        message = "Waiting for macOS…"
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        DispatchQueue.main.async {
            self.message = "Approve Framelight in System Settings → Privacy & Security (or General → Login Items & Extensions → Camera Extensions)."
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.message = result == .completed
                ? "Done. Choose “\(VirtualCameraConfig.deviceName)” in Zoom, Meet, Teams or OBS."
                : "Done. Restart your Mac to finish."
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.message = "Failed: \(error.localizedDescription)"
        }
    }
}
