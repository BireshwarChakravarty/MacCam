import SwiftUI
import UniformTypeIdentifiers

struct PresetsPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: PresetStore
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Preset name", text: $newName)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Label("Save Current Setup", systemImage: "square.and.arrow.down")
            } footer: {
                Text("Saves every camera hardware setting plus all Studio settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !store.userPresets.isEmpty {
                Section {
                    ForEach(store.userPresets) { preset in
                        PresetRow(preset: preset)
                            .contextMenu {
                                Button("Update with Current Settings") {
                                    var p = preset
                                    p.hardware = model.controls.snapshot()
                                    p.software = model.settings
                                    store.update(p)
                                }
                                Button("Export…") { export(preset) }
                                Divider()
                                Button("Delete", role: .destructive) { store.delete(preset) }
                            }
                    }
                } header: {
                    Label("My Presets", systemImage: "star")
                }
            }

            Section {
                ForEach(store.presets.filter(\.builtIn)) { preset in
                    PresetRow(preset: preset)
                }
            } header: {
                Label("Starter Looks", systemImage: "sparkles")
            } footer: {
                Text("Starter looks only change Studio settings; your camera hardware settings stay as they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Import Preset…", action: importPreset)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.saveCurrentAsPreset(named: name)
        newName = ""
    }

    private func export(_ preset: Preset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(preset.name).maccam.json"
        if panel.runModal() == .OK, let url = panel.url {
            try? store.exportJSON(preset, to: url)
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.importJSON(from: url) } catch { model.flash("Couldn't import: \(error.localizedDescription)") }
        }
    }
}

private struct PresetRow: View {
    @EnvironmentObject var model: AppModel
    let preset: Preset

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Apply") { model.apply(preset) }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !preset.hardware.isEmpty { parts.append("\(preset.hardware.count) camera settings") }
        if preset.software.autoFraming { parts.append("auto framing") }
        if preset.software.backgroundMode != .none { parts.append("background \(preset.software.backgroundMode.rawValue.lowercased())") }
        if preset.software.look != .none { parts.append(preset.software.look.rawValue) }
        if !preset.software.isColorNeutral && preset.software.look == .none { parts.append("color grade") }
        return parts.isEmpty ? "Clean, unprocessed" : parts.joined(separator: " · ")
    }
}
