import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import QuartzCore

/// `Framelight --benchmark [--out file.md]`
///
/// Runs headless (no camera, no window):
///   1. Throughput of the full pipeline on synthetic 4K camera frames, per configuration.
///   2. Objective quality against the naive methods most webcam apps use:
///      halo around a blurred background, temporal noise reduction (noise removed, ghosting),
///      and skin hue drift under contrast + saturation.
/// Exits non-zero if a quality check regresses, so CI catches it.
enum Benchmark {
    private static var report: [String] = []
    private static var failures: [String] = []

    private static func log(_ line: String = "") {
        print(line)
        report.append(line)
    }

    static func run() -> Int32 {
        let processor = FrameProcessor()
        let context = processor.ciContext
        log("# Framelight benchmark")
        log()
        log("- Date: \(ISO8601DateFormatter().string(from: Date()))")
        log("- GPU: \(processor.metalDevice?.name ?? "none (Core Image CPU renderer)")")
        log("- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("- CPU cores: \(ProcessInfo.processInfo.activeProcessorCount)")
        log()

        throughput(processor)
        haloQuality(processor, context: context)
        noiseQuality(processor, context: context)
        skinQuality(context: context)

        log()
        if failures.isEmpty {
            log("**All quality checks passed.**")
        } else {
            log("**Quality regressions:**")
            failures.forEach { log("- \($0)") }
        }

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
            try? report.joined(separator: "\n").write(toFile: args[i + 1], atomically: true, encoding: .utf8)
        }
        return failures.isEmpty ? 0 : 1
    }

    // MARK: 1. Throughput

    private static func throughput(_ processor: FrameProcessor) {
        log("## Pipeline speed (3840×2160 camera frames)")
        log()
        let frames = (0..<4).compactMap { makeSceneBuffer(width: 3840, height: 2160, seed: UInt64($0 + 1)) }
        guard frames.count == 4 else { log("Couldn't create test frames."); return }

        var configs: [(String, ProcessingSettings)] = []
        var off = ProcessingSettings()
        off.autoLight = false; off.naturalSkin = false; off.denoise = 0; off.lookIntensity = 0
        configs.append(("Camera only (crop + scale to 1080p)", off))
        configs.append(("Framelight defaults (look, auto light, skin tones, noise reduction)", ProcessingSettings()))
        var blur = ProcessingSettings(); blur.backgroundMode = .blur
        configs.append(("Defaults + background blur", blur))
        var everything = blur
        everything.autoFraming = true; everything.sharpen = 0.3; everything.vignette = 0.3
        everything.nameTagEnabled = true; everything.nameTagTitle = "Benchmark"; everything.nameTagSubtitle = "Framelight"
        configs.append(("Everything on (blur, framing, detail, name tag)", everything))
        var uhd = ProcessingSettings(); uhd.outputResolution = .uhd2160
        configs.append(("Defaults at 4K output", uhd))

        log("| Configuration | Mean ms/frame | p95 ms | Max fps | Fits 30 fps |")
        log("|---|---:|---:|---:|:---:|")
        for (name, settings) in configs {
            processor.settings = settings
            var times: [Double] = []
            for i in 0..<75 {
                guard let sample = sampleBuffer(frames[i % frames.count], index: i) else { continue }
                let start = CACurrentMediaTime()
                processor.process(sample)
                let ms = (CACurrentMediaTime() - start) * 1000
                if i >= 15 { times.append(ms) }      // skip warm-up (shader compiles, first LUT, first mask)
            }
            let mean = times.reduce(0, +) / Double(max(1, times.count))
            let p95 = times.sorted()[min(times.count - 1, Int(Double(times.count - 1) * 0.95))]
            log(String(format: "| %@ | %.1f | %.1f | %.0f | %@ |", name, mean, p95, 1000 / max(mean, 0.01), p95 < 33.3 ? "✅" : "⚠️"))
        }
        log()
        log("Times are wall-clock per frame, including GPU work and waiting for it. On a virtual machine without GPU acceleration they're much slower than on a real Mac.")
        log()
    }

    // MARK: 2. Halo

    private static func haloQuality(_ processor: FrameProcessor, context: CIContext) {
        log("## Background blur halo")
        log()
        let size = CGSize(width: 1920, height: 1080)
        let rect = CGRect(origin: .zero, size: size)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = 300

        // Busy background (stripes) and a strongly coloured "person" disc.
        let stripes = CIFilter.stripesGenerator()
        stripes.color0 = CIColor(red: 0.95, green: 0.85, blue: 0.2)
        stripes.color1 = CIColor(red: 0.1, green: 0.55, blue: 0.3)
        stripes.width = 24
        stripes.center = .zero
        let background = stripes.outputImage!.cropped(to: rect)
        let person = CIImage(color: CIColor(red: 0.75, green: 0.05, blue: 0.1)).cropped(to: rect)
        let disc = CIFilter.radialGradient()
        disc.center = center
        disc.radius0 = Float(radius - 1.5)
        disc.radius1 = Float(radius + 1.5)
        disc.color0 = CIColor(red: 1, green: 1, blue: 1)
        disc.color1 = CIColor(red: 0, green: 0, blue: 0)
        let matte = disc.outputImage!.cropped(to: rect)
        let frame = person.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: matte])

        let blurRadius: CGFloat = 20
        // A blur can only carry the subject's colour as far as its own reach: disc radius + Gaussian tail.
        let haloReach = Int(blurRadius * 1.5)
        func composite(_ bg: CIImage) -> CIImage {
            person.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: matte]).cropped(to: rect)
        }
        // Ground truth: the room blurred without the person in it.
        let truth = composite(naiveLensBlur(background, radius: blurRadius))
        // What most apps do: blur the whole frame (person included), then paste the person back.
        let naive = composite(naiveLensBlur(frame, radius: blurRadius))
        // Framelight: normalized-convolution blur that excludes the person.
        let ours = composite(processor.haloFreeLensBlur(frame, matte: matte, radius: blurRadius))

        let t = read(truth, context: context, rect: rect)
        let n = read(naive, context: context, rect: rect)
        let o = read(ours, context: context, rect: rect)
        let w = Int(size.width), h = Int(size.height)
        let subject: [Float] = { let p = read(person, context: context, rect: CGRect(x: 0, y: 0, width: 1, height: 1)); return [p[0], p[1], p[2]] }()
        /// Total error, and the part of it that points toward the subject's colour (the halo itself).
        func bandError(_ img: [Float]) -> (total: Double, bleed: Double) {
            var total = 0.0, bleed = 0.0, count = 0
            for y in stride(from: 0, to: h, by: 2) {
                for x in stride(from: 0, to: w, by: 2) {
                    let d = hypot(Double(x) - Double(center.x), Double(y) - Double(center.y)) - Double(radius)
                    guard d > 2, d < Double(haloReach) else { continue }
                    let i = (y * w + x) * 4
                    let e = [img[i] - t[i], img[i + 1] - t[i + 1], img[i + 2] - t[i + 2]]
                    let dir = [subject[0] - t[i], subject[1] - t[i + 1], subject[2] - t[i + 2]]
                    let len = sqrt(dir.map { $0 * $0 }.reduce(0, +))
                    total += Double(abs(e[0]) + abs(e[1]) + abs(e[2])) / 3
                    if len > 1e-4 { bleed += max(0, Double((e[0] * dir[0] + e[1] * dir[1] + e[2] * dir[2]) / len)) }
                    count += 1
                }
            }
            let n = Double(max(1, count))
            return (total / n * 255, bleed / n * 255)
        }
        let naiveErr = bandError(n), ourErr = bandError(o)
        let reduction = naiveErr.bleed > 0 ? (1 - ourErr.bleed / naiveErr.bleed) * 100 : 0
        log("Within the reach of a 20 px blur (2–\(haloReach) px from the subject), compared with a true blur of the room. Scale 0–255, lower is better.")
        log("**Subject colour bleed** is the halo: error pointing toward the person's colour. **Total error** also includes the room hidden behind the person, which no method can see.")
        log()
        log("| Method | Subject colour bleed (halo) | Total error |")
        log("|---|---:|---:|")
        log(String(format: "| Blur whole frame, paste person back (typical) | %.2f | %.2f |", naiveErr.bleed, naiveErr.total))
        log(String(format: "| Framelight halo-free blur | %.2f | %.2f |", ourErr.bleed, ourErr.total))
        log()
        log(String(format: "Halo reduced by **%.0f%%**.", reduction))
        log()
        if reduction < 60 { failures.append(String(format: "Halo (subject colour bleed) reduced only %.0f%% (want ≥ 60%%)", reduction)) }
    }

    private static func naiveLensBlur(_ image: CIImage, radius: CGFloat) -> CIImage {
        let ext = image.extent
        let down: CGFloat = 0.25
        let r = max(1, radius * down)
        let disc = CIFilter.discBlur()
        disc.inputImage = image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: down, y: down))
        disc.radius = Float(r)
        return disc.outputImage!
            .applyingGaussianBlur(sigma: Double(max(0.8, r * 0.3)))
            .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
            .cropped(to: ext)
    }

    // MARK: 3. Noise

    private static func noiseQuality(_ processor: FrameProcessor, context: CIContext) {
        log("## Noise reduction")
        log()
        let size = CGSize(width: 960, height: 540)
        let rect = CGRect(origin: .zero, size: size)
        let clean = texturedScene(size: size)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

        /// Runs 24 frames through a temporal filter, feeding each output back as the next "previous".
        func run(noise: CGFloat, strength: Double, adaptive: Bool, scene: (Int) -> CIImage) -> CIImage {
            var pool = BufferPool()
            var previous: CIImage?
            var out = scene(0)
            for f in 0..<24 {
                let current = processor.addGrain(scene(f), extent: rect, amount: noise)   // fresh sensor-like noise each frame
                if let previous {
                    out = adaptive
                        ? processor.temporalDenoise(current: current, previous: previous, strength: strength)
                        // Non-adaptive temporal averaging, what simple "3D NR" does.
                        : current.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: previous, kCIInputTimeKey: 0.65])
                } else {
                    out = current
                }
                if let buf = pool.make(size) {
                    context.render(out, to: buf, bounds: rect, colorSpace: srgb)
                    out = CIImage(cvPixelBuffer: buf)
                }
                previous = out
            }
            return out
        }

        let truth = read(clean, context: context, rect: rect, colorSpace: srgb)
        log("| Scene | Noise in (0–255 RMS) | Removed at default (35%) | Removed at maximum |")
        log("|---|---:|---:|---:|")
        var typicalGain = 0.0
        for (name, amount) in [("Typical room", CGFloat(0.02)), ("Dim room (high gain)", CGFloat(0.05))] {
            let raw = read(processor.addGrain(clean, extent: rect, amount: amount), context: context, rect: rect, colorSpace: srgb)
            let rawRMS = rms(raw, truth)
            if rawRMS < 0.002 { failures.append(String(format: "Test noise wasn't applied (RMS %.4f)", rawRMS)) }
            let def = rms(read(run(noise: amount, strength: 0.35, adaptive: true) { _ in clean }, context: context, rect: rect, colorSpace: srgb), truth)
            let maxRMS = rms(read(run(noise: amount, strength: 1.0, adaptive: true) { _ in clean }, context: context, rect: rect, colorSpace: srgb), truth)
            let gDef = 20 * log10(rawRMS / Swift.max(def, 1e-9)), gMax = 20 * log10(rawRMS / Swift.max(maxRMS, 1e-9))
            if amount < 0.03 { typicalGain = gDef }
            log(String(format: "| %@ | %.1f | %.1f dB | %.1f dB |", name, rawRMS * 255, gDef, gMax))
        }
        log()

        // Moving object: the dark trail left behind (a bias, so leftover noise averages out).
        let speed: CGFloat = 14
        func moving(_ f: Int) -> CIImage {
            let square = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.08))
                .cropped(to: CGRect(x: 120 + CGFloat(f) * speed, y: 200, width: 140, height: 140))
            return square.composited(over: clean).cropped(to: rect)
        }
        let movingTruth = read(moving(23), context: context, rect: rect, colorSpace: srgb)
        let ours = read(run(noise: 0.02, strength: 1.0, adaptive: true, scene: moving), context: context, rect: rect, colorSpace: srgb)
        let simple = read(run(noise: 0.02, strength: 1.0, adaptive: false, scene: moving), context: context, rect: rect, colorSpace: srgb)
        let x0 = Int(120 + 23 * speed - 6 * speed), x1 = Int(120 + 23 * speed)
        let ghostOurs = trailDarkening(ours, movingTruth, width: Int(size.width), x: x0..<x1, y: 200..<340)
        let ghostSimple = trailDarkening(simple, movingTruth, width: Int(size.width), x: x0..<x1, y: 200..<340)
        log("| Ghost trail behind a moving dark object (0–255, lower is better) | Result |")
        log("|---|---:|")
        log(String(format: "| Framelight motion-adaptive, maximum strength | %.2f |", ghostOurs * 255))
        log(String(format: "| Simple temporal averaging | %.2f |", ghostSimple * 255))
        log()
        if typicalGain < 2.5 { failures.append(String(format: "Noise reduction only %.1f dB in a typical room (want ≥ 2.5 dB)", typicalGain)) }
        if ghostOurs > ghostSimple * 0.5 { failures.append(String(format: "Ghosting %.2f is not well below simple averaging %.2f", ghostOurs * 255, ghostSimple * 255)) }
    }

    /// How much darker than the truth the area behind a moving dark object is (the ghost).
    private static func trailDarkening(_ a: [Float], _ truth: [Float], width: Int, x: Range<Int>, y: Range<Int>) -> Double {
        var sum = 0.0, n = 0
        let height = a.count / 4 / width
        for yy in y {
            let row = min(height - 1, max(0, yy))      // the band is symmetric top-to-bottom, so row order doesn't matter
            for xx in x where xx >= 0 && xx < width {
                let i = (row * width + xx) * 4
                for c in 0..<3 { sum += Double(truth[i + c] - a[i + c]) }
                n += 3
            }
        }
        return max(0, sum / Double(max(1, n)))
    }

    private static func texturedScene(size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let checker = CIFilter.checkerboardGenerator()
        checker.color0 = CIColor(red: 0.55, green: 0.5, blue: 0.45)
        checker.color1 = CIColor(red: 0.7, green: 0.66, blue: 0.6)
        checker.width = 32
        checker.center = .zero
        return checker.outputImage!.applyingGaussianBlur(sigma: 3).cropped(to: rect)
    }

    // MARK: 4. Skin

    private static func skinQuality(context: CIContext) {
        log("## Skin colour under contrast +15%, saturation +30%")
        log()
        let skins: [(Int, Int, Int)] = [(194, 150, 130), (115, 82, 68), (0xd7, 0xbd, 0x96), (0xa0, 0x7e, 0x56),
                                        (0x82, 0x5c, 0x43), (0x60, 0x41, 0x34)]
        let others: [(Int, Int, Int)] = [(60, 90, 170), (70, 140, 80)]
        let all = skins + others
        let patch = 16
        let rect = CGRect(x: 0, y: 0, width: patch * all.count, height: patch)
        var chart = CIImage.empty()
        for (i, c) in all.enumerated() {
            let colour = CIImage(color: CIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
                .cropped(to: CGRect(x: i * patch, y: 0, width: patch, height: patch))
            chart = colour.composited(over: chart)
        }

        // Typical: RGB-space saturation/contrast (Core Image colour controls).
        let typical = chart.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3, kCIInputContrastKey: 1.15])
        // Framelight: perceptual engine baked into a LUT.
        var g = Grade.neutral
        g.contrast = 1.15
        g.saturation = 1.3
        let lut = GradeEngine.buildLUT(g, dimension: 33)
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = chart
        cube.cubeDimension = 33
        cube.cubeData = lut.withUnsafeBufferPointer { Data(buffer: $0) }
        cube.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        let ours = cube.outputImage!

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = read(chart, context: context, rect: rect, colorSpace: srgb)
        let t = read(typical, context: context, rect: rect, colorSpace: srgb)
        let o = read(ours, context: context, rect: rect, colorSpace: srgb)
        func lch(_ px: [Float], _ i: Int) -> (C: Double, h: Double) {
            let idx = (patch / 2 * Int(rect.width) + i * patch + patch / 2) * 4
            let lab = ColorMath.linearToOKLab(ColorMath.srgbToLinear(Double(px[idx])), ColorMath.srgbToLinear(Double(px[idx + 1])),
                                              ColorMath.srgbToLinear(Double(px[idx + 2])))
            return (hypot(lab.a, lab.b), atan2(lab.b, lab.a) * 180 / .pi)
        }
        var tHue = 0.0, oHue = 0.0, tSkinC = 0.0, oSkinC = 0.0, tOtherC = 0.0, oOtherC = 0.0
        for i in 0..<all.count {
            let b = lch(base, i), tt = lch(t, i), oo = lch(o, i)
            if i < skins.count {
                tHue = max(tHue, abs(ColorMath.angleDelta(tt.h, b.h)))
                oHue = max(oHue, abs(ColorMath.angleDelta(oo.h, b.h)))
                tSkinC += tt.C / b.C / Double(skins.count)
                oSkinC += oo.C / b.C / Double(skins.count)
            } else {
                tOtherC += tt.C / b.C / Double(others.count)
                oOtherC += oo.C / b.C / Double(others.count)
            }
        }
        log("| Method | Worst skin hue shift | Skin saturation | Other colours' saturation |")
        log("|---|---:|---:|---:|")
        log(String(format: "| RGB colour controls (typical) | %.1f° | ×%.2f | ×%.2f |", tHue, tSkinC, tOtherC))
        log(String(format: "| Framelight perceptual engine | %.1f° | ×%.2f | ×%.2f |", oHue, oSkinC, oOtherC))
        log()
        log("Skin of six tones (Macbeth chart and Monk scale). Hue is measured in OKLab.")
        if oHue > max(3, tHue * 0.6) { failures.append(String(format: "Skin hue shift %.1f° not clearly below typical %.1f°", oHue, tHue)) }
        if oSkinC > tSkinC { failures.append("Skin saturation rises more than with RGB controls") }
    }

    // MARK: Helpers

    private static func read(_ image: CIImage, context: CIContext, rect: CGRect,
                             colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!) -> [Float] {
        let w = Int(rect.width), h = Int(rect.height)
        var data = [Float](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { ptr in
            context.render(image, toBitmap: ptr.baseAddress!, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: colorSpace)
        }
        return data
    }

    private static func rms(_ a: [Float], _ b: [Float]) -> Double {
        var sum = 0.0, n = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            for c in 0..<3 { let d = Double(a[i + c] - b[i + c]); sum += d * d }
            n += 3
        }
        return sqrt(sum / Double(max(1, n)))
    }

    /// A synthetic camera frame: a room with detail, a window, and a person.
    private static func makeSceneBuffer(width: Int, height: Int, seed: UInt64) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let W = CGFloat(width), H = CGFloat(height)
        ctx.setFillColor(CGColor(red: 0.62, green: 0.55, blue: 0.48, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.94, blue: 1, alpha: 1)); ctx.fill(CGRect(x: W * 0.06, y: H * 0.3, width: W * 0.22, height: H * 0.6))
        for i in 0..<14 {   // shelf of books: detail and colour
            ctx.setFillColor(CGColor(red: CGFloat((i * 37) % 100) / 100, green: CGFloat((i * 53) % 100) / 100, blue: CGFloat((i * 71) % 100) / 100, alpha: 1))
            ctx.fill(CGRect(x: W * 0.62 + CGFloat(i) * W * 0.022, y: H * 0.62, width: W * 0.018, height: H * (0.12 + CGFloat(i % 4) * 0.03)))
        }
        ctx.setFillColor(CGColor(red: 0.17, green: 0.29, blue: 0.43, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: W * 0.32, y: -H * 0.25, width: W * 0.36, height: H * 0.7))
        ctx.setFillColor(CGColor(red: 0.78, green: 0.56, blue: 0.43, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: W * 0.43, y: H * 0.38, width: W * 0.14, height: H * 0.36))
        // Sensor-like noise.
        var state = seed &* 0x9E3779B97F4A7C15
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in stride(from: 0, to: height, by: 1) {
            let row = base + y * bpr
            for x in stride(from: 0, to: width * 4, by: 4) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let n = Int((state >> 59) & 0x0F) - 8
                for c in 0..<3 { row[x + c] = UInt8(clamping: Int(row[x + c]) + n) }
            }
        }
        return pb
    }

    private static func sampleBuffer(_ pb: CVPixelBuffer, index: Int) -> CMSampleBuffer? {
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fd)
        guard let fd else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fd,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        return sb
    }
}
