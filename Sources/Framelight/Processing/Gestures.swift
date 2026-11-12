import Foundation

/// The hand joints gesture recognition needs (normalized image coordinates, bottom-left origin).
struct HandPose {
    struct Point { var x: Double; var y: Double; var confidence: Double }
    var wrist: Point?
    var thumbTip: Point?, thumbMP: Point?
    var indexTip: Point?, indexPIP: Point?
    var middleTip: Point?, middlePIP: Point?
    var ringTip: Point?, ringPIP: Point?
    var littleTip: Point?, littlePIP: Point?
}

enum HandGesture: String {
    case openPalm      // ✋ toggles auto framing (like Insta360 / OBSBOT)
    case victory       // ✌️ toggles background blur
}

enum GestureClassifier {
    private static func dist(_ a: HandPose.Point, _ b: HandPose.Point) -> Double { hypot(a.x - b.x, a.y - b.y) }

    /// nil = unknown (missing joints), true = extended, false = folded.
    private static func extended(tip: HandPose.Point?, pip: HandPose.Point?, wrist: HandPose.Point?) -> Bool? {
        guard let tip, let pip, let wrist, tip.confidence > 0.3, pip.confidence > 0.3, wrist.confidence > 0.3 else { return nil }
        let t = dist(tip, wrist), p = dist(pip, wrist)
        if t > p * 1.18 { return true }
        if t < p * 1.02 { return false }
        return nil
    }

    static func classify(_ h: HandPose) -> HandGesture? {
        guard let index = extended(tip: h.indexTip, pip: h.indexPIP, wrist: h.wrist),
              let middle = extended(tip: h.middleTip, pip: h.middlePIP, wrist: h.wrist),
              let ring = extended(tip: h.ringTip, pip: h.ringPIP, wrist: h.wrist),
              let little = extended(tip: h.littleTip, pip: h.littlePIP, wrist: h.wrist) else { return nil }
        let thumb = extended(tip: h.thumbTip, pip: h.thumbMP, wrist: h.wrist)

        if index && middle && ring && little && thumb == true {
            return .openPalm
        }
        if index && middle && !ring && !little {
            // Index and middle fingers apart (not a "two fingers together" point).
            if let a = h.indexTip, let b = h.middleTip, let w = h.wrist, dist(a, b) > 0.18 * dist(a, w) {
                return .victory
            }
        }
        return nil
    }
}

/// Fires a gesture once it has been held steadily, then waits for a cooldown and a release.
struct GestureTracker {
    var holdTime = 0.8
    var cooldown = 2.0

    private var candidate: HandGesture?
    private var since: Double = 0
    private var lastFired: Double = -.infinity
    private var needsRelease = false

    mutating func update(_ gesture: HandGesture?, now: Double) -> HandGesture? {
        guard let gesture else {
            candidate = nil
            needsRelease = false
            return nil
        }
        if gesture != candidate {
            candidate = gesture
            since = now
            needsRelease = false
            return nil
        }
        guard !needsRelease, now - since >= holdTime, now - lastFired >= cooldown else { return nil }
        lastFired = now
        needsRelease = true
        return gesture
    }
}
