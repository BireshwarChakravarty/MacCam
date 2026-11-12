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

/// "When this app comes to the front, apply this preset."
struct AppRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var presetID: UUID
}

/// Named snapshots of hardware + software settings, stored as JSON in Application Support.
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [Preset] = []
    @Published private(set) var rules: [AppRule] = []

    private let rulesURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Framelight", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("automations.json")
    }()

    func addRule(bundleID: String, appName: String, presetID: UUID) {
        rules.removeAll { $0.bundleID == bundleID }
        rules.append(AppRule(bundleID: bundleID, appName: appName, presetID: presetID))
        saveRules()
    }

    func removeRule(_ rule: AppRule) {
        rules.removeAll { $0.id == rule.id }
        saveRules()
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) { try? data.write(to: rulesURL, options: .atomic) }
    }

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
        guard let dict = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              var preset = Self.preset(from: dict) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        preset.id = UUID()
        preset.builtIn = false
        presets.append(preset)
        save()
    }

    private func load() {
        var stored: [Preset] = []
        // Tolerant: presets saved by older versions keep their values; new settings get defaults.
        if let data = try? Data(contentsOf: url),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            stored = array.compactMap(Self.preset(from:))
        }
        presets = Self.builtIns + stored
        if let data = try? Data(contentsOf: rulesURL), let decoded = try? JSONDecoder().decode([AppRule].self, from: data) {
            rules = decoded
        }
    }

    private static func preset(from dict: [String: Any]) -> Preset? {
        guard let name = dict["name"] as? String,
              let softwareDict = dict["software"] as? [String: Any],
              let software = ProcessingSettings.tolerant(fromObject: softwareDict) else { return nil }
        var p = Preset(name: name, software: software)
        if let id = (dict["id"] as? String).flatMap(UUID.init(uuidString:)) { p.id = id }
        if let created = dict["created"] as? Double { p.created = Date(timeIntervalSinceReferenceDate: created) }
        if let hardware = dict["hardware"] as? [String: Int] { p.hardware = hardware }
        return p
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
            make("Bright & Clean") { s in
                s.look = .daylight
            },
            make("Warm Evening") { s in
                s.look = .warmRoom; s.warmth = 12
            },
            make("Soft Film") { s in
                s.look = .softFilm; s.vignette = 0.25
            },
            make("Streamer") { s in
                s.look = .studioCrisp; s.autoFraming = true; s.framingSubject = .upperBody
                s.backgroundMode = .studioLight; s.backgroundStrength = 0.5; s.sharpen = 0.2
            },
            make("Meeting Focus") { s in
                s.autoFraming = true; s.framingSubject = .face; s.framingTightness = 0.35
                s.backgroundMode = .blur; s.backgroundStrength = 0.55
            },
            make("Low Light") { s in
                s.denoise = 0.75; s.shadows = 0.3; s.look = .natural
            },
            make("Moody Stream") { s in
                s.look = .moody; s.backgroundMode = .studioLight; s.backgroundStrength = 0.7; s.vignette = 0.3
            },
        ]
    }()
}
