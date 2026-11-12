import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Metal
import AppKit
import QuartzCore

/// Reusable pool of BGRA IOSurface-backed pixel buffers of one size.
struct BufferPool {
    private var pool: CVPixelBufferPool?
    private var size: CGSize = .zero

    mutating func make(_ newSize: CGSize) -> CVPixelBuffer? {
        if pool == nil || size != newSize {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(newSize.width),
                kCVPixelBufferHeightKey as String: Int(newSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                    attrs as CFDictionary, &newPool)
            pool = newPool
            size = newSize
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        if let buffer {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        return buffer
    }
}

/// The software pipeline. Everything runs at output resolution after framing:
/// framing crop → temporal noise reduction → auto light & skin-tone white balance → exposure/WB/tone
/// → background (edge-aware matte, halo-free lens blur) → natural grade (3D LUT) → detail → orientation.
final class FrameProcessor: @unchecked Sendable {
    let ciContext: CIContext
    let metalDevice: MTLDevice?

    private let lock = NSLock()
    private var _settings = ProcessingSettings()
    private var needsFramerReset = false
    private let vision = VisionAnalyzer()
    private let framer = AutoFramer()

    // Buffers
    private var outputPool = BufferPool()
    private var cleanPool = BufferPool()
    private var previewPool = BufferPool()
    private var virtualPool = BufferPool()
    private var maskPool = BufferPool()
    private var previousClean: CVPixelBuffer?
    private var previousMask: CVPixelBuffer?
    private var backgroundImage: CIImage?
    private var backgroundImagePath: String?

    // Grade LUTs
    private let gradeQueue = DispatchQueue(label: "framelight.grade", qos: .userInitiated)
    private var lut: (key: Grade, data: Data)?
    private var lutPending: Grade?
    private static let lutDimension = 33

    // Auto light (face-metered exposure + skin-tone white balance)
    private let meterQueue = DispatchQueue(label: "framelight.meter", qos: .userInitiated)
    private var meterBusy = false
    private var targetEV = 0.0
    private var currentEV = 0.0
    private var targetGains = SIMD3<Double>(1, 1, 1)
    private var currentGains = SIMD3<Double>(1, 1, 1)
    private var lastFaceSeen = -Double.infinity
    private var lastFrameTime: Double?

    // Side work
    private var frameCount = 0
    private let histogramQueue = DispatchQueue(label: "framelight.histogram", qos: .utility)
    private var histogramBusy = false
    private let thumbQueue = DispatchQueue(label: "framelight.thumbnails", qos: .utility)
    private var thumbBusy = false
    private var thumbLUTs: [LookStyle: (key: Grade, data: Data)] = [:]

    /// Processed output (recorder). Called on the capture queue.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// What the window shows; includes the before/after split when Compare is on.
    var onPreview: ((CVPixelBuffer) -> Void)?
    /// 1920×1080 frames for the virtual camera.
    var onVirtualCameraFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var virtualCameraEnabled = false
    var onHistogram: (([[Float]]) -> Void)?
    var onStats: ((FrameStats) -> Void)?
    /// Small previews of every look on the live image, about once a second.
    var onLookThumbnails: (([LookStyle: CGImage]) -> Void)?

    struct FrameStats {
        var sourceSize: CGSize
        var outputSize: CGSize
        var crop: CGRect
        var zoom: Double
        var facesDetected: Int
        var autoExposure: Double
        var skinCorrection: Bool
    }

    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let linearSRGB = CGColorSpace(name: CGColorSpace.linearSRGB)!

    init() {
        metalDevice = MTLCreateSystemDefaultDevice()
        if let metalDevice {
            ciContext = CIContext(mtlDevice: metalDevice, options: [.cacheIntermediates: false, .name: "Framelight"])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        requestLUT(ProcessingSettings().grade.key)
    }

    var settings: ProcessingSettings {
        get { lock.locked { _settings } }
        set {
            lock.locked {
                if newValue.autoFraming != _settings.autoFraming { needsFramerReset = true }
                if newValue.backgroundMode == .none { vision.clearMask() }
                _settings = newValue
            }
            requestLUT(newValue.grade.key)
        }
    }

    // MARK: Per-frame

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let input = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = CACurrentMediaTime()
        let (s, resetFramer): (ProcessingSettings, Bool) = lock.locked {
            defer { needsFramerReset = false }
            return (_settings, needsFramerReset)
        }
        if resetFramer { framer.reset() }
        frameCount &+= 1
        let dt = min(0.25, max(0, now - (lastFrameTime ?? now - 1.0 / 30.0)))
        lastFrameTime = now

        let sourceSize = CGSize(width: CVPixelBufferGetWidth(input), height: CVPixelBufferGetHeight(input))
        let outSize = s.outputResolution.size
        let outRect = CGRect(origin: .zero, size: outSize)
        let aspect = outSize.width / outSize.height

        let needsFaces = s.autoFraming || s.autoLight || s.naturalSkin
        vision.submit(input, detect: needsFaces, segment: s.backgroundMode != .none)
        let detection = needsFaces ? vision.latestDetection : nil

        // 1. Framing.
        let crop: CGRect
        if s.autoFraming {
            crop = framer.crop(source: sourceSize, aspect: aspect, settings: s, detection: detection, now: now)
        } else {
            crop = AutoFramer.manualCrop(source: sourceSize, aspect: aspect, zoom: s.digitalZoom, panX: s.panX, panY: s.panY)
        }
        var image = scale(CIImage(cvPixelBuffer: input), crop: crop, to: outSize)

        // 2. Motion-adaptive temporal noise reduction (keeps skin texture, unlike spatial smoothing).
        if s.denoise > 0.01, let prev = previousClean,
           CVPixelBufferGetWidth(prev) == Int(outSize.width), CVPixelBufferGetHeight(prev) == Int(outSize.height) {
            image = temporalDenoise(current: image, previous: CIImage(cvPixelBuffer: prev), strength: s.denoise)
        }
        guard let cleanBuffer = cleanPool.make(outSize) else { return }
        ciContext.render(image, to: cleanBuffer, bounds: outRect, colorSpace: srgb)
        previousClean = cleanBuffer
        let clean = CIImage(cvPixelBuffer: cleanBuffer)

        // 3. Auto light: meter the face, ease toward the correction.
        updateAutoLight(settings: s, source: input, detection: detection, now: now, dt: dt)
        let (ev, gains): (Double, SIMD3<Double>) = lock.locked { (currentEV, currentGains) }

        // 4. Exposure, white balance and local tone, in linear light.
        image = applyLight(clean, settings: s, autoEV: ev, skinGains: gains)

        // 5. Background.
        if s.backgroundMode != .none, let maskBuffer = vision.latestMask {
            let matte = outputMatte(maskBuffer, sourceSize: sourceSize, crop: crop, guide: clean)
            image = applyBackground(image, matte: matte, settings: s)
        }

        // 6. Natural grade (look + contrast + saturation), one 3D LUT.
        image = applyGrade(image)

        // 7. Detail.
        image = applyDetail(image, settings: s, size: outSize)

        // 8. Orientation.
        image = orient(image, settings: s, size: outSize).cropped(to: outRect)

        guard let output = outputPool.make(outSize) else { return }
        ciContext.render(image, to: output, bounds: outRect, colorSpace: srgb)
        onFrame?(output, time)

        // Preview (optionally split before/after; never sent to other apps).
        if s.compare, let preview = previewPool.make(outSize) {
            let before = orient(clean, settings: s, size: outSize)
                .cropped(to: CGRect(x: 0, y: 0, width: outSize.width / 2, height: outSize.height))
            let divider = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.85))
                .cropped(to: CGRect(x: outSize.width / 2 - 1.5, y: 0, width: 3, height: outSize.height))
            let split = divider.composited(over: before.composited(over: CIImage(cvPixelBuffer: output)))
            ciContext.render(split, to: preview, bounds: outRect, colorSpace: srgb)
            onPreview?(preview)
        } else {
            onPreview?(output)
        }

        // Virtual camera (fixed 1080p).
        if virtualCameraEnabled, let onVirtualCameraFrame {
            let vSize = CGSize(width: Int(VirtualCameraConfig.width), height: Int(VirtualCameraConfig.height))
            if vSize == outSize {
                onVirtualCameraFrame(output, time)
            } else if let vbuf = virtualPool.make(vSize) {
                let scaled = CIImage(cvPixelBuffer: output)
                    .transformed(by: CGAffineTransform(scaleX: vSize.width / outSize.width, y: vSize.height / outSize.height))
                ciContext.render(scaled, to: vbuf, bounds: CGRect(origin: .zero, size: vSize), colorSpace: srgb)
                onVirtualCameraFrame(vbuf, time)
            }
        }

        // Side work, off the video thread.
        if frameCount % 8 == 0 {
            publishHistogram(output)
            let fullHeight = AutoFramer.fullCrop(source: sourceSize, aspect: aspect).height
            onStats?(FrameStats(sourceSize: sourceSize, outputSize: outSize, crop: crop,
                                zoom: Double(fullHeight / max(1, crop.height)),
                                facesDetected: max(detection?.faces.count ?? 0, detection?.bodies.count ?? 0),
                                autoExposure: s.autoLight ? ev : 0,
                                skinCorrection: s.naturalSkin && abs(gains.x - 1) + abs(gains.y - 1) + abs(gains.z - 1) > 0.01))
        }
        if frameCount % 36 == 0 {
            publishThumbnails(clean: cleanBuffer, settings: s, ev: ev, gains: gains)
        }
    }

    // MARK: Framing

    private func scale(_ image: CIImage, crop: CGRect, to size: CGSize) -> CIImage {
        let scale = size.height / crop.height
        let moved = image.clampedToExtent()
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        if scale < 0.75 {
            // High-quality downscale (e.g. 4K sensor → 1080p) to avoid aliasing.
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = moved
            f.scale = Float(scale)
            f.aspectRatio = Float((size.width / crop.width) / scale)
            return (f.outputImage ?? moved).cropped(to: CGRect(origin: .zero, size: size))
        }
        return moved.transformed(by: CGAffineTransform(scaleX: size.width / crop.width, y: scale))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private func orient(_ image: CIImage, settings s: ProcessingSettings, size: CGSize) -> CIImage {
        guard s.mirror || s.flipVertical else { return image }
        let t = CGAffineTransform(translationX: s.mirror ? size.width : 0, y: s.flipVertical ? size.height : 0)
            .scaledBy(x: s.mirror ? -1 : 1, y: s.flipVertical ? -1 : 1)
        return image.transformed(by: t)
    }

    // MARK: Noise

    /// Averages with the previous frame only where nothing moved, so static skin keeps its texture
    /// while sensor noise drops; moving areas use the current frame and never ghost.
    private func temporalDenoise(current: CIImage, previous: CIImage, strength: Double) -> CIImage {
        let ext = current.extent
        let diff = CIFilter.colorAbsoluteDifference()
        diff.inputImage = current.applyingFilter("CILinearToSRGBToneCurve")
        diff.inputImage2 = previous.applyingFilter("CILinearToSRGBToneCurve")
        guard let d = diff.outputImage else { return current }

        // Differences below the noise floor count as "still"; anything bigger is motion.
        let gain: CGFloat = 16, floor: CGFloat = 0.03
        let m = CIFilter.colorMatrix()
        m.inputImage = d
        let w = gain / 3
        m.rVector = CIVector(x: w, y: w, z: w, w: 0)
        m.gVector = CIVector(x: w, y: w, z: w, w: 0)
        m.bVector = CIVector(x: w, y: w, z: w, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: -gain * floor, y: -gain * floor, z: -gain * floor, w: 0)
        guard let raw = m.outputImage else { return current }
        let motion = raw.applyingFilter("CIColorClamp").clampedToExtent().applyingGaussianBlur(sigma: 2.5).cropped(to: ext)

        let average = CIFilter.dissolveTransition()
        average.inputImage = current
        average.targetImage = previous
        average.time = Float(0.2 + 0.45 * min(1, strength))

        let mix = CIFilter.blendWithMask()
        mix.inputImage = current
        mix.backgroundImage = average.outputImage
        mix.maskImage = motion
        return (mix.outputImage ?? current).cropped(to: ext)
    }

    // MARK: Light

    private func applyLight(_ input: CIImage, settings s: ProcessingSettings, autoEV: Double, skinGains: SIMD3<Double>) -> CIImage {
        var image = input
        let ev = s.exposure + (s.autoLight ? autoEV : 0)
        if abs(ev) > 0.005 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(ev)
            image = f.outputImage ?? image
        }

        if s.naturalSkin, abs(skinGains.x - 1) + abs(skinGains.y - 1) + abs(skinGains.z - 1) > 0.002 {
            // White balance as per-channel gains in linear light (von Kries), from the skin tone line.
            let f = CIFilter.colorMatrix()
            f.inputImage = image
            f.rVector = CIVector(x: CGFloat(skinGains.x), y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: CGFloat(skinGains.y), z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: CGFloat(skinGains.z), w: 0)
            image = f.outputImage ?? image
        }

        if s.warmth != 0 || s.tint != 0 {
            // Higher "neutral" temperature renders the image warmer (chromatic adaptation).
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500 + CGFloat(s.warmth) * 15, y: CGFloat(s.tint) * 0.4)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            image = f.outputImage ?? image
        }

        // Protect bright windows when auto light lifts a backlit face.
        var highlights = s.highlights
        if s.autoLight, autoEV > 0.25 { highlights = min(highlights, 1 - min(0.3, (autoEV - 0.25) * 0.3)) }
        if highlights < 0.999 || s.shadows > 0.001 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = Float(highlights)
            f.shadowAmount = Float(s.shadows)
            image = f.outputImage ?? image
        }
        return image.cropped(to: input.extent)
    }

    private func updateAutoLight(settings s: ProcessingSettings, source: CVPixelBuffer, detection: FramingDetection?,
                                 now: Double, dt: Double) {
        let active = s.autoLight || s.naturalSkin
        let face = detection?.faces.max { $0.width * $0.height < $1.width * $1.height }
        if active, let face {
            lastFaceSeen = now
            if frameCount % 5 == 0 { startMeter(source: source, face: face) }
        }
        lock.locked {
            if !active || now - lastFaceSeen > 2.5 {
                targetEV = 0
                targetGains = SIMD3(1, 1, 1)
            }
            let aEV = 1 - exp(-dt / 1.2)        // exposure eases over ~1 s
            let aWB = 1 - exp(-dt / 2.0)        // colour eases over ~2 s
            currentEV += (targetEV - currentEV) * aEV
            currentGains += (targetGains - currentGains) * aWB
        }
    }

    /// Averages the skin in the middle of the face (cheeks, nose; not hair or background).
    private func startMeter(source: CVPixelBuffer, face: CGRect) {
        let start: Bool = lock.locked {
            guard !meterBusy else { return false }
            meterBusy = true
            return true
        }
        guard start else { return }
        meterQueue.async { [self] in
            defer { lock.locked { meterBusy = false } }
            let image = CIImage(cvPixelBuffer: source)
            let W = image.extent.width, H = image.extent.height
            let region = CGRect(x: (face.minX + face.width * 0.22) * W, y: (face.minY + face.height * 0.18) * H,
                                width: face.width * 0.56 * W, height: face.height * 0.5 * H).integral
            guard region.width >= 4, region.height >= 4 else { return }
            let avg = CIFilter.areaAverage()
            avg.inputImage = image
            avg.extent = region
            guard let out = avg.outputImage else { return }
            var px = [Float](repeating: 0, count: 4)
            px.withUnsafeMutableBytes { ptr in
                ciContext.render(out, toBitmap: ptr.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                 format: .RGBAf, colorSpace: linearSRGB)
            }
            let r = Double(px[0]), g = Double(px[1]), b = Double(px[2])
            let ev = GradeEngine.exposureCorrection(faceLuminance: ColorMath.luminance(r, g, b))
            let gains = GradeEngine.skinBalanceGains(faceLinear: r, g, b)
            lock.locked {
                targetEV = ev
                targetGains = SIMD3(gains.0, gains.1, gains.2)
            }
        }
    }

    // MARK: Background

    /// Person matte in output coordinates: temporally smoothed, then upsampled with the real
    /// image as a guide so its edge follows hair and shoulders instead of a blurry blob.
    private func outputMatte(_ maskBuffer: CVPixelBuffer, sourceSize: CGSize, crop: CGRect, guide: CIImage) -> CIImage {
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        let mw = mask.extent.width, mh = mask.extent.height
        if let prev = previousMask, CVPixelBufferGetWidth(prev) == Int(mw), CVPixelBufferGetHeight(prev) == Int(mh) {
            let d = CIFilter.dissolveTransition()
            d.inputImage = mask
            d.targetImage = CIImage(cvPixelBuffer: prev)
            d.time = 0.4
            mask = d.outputImage ?? mask
        }
        if let store = maskPool.make(CGSize(width: mw, height: mh)) {
            ciContext.render(mask, to: store)
            previousMask = store
            mask = CIImage(cvPixelBuffer: store)
        }

        let sx = mw / sourceSize.width, sy = mh / sourceSize.height
        let mCrop = CGRect(x: crop.minX * sx, y: crop.minY * sy, width: crop.width * sx, height: crop.height * sy)
        let small = mask.clampedToExtent()
            .cropped(to: mCrop)
            .transformed(by: CGAffineTransform(translationX: -mCrop.minX, y: -mCrop.minY))
            .cropped(to: CGRect(origin: .zero, size: mCrop.size))

        let up = CIFilter.edgePreserveUpsample()
        up.inputImage = guide
        up.smallImage = small
        up.spatialSigma = 3
        up.lumaSigma = 0.15
        if let out = up.outputImage {
            return out.cropped(to: guide.extent)
        }
        return small.transformed(by: CGAffineTransform(scaleX: guide.extent.width / mCrop.width,
                                                       y: guide.extent.height / mCrop.height)).cropped(to: guide.extent)
    }

    private func applyBackground(_ image: CIImage, matte: CIImage, settings s: ProcessingSettings) -> CIImage {
        let ext = image.extent
        let k = s.backgroundStrength
        let background: CIImage
        var subject = image

        switch s.backgroundMode {
        case .none:
            return image
        case .blur:
            let radius = (3 + 24 * k) * ext.height / 1080
            background = addGrain(haloFreeLensBlur(image, matte: matte, radius: radius), extent: ext)
        case .studioLight:
            // Like a key light on you and a dimmer room: subject up a little, background down.
            subject = image.applyingFilter("CIExposureAdjust", [kCIInputEVKey: 0.22 * k])
            background = image
                .applyingFilter("CIExposureAdjust", [kCIInputEVKey: -0.95 * k])
                .applyingFilter("CIColorControls", [kCIInputSaturationKey: 1 - 0.2 * k])
        case .color:
            let flat = CIImage(color: CIColor(cgColor: NSColor(hex: s.backgroundColorHex).cgColor)).cropped(to: ext)
            // A soft falloff reads as a lit backdrop rather than a flat fill.
            let falloff = CIFilter.vignetteEffect()
            falloff.inputImage = flat
            falloff.center = CGPoint(x: ext.midX, y: ext.midY * 1.1)
            falloff.radius = Float(ext.width * 0.55)
            falloff.intensity = 0.45
            falloff.falloff = 0.8
            background = addGrain(falloff.outputImage?.cropped(to: ext) ?? flat, extent: ext)
        case .image:
            if let bg = loadBackgroundImage(path: s.backgroundImagePath) {
                let scale = max(ext.width / bg.extent.width, ext.height / bg.extent.height)
                let scaled = bg.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let dx = (ext.width - scaled.extent.width) / 2 - scaled.extent.minX
                let dy = (ext.height - scaled.extent.height) / 2 - scaled.extent.minY
                // Slight defocus: a sharp photo behind a webcam image never looks real.
                let placed = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
                    .clampedToExtent().applyingGaussianBlur(sigma: 1.5 + 4 * k).cropped(to: ext)
                background = addGrain(placed, extent: ext)
            } else {
                background = CIImage(color: CIColor(red: 0.12, green: 0.14, blue: 0.18)).cropped(to: ext)
            }
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = subject
        blend.backgroundImage = background
        blend.maskImage = matte
        return (blend.outputImage ?? image).cropped(to: ext)
    }

    /// Normalized convolution: blur the background with the person removed (premultiplied by the
    /// background weight), then divide by the blurred weight. The person's colours can't bleed out,
    /// so there's no halo. A disc kernel gives lens-like bokeh instead of a smeary Gaussian.
    private func haloFreeLensBlur(_ image: CIImage, matte: CIImage, radius: CGFloat) -> CIImage {
        let ext = image.extent
        // Background weight = 1 - person, pushed to 0 slightly early so edge pixels don't contribute.
        let weight = CIFilter.colorMatrix()
        weight.inputImage = matte.applyingFilter("CIColorInvert")
        weight.rVector = CIVector(x: 1.3, y: 0, z: 0, w: 0)
        weight.gVector = CIVector(x: 0, y: 1.3, z: 0, w: 0)
        weight.bVector = CIVector(x: 0, y: 0, z: 1.3, w: 0)
        weight.biasVector = CIVector(x: -0.3, y: -0.3, z: -0.3, w: 0)
        let w = (weight.outputImage ?? matte).applyingFilter("CIColorClamp")

        let premultiplied = CIFilter.blendWithMask()
        premultiplied.inputImage = image
        premultiplied.backgroundImage = CIImage.empty()
        premultiplied.maskImage = w
        guard let weighted = premultiplied.outputImage else { return image }

        let down: CGFloat = 0.25
        let r = max(1, radius * down)
        let disc = CIFilter.discBlur()
        disc.inputImage = weighted.clampedToExtent().transformed(by: CGAffineTransform(scaleX: down, y: down))
        disc.radius = Float(r)
        guard let blurred = disc.outputImage else { return image }
        return blurred
            .applyingGaussianBlur(sigma: Double(max(0.8, r * 0.3)))
            .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
            .cropped(to: ext)
            .unpremultiplyingAlpha()
            .settingAlphaOne(in: ext)
    }

    /// Real optics keep sensor noise in out-of-focus areas; matching it hides the "pasted" look.
    private func addGrain(_ image: CIImage, extent: CGRect, amount: CGFloat = 0.016) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let shifted = noise
            .transformed(by: CGAffineTransform(translationX: CGFloat.random(in: 0..<512), y: CGFloat.random(in: 0..<512)))
            .cropped(to: extent)
        let m = CIFilter.colorMatrix()
        m.inputImage = shifted
        let k = amount / 3
        m.rVector = CIVector(x: k, y: k, z: k, w: 0)
        m.gVector = CIVector(x: k, y: k, z: k, w: 0)
        m.bVector = CIVector(x: k, y: k, z: k, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: -amount / 2, y: -amount / 2, z: -amount / 2, w: 0)
        guard let grain = m.outputImage else { return image }
        let add = CIFilter.additionCompositing()
        add.inputImage = grain
        add.backgroundImage = image.applyingFilter("CILinearToSRGBToneCurve")
        guard let out = add.outputImage else { return image }
        return out.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    private func loadBackgroundImage(path: String?) -> CIImage? {
        guard let path else { return nil }
        if path == backgroundImagePath, let backgroundImage { return backgroundImage }
        backgroundImagePath = path
        backgroundImage = CIImage(contentsOf: URL(fileURLWithPath: path))
        return backgroundImage
    }

    // MARK: Grade

    private func requestLUT(_ key: Grade) {
        let start: Bool = lock.locked {
            if lut?.key == key || lutPending == key { return false }
            lutPending = key
            return true
        }
        guard start else { return }
        gradeQueue.async { [self] in
            let floats = GradeEngine.buildLUT(key, dimension: Self.lutDimension)
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            lock.locked {
                lut = (key, data)
                if lutPending == key { lutPending = nil }
            }
        }
    }

    private func applyGrade(_ image: CIImage) -> CIImage {
        guard let current = lock.locked({ lut }), !current.key.isNeutral else { return image }
        return applyCube(current.data, to: image)
    }

    private func applyCube(_ data: Data, to image: CIImage) -> CIImage {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(Self.lutDimension)
        f.cubeData = data
        f.colorSpace = srgb
        return f.outputImage?.cropped(to: image.extent) ?? image
    }

    // MARK: Detail

    private func applyDetail(_ input: CIImage, settings s: ProcessingSettings, size: CGSize) -> CIImage {
        var image = input
        if s.sharpen > 0.01 {
            // Fine luminance detail only: no colour fringing, no halos.
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(s.sharpen * 0.55)
            f.radius = Float(1.1 * size.height / 1080)
            image = f.outputImage ?? image
        }
        if s.vignette > 0.01 {
            let f = CIFilter.vignetteEffect()
            f.inputImage = image
            f.center = CGPoint(x: size.width / 2, y: size.height / 2)
            f.radius = Float(hypot(size.width, size.height) * 0.42)
            f.intensity = Float(s.vignette * 0.35)
            f.falloff = 0.7
            image = f.outputImage ?? image
        }
        return image.cropped(to: input.extent)
    }

    // MARK: Side outputs

    private func publishHistogram(_ output: CVPixelBuffer) {
        guard let onHistogram else { return }
        let start: Bool = lock.locked {
            guard !histogramBusy else { return false }
            histogramBusy = true
            return true
        }
        guard start else { return }
        histogramQueue.async { [self] in
            onHistogram(histogram(of: output))
            lock.locked { histogramBusy = false }
        }
    }

    private func publishThumbnails(clean: CVPixelBuffer, settings s: ProcessingSettings, ev: Double, gains: SIMD3<Double>) {
        guard let onLookThumbnails else { return }
        let start: Bool = lock.locked {
            guard !thumbBusy else { return false }
            thumbBusy = true
            return true
        }
        guard start else { return }
        thumbQueue.async { [self] in
            defer { lock.locked { thumbBusy = false } }
            let full = CIImage(cvPixelBuffer: clean)
            let scale = 240 / full.extent.width
            var base = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            base = applyLight(base, settings: s, autoEV: ev, skinGains: gains)
            base = orient(base, settings: s, size: base.extent.size)
            let rect = base.extent
            var result: [LookStyle: CGImage] = [:]
            for look in LookStyle.allCases {
                let key = s.grade(for: look).key
                if thumbLUTs[look]?.key != key {
                    let floats = GradeEngine.buildLUT(key, dimension: 17)
                    thumbLUTs[look] = (key, floats.withUnsafeBufferPointer { Data(buffer: $0) })
                }
                var img = base
                if !key.isNeutral, let data = thumbLUTs[look]?.data {
                    let f = CIFilter.colorCubeWithColorSpace()
                    f.inputImage = base
                    f.cubeDimension = 17
                    f.cubeData = data
                    f.colorSpace = srgb
                    img = f.outputImage ?? base
                }
                if let cg = ciContext.createCGImage(img, from: rect, format: .RGBA8, colorSpace: srgb) {
                    result[look] = cg
                }
            }
            onLookThumbnails(result)
        }
    }

    private func histogram(of buffer: CVPixelBuffer) -> [[Float]] {
        let bins = 64
        let image = CIImage(cvPixelBuffer: buffer).applyingFilter("CILinearToSRGBToneCurve")
        let small = image.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let f = CIFilter.areaHistogram()
        f.inputImage = small
        f.extent = small.extent
        f.count = bins
        f.scale = 1
        guard let out = f.outputImage else { return [] }
        var data = [Float](repeating: 0, count: bins * 4)
        data.withUnsafeMutableBytes { ptr in
            ciContext.render(out, toBitmap: ptr.baseAddress!, rowBytes: bins * 4 * MemoryLayout<Float>.size,
                             bounds: CGRect(x: 0, y: 0, width: bins, height: 1), format: .RGBAf, colorSpace: nil)
        }
        var r = [Float](repeating: 0, count: bins), g = r, b = r, l = r
        for i in 0..<bins {
            r[i] = data[i * 4]; g[i] = data[i * 4 + 1]; b[i] = data[i * 4 + 2]
            l[i] = 0.2126 * r[i] + 0.7152 * g[i] + 0.0722 * b[i]
        }
        let peak = max(r.max() ?? 1, g.max() ?? 1, b.max() ?? 1, 1e-6)
        return [r, g, b, l].map { $0.map { min(1, $0 / peak) } }
    }

    // MARK: Snapshots

    func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        ciContext.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0,
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)), format: .RGBA8, colorSpace: srgb)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
