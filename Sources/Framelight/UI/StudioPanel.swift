import SwiftUI

/// Software features: look, light & colour, detail, background, framing, output.
struct StudioPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            lookSection
            lightSection
            detailSection
            backgroundSection
            framingSection
            overlaySection
            outputSection
            virtualCameraSection

            Section {
                HStack {
                    Button("Reset Studio") { model.resetSoftware() }
                    Spacer()
                    Toggle("Compare Before / After", isOn: $model.settings.compare)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Look

    private var lookSection: some View {
        Section {
            LookGrid(live: model.live, selected: $model.settings.look)
                .padding(.vertical, 4)
            TunedSlider("Strength", value: $model.settings.lookIntensity, in: 0...1, reset: 1) { "\(Int(($0 * 100).rounded()))%" }
            HStack {
                Picker("Creative LUT", selection: Binding(get: { model.settings.customLUT ?? "" },
                                                          set: { model.settings.customLUT = $0.isEmpty ? nil : $0 })) {
                    Text("None").tag("")
                    ForEach(model.lutNames, id: \.self) { Text($0).tag($0) }
                }
                Button("Import…") { model.importLUT() }
            }
            if let lut = model.settings.customLUT {
                TunedSlider("LUT Strength", value: $model.settings.customLUTIntensity, in: 0...1, reset: 1) { "\(Int(($0 * 100).rounded()))%" }
                Button("Remove “\(lut)” from Library", role: .destructive) { model.removeLUT(lut) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } header: {
            Label("Look", systemImage: "camera.filters")
        } footer: {
            Text(model.settings.look.summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Light & colour

    private var lightSection: some View {
        Section {
            Toggle(isOn: $model.settings.autoLight) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Light")
                    LiveCaption(live: model.live) { autoLightStatus($0) }
                }
            }
            if model.settings.autoLight {
                Picker("Metering", selection: $model.settings.meteringMode) {
                    ForEach(MeteringMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Toggle(isOn: $model.settings.naturalSkin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Natural Skin Tones")
                    LiveCaption(live: model.live) { skinStatus($0) }
                }
            }
            .disabled(model.settings.hasWhitePoint)
            HStack {
                Button {
                    model.pickingWhitePoint.toggle()
                } label: {
                    Label(model.pickingWhitePoint ? "Click something white in the preview…" : "Pick White Point",
                          systemImage: "eyedropper")
                }
                Spacer()
                if model.settings.hasWhitePoint {
                    Button("Clear") { model.clearWhitePoint() }
                }
            }

            TunedSlider("Exposure", value: $model.settings.exposure, in: -2...2, reset: 0) { String(format: "%+.1f EV", $0) }
            TunedSlider("Temperature", value: $model.settings.warmth, in: -100...100, reset: 0) { v in
                let k = Int((v * 15).rounded())
                return k == 0 ? "As shot" : (k > 0 ? "+\(k) K warmer" : "\(-k) K cooler")
            }
            TunedSlider("Tint", value: $model.settings.tint, in: -100...100, reset: 0) { v in
                let t = Int(v.rounded())
                return t == 0 ? "0" : (t > 0 ? "+\(t) magenta" : "\(-t) green")
            }
            TunedSlider("Contrast", value: $model.settings.contrast, in: 0.75...1.3, reset: 1) { signedPercent($0 - 1) }
            TunedSlider("Saturation", value: $model.settings.saturation, in: 0...1.6, reset: 1) { signedPercent($0 - 1) }
            TunedSlider("Vibrance", value: $model.settings.vibrance, in: -1...1, reset: 0) { signedPercent($0) }
            TunedSlider("Highlight Recovery", value: Binding(get: { (1 - model.settings.highlights) / 0.6 },
                                                             set: { model.settings.highlights = 1 - $0 * 0.6 }),
                        in: 0...1, reset: 0) { "\(Int(($0 * 100).rounded()))%" }
            TunedSlider("Shadow Lift", value: Binding(get: { model.settings.shadows / 0.8 },
                                                      set: { model.settings.shadows = $0 * 0.8 }),
                        in: 0...1, reset: 0) { "\(Int(($0 * 100).rounded()))%" }
        } header: {
            Label("Light & Color", systemImage: "sun.max")
        } footer: {
            Text("Saturation is held back on skin and hue never shifts, so faces stay true. Double-click a slider's name to reset it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func autoLightStatus(_ stats: FrameProcessor.FrameStats?) -> String {
        guard model.settings.autoLight else { return "Meters your face (or the scene) and only steps in when it's too dark or too bright." }
        guard let ev = stats?.autoExposure, abs(ev) >= 0.05 else { return "Your face is well exposed. No correction." }
        return String(format: "Correcting %+.1f EV for your face", ev)
    }

    private func skinStatus(_ stats: FrameProcessor.FrameStats?) -> String {
        if model.settings.hasWhitePoint { return "Paused while your picked white point is in use." }
        guard model.settings.naturalSkin else { return "Removes green or magenta casts using your skin tone, like a colourist." }
        return stats?.skinCorrection == true ? "Correcting a colour cast from the lighting." : "Skin tones look natural. No correction."
    }

    // MARK: Detail

    private var detailSection: some View {
        Section {
            TunedSlider("Noise Reduction", value: $model.settings.denoise, in: 0...1, reset: 0.35) { "\(Int(($0 * 100).rounded()))%" }
            TunedSlider("Sharpness", value: $model.settings.sharpen, in: 0...1, reset: 0) { "\(Int(($0 * 100).rounded()))%" }
            TunedSlider("Vignette", value: $model.settings.vignette, in: 0...1, reset: 0) { "\(Int(($0 * 100).rounded()))%" }
        } header: {
            Label("Detail", systemImage: "wand.and.stars")
        } footer: {
            Text("Noise reduction averages frames only where nothing moves, so skin keeps its texture instead of looking plastic.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Background

    private var backgroundSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(BackgroundMode.allCases) { mode in
                    Button {
                        model.settings.backgroundMode = mode
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: mode.symbol).font(.system(size: 15))
                            Text(mode.rawValue).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .background(model.settings.backgroundMode == mode ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(model.settings.backgroundMode == mode ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1))
                }
            }
            if model.settings.backgroundMode != .none {
                TunedSlider("Strength", value: $model.settings.backgroundStrength, in: 0...1, reset: 0.6) { "\(Int(($0 * 100).rounded()))%" }
            }
            switch model.settings.backgroundMode {
            case .color:
                ColorPicker("Backdrop Color", selection: Binding(
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
            default:
                EmptyView()
            }
        } header: {
            Label("Background", systemImage: "person.and.background.dotted")
        } footer: {
            Text(backgroundFooter).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var backgroundFooter: String {
        switch model.settings.backgroundMode {
        case .none: return "Keeps the room exactly as the camera sees it."
        case .blur: return "Lens-style blur with no halo around you. The blurred area keeps a little grain so it doesn't look pasted on."
        case .studioLight: return "Lifts you slightly and dims the room, like a key light in a darker space."
        case .color: return "A softly lit studio backdrop."
        case .image: return "Your photo, slightly defocused so it sits naturally behind you."
        }
    }

    // MARK: Framing

    private var framingSection: some View {
        Section {
            Toggle(isOn: $model.settings.autoFraming) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Framing")
                    Text("Follows you smoothly by cropping the 4K sensor, like Center Stage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.settings.autoFraming {
                Picker("Follow", selection: $model.settings.framingSubject) {
                    ForEach(FramingSubject.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                TunedSlider("Tightness", value: $model.settings.framingTightness, in: 0...1, reset: 0.5) { "\(Int(($0 * 100).rounded()))%" }
                TunedSlider("Motion Speed", value: $model.settings.framingSpeed, in: 0...1, reset: 0.5) { "\(Int(($0 * 100).rounded()))%" }
                TunedSlider("Max Zoom", value: $model.settings.maxZoom, in: 1...4, reset: 2.5) { String(format: "%.1f×", $0) }
            } else {
                TunedSlider("Digital Zoom", value: $model.settings.digitalZoom, in: 1...4, reset: 1) { String(format: "%.1f×", $0) }
                if model.settings.digitalZoom > 1.01 {
                    TunedSlider("Pan", value: $model.settings.panX, in: -1...1, reset: 0) { String(format: "%+.2f", $0) }
                    TunedSlider("Tilt", value: $model.settings.panY, in: -1...1, reset: 0) { String(format: "%+.2f", $0) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Shots").font(.subheadline)
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { i in
                        Button {
                            model.recallShot(i)
                        } label: {
                            VStack(spacing: 1) {
                                Text("\(i + 1)").font(.headline)
                                Text(model.shots[i].map { String(format: "%.1f×", $0.zoom) } ?? "empty")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        .contextMenu {
                            Button("Save Current Framing to Shot \(i + 1)") { model.saveShot(i) }
                            if model.shots[i] != nil { Button("Clear Shot \(i + 1)", role: .destructive) { model.clearShot(i) } }
                        }
                        .help("⌘\(i + 1) to recall · right-click to save")
                    }
                }
                Text("Right-click a shot to save the current zoom and pan. Recall with ⌘1–⌘4; the camera glides there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: $model.settings.gestureControl) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gesture Control")
                    Text("Hold up an open palm ✋ to toggle Auto Framing, or a peace sign ✌️ to toggle background blur.")
                        .font(.caption).foregroundStyle(.secondary)
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

    // MARK: Overlay

    private var overlaySection: some View {
        Section {
            Toggle("Name Tag", isOn: $model.settings.nameTagEnabled)
            if model.settings.nameTagEnabled {
                TextField("Name", text: $model.settings.nameTagTitle)
                TextField("Title or handle (optional)", text: $model.settings.nameTagSubtitle)
            }
            Toggle(isOn: Binding(get: { model.settings.privacy }, set: { _ in model.togglePrivacy() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy")
                    Text("Blurs you completely in calls and recordings (⌘⇧H).").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("Overlay & Privacy", systemImage: "text.below.photo")
        }
    }

    // MARK: Output

    private var outputSection: some View {
        Section {
            Picker("Output Resolution", selection: $model.settings.outputResolution) {
                ForEach(OutputResolution.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Shape", selection: $model.settings.outputAspect) {
                ForEach(OutputAspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if model.settings.outputAspect != .widescreen {
                Text("Recordings use this shape. Other apps receive 16:9 with the shot centred on a soft fill.")
                    .font(.caption).foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 2) {
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
            Text("Pick “\(VirtualCameraConfig.deviceName)” in Zoom, Google Meet, Teams, OBS or FaceTime to use everything above there. Keep Framelight running.")
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

    private func signedPercent(_ v: Double) -> String {
        let p = Int((v * 100).rounded())
        return p == 0 ? "0%" : String(format: "%+ld%%", p)
    }
}

// MARK: - Look grid

/// Observes only the thumbnails, so a new thumbnail doesn't redraw the rest of the sidebar.
private struct LookGrid: View {
    @ObservedObject var live: LiveState
    @Binding var selected: LookStyle

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
            ForEach(LookStyle.allCases) { look in
                LookTile(look: look, image: live.lookThumbnails[look], selected: selected == look) {
                    selected = look
                }
            }
        }
    }
}

// MARK: - Look tile

private struct LookTile: View {
    let look: LookStyle
    let image: NSImage?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(16 / 9, contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.15))
                            .aspectRatio(16 / 9, contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2.5 : 1))
                Text(look.displayName)
                    .font(.caption2.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(look.summary)
        .accessibilityLabel(look.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Slider

struct TunedSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let reset: Double
    let display: (Double) -> String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, reset: Double,
         display: @escaping (Double) -> String) {
        self.title = title
        self._value = value
        self.range = range
        self.reset = reset
        self.display = display
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display(value))
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
