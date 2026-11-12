import SwiftUI
import AVFoundation

enum SidebarTab: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case studio = "Studio"
    case presets = "Presets"
    case info = "Info"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("sidebarTab") private var tab: SidebarTab = .camera

    @State private var showInspector = true

    var body: some View {
        previewArea
            .frame(minWidth: 560, minHeight: 420)
            .ignoresSafeArea(edges: .bottom)
            .toolbar { toolbarContent }
            .inspector(isPresented: $showInspector) {
                sidebar
                    .inspectorColumnWidth(min: 320, ideal: 370, max: 480)
            }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SidebarTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Group {
                switch tab {
                case .camera: HardwarePanel(controls: model.controls)
                case .studio: StudioPanel()
                case .presets: PresetsPanel(store: model.presets)
                case .info: InfoPanel(controls: model.controls)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker("Camera", selection: Binding(
                get: { model.camera.activeDevice?.uniqueID ?? "" },
                set: { id in
                    if let device = model.camera.devices.first(where: { $0.uniqueID == id }) {
                        Task { await model.select(device) }
                    }
                })) {
                if model.camera.activeDevice == nil { Text("No camera").tag("") }
                ForEach(model.camera.devices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
            .help("Camera")

            Picker("Format", selection: Binding(
                get: { model.camera.activeFormatID ?? "" },
                set: { id in
                    if let option = model.camera.formats.first(where: { $0.id == id }) { model.selectFormat(option) }
                })) {
                if model.camera.activeFormatID == nil { Text("—").tag("") }
                ForEach(model.camera.formats) { Text($0.label).tag($0.id) }
            }
            .help("Capture resolution, frame rate and codec")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.settings.autoFraming) {
                Label("Auto Framing", systemImage: "person.crop.square.filled.and.at.rectangle")
            }
            .help("Auto Framing")

            Button { model.snapshot() } label: { Label("Take Photo", systemImage: "camera") }
                .help("Take photo")

            Button { model.toggleRecording() } label: {
                Label(model.isRecording ? "Stop Recording" : "Record",
                      systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(model.isRecording ? .red : nil)
            .help(model.isRecording ? "Stop recording" : "Record video")

            Button { showInspector.toggle() } label: { Label("Controls", systemImage: "sidebar.right") }
                .help("Show or hide controls")
        }
    }

    // MARK: Preview

    private var previewArea: some View {
        ZStack {
            Color.black
            if model.camera.authorization == .denied || model.camera.authorization == .restricted {
                permissionView
            } else if model.camera.devices.isEmpty {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("Plug in your webcam").font(.title3)
                }
                .foregroundStyle(.secondary)
            } else {
                PreviewView(frames: model.frames, context: model.processor.ciContext, device: model.processor.metalDevice)
                if model.showGrid {
                    GridOverlay(aspect: model.settings.outputResolution.size.width / model.settings.outputResolution.size.height)
                }
            }

            VStack {
                HStack(alignment: .top) {
                    statusChips
                    Spacer()
                    if model.isRecording {
                        Label("REC", systemImage: "circle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .glassEffect(.regular, in: Capsule())
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if model.showHistogram, !model.histogram.isEmpty {
                        HistogramView(channels: model.histogram)
                    }
                    Spacer()
                    if let toast = model.toast {
                        Text(toast)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .glassEffect(.regular, in: Capsule())
                            .transition(.opacity)
                    }
                }
            }
            .padding(12)

            if let error = model.camera.errorMessage {
                VStack {
                    Spacer()
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .padding(10)
                        .background(.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.black)
                        .padding(.bottom, 100)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
    }

    /// Live status pills over the video: frame rate, virtual camera, framing.
    private var statusChips: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Text(String(format: "%.0f fps", model.camera.measuredFPS))
                    .monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                if model.virtualCameraStatus == .streaming {
                    Label("Virtual Cam Live", systemImage: "dot.radiowaves.left.and.right")
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassEffect(.regular.tint(.green.opacity(0.35)), in: Capsule())
                }
                if model.settings.autoFraming {
                    Group {
                        if model.showFramingOverlay, let stats = model.stats {
                            Text(String(format: "Auto Framing · %.2f× · %ld face%@", stats.zoom, stats.facesDetected,
                                        stats.facesDetected == 1 ? "" : "s"))
                                .monospacedDigit()
                        } else {
                            Label("Auto Framing", systemImage: "person.crop.square.filled.and.at.rectangle")
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                }
            }
            .font(.caption.weight(.semibold))
        }
    }

    private var permissionView: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash").font(.system(size: 40))
            Text("Framelight needs camera access").font(.title3)
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
        }
        .foregroundStyle(.secondary)
    }
}
