import Foundation

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var created = Date()
    /// UVC control values keyed by control id. Empty = leave the hardware alone.
    var hardware: [String: Int] = [:]
    var software: ProcessingSettings
    var builtIn = false
}

/// Named snapshots of hardware + software settings, stored as JSON in Application Support.
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [Preset] = []

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Framelight", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("presets.json")
    }()

    init() {
        load()
    }

    var userPresets: [Preset] { presets.filter { !$0.builtIn } }

    func add(name: String, hardware: [String: Int], software: ProcessingSettings) {
        presets.append(Preset(name: name, hardware: hardware, software: software))
        save()
    }

    func update(_ preset: Preset) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[i] = preset
        save()
    }

    func delete(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id && !$0.builtIn }
        save()
    }

    func exportJSON(_ preset: Preset, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: url)
    }

    func importJSON(from url: URL) throws {
        var preset = try JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))
        preset.id = UUID()
        preset.builtIn = false
        presets.append(preset)
        save()
    }

    private func load() {
        var stored: [Preset] = []
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([Preset].self, from: data) {
            stored = decoded
        }
        presets = Self.builtIns + stored
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(userPresets) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Software-only starting points; they leave the camera's hardware settings untouched.
    static let builtIns: [Preset] = {
        func make(_ name: String, _ configure: (inout ProcessingSettings) -> Void) -> Preset {
            var s = ProcessingSettings()
            configure(&s)
            return Preset(id: UUID(), name: name, software: s, builtIn: true)
        }
        return [
            make("Natural") { _ in },
            make("Warm & Cozy") { s in
                s.warmth = 28; s.vibrance = 0.15; s.shadows = 0.15; s.contrast = 0.97
            },
            make("Cool Studio") { s in
                s.warmth = -18; s.contrast = 1.08; s.saturation = 0.95; s.sharpen = 0.2
            },
            make("Streamer Pop") { s in
                s.vibrance = 0.35; s.contrast = 1.1; s.shadows = 0.2; s.sharpen = 0.25; s.vignette = 0.25
                s.autoFraming = true; s.framingSubject = .upperBody
            },
            make("Cinematic") { s in
                s.look = .cinematic; s.vignette = 0.35; s.backgroundMode = .blur; s.backgroundBlur = 0.5
            },
            make("Low-Light Rescue") { s in
                s.exposure = 0.5; s.shadows = 0.45; s.highlights = 0.85; s.denoise = 0.6; s.vibrance = 0.1
            },
            make("Meeting Focus") { s in
                s.autoFraming = true; s.framingSubject = .face; s.framingTightness = 0.35
                s.backgroundMode = .blur; s.backgroundBlur = 0.7
            },
        ]
    }()
}
