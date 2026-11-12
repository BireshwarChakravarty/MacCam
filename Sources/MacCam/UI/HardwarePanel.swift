import SwiftUI

/// Every UVC control the camera reports, grouped and live.
struct HardwarePanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controls: UVCControlStore

    var body: some View {
        Form {
            if controls.device == nil {
                Section {
                    noControlsView
                }
            } else if controls.isLoading && controls.states.isEmpty {
                Section {
                    HStack { ProgressView().controlSize(.small); Text("Reading camera controls…") }
                }
            } else {
                ForEach(UVCControlGroup.allCases) { group in
                    let items = controls.states(in: group)
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { state in
                                UVCControlRow(controls: controls, state: state)
                            }
                        } header: {
                            Label(group.rawValue, systemImage: group.symbol)
                        }
                    }
                }

                Section {
                    Toggle("Restore my settings when the camera reconnects", isOn: $model.autoRestoreOnConnect)
                        .help("Most webcams forget their settings when unplugged or when the Mac sleeps. MacCam re-applies them.")
                    HStack {
                        Button("Reset All to Defaults") { controls.resetToDefaults() }
                        Spacer()
                        Button("Re-read Camera") { Task { await controls.refresh() } }
                    }
                    if let error = controls.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                } footer: {
                    Text("These settings live inside the camera itself, so they also apply in Zoom, Meet, OBS and every other app, even when MacCam's virtual camera isn't used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var noControlsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No hardware controls found", systemImage: "cable.connector.slash")
                .font(.headline)
            Text("MacCam talks to USB (UVC) webcams directly. Built-in FaceTime and Continuity cameras don't expose these controls, but the Studio tab still works for them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Scan USB Again") { Task { await model.reloadControls() } }
        }
        .padding(.vertical, 4)
    }
}

struct UVCControlRow: View {
    @ObservedObject var controls: UVCControlStore
    let state: UVCControlState

    private var locked: Bool { controls.isAutoActive(for: state) || !state.canSet }

    var body: some View {
        Group {
            switch state.definition.kind {
            case .toggle:
                Toggle(isOn: Binding(get: { state.current != 0 },
                                     set: { controls.setValue(state.id, $0 ? 1 : 0) })) {
                    Text(state.definition.name)
                }
                .disabled(!state.canSet)
            case .menu, .aeMode:
                Picker(state.definition.name, selection: Binding(get: { state.current },
                                                                 set: { controls.setValue(state.id, $0) })) {
                    ForEach(state.menuOptions) { option in
                        Text(option.label).tag(option.value)
                    }
                    if !state.menuOptions.contains(where: { $0.value == state.current }) {
                        Text("Value \(state.current)").tag(state.current)
                    }
                }
                .disabled(!state.canSet)
            case .range:
                rangeRow
            }
        }
        .help(state.definition.help)
    }

    private var rangeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(state.definition.name)
                if locked {
                    Text("AUTO")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let def = state.defaultValue, def != state.current, !locked {
                    Button {
                        controls.reset(state.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to camera default (\(def))")
                }
            }
            Slider(value: Binding(get: { Double(state.current) },
                                  set: { controls.setValue(state.id, Int($0.rounded())) }),
                   in: Double(state.minimum)...Double(max(state.maximum, state.minimum + 1)))
                .disabled(locked)
            HStack {
                Text("\(state.minimum)")
                Spacer()
                Text("\(state.maximum)")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var valueText: String {
        switch state.definition.id {
        case "ct.exposureTime":
            let seconds = Double(state.current) / 10_000
            return seconds > 0 ? "1/\(Int((1 / seconds).rounded())) s" : "\(state.current)"
        case "ct.pan", "ct.tilt":
            return String(format: "%.1f°", Double(state.current) / 3600)
        default:
            if let unit = state.definition.valueUnit, unit == "K" || unit == "°" {
                return "\(state.current) \(unit)"
            }
            return "\(state.current)"
        }
    }
}
