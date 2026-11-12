import Foundation
import Combine

struct UVCControlState: Identifiable, Equatable {
    let definition: UVCControlDefinition
    var minimum: Int = 0
    var maximum: Int = 0
    var resolution: Int = 1
    var defaultValue: Int?
    var current: Int = 0
    /// GET_INFO capabilities bitmap (D0 get, D1 set, D2 disabled by auto mode, D3 autoupdate, D4 async).
    var info: UInt8 = 0x03

    var id: String { definition.id }
    var canSet: Bool { info & 0x02 != 0 }
    var disabledByAutoMode: Bool { info & 0x04 != 0 }

    var menuOptions: [UVCMenuOption] {
        switch definition.kind {
        case .menu(let options):
            if maximum > minimum {
                return options.filter { $0.value >= minimum && $0.value <= maximum }
            }
            return options
        case .aeMode:
            let bitmap = resolution > 1 ? resolution : (AEMode.manual | AEMode.aperturePriority)
            return [AEMode.manual, AEMode.auto, AEMode.shutterPriority, AEMode.aperturePriority]
                .filter { bitmap & $0 != 0 }
                .map { UVCMenuOption(value: $0, label: AEMode.label($0)) }
        default:
            return []
        }
    }
}

/// Owns the hardware controls of one camera: discovery, reads, coalesced writes and persistence.
@MainActor
final class UVCControlStore: ObservableObject {
    @Published private(set) var states: [String: UVCControlState] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    let device: UVCDevice?
    private let queue = DispatchQueue(label: "framelight.uvc", qos: .userInitiated)
    private var pendingWrites: [String: Int] = [:]
    private var flushScheduled = false
    private var pollTimer: Timer?

    /// Remembered per-camera values, re-applied when the camera is reconnected
    /// (most webcams forget everything on power loss).
    var persistenceKey: String? {
        guard let device else { return nil }
        return "uvc.saved.\(device.idString).\(device.serialNumber ?? device.name)"
    }

    init(device: UVCDevice?) {
        self.device = device
    }

    /// Stops background polling; call before discarding the store.
    func invalidate() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    var supportedStates: [UVCControlState] {
        UVCCatalog.all.compactMap { states[$0.id] }
    }

    func states(in group: UVCControlGroup) -> [UVCControlState] {
        supportedStates.filter { $0.definition.group == group }
    }

    func state(_ id: String) -> UVCControlState? { states[id] }

    /// True when an automatic mode currently owns this control.
    func isAutoActive(for state: UVCControlState) -> Bool {
        if state.disabledByAutoMode { return true }
        guard let autoID = state.definition.autoControlID, let auto = states[autoID] else { return false }
        if auto.definition.kind == .aeMode {
            return AEMode.exposureIsAutomatic(auto.current)
        }
        return auto.current != 0
    }

    // MARK: Loading

    func load(probeAll: Bool = false) async {
        guard let device else { return }
        isLoading = true
        defer { isLoading = false }

        let topology = device.topology
        let candidates = UVCCatalog.all.filter { def in
            switch def.unit {
            case .cameraTerminal:
                guard topology.cameraTerminalID != nil else { return false }
                return probeAll || topology.cameraControls & (1 << UInt64(def.bit)) != 0
            case .processingUnit:
                guard topology.processingUnitID != nil else { return false }
                return probeAll || topology.processingControls & (1 << UInt64(def.bit)) != 0
            }
        }

        let loaded: [UVCControlState] = await withCheckedContinuation { cont in
            queue.async {
                let results = candidates.compactMap { UVCControlStore.probe($0, device: device) }
                cont.resume(returning: results)
            }
        }

        // If the descriptor bitmaps are empty or lying, fall back to probing everything once.
        if loaded.isEmpty && !probeAll {
            await load(probeAll: true)
            return
        }
        states = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        startPolling()
    }

    nonisolated private static func unitID(for def: UVCControlDefinition, device: UVCDevice) -> UInt8? {
        switch def.unit {
        case .cameraTerminal: return device.topology.cameraTerminalID
        case .processingUnit: return device.topology.processingUnitID
        }
    }

    nonisolated private static func probe(_ def: UVCControlDefinition, device: UVCDevice) -> UVCControlState? {
        guard let unit = unitID(for: def, device: device) else { return nil }
        var state = UVCControlState(definition: def)

        if let info = try? device.get(.getInfo, unit: unit, selector: def.selector, length: 1) {
            state.info = info[0]
            if state.info & 0x01 == 0 { return nil } // GET not supported => unusable
        }
        guard let cur = try? device.get(.getCur, unit: unit, selector: def.selector, length: def.length) else { return nil }
        state.current = cur.int(at: def.fieldOffset, size: def.fieldSize, signed: def.signed)

        func read(_ code: UVCRequestCode) -> Int? {
            guard let bytes = try? device.get(code, unit: unit, selector: def.selector, length: def.length) else { return nil }
            return bytes.int(at: def.fieldOffset, size: def.fieldSize, signed: def.signed)
        }

        switch def.kind {
        case .range:
            guard let lo = read(.getMin), let hi = read(.getMax), hi > lo else { return nil }
            state.minimum = lo
            state.maximum = hi
            state.resolution = max(1, read(.getRes) ?? 1)
        case .toggle:
            state.minimum = 0
            state.maximum = 1
        case .menu:
            state.minimum = read(.getMin) ?? 0
            state.maximum = read(.getMax) ?? 0
        case .aeMode:
            state.resolution = read(.getRes) ?? 0
        }
        state.defaultValue = read(.getDef)
        return state
    }

    // MARK: Writing

    /// Updates the UI immediately and writes to the camera, coalescing rapid slider drags.
    func setValue(_ id: String, _ value: Int) {
        guard var state = states[id] else { return }
        var v = value
        if state.definition.kind == .range {
            let step = max(1, state.resolution)
            v = state.minimum + Int((Double(v - state.minimum) / Double(step)).rounded()) * step
            v = min(max(v, state.minimum), state.maximum)
        }
        guard v != state.current || state.definition.isAutoSwitch else { return }
        state.current = v
        states[id] = state
        pendingWrites[id] = v
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        // ~30 writes/s max per control while dragging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in
            Task { @MainActor in await self?.flush() }
        }
    }

    private func flush() async {
        flushScheduled = false
        guard let device, !pendingWrites.isEmpty else { return }
        // Switch auto modes before manual values so the manual values are accepted.
        let writes = pendingWrites.sorted { a, b in
            let aAuto = UVCCatalog.byID[a.key]?.isAutoSwitch ?? false
            let bAuto = UVCCatalog.byID[b.key]?.isAutoSwitch ?? false
            return aAuto && !bAuto
        }
        pendingWrites.removeAll()
        let touchedAuto = writes.contains { UVCCatalog.byID[$0.key]?.isAutoSwitch ?? false }

        let error: String? = await withCheckedContinuation { cont in
            queue.async {
                var lastError: String?
                for (id, value) in writes {
                    guard let def = UVCCatalog.byID[id] else { continue }
                    do { try UVCControlStore.write(def, value: value, device: device) } catch {
                        lastError = "\(def.name): \(error)"
                    }
                }
                cont.resume(returning: lastError)
            }
        }
        lastError = error
        if touchedAuto {
            // Auto mode changes affect which controls are writable and their live values.
            try? await Task.sleep(nanoseconds: 150_000_000)
            await refresh()
        }
        persist()
    }

    nonisolated private static func write(_ def: UVCControlDefinition, value: Int, device: UVCDevice) throws {
        guard let unit = unitID(for: def, device: device) else { return }
        var payload: [UInt8]
        if def.isComposite {
            payload = try device.get(.getCur, unit: unit, selector: def.selector, length: def.length)
        } else {
            payload = [UInt8](repeating: 0, count: def.length)
        }
        payload.put(value, at: def.fieldOffset, size: def.fieldSize)
        try device.set(unit: unit, selector: def.selector, data: payload)
    }

    /// Re-reads current values and capability flags (used after auto toggles and for live auto values).
    func refresh(only ids: [String]? = nil) async {
        guard let device else { return }
        let targets = (ids ?? Array(states.keys)).compactMap { states[$0] }
        let updated: [UVCControlState] = await withCheckedContinuation { cont in
            queue.async {
                let results: [UVCControlState] = targets.map { old in
                    var s = old
                    guard let unit = UVCControlStore.unitID(for: s.definition, device: device) else { return s }
                    if let info = try? device.get(.getInfo, unit: unit, selector: s.definition.selector, length: 1) {
                        s.info = info[0]
                    }
                    if let cur = try? device.get(.getCur, unit: unit, selector: s.definition.selector, length: s.definition.length) {
                        s.current = cur.int(at: s.definition.fieldOffset, size: s.definition.fieldSize, signed: s.definition.signed)
                    }
                    return s
                }
                cont.resume(returning: results)
            }
        }
        for s in updated where pendingWrites[s.id] == nil {
            states[s.id] = s
        }
    }

    /// While auto modes run, show the values the camera is choosing (e.g. live colour temperature).
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pendingWrites.isEmpty else { return }
                let autoOwned = self.states.values.filter { self.isAutoActive(for: $0) }.map(\.id)
                if !autoOwned.isEmpty { await self.refresh(only: autoOwned) }
            }
        }
    }

    func resetToDefaults() {
        // Re-enable auto modes first, then restore defaults for everything.
        for state in supportedStates {
            if let def = state.defaultValue { setValue(state.id, def) }
        }
    }

    /// Puts the camera's own processing in a neutral state that software can build on.
    /// Cheap webcams over-sharpen (halos, "crunchy" skin) and push saturation by default; neither can be
    /// undone later, so they're set at the source. Automatic exposure, white balance and focus stay on.
    func applyNaturalBaseline() -> [String] {
        var changed: [String] = []
        func set(_ id: String, _ value: Int?) {
            guard let state = states[id], state.canSet, let value, value != state.current else { return }
            setValue(id, value)
            changed.append(state.definition.name)
        }
        if let ae = states["ct.aeMode"] {
            let modes = ae.menuOptions.map(\.value)
            set("ct.aeMode", modes.contains(AEMode.aperturePriority) ? AEMode.aperturePriority
                : (modes.contains(AEMode.auto) ? AEMode.auto : nil))
        }
        set("pu.wbTempAuto", 1)
        set("ct.focusAuto", 1)
        if let sharp = states["pu.sharpness"] {
            // About a third of the camera's default: removes halos, keeps real detail.
            let base = sharp.defaultValue ?? (sharp.minimum + (sharp.maximum - sharp.minimum) / 2)
            set("pu.sharpness", sharp.minimum + Int(Double(base - sharp.minimum) * 0.35))
        }
        for id in ["pu.saturation", "pu.contrast", "pu.gamma", "pu.hue", "pu.brightness"] {
            set(id, states[id]?.defaultValue)
        }
        if let gain = states["pu.gain"], !isAutoActive(for: gain) {
            set("pu.gain", gain.defaultValue)
        }
        return changed
    }

    func reset(_ id: String) {
        if let def = states[id]?.defaultValue { setValue(id, def) }
    }

    // MARK: Snapshots & persistence

    /// Writable values, suitable for presets.
    func snapshot() -> [String: Int] {
        var out: [String: Int] = [:]
        for state in supportedStates where state.canSet {
            // Skip manual values that are owned by an auto mode; they would fight it on restore.
            if !state.definition.isAutoSwitch && isAutoActive(for: state) { continue }
            out[state.id] = state.current
        }
        return out
    }

    func apply(_ values: [String: Int]) {
        for (id, value) in values where states[id] != nil {
            if let state = states[id], state.current == value, !state.definition.isAutoSwitch { continue }
            setValue(id, value)
        }
    }

    private func persist() {
        guard let key = persistenceKey else { return }
        UserDefaults.standard.set(snapshot(), forKey: key)
    }

    var savedValues: [String: Int]? {
        guard let key = persistenceKey else { return nil }
        return UserDefaults.standard.dictionary(forKey: key) as? [String: Int]
    }

    func restoreSaved() {
        if let saved = savedValues { apply(saved) }
    }
}
