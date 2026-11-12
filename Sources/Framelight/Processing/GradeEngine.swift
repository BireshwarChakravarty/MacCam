import Foundation

/// Looks are parameter sets for one natural grading model, not stacked effects.
/// Each stays close to what a well-exposed camera would produce.
enum LookStyle: String, Codable, CaseIterable, Identifiable {
    case natural
    case daylight
    case warmRoom
    case softFilm
    case studioCrisp
    case moody
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .natural: return "Natural"
        case .daylight: return "Bright & Clean"
        case .warmRoom: return "Warm Room"
        case .softFilm: return "Soft Film"
        case .studioCrisp: return "Studio Crisp"
        case .moody: return "Moody"
        case .mono: return "Monochrome"
        }
    }

    var summary: String {
        switch self {
        case .natural: return "True to life with gentle highlight roll-off"
        case .daylight: return "A touch brighter and more open"
        case .warmRoom: return "Cosy warmth for evening lamps"
        case .softFilm: return "Lower contrast, film-like highlights"
        case .studioCrisp: return "Clean contrast for streaming"
        case .moody: return "Muted colour, deeper shadows"
        case .mono: return "Natural black and white"
        }
    }

    /// The look at full strength.
    var base: Grade {
        var g = Grade()
        switch self {
        case .natural:
            g.shoulder = 0.35; g.vibrance = 0.06; g.chromaRolloff = 0.5
        case .daylight:
            g.contrast = 1.04; g.vibrance = 0.12; g.shoulder = 0.4; g.chromaRolloff = 0.6
            g.midLift = 0.02
        case .warmRoom:
            g.saturation = 0.97; g.shoulder = 0.45; g.chromaRolloff = 0.6; g.blackLift = 0.008
            g.highlightA = 0.002; g.highlightB = 0.008; g.shadowA = 0.001; g.shadowB = 0.004
        case .softFilm:
            g.contrast = 0.93; g.blackLift = 0.025; g.shoulder = 0.75; g.saturation = 0.9; g.chromaRolloff = 0.85
            g.greenShift = 8; g.highlightA = 0.002; g.highlightB = 0.008; g.shadowA = -0.003; g.shadowB = -0.006
        case .studioCrisp:
            g.contrast = 1.1; g.vibrance = 0.14; g.shoulder = 0.35; g.chromaRolloff = 0.5
        case .moody:
            g.contrast = 1.08; g.saturation = 0.8; g.shoulder = 0.55; g.chromaRolloff = 0.9; g.blackLift = 0.01
            g.shadowA = -0.004; g.shadowB = -0.012; g.highlightA = 0.002; g.highlightB = 0.006
        case .mono:
            g.mono = true; g.contrast = 1.06; g.shoulder = 0.45
        }
        return g
    }
}

/// Parameters of the natural grading model. The neutral value of every field is an identity transform.
struct Grade: Hashable {
    var contrast = 1.0          // S-curve on perceptual lightness around mid-grey
    var saturation = 1.0        // chroma scale, damped on skin
    var vibrance = 0.0          // boosts muted colours more than vivid ones, skips skin
    var shoulder = 0.0          // filmic highlight roll-off
    var blackLift = 0.0         // raised black point (film fade)
    var midLift = 0.0           // gentle brightening of mid-tones
    var chromaRolloff = 0.0     // colour fades out near black and white, as on film
    var greenShift = 0.0        // degrees: rotates foliage greens toward teal
    var shadowA = 0.0, shadowB = 0.0         // OKLab tint in shadows
    var highlightA = 0.0, highlightB = 0.0   // OKLab tint in highlights
    var mono = false
    var skinProtect = 0.75      // how much saturation changes are held back on skin

    static let neutral = Grade()

    /// Blends from neutral toward `self` (look intensity).
    func scaled(_ t: Double) -> Grade {
        let n = Grade.neutral
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        var g = self
        g.contrast = mix(n.contrast, contrast)
        g.saturation = mix(n.saturation, saturation)
        g.vibrance = mix(n.vibrance, vibrance)
        g.shoulder = mix(n.shoulder, shoulder)
        g.blackLift = mix(n.blackLift, blackLift)
        g.midLift = mix(n.midLift, midLift)
        g.chromaRolloff = mix(n.chromaRolloff, chromaRolloff)
        g.greenShift = mix(n.greenShift, greenShift)
        g.shadowA = mix(0, shadowA); g.shadowB = mix(0, shadowB)
        g.highlightA = mix(0, highlightA); g.highlightB = mix(0, highlightB)
        g.mono = mono && t >= 0.5
        return g
    }

    /// Applies the user's own adjustments on top of a look.
    func adjusted(contrast c: Double, saturation s: Double, vibrance v: Double) -> Grade {
        var g = self
        g.contrast *= c
        g.saturation *= s
        g.vibrance = min(1, max(-1, g.vibrance + v))
        return g
    }

    /// Rounded copy used as a cache key (avoids rebuilding for imperceptible slider jitter).
    var key: Grade {
        func r(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        var g = self
        g.contrast = r(contrast); g.saturation = r(saturation); g.vibrance = r(vibrance)
        g.shoulder = r(shoulder); g.blackLift = r(blackLift); g.midLift = r(midLift)
        g.chromaRolloff = r(chromaRolloff); g.greenShift = r(greenShift)
        g.shadowA = r(shadowA); g.shadowB = r(shadowB); g.highlightA = r(highlightA); g.highlightB = r(highlightB)
        return g
    }

    var isNeutral: Bool { key == Grade.neutral.key }
}

enum GradeEngine {
    /// OKLab lightness of 18% grey: the contrast pivot.
    static let pivot = 0.5663

    /// OKLab hue range (degrees) where human skin falls, across the Monk skin tone scale
    /// and calibrated photographed skin (≈ 44°–85°). Centre and half-width of the protection window.
    static let skinHueCenter = 62.0
    static let skinHuePlateau = 20.0      // full protection within ±20° of the centre
    static let skinHueHalfWidth = 42.0    // fades to none at ±42°

    // MARK: Tone

    static func contrastCurve(_ x: Double, _ k: Double) -> Double {
        guard abs(k - 1) > 1e-6, x > 0, x < 1 else { return min(max(x, 0), 1) }
        let g = log(0.5) / log(pivot)
        let t = pow(x, g)
        let tk = pow(t, k), uk = pow(1 - t, k)
        let s = tk / (tk + uk)
        return pow(s, 1 / g)
    }

    static func tone(_ L: Double, _ g: Grade) -> Double {
        var y = contrastCurve(L, g.contrast)
        if g.midLift != 0 {
            y += g.midLift * 4 * y * (1 - y)                   // lifts mid-tones, keeps black and white
        }
        if g.shoulder > 0 {
            let s = smoothstepLocal(0.72, 1.0, y)
            y -= g.shoulder * 0.07 * s * s                      // roll highlights off instead of clipping
        }
        if g.blackLift > 0 {
            y = g.blackLift + y * (1 - g.blackLift)
        }
        return min(max(y, 0), 1)
    }

    private static func smoothstepLocal(_ a: Double, _ b: Double, _ x: Double) -> Double {
        ColorMath.smoothstep(a, b, x)
    }

    // MARK: Skin

    /// 0…1: how much an OKLab colour looks like skin (hue window, plausible chroma).
    static func skinWeight(hue: Double, chroma: Double) -> Double {
        let d = abs(ColorMath.angleDelta(hue, skinHueCenter))
        guard d < skinHueHalfWidth else { return 0 }
        let fall = max(0, d - skinHuePlateau) / (skinHueHalfWidth - skinHuePlateau)
        let hueW = 0.5 * (1 + cos(Double.pi * fall))
        let chromaW = ColorMath.smoothstep(0.006, 0.02, chroma) * (1 - ColorMath.smoothstep(0.13, 0.19, chroma))
        return hueW * chromaW
    }

    // MARK: Per-colour transform

    /// Grades one sRGB-encoded colour (0…1). This is what gets baked into the 3D LUT.
    static func apply(_ g: Grade, r: Double, g gr: Double, b: Double) -> (Double, Double, Double) {
        let lr = ColorMath.srgbToLinear(r), lg = ColorMath.srgbToLinear(gr), lb = ColorMath.srgbToLinear(b)
        let lab = ColorMath.linearToOKLab(lr, lg, lb)

        if g.mono {
            // Natural B&W: slightly red-weighted luminance flatters skin (like a light yellow filter).
            let y = 0.30 * lr + 0.59 * lg + 0.11 * lb
            let L = tone(cbrt(max(y, 0)), g)
            let v = ColorMath.linearToSRGB(L * L * L)
            return (v, v, v)
        }

        let L0 = lab.L
        let L1 = tone(L0, g)
        let C0 = hypot(lab.a, lab.b)
        var h = atan2(lab.b, lab.a) * 180 / .pi

        let skin = skinWeight(hue: h, chroma: C0)
        var C = C0

        // Saturation (skin-damped) and vibrance (muted colours first, skin mostly skipped).
        C *= 1 + (g.saturation - 1) * (1 - g.skinProtect * skin)
        if g.vibrance != 0 {
            let muted = 1 - ColorMath.smoothstep(0.02, 0.17, C0)
            C *= max(0, 1 + g.vibrance * muted * (1 - 0.85 * skin))
        }

        // Keep perceived saturation steady when contrast moves lightness (Hunt effect).
        if L0 > 1e-4, abs(L1 - L0) > 1e-6 {
            C *= min(1.35, max(0.65, pow(L1 / L0, 0.5)))
        }

        // Film-like fade of colour near black and white.
        if g.chromaRolloff > 0 {
            let fade = 0.65 * ColorMath.smoothstep(0.86, 1.0, L1) + 0.5 * (1 - ColorMath.smoothstep(0.02, 0.14, L1))
            C *= 1 - g.chromaRolloff * min(1, fade)
        }

        // Rotate foliage greens slightly toward teal (OKLab green ≈ 120°–165°).
        if g.greenShift != 0 {
            let d = abs(ColorMath.angleDelta(h, 142))
            if d < 40 { h += g.greenShift * 0.5 * (1 + cos(Double.pi * d / 40)) }
        }

        let hr = h * .pi / 180
        var a = C * cos(hr), bb = C * sin(hr)
        // Split toning, weighted to shadows / highlights.
        let sw = (1 - L1) * (1 - L1), hw = L1 * L1
        a += g.shadowA * sw + g.highlightA * hw
        bb += g.shadowB * sw + g.highlightB * hw

        let lin = ColorMath.okLabToLinearInGamut(ColorMath.Lab(L: L1, a: a, b: bb))
        return (ColorMath.linearToSRGB(lin.0), ColorMath.linearToSRGB(lin.1), ColorMath.linearToSRGB(lin.2))
    }

    /// RGBA float cube for CIColorCubeWithColorSpace (red fastest, then green, then blue), sRGB-encoded.
    static func buildLUT(_ g: Grade, dimension n: Int = 33) -> [Float] {
        var data = [Float](repeating: 1, count: n * n * n * 4)
        let scale = 1.0 / Double(n - 1)
        let identity = g.isNeutral
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let rr = Double(ri) * scale, gg = Double(gi) * scale, bb = Double(bi) * scale
                    let out = identity ? (rr, gg, bb) : apply(g, r: rr, g: gg, b: bb)
                    data[i] = Float(out.0); data[i + 1] = Float(out.1); data[i + 2] = Float(out.2); data[i + 3] = 1
                    i += 4
                }
            }
        }
        return data
    }

    // MARK: Auto light (face-metered)

    /// Video convention: a well-exposed face reads roughly 40–70 IRE depending on complexion.
    /// Only correct faces outside that band, so darker and lighter skin both stay true.
    static let faceBandLinear: ClosedRange<Double> = ColorMath.srgbToLinear(0.38)...ColorMath.srgbToLinear(0.70)

    /// Exposure correction (EV) for a face with this mean linear luminance.
    static func exposureCorrection(faceLuminance y: Double) -> Double {
        guard y > 1e-4 else { return 0 }
        if y < faceBandLinear.lowerBound { return min(1.3, log2(faceBandLinear.lowerBound / y)) }
        if y > faceBandLinear.upperBound { return max(-1.0, log2(faceBandLinear.upperBound / y)) }
        return 0
    }

    /// Centre-weighted / average metering: a scene's mean usually sits near 18% grey (≈ 0.46 encoded).
    /// Correct only outside a comfortable band, like a camera's exposure latitude.
    static let sceneBandLinear: ClosedRange<Double> = ColorMath.srgbToLinear(0.33)...ColorMath.srgbToLinear(0.60)

    static func sceneExposureCorrection(meanLuminance y: Double) -> Double {
        guard y > 1e-4 else { return 0 }
        if y < sceneBandLinear.lowerBound { return min(1.0, log2(sceneBandLinear.lowerBound / y)) }
        if y > sceneBandLinear.upperBound { return max(-1.0, log2(sceneBandLinear.upperBound / y)) }
        return 0
    }

    /// Skin hues accepted as-is; outside this the light (not the skin) is assumed to be off.
    static let acceptedSkinHues: ClosedRange<Double> = 38...88

    /// Linear RGB gains that nudge a face's hue back into the natural skin range, keeping luminance.
    /// Returns (1,1,1) when the face already looks natural or the reading is unreliable.
    static func skinBalanceGains(faceLinear r: Double, _ g: Double, _ b: Double, strength: Double = 0.7) -> (Double, Double, Double) {
        let lab = ColorMath.linearToOKLab(r, g, b)
        let C = hypot(lab.a, lab.b)
        guard C > 0.015, lab.L > 0.15 else { return (1, 1, 1) }     // too grey or too dark to judge
        let h = atan2(lab.b, lab.a) * 180 / .pi
        let edge: Double
        if h < acceptedSkinHues.lowerBound || h > 270 { edge = acceptedSkinHues.lowerBound }
        else if h > acceptedSkinHues.upperBound { edge = acceptedSkinHues.upperBound }
        else { return (1, 1, 1) }
        let delta = ColorMath.angleDelta(edge, h)
        guard abs(delta) < 60 else { return (1, 1, 1) }            // wildly off: probably coloured lighting on purpose
        let move = max(-22, min(22, delta)) * strength
        let nh = (h + move) * .pi / 180
        let target = ColorMath.okLabToLinear(ColorMath.Lab(L: lab.L, a: C * cos(nh), b: C * sin(nh)))
        var gains = (max(target.0, 1e-4) / max(r, 1e-4), max(target.1, 1e-4) / max(g, 1e-4), max(target.2, 1e-4) / max(b, 1e-4))
        let y0 = ColorMath.luminance(r, g, b)
        let y1 = ColorMath.luminance(r * gains.0, g * gains.1, b * gains.2)
        if y1 > 1e-6 {
            let k = y0 / y1
            gains = (gains.0 * k, gains.1 * k, gains.2 * k)
        }
        func clampGain(_ x: Double) -> Double { min(1.25, max(0.8, x)) }
        return (clampGain(gains.0), clampGain(gains.1), clampGain(gains.2))
    }
}
