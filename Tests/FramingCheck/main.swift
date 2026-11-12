// Simulates auto framing with realistic detections from a 4K webcam at desk distance.
//   swiftc -swift-version 5 Sources/Framelight/Processing/{AutoFramer,ProcessingSettings,GradeEngine,ColorMath}.swift \
//     Tests/FramingCheck/main.swift -o framingcheck && ./framingcheck
import Foundation

var failures = 0
func expect(_ cond: Bool, _ msg: String, line: Int = #line) {
    print((cond ? "  ok   " : "  FAIL ") + msg)
    if !cond { failures += 1 }
}

let source = CGSize(width: 3840, height: 2160)
let aspect: CGFloat = 16.0 / 9.0
let full = AutoFramer.fullCrop(source: source, aspect: aspect)

/// Typical seated person ~60 cm from a wide 4K webcam (normalized, bottom-left origin).
func person(atX x: CGFloat) -> (face: CGRect, body: CGRect) {
    (CGRect(x: x - 0.06, y: 0.50, width: 0.12, height: 0.21),
     CGRect(x: x - 0.26, y: 0.0, width: 0.52, height: 0.95))
}

/// Runs the framer at 30 fps with a new detection every 3rd frame (≈ 10 Hz like the app).
var trace: [CGRect] = []

@discardableResult
func run(_ framer: AutoFramer, seconds: Double, start: Double, settings: ProcessingSettings,
         detect: (Double) -> FramingDetection) -> (crop: CGRect, end: Double) {
    var crop = full
    var t = start
    var frame = 0
    var lastDetection: FramingDetection?
    while t < start + seconds {
        if frame % 3 == 0 { lastDetection = detect(t) }
        crop = framer.crop(source: source, aspect: aspect, settings: settings, detection: lastDetection, now: t)
        trace.append(crop)
        // Invariants on every frame.
        if crop.minX < full.minX - 0.5 || crop.maxX > full.maxX + 0.5 || crop.minY < -0.5 || crop.maxY > full.maxY + 0.5 {
            failures += 1; print("  FAIL crop left the sensor at t=\(t): \(crop)")
        }
        if abs(crop.width / crop.height - aspect) > 0.01 {
            failures += 1; print("  FAIL crop aspect \(crop.width / crop.height) at t=\(t)")
        }
        t += 1.0 / 30.0
        frame += 1
    }
    return (crop, t)
}

func zoom(_ c: CGRect) -> Double { Double(full.height / c.height) }
func contains(_ crop: CGRect, _ normalized: CGRect) -> Bool {
    let r = CGRect(x: normalized.minX * source.width, y: normalized.minY * source.height,
                   width: normalized.width * source.width, height: normalized.height * source.height)
    return r.minX >= crop.minX - 1 && r.maxX <= crop.maxX + 1 && r.minY >= crop.minY - 1 && r.maxY <= crop.maxY + 1
}

for subject in FramingSubject.allCases {
    print("Subject: \(subject.rawValue)")
    var s = ProcessingSettings()
    s.autoFraming = true
    s.framingSubject = subject
    let framer = AutoFramer()
    let p = person(atX: 0.5)

    // 1. Seated person in the middle: the shot must actually zoom in and keep the face.
    let (c1, t1) = run(framer, seconds: 3, start: 100, settings: s) { t in
        FramingDetection(faces: [p.face], bodies: [p.body], time: t)
    }
    let minZoom: Double = subject == .face ? 1.8 : (subject == .upperBody ? 1.25 : 1.2)
    expect(zoom(c1) >= minZoom, String(format: "zooms in on a centred person: %.2f× (want ≥ %.2f×)", zoom(c1), minZoom))
    expect(zoom(c1) <= s.maxZoom + 0.01, String(format: "respects max zoom %.1f×", s.maxZoom))
    expect(contains(c1, p.face), "face stays fully in shot")
    let faceCenterY = (p.face.midY * source.height - c1.minY) / c1.height
    expect(faceCenterY > 0.5 && faceCenterY < 0.8, String(format: "face sits in the upper part of the shot (%.2f)", faceCenterY))

    // 2. Person moves to the left third: the crop follows.
    let moved = person(atX: 0.28)
    let (c2, t2) = run(framer, seconds: 3, start: t1, settings: s) { t in
        FramingDetection(faces: [moved.face], bodies: [moved.body], time: t)
    }
    let faceX = moved.face.midX * source.width
    expect(contains(c2, moved.face), "face still in shot after moving left")
    expect(c2.midX < c1.midX - 200, String(format: "crop followed left (%.0f → %.0f px)", c1.midX, c2.midX))
    expect(abs(c2.midX - faceX) < c2.width * 0.2 || c2.minX <= full.minX + 1,
           String(format: "subject roughly centred (offset %.0f px of %.0f)", c2.midX - faceX, c2.width))

    // 3. Small jitter must not move the shot (dead zone).
    let before = framer.target
    run(framer, seconds: 1, start: t2, settings: s) { t in
        let jitter = CGFloat(sin(t * 17)) * 0.004
        let j = person(atX: 0.28 + jitter)
        return FramingDetection(faces: [j.face], bodies: [j.body], time: t)
    }
    expect(framer.target == before, "ignores small jitter")

    // 4. Nobody in view: ease back to the wide shot.
    let (c4, _) = run(framer, seconds: 4.5, start: t2 + 1, settings: s) { t in
        FramingDetection(faces: [], bodies: [], time: t)
    }
    expect(zoom(c4) < 1.05, String(format: "returns to wide shot when empty: %.2f×", zoom(c4)))
}

print("Body only (face turned away)")
do {
    var s = ProcessingSettings(); s.autoFraming = true
    let p = person(atX: 0.6)
    let (c, _) = run(AutoFramer(), seconds: 3, start: 0, settings: s) { t in
        FramingDetection(faces: [], bodies: [p.body], time: t)
    }
    expect(zoom(c) > 1.15, String(format: "still frames from the body box: %.2f×", zoom(c)))
}

print("Two people")
do {
    var s = ProcessingSettings(); s.autoFraming = true; s.framingSubject = .group
    let a = person(atX: 0.3), b = person(atX: 0.72)
    let (c, _) = run(AutoFramer(), seconds: 3, start: 0, settings: s) { t in
        FramingDetection(faces: [a.face, b.face], bodies: [a.body, b.body], time: t)
    }
    expect(contains(c, a.face) && contains(c, b.face), "both faces in shot")
}

print("Tightness")
do {
    var tight = ProcessingSettings(); tight.autoFraming = true; tight.framingTightness = 1
    var loose = tight; loose.framingTightness = 0
    let p = person(atX: 0.5)
    let ct = run(AutoFramer(), seconds: 3, start: 0, settings: tight) { FramingDetection(faces: [p.face], bodies: [p.body], time: $0) }.crop
    let cl = run(AutoFramer(), seconds: 3, start: 0, settings: loose) { FramingDetection(faces: [p.face], bodies: [p.body], time: $0) }.crop
    expect(zoom(ct) > zoom(cl) + 0.2, String(format: "tight %.2f× > loose %.2f×", zoom(ct), zoom(cl)))
}

/// Largest frame-to-frame change in velocity (px/frame²) of the crop centre and height.
func jerkiness(_ t: [CGRect]) -> Double {
    guard t.count > 2 else { return 0 }
    var worst = 0.0
    for i in 2..<t.count {
        for f in [{ (r: CGRect) in r.midX }, { (r: CGRect) in r.midY }, { (r: CGRect) in r.height }] {
            let a = Double(f(t[i]) - 2 * f(t[i - 1]) + f(t[i - 2]))
            worst = max(worst, abs(a))
        }
    }
    return worst
}

/// Deterministic pseudo-random noise like Vision's box-to-box wobble.
var seed: UInt64 = 42
func noise(_ amp: Double) -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat((Double(seed >> 33) / Double(1 << 31) - 0.5) * 2 * amp)
}

print("Smoothness")
do {
    var s = ProcessingSettings(); s.autoFraming = true
    let framer = AutoFramer()
    // Noisy detections of someone sitting still (±1.5% box wobble, like real Vision output).
    trace = []
    let (_, t1) = run(framer, seconds: 2, start: 0, settings: s) { t in
        let p = person(atX: 0.5)
        let f = p.face.offsetBy(dx: noise(0.015), dy: noise(0.015)).insetBy(dx: noise(0.006), dy: noise(0.006))
        return FramingDetection(faces: [f], bodies: [p.body], time: t)
    }
    trace = []
    run(framer, seconds: 4, start: t1, settings: s) { t in
        let p = person(atX: 0.5)
        let f = p.face.offsetBy(dx: noise(0.015), dy: noise(0.015)).insetBy(dx: noise(0.006), dy: noise(0.006))
        return FramingDetection(faces: [f], bodies: [p.body], time: t)
    }
    let xs = trace.map { Double($0.midX) }
    let wander = (xs.max()! - xs.min()!)
    expect(wander < 40, String(format: "holds still while you sit still despite noisy boxes (wander %.1f px of 3840)", wander))

    // Walking across the frame: motion must be smooth (no sudden speed changes).
    trace = []
    run(framer, seconds: 5, start: t1 + 4, settings: s) { t in
        let x = 0.5 - 0.25 * min(1, (t - (t1 + 4)) / 2.0)          // walk left over 2 s
        let p = person(atX: CGFloat(x))
        let f = p.face.offsetBy(dx: noise(0.01), dy: noise(0.01))
        return FramingDetection(faces: [f], bodies: [p.body], time: t)
    }
    let j = jerkiness(trace)
    expect(j < 3.0, String(format: "smooth follow: max speed change %.2f px/frame² (want < 3)", j))
    var maxStep = 0.0
    for i in 1..<trace.count { maxStep = max(maxStep, Double(abs(trace[i].midX - trace[i - 1].midX))) }
    expect(maxStep < 45, String(format: "no jumps: max %.1f px per frame at 4K", maxStep))
}

print("Kreo Owl 4K Pro geometry (77° lens; face = 0.38 / 0.29 / 0.23 of frame height at 0.6 / 0.8 / 1.0 m)")
do {
    func kreoPerson(faceHeight fh: CGFloat, atX x: CGFloat) -> (face: CGRect, body: CGRect) {
        let fw = fh * 9 / 16 * 0.95                   // face box in normalized units (frame is 16:9)
        return (CGRect(x: x - fw / 2, y: 0.42, width: fw, height: fh),
                CGRect(x: x - fw * 2.2, y: 0, width: fw * 4.4, height: min(1, 0.42 + fh * 1.1)))
    }
    for (dist, fh) in [(0.6, 0.38), (0.8, 0.29), (1.0, 0.23)] as [(Double, CGFloat)] {
        var s = ProcessingSettings(); s.autoFraming = true          // defaults: Face, tightness 0.65
        let framer = AutoFramer()
        let p = kreoPerson(faceHeight: fh, atX: 0.5)
        let (c, t) = run(framer, seconds: 3, start: 0, settings: s) { FramingDetection(faces: [p.face], bodies: [p.body], time: $0) }
        expect(contains(c, p.face), String(format: "%.1f m: face fully in shot", dist))
        let want = dist >= 0.8 ? 1.35 : 1.1
        expect(zoom(c) >= want, String(format: "%.1f m: default framing zooms %.2f× (want ≥ %.2f×)", dist, zoom(c), want))
        let moved = kreoPerson(faceHeight: fh, atX: 0.3)
        let (c2, _) = run(framer, seconds: 3, start: t, settings: s) { FramingDetection(faces: [moved.face], bodies: [moved.body], time: $0) }
        expect(c2.midX < c.midX - 100 && contains(c2, moved.face),
               String(format: "%.1f m: follows a lean to the left (%.0f → %.0f px)", dist, c.midX, c2.midX))
    }
    var ub = ProcessingSettings(); ub.autoFraming = true; ub.framingSubject = .upperBody; ub.framingTightness = 0.5
    let far = kreoPerson(faceHeight: 0.23, atX: 0.5)
    let cu = run(AutoFramer(), seconds: 3, start: 0, settings: ub) { FramingDetection(faces: [far.face], bodies: [far.body], time: $0) }.crop
    expect(zoom(cu) > 1.15, String(format: "Upper Body works from 1 m back: %.2f×", zoom(cu)))
}

print(failures == 0 ? "ALL FRAMING CHECKS PASSED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
