import SwiftUI

/// Quick controls from the menu bar, so Framelight can run in the background during calls.
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Auto Framing", isOn: $model.settings.autoFraming)
        Toggle("Background Blur", isOn: Binding(
            get: { model.settings.backgroundMode == .blur },
            set: { model.settings.backgroundMode = $0 ? .blur : .none }))
        Toggle("Mirror", isOn: $model.settings.mirror)
        Toggle("Privacy", isOn: Binding(get: { model.settings.privacy }, set: { _ in model.togglePrivacy() }))
        Toggle("Virtual Camera", isOn: Binding(
            get: { model.virtualCameraOn && model.virtualCameraStatus != .off },
            set: { model.setVirtualCamera($0) }))

        Divider()

        Menu("Presets") {
            ForEach(model.presets.presets) { preset in
                Button(preset.name) { model.apply(preset) }
            }
        }
        Menu("Shots") {
            ForEach(0..<4, id: \.self) { i in
                Button(model.shots[i] == nil ? "Shot \(i + 1) (empty)" : "Shot \(i + 1)") { model.recallShot(i) }
            }
        }
        Menu("Camera") {
            ForEach(model.camera.devices, id: \.uniqueID) { device in
                Button(device.localizedName) { Task { await model.select(device) } }
            }
        }
        Button("Re-apply Camera Settings") { model.controls.restoreSaved() }

        Divider()

        Button("Take Photo") { model.snapshot() }
        Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }

        Divider()

        Button("Open Framelight") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Framelight") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
