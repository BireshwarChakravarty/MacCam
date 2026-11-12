import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run); harmless inside an .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep running in the menu bar so the virtual camera keeps working during calls.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MacCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @State private var started = false

    var body: some Scene {
        Window("MacCam", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    guard !started else { return }
                    started = true
                    await model.start()
                }
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandMenu("Camera") {
                Button("Take Photo") { model.snapshot() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Toggle Auto Framing") { model.settings.autoFraming.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Toggle Background Blur") {
                    model.settings.backgroundMode = model.settings.backgroundMode == .blur ? .none : .blur
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Toggle Mirror") { model.settings.mirror.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button("Reload Camera Controls") { Task { await model.reloadControls() } }
            }
        }

        MenuBarExtra("MacCam", systemImage: "web.camera") {
            MenuBarView()
                .environmentObject(model)
        }
    }
}
