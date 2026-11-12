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

            automationsSection

            Section {
                Button("Import Preset…", action: importPreset)
            }
        }
        .formStyle(.grouped)
    }

    @State private var ruleApp = ""
    @State private var rulePreset: UUID?

    private var runningApps: [(id: String, name: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> (id: String, name: String)? in
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return (id: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var automationsSection: some View {
        Section {
            ForEach(store.rules) { rule in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.appName)
                        Text("→ " + (store.presets.first { $0.id == rule.presetID }?.name ?? "missing preset"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { store.removeRule(rule) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            Picker("When", selection: $ruleApp) {
                Text("Choose an open app…").tag("")
                ForEach(runningApps, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Apply", selection: $rulePreset) {
                Text("Choose a preset…").tag(UUID?.none)
                ForEach(store.presets) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            Button("Add Rule") {
                guard let preset = rulePreset, let app = runningApps.first(where: { $0.id == ruleApp }) else { return }
                store.addRule(bundleID: app.id, appName: app.name, presetID: preset)
                ruleApp = ""; rulePreset = nil
            }
            .disabled(ruleApp.isEmpty || rulePreset == nil)
            Toggle(isOn: $model.holdCameraSettings) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hold Camera Settings")
                    Text("Zoom, Teams and browsers sometimes reset webcam settings. Framelight puts yours back within seconds.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let last = model.lastAutomation {
                Text("Last applied: \(last)").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Label("Automations", systemImage: "bolt.badge.clock")
        } footer: {
            Text("When an app comes to the front, Framelight applies the preset you picked for it, for example Meeting Focus for Zoom and Streamer for OBS.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
        panel.nameFieldStringValue = "\(preset.name).framelight.json"
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
        if preset.software.backgroundMode != .none { parts.append(preset.software.backgroundMode.rawValue.lowercased()) }
        parts.insert(preset.software.look.displayName, at: 0)
        if preset.software.denoise > 0.6 { parts.append("strong noise reduction") }
        return parts.joined(separator: " · ")
    }
}
