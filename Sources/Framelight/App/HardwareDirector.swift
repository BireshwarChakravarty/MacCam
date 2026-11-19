import Foundation
import CoreGraphics

/// "In the Camera" mode: turns what Framelight sees (face position, face brightness, a picked white spot)
/// into live changes to the webcam's own controls. FaceTime, Zoom and every other app read the camera's
/// output directly, so they get the result without a virtual camera.
@MainActor
final class HardwareDirector {
    weak var model: AppModel?

    // Framing
    private var lastFramingTick = 0.0
    private var panSign = 1.0, tiltSign = 1.0
    private var lastPanError: Double?, lastTiltError: Double?
    private var panWrongWay = 0, tiltWrongWay = 0

    // Light
    private var lastLightTick = 0.0
    private var lightBase: (id: String, value: Int)?

    // White balance search in progress
    private(set) var matchingWhite = false

    private var controls: UVCControlStore? { model?.controls }

    // MARK: Capabilities

    struct Capabilities {
        var zoom = false, pan = false, tilt = false
        var light = false, whiteBalance = false, colour = false, privacy = false
        var framing: Bool { zoom || pan || tilt }
    }

    var capabilities: Capabilities {
        guard let c = controls else { return Capabilities() }
        func can(_ id: String) -> Bool { c.state(id)?.canSet ?? false }
        return Capabilities(zoom: can("ct.zoom") || can("pu.digitalMultiplier"),
                            pan: can("ct.pan"), tilt: can("ct.tilt"),
                            light: can("pu.brightness") || can("pu.gain"),
                            whiteBalance: can("pu.wbTemp"),
                            colour: can("pu.saturation") || can("pu.contrast"),
                            privacy: can("ct.privacy"))
    }

    // MARK: Auto framing with the camera's zoom / pan / tilt

    /// Closed loop: nudges the camera's PTZ so the face lands at the target size and position.
    /// Works without knowing how a camera maps its PTZ units, and learns the direction of pan/tilt.
    func handle(_ d: FramingDetection) {
        guard let m = model, let c = controls, m.settings.effectsTarget == .camera, m.settings.autoFraming else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastFramingTick > 0.12 else { return }      // ~8 updates a second
        lastFramingTick = now

        let faces = d.faces
        guard !faces.isEmpty else { return }
        let subject: CGRect
        if m.settings.framingSubject == .group {
            subject = faces.dropFirst().reduce(faces[0]) { $0.union($1) }
        } else {
            subject = faces.max { $0.width * $0.height < $1.width * $1.height }!
        }
        let speed = 0.5 + m.settings.framingSpeed            // 0.5…1.5

        // Zoom: face (or group) height as a share of the frame.
        let loose = 1 - m.settings.framingTightness
        let targetHeight: Double
        switch m.settings.framingSubject {
        case .face: targetHeight = 0.46 - 0.12 * loose
        case .upperBody: targetHeight = 0.32 - 0.08 * loose
        case .group: targetHeight = 0.55 - 0.15 * loose
        }
        let zoomID = c.state("ct.zoom")?.canSet == true ? "ct.zoom" : "pu.digitalMultiplier"
        if let z = c.state(zoomID), z.canSet {
            let err = log(targetHeight / max(0.02, Double(subject.height)))
            if abs(err) > 0.12 {
                let range = Double(z.maximum - z.minimum)
                let step = max(-0.05, min(0.05, err * 0.2 * speed)) * range
                let next = max(z.minimum, min(z.maximum, z.current + Int(step.rounded())))
                if next != z.current { c.setValue(zoomID, next) }
            }
        }

        // Pan / tilt: keep the subject centred, eyes a little above the middle.
        let ex = Double(subject.midX) - 0.5
        let ey = Double(subject.midY) - (m.settings.framingSubject == .face ? 0.56 : 0.6)
        adjust("ct.pan", error: ex, sign: &panSign, lastError: &lastPanError, wrongWay: &panWrongWay, speed: speed, c: c)
        adjust("ct.tilt", error: ey, sign: &tiltSign, lastError: &lastTiltError, wrongWay: &tiltWrongWay, speed: speed, c: c)
    }

    private func adjust(_ id: String, error e: Double, sign: inout Double, lastError: inout Double?,
                        wrongWay: inout Int, speed: Double, c: UVCControlStore) {
        guard let st = c.state(id), st.canSet else { return }
        // Learn the direction: if the error keeps growing after we act, this camera's axis is reversed.
        if let last = lastError, abs(last) > 0.07 {
            if abs(e) > abs(last) + 0.02 && (e > 0) == (last > 0) { wrongWay += 1 } else { wrongWay = 0 }
            if wrongWay >= 3 { sign = -sign; wrongWay = 0 }
        }
        lastError = e
        guard abs(e) > 0.07 else { return }                  // dead zone: don't chase small movements
        let range = Double(st.maximum - st.minimum)
        let step = max(-0.04, min(0.04, e * 0.12 * speed)) * range * sign
        let next = max(st.minimum, min(st.maximum, st.current + Int(step.rounded())))
        if next != st.current { c.setValue(id, next) }
    }

    func stopFraming() {
        lastPanError = nil
        lastTiltError = nil
    }

    // MARK: Auto light with the camera's brightness / gain

    /// Face-metered: only acts when the face is outside the 40–70 IRE band for skin,
    /// and never moves more than ±30% of the control's range from where you left it.
    func handleFace(_ rgb: SIMD3<Double>) {
        guard let m = model, let c = controls, m.settings.effectsTarget == .camera, m.settings.autoLight else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastLightTick > 0.6 else { return }
        lastLightTick = now

        let id = c.state("pu.brightness")?.canSet == true ? "pu.brightness" : "pu.gain"
        guard let st = c.state(id), st.canSet else { return }
        if lightBase?.id != id { lightBase = (id, st.current) }
        let ev = GradeEngine.exposureCorrection(faceLuminance: ColorMath.luminance(rgb.x, rgb.y, rgb.z))
        guard abs(ev) > 0.12, let base = lightBase else { return }
        let range = Double(st.maximum - st.minimum)
        let step = max(Double(st.resolution), 0.025 * range) * (ev > 0 ? 1 : -1)
        let low = max(st.minimum, base.value - Int(0.3 * range)), high = min(st.maximum, base.value + Int(0.3 * range))
        let next = max(low, min(high, st.current + Int(step.rounded())))
        if next != st.current { c.setValue(id, next) }
    }

    /// Forget the auto-light reference (e.g. when the user changes brightness themselves or switches modes).
    func resetLight() { lightBase = nil }

    // MARK: Looks with the camera's colour controls

    /// Approximates a look with the camera's own colour controls, as offsets from its defaults
    /// (a share of each control's range). Coarser than Framelight's GPU looks, but visible in every app.
    static func offsets(for look: LookStyle) -> [String: Double] {
        switch look {
        case .natural: return [:]
        case .daylight: return ["pu.gamma": 0.06, "pu.brightness": 0.03, "pu.saturation": 0.04]
        case .warmRoom: return ["pu.saturation": -0.02, "pu.contrast": -0.03, "pu.gamma": 0.03]
        case .softFilm: return ["pu.contrast": -0.10, "pu.saturation": -0.08, "pu.gamma": 0.04]
        case .studioCrisp: return ["pu.contrast": 0.08, "pu.saturation": 0.06]
        case .moody: return ["pu.contrast": 0.10, "pu.saturation": -0.18, "pu.brightness": -0.04]
        case .mono: return ["pu.saturation": -1]
        }
    }

    func applyLook(_ look: LookStyle, intensity: Double) {
        guard let c = controls else { return }
        for id in ["pu.gamma", "pu.brightness", "pu.saturation", "pu.contrast"] {
            guard let st = c.state(id), st.canSet else { continue }
            let base = st.defaultValue ?? st.current
            let offset = (Self.offsets(for: look)[id] ?? 0) * intensity
            let range = Double(st.maximum - st.minimum)
            let target = offset <= -1 ? st.minimum : base + Int((offset * range).rounded())
            let value = max(st.minimum, min(st.maximum, target))
            if value != st.current { c.setValue(id, value) }
        }
        resetLight()
    }

    // MARK: White point with the camera's white balance

    /// Searches the camera's colour temperature until the picked spot is neutral (red ≈ blue),
    /// checking the live image after each step. `point` is normalized, bottom-left origin.
    func matchWhitePoint(at point: CGPoint) async -> Bool {
        guard let m = model, let c = controls, let wb = c.state("pu.wbTemp"), wb.canSet, !matchingWhite else { return false }
        matchingWhite = true
        defer { matchingWhite = false }
        if c.state("pu.wbTempAuto")?.current == 1 { c.setValue("pu.wbTempAuto", 0) }
        try? await Task.sleep(nanoseconds: 300_000_000)

        var lo = Double(max(wb.minimum, 2500)), hi = Double(min(wb.maximum, 7500))
        for _ in 0..<7 {
            let mid = ((lo + hi) / 2).rounded()
            c.setValue("pu.wbTemp", Int(mid))
            try? await Task.sleep(nanoseconds: 450_000_000)   // let the camera settle and new frames arrive
            guard let rgb = m.processor.sample(at: point) else { return false }
            // Too blue → the camera assumed too cool a light → raise the setting (warmer), and vice versa.
            if rgb.z > rgb.x { lo = mid } else { hi = mid }
        }
        c.setValue("pu.wbTemp", Int(((lo + hi) / 2).rounded()))
        return true
    }

    // MARK: Privacy

    /// Uses the camera's own privacy control (if it has one), so every app sees it.
    func setPrivacy(_ on: Bool) -> Bool {
        guard let c = controls, let st = c.state("ct.privacy"), st.canSet else { return false }
        c.setValue("ct.privacy", on ? 1 : 0)
        return true
    }
}
