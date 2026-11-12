import SwiftUI

/// Software features: auto framing, background, colour grading, output.
struct StudioPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            framingSection
            backgroundSection
            colorSection
            detailSection
            lookSection
            outputSection
            virtualCameraSection

            Section {
                Button("Reset Studio Settings") { model.resetSoftware() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Framing

    private var framingSection: some View {
        Section {
            Toggle(isOn: $model.settings.autoFraming) {
                VStack(alignment: .leading) {
                    Text("Auto Framing")
                    Text("Keeps you centred, like Center Stage, by cropping the 4K sensor.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.settings.autoFraming {
                Picker("Follow", selection: $model.settings.framingSubject) {
                    ForEach(FramingSubject.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                TunedSlider("Tightness", value: $model.settings.framingTightness, in: 0...1, reset: 0.5, format: .percent)
                TunedSlider("Motion Speed", value: $model.settings.framingSpeed, in: 0...1, reset: 0.5, format: .percent)
                TunedSlider("Max Zoom", value: $model.settings.maxZoom, in: 1...4, reset: 2.5, format: .multiplier)
                Toggle("Show framing info", isOn: $model.showFramingOverlay)
            } else {
                TunedSlider("Digital Zoom", value: $model.settings.digitalZoom, in: 1...4, reset: 1, format: .multiplier)
                if model.settings.digitalZoom > 1.01 {
                    TunedSlider("Pan", value: $model.settings.panX, in: -1...1, reset: 0, format: .signed)
                    TunedSlider("Tilt", value: $model.settings.panY, in: -1...1, reset: 0, format: .signed)
                }
            }
            HStack {
                Toggle("Mirror", isOn: $model.settings.mirror)
                Spacer()
                Toggle("Upside Down", isOn: $model.settings.flipVertical)
            }
        } header: {
            Label("Framing", systemImage: "person.crop.rectangle")
        }
    }

    // MARK: Background

    private var backgroundSection: some View {
        Section {
            Picker("Background", selection: $model.settings.backgroundMode) {
                ForEach(BackgroundMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch model.settings.backgroundMode {
            case .none:
                EmptyView()
            case .blur:
                TunedSlider("Blur Strength", value: $model.settings.backgroundBlur, in: 0...1, reset: 0.6, format: .percent)
            case .color:
                ColorPicker("Color", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: model.settings.backgroundColorHex)) },
                    set: { model.settings.backgroundColorHex = NSColor($0).hexString }), supportsOpacity: false)
            case .image:
                HStack {
                    Text(model.settings.backgroundImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No image")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { model.chooseBackgroundImage() }
                }
            }
        } header: {
            Label("Background", systemImage: "person.and.background.dotted")
        }
    }

    // MARK: Colour

    private var colorSection: some View {
        Section {
            TunedSlider("Warmth", value: $model.settings.warmth, in: -100...100, reset: 0, format: .integer)
            TunedSlider("Tint", value: $model.settings.tint, in: -100...100, reset: 0, format: .integer)
            TunedSlider("Exposure", value: $model.settings.exposure, in: -2...2, reset: 0, format: .ev)
            TunedSlider("Contrast", value: $model.settings.contrast, in: 0.5...1.5, reset: 1, format: .centeredPercent)
            TunedSlider("Brightness", value: $model.settings.brightness, in: -0.3...0.3, reset: 0, format: .signed)
            TunedSlider("Highlights", value: $model.settings.highlights, in: 0...1, reset: 1, format: .percent)
            TunedSlider("Shadows", value: $model.settings.shadows, in: 0...1, reset: 0, format: .percent)
            TunedSlider("Saturation", value: $model.settings.saturation, in: 0...2, reset: 1, format: .centeredPercent)
            TunedSlider("Vibrance", value: $model.settings.vibrance, in: -1...1, reset: 0, format: .signed)
        } header: {
            Label("Color & Tone", systemImage: "paintpalette")
        } footer: {
            Text("Applied in software on top of the camera's own settings. Double-click a slider's label to reset it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detailSection: some View {
        Section {
            TunedSlider("Sharpen", value: $model.settings.sharpen, in: 0...1, reset: 0, format: .percent)
            TunedSlider("Noise Reduction", value: $model.settings.denoise, in: 0...1, reset: 0, format: .percent)
            TunedSlider("Vignette", value: $model.settings.vignette, in: 0...1, reset: 0, format: .percent)
        } header: {
            Label("Detail", systemImage: "wand.and.stars")
        }
    }

    private var lookSection: some View {
        Section {
            Picker("Look", selection: $model.settings.look) {
                ForEach(Look.allCases) { Text($0.rawValue).tag($0) }
            }
            if model.settings.look != .none {
                TunedSlider("Intensity", value: $model.settings.lookIntensity, in: 0...1, reset: 1, format: .percent)
            }
        } header: {
            Label("Look", systemImage: "camera.filters")
        }
    }

    // MARK: Output

    private var outputSection: some View {
        Section {
            Picker("Output Resolution", selection: $model.settings.outputResolution) {
                ForEach(OutputResolution.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Record in HEVC (smaller files)", isOn: $model.recordHEVC)
            HStack {
                Toggle("Histogram", isOn: $model.showHistogram)
                Spacer()
                Toggle("Grid", isOn: $model.showGrid)
            }
        } header: {
            Label("Output", systemImage: "rectangle.on.rectangle")
        }
    }

    private var virtualCameraSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.virtualCameraOn && model.virtualCameraStatus != .off },
                                 set: { model.setVirtualCamera($0) })) {
                VStack(alignment: .leading) {
                    Text("Send to Virtual Camera")
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Install Virtual Camera") { model.installer.install() }
                    .disabled(model.installer.isWorking)
                Button("Uninstall") { model.installer.uninstall() }
                    .disabled(model.installer.isWorking)
            }
            if let message = model.installer.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Label("Virtual Camera", systemImage: "video.badge.waveform")
        } footer: {
            Text("Pick “\(VirtualCameraConfig.deviceName)” in Zoom, Google Meet, Teams, OBS or FaceTime to get auto framing, background and colour effects there. Keep Framelight running.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch model.virtualCameraStatus {
        case .off: return "Off"
        case .streaming: return "Live — sending frames"
        case .notInstalled: return "Virtual camera not installed yet (or not approved)"
        case .failed(let message): return message
        }
    }
}

// MARK: - Slider

enum SliderFormat {
    case percent, centeredPercent, signed, integer, multiplier, ev

    func string(_ v: Double) -> String {
        switch self {
        case .percent: return "\(Int((v * 100).rounded()))%"
        case .centeredPercent: return String(format: "%+ld%%", Int(((v - 1) * 100).rounded()))
        case .signed: return String(format: "%+.2f", v)
        case .integer: return String(format: "%+ld", Int(v.rounded()))
        case .multiplier: return String(format: "%.1f×", v)
        case .ev: return String(format: "%+.1f EV", v)
        }
    }
}

struct TunedSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let reset: Double
    let format: SliderFormat

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, reset: Double, format: SliderFormat) {
        self.title = title
        self._value = value
        self.range = range
        self.reset = reset
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format.string(value))
                    .monospacedDigit()
                    .foregroundStyle(abs(value - reset) < 0.0001 ? .secondary : .primary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = reset }
            .help("Double-click to reset")
            Slider(value: $value, in: range)
        }
    }
}
