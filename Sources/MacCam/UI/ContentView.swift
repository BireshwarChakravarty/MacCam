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

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                previewArea
            }
            .frame(minWidth: 560)

            Divider()

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
            .frame(width: 360)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
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
            .frame(maxWidth: 240)

            Picker("Format", selection: Binding(
                get: { model.camera.activeFormatID ?? "" },
                set: { id in
                    if let option = model.camera.formats.first(where: { $0.id == id }) { model.selectFormat(option) }
                })) {
                if model.camera.activeFormatID == nil { Text("—").tag("") }
                ForEach(model.camera.formats) { Text($0.label).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: 260)

            Text(String(format: "%.0f fps", model.camera.measuredFPS))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if model.virtualCameraStatus == .streaming {
                Label("Virtual Cam", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }

            Button {
                model.settings.autoFraming.toggle()
            } label: {
                Image(systemName: model.settings.autoFraming ? "person.crop.square.filled.and.at.rectangle" : "person.crop.square")
            }
            .help("Auto Framing")

            Button { model.snapshot() } label: { Image(systemName: "camera") }
                .help("Take photo")

            Button { model.toggleRecording() } label: {
                Image(systemName: model.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(model.isRecording ? .red : .primary)
            }
            .help(model.isRecording ? "Stop recording" : "Record video")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Preview

    private var previewArea: some View {
        ZStack {
            Color.black
            if model.camera.authorization == .denied || model.camera.authorization == .restricted {
                permissionView
            } else if model.camera.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "web.camera").font(.system(size: 40))
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
                    if model.showFramingOverlay, model.settings.autoFraming, let stats = model.stats {
                        Text(String(format: "Zoom %.2f×  ·  %ld face%@", stats.zoom, stats.facesDetected, stats.facesDetected == 1 ? "" : "s"))
                            .font(.caption.monospacedDigit())
                            .padding(6)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    if model.isRecording {
                        Label("REC", systemImage: "circle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                            .padding(6)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
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
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
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

    private var permissionView: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash").font(.system(size: 40))
            Text("MacCam needs camera access").font(.title3)
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
        }
        .foregroundStyle(.secondary)
    }
}
