import Foundation

/// Colour-space math shared by the grade engine and the scene meter.
/// Pure Swift (no Apple frameworks) so it can be tested anywhere.
enum ColorMath {
    // MARK: sRGB transfer

    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ c: Double) -> Double {
        let v = max(0, c)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    // MARK: OKLab (Björn Ottosson, 2020) on linear sRGB

    struct Lab { var L: Double; var a: Double; var b: Double }

    static func linearToOKLab(_ r: Double, _ g: Double, _ b: Double) -> Lab {
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return Lab(L: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                   a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                   b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    static func okLabToLinear(_ lab: Lab) -> (Double, Double, Double) {
        let l_ = lab.L + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let m_ = lab.L - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let s_ = lab.L - 0.0894841775 * lab.a - 1.2914855480 * lab.b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// Converts OKLab to linear sRGB, reducing chroma (never hue or lightness) until it fits the gamut.
    static func okLabToLinearInGamut(_ lab: Lab) -> (Double, Double, Double) {
        func fits(_ c: (Double, Double, Double)) -> Bool {
            let e = 1e-5
            return c.0 >= -e && c.1 >= -e && c.2 >= -e && c.0 <= 1 + e && c.1 <= 1 + e && c.2 <= 1 + e
        }
        let L = min(max(lab.L, 0), 1)
        let direct = okLabToLinear(Lab(L: L, a: lab.a, b: lab.b))
        if fits(direct) { return direct }
        var lo = 0.0, hi = 1.0
        for _ in 0..<14 {
            let mid = (lo + hi) / 2
            if fits(okLabToLinear(Lab(L: L, a: lab.a * mid, b: lab.b * mid))) { lo = mid } else { hi = mid }
        }
        let c = okLabToLinear(Lab(L: L, a: lab.a * lo, b: lab.b * lo))
        return (min(max(c.0, 0), 1), min(max(c.1, 0), 1), min(max(c.2, 0), 1))
    }

    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: Helpers

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Signed smallest difference between two angles, in degrees (-180...180].
    static func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}
