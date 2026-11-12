// Checks the natural colour engine for the properties that separate a natural grade from a "filter".
//   swiftc -O -swift-version 5 Sources/Framelight/Processing/ColorMath.swift \
//     Sources/Framelight/Processing/GradeEngine.swift Tests/ColorCheck/main.swift -o colorcheck && ./colorcheck
import Foundation

var failures = 0
func expect(_ cond: Bool, _ msg: String) {
    print((cond ? "  ok   " : "  FAIL ") + msg)
    if !cond { failures += 1 }
}
func srgb(_ r: Int, _ g: Int, _ b: Int) -> (Double, Double, Double) { (Double(r) / 255, Double(g) / 255, Double(b) / 255) }
func lch(_ c: (Double, Double, Double)) -> (L: Double, C: Double, h: Double) {
    let lab = ColorMath.linearToOKLab(ColorMath.srgbToLinear(c.0), ColorMath.srgbToLinear(c.1), ColorMath.srgbToLinear(c.2))
    return (lab.L, hypot(lab.a, lab.b), atan2(lab.b, lab.a) * 180 / .pi)
}
func graded(_ g: Grade, _ c: (Double, Double, Double)) -> (Double, Double, Double) { GradeEngine.apply(g, r: c.0, g: c.1, b: c.2) }

let skinSamples: [(String, (Double, Double, Double))] = [
    ("Macbeth light skin", srgb(194, 150, 130)), ("Macbeth dark skin", srgb(115, 82, 68)),
    ("Monk 3", srgb(0xf7, 0xea, 0xd0)), ("Monk 5", srgb(0xd7, 0xbd, 0x96)), ("Monk 6", srgb(0xa0, 0x7e, 0x56)),
    ("Monk 7", srgb(0x82, 0x5c, 0x43)), ("Monk 8", srgb(0x60, 0x41, 0x34)), ("Monk 9", srgb(0x3a, 0x31, 0x2a)),
]

print("Neutral grade is an identity")
do {
    var worst = 0.0
    for r in stride(from: 0.0, through: 1.0, by: 0.1) { for g in stride(from: 0.0, through: 1.0, by: 0.1) { for b in stride(from: 0.0, through: 1.0, by: 0.1) {
        let o = GradeEngine.apply(.neutral, r: r, g: g, b: b)
        worst = max(worst, abs(o.0 - r), abs(o.1 - g), abs(o.2 - b))
    } } }
    expect(worst < 0.002, String(format: "max error %.5f", worst))
}

print("Every look: neutral greys, sane black and white, monotonic tone")
for look in LookStyle.allCases {
    let g = look.base
    var grayTint = 0.0
    for v in stride(from: 0.02, through: 0.98, by: 0.04) {
        let o = graded(g, (v, v, v))
        grayTint = max(grayTint, abs(o.0 - o.1), abs(o.1 - o.2), abs(o.0 - o.2))
    }
    let splitToned = g.shadowA != 0 || g.highlightA != 0
    expect(grayTint < (splitToned ? 0.035 : 0.004), String(format: "%@: grey tint %.4f", look.displayName, grayTint))
    let black = graded(g, (0, 0, 0)), white = graded(g, (1, 1, 1))
    expect(max(black.0, black.1, black.2) < 0.12, String(format: "%@: black stays dark (%.3f)", look.displayName, max(black.0, black.1, black.2)))
    expect(min(white.0, white.1, white.2) > 0.9, String(format: "%@: white stays bright (%.3f)", look.displayName, min(white.0, white.1, white.2)))
    var prev = -1.0, monotonic = true
    for i in 0...200 { let y = GradeEngine.tone(Double(i) / 200, g); if y < prev - 1e-9 { monotonic = false }; prev = y }
    expect(monotonic, "\(look.displayName): tone curve never reverses")
}

print("Skin stays true in every look (hue drift ≤ 6°, lightness drift ≤ 0.06)")
for look in LookStyle.allCases where look != .mono {
    var worstHue = 0.0, worstL = 0.0
    for (_, c) in skinSamples {
        let a = lch(c), b = lch(graded(look.base, c))
        if a.C > 0.02 { worstHue = max(worstHue, abs(ColorMath.angleDelta(b.h, a.h))) }
        worstL = max(worstL, abs(b.L - a.L))
    }
    expect(worstHue <= 6 && worstL <= 0.06, String(format: "%@: hue drift %.1f°, lightness drift %.3f", look.displayName, worstHue, worstL))
}

print("Saturation keeps hue and protects skin")
do {
    var g = Grade(); g.saturation = 1.35
    var worstHue = 0.0
    for c in [srgb(60, 90, 170), srgb(70, 140, 80), srgb(170, 60, 70), srgb(120, 100, 160), srgb(90, 150, 160)] {
        let a = lch(c), b = lch(graded(g, c))
        worstHue = max(worstHue, abs(ColorMath.angleDelta(b.h, a.h)))
    }
    expect(worstHue < 1.5, String(format: "hue held within %.2f° on non-skin colours", worstHue))
    let skin = srgb(194, 150, 130), blue = srgb(60, 90, 170)
    let skinGain = lch(graded(g, skin)).C / lch(skin).C
    let blueGain = lch(graded(g, blue)).C / lch(blue).C
    expect(skinGain < 1.15 && blueGain > 1.25, String(format: "skin chroma ×%.2f vs blue ×%.2f", skinGain, blueGain))
}

print("Vibrance favours muted colours")
do {
    var g = Grade(); g.vibrance = 0.5
    let muted = srgb(120, 130, 150), vivid = srgb(30, 80, 220)
    let m = lch(graded(g, muted)).C / lch(muted).C, v = lch(graded(g, vivid)).C / lch(vivid).C
    expect(m > v + 0.1, String(format: "muted ×%.2f, vivid ×%.2f", m, v))
}

print("Contrast pivots on mid-grey")
do {
    var g = Grade(); g.contrast = 1.25
    expect(abs(GradeEngine.tone(GradeEngine.pivot, g) - GradeEngine.pivot) < 1e-6, "mid-grey unchanged")
    expect(GradeEngine.tone(0.3, g) < 0.3 && GradeEngine.tone(0.85, g) > 0.85, "shadows deeper, highlights brighter")
}

print("Monochrome is truly neutral")
do {
    let o = graded(LookStyle.mono.base, srgb(200, 120, 90))
    expect(abs(o.0 - o.1) < 1e-6 && abs(o.1 - o.2) < 1e-6, "no colour left")
}

print("Auto light: face exposure band")
do {
    expect(GradeEngine.exposureCorrection(faceLuminance: 0.2) == 0, "well-exposed face untouched")
    expect(GradeEngine.exposureCorrection(faceLuminance: ColorMath.srgbToLinear(0.4)) == 0, "deep skin tone at 40 IRE untouched")
    let dark = GradeEngine.exposureCorrection(faceLuminance: 0.04)
    expect(dark > 0.9 && dark <= 1.3, String(format: "underexposed face lifted %.2f EV (capped)", dark))
    let bright = GradeEngine.exposureCorrection(faceLuminance: 0.8)
    expect(bright < -0.5 && bright >= -1.0, String(format: "overexposed face lowered %.2f EV", bright))
}

print("Natural skin tones: white balance from the face")
do {
    for (name, c) in skinSamples {
        let lin = (ColorMath.srgbToLinear(c.0), ColorMath.srgbToLinear(c.1), ColorMath.srgbToLinear(c.2))
        let gains = GradeEngine.skinBalanceGains(faceLinear: lin.0, lin.1, lin.2)
        let untouched = abs(gains.0 - 1) < 1e-9 && abs(gains.1 - 1) < 1e-9 && abs(gains.2 - 1) < 1e-9
        expect(untouched, "\(name): left alone")
    }
    // A face under a green-ish fluorescent cast.
    let face = (ColorMath.srgbToLinear(0.66), ColorMath.srgbToLinear(0.62), ColorMath.srgbToLinear(0.45))
    let before = lch((0.66, 0.62, 0.45))
    let gains = GradeEngine.skinBalanceGains(faceLinear: face.0, face.1, face.2)
    let fixedLin = (face.0 * gains.0, face.1 * gains.1, face.2 * gains.2)
    let after = ColorMath.linearToOKLab(fixedLin.0, fixedLin.1, fixedLin.2)
    let afterHue = atan2(after.b, after.a) * 180 / .pi
    expect(before.h > 88 && afterHue < before.h - 5, String(format: "green cast corrected: hue %.1f° → %.1f°", before.h, afterHue))
    let y0 = ColorMath.luminance(face.0, face.1, face.2), y1 = ColorMath.luminance(fixedLin.0, fixedLin.1, fixedLin.2)
    expect(abs(y1 - y0) / y0 < 0.03, "brightness of the face preserved")
    let grey = GradeEngine.skinBalanceGains(faceLinear: 0.2, 0.2, 0.2)
    expect(grey == (1, 1, 1), "grey reading ignored")
}

print("LUT")
do {
    let start = Date()
    var finite = true
    for look in LookStyle.allCases {
        let lut = GradeEngine.buildLUT(look.base)
        if lut.count != 33 * 33 * 33 * 4 || lut.contains(where: { !$0.isFinite || $0 < -0.001 || $0 > 1.001 }) { finite = false }
    }
    expect(finite, "every look builds a valid 33³ LUT")
    print(String(format: "  info %.0f ms per LUT (debug-free -O build)", Date().timeIntervalSince(start) * 1000 / Double(LookStyle.allCases.count)))
}

print("Custom LUTs (.cube)")
do {
    var identity = "TITLE \"Identity\"\n# comment\nLUT_3D_SIZE 2\n"
    for b in 0...1 { for g in 0...1 { for r in 0...1 { identity += "\(r) \(g) \(b)\n" } } }
    let lut = try? CubeParser.parse(identity, name: "id")
    expect(lut?.dimension == 2 && lut?.data.count == 32, "parses a 2³ cube")
    expect(lut.map { $0.data[4] == 1 && $0.data[5] == 0 && $0.data[6] == 0 } ?? false, "red varies fastest (matches Core Image)")
    expect((try? CubeParser.parse("LUT_1D_SIZE 1024\n0 0 0", name: "x")) == nil, "rejects 1D LUTs")
    expect((try? CubeParser.parse("LUT_3D_SIZE 2\n0 0 0\n1 1 1", name: "x")) == nil, "rejects truncated data")
    expect((try? CubeParser.parse(identity.replacingOccurrences(of: "LUT_3D_SIZE 2", with: "LUT_3D_SIZE 2\nDOMAIN_MAX 4 4 4"), name: "x")) == nil,
           "rejects log-domain LUTs")
}

print("Saved settings survive app updates")
do {
    // A settings file from an older version: a removed look ("cinematic"), a renamed key, no new keys.
    let old: [String: Any] = ["autoFraming": true, "look": "cinematic", "warmth": 20.0, "backgroundBlur": 0.4,
                              "mirror": true, "framingSubject": "Face"]
    let s = ProcessingSettings.tolerant(fromObject: old)
    expect(s != nil, "old settings still load")
    expect(s?.autoFraming == true && s?.warmth == 20 && s?.mirror == true && s?.framingSubject == .face, "valid values kept")
    expect(s?.look == .natural, "unknown look falls back to Natural")
    expect(s?.meteringMode == .face && s?.denoise == 0.35, "new settings get defaults")
}

print("Output shapes")
do {
    var s = ProcessingSettings()
    s.outputResolution = .hd1080
    s.outputAspect = .widescreen; expect(s.outputSize == CGSize(width: 1920, height: 1080), "16:9 → 1920×1080")
    s.outputAspect = .vertical; expect(s.outputSize == CGSize(width: 1080, height: 1920), "9:16 → 1080×1920")
    s.outputAspect = .square; expect(s.outputSize == CGSize(width: 1080, height: 1080), "1:1 → 1080×1080")
    s.outputAspect = .classic; expect(s.outputSize == CGSize(width: 1440, height: 1080), "4:3 → 1440×1080")
}

print("Gestures")
do {
    typealias P = HandPose.Point
    func hand(extended fingers: Set<String>, thumb: Bool) -> HandPose {
        // Wrist at the bottom, fingers pointing up; an extended tip is far above its PIP joint.
        let w = P(x: 0.5, y: 0.2, confidence: 0.9)
        func finger(_ name: String, x: Double) -> (P, P) {
            let pip = P(x: x, y: 0.42, confidence: 0.9)
            let tip = fingers.contains(name) ? P(x: x + (name == "middle" ? 0.03 : name == "index" ? -0.03 : 0), y: 0.6, confidence: 0.9)
                                             : P(x: x, y: 0.34, confidence: 0.9)
            return (tip, pip)
        }
        let i = finger("index", x: 0.44), m = finger("middle", x: 0.5), r = finger("ring", x: 0.56), l = finger("little", x: 0.61)
        let thumbMP = P(x: 0.38, y: 0.3, confidence: 0.9)
        let thumbTip = thumb ? P(x: 0.28, y: 0.42, confidence: 0.9) : P(x: 0.42, y: 0.28, confidence: 0.9)
        return HandPose(wrist: w, thumbTip: thumbTip, thumbMP: thumbMP, indexTip: i.0, indexPIP: i.1, middleTip: m.0, middlePIP: m.1,
                        ringTip: r.0, ringPIP: r.1, littleTip: l.0, littlePIP: l.1)
    }
    expect(GestureClassifier.classify(hand(extended: ["index", "middle", "ring", "little"], thumb: true)) == .openPalm, "open palm")
    expect(GestureClassifier.classify(hand(extended: ["index", "middle"], thumb: false)) == .victory, "peace sign")
    expect(GestureClassifier.classify(hand(extended: [], thumb: false)) == nil, "fist is ignored")
    expect(GestureClassifier.classify(hand(extended: ["index"], thumb: false)) == nil, "pointing is ignored")

    var tracker = GestureTracker()
    var fired: [HandGesture] = []
    for i in 0..<30 { if let g = tracker.update(.openPalm, now: Double(i) * 0.1) { fired.append(g) } }   // held 3 s
    expect(fired == [.openPalm], "fires once after holding, not repeatedly")
    var quick = GestureTracker()
    var quickFired = false
    for i in 0..<5 { if quick.update(.openPalm, now: Double(i) * 0.1) != nil { quickFired = true } }      // 0.4 s wave
    expect(!quickFired, "a brief wave doesn't trigger")
}

print("Scene metering")
do {
    expect(GradeEngine.sceneExposureCorrection(meanLuminance: 0.18) == 0, "18% grey scene untouched")
    expect(GradeEngine.sceneExposureCorrection(meanLuminance: 0.03) > 0.5, "dark scene lifted")
}

print(failures == 0 ? "ALL COLOR CHECKS PASSED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
