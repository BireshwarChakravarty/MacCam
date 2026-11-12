import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Metal
import AppKit
import QuartzCore

/// The software pipeline: background effects → framing crop → colour grade → output buffer.
/// Every consumer (preview, recorder, virtual camera) receives the same processed frame.
final class FrameProcessor: @unchecked Sendable {
    let ciContext: CIContext
    let metalDevice: MTLDevice?

    private let lock = NSLock()
    private var _settings = ProcessingSettings()
    private let vision = VisionAnalyzer()
    private let framer = AutoFramer()

    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private var virtualPool: CVPixelBufferPool?
    private var backgroundImage: CIImage?
    private var backgroundImagePath: String?
    private var frameCount = 0
    private var lastCrop: CGRect = .zero
    private var needsFramerReset = false
    private let histogramQueue = DispatchQueue(label: "framelight.histogram", qos: .utility)
    private var histogramBusy = false

    /// Called on the capture queue for every processed frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// Receives a 1920×1080 copy when the virtual camera needs a different size than the output.
    var onVirtualCameraFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var virtualCameraEnabled = false
    /// Called a few times per second with RGB + luma histograms (64 bins each).
    var onHistogram: (([[Float]]) -> Void)?
    var onStats: ((FrameStats) -> Void)?

    struct FrameStats {
        var sourceSize: CGSize
        var outputSize: CGSize
        var crop: CGRect
        var zoom: Double
        var facesDetected: Int
    }

    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    init() {
        metalDevice = MTLCreateSystemDefaultDevice()
        if let metalDevice {
            ciContext = CIContext(mtlDevice: metalDevice, options: [.cacheIntermediates: false, .name: "Framelight"])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
    }

    var settings: ProcessingSettings {
        get { lock.locked { _settings } }
        set {
            lock.locked {
                if newValue.autoFraming != _settings.autoFraming { needsFramerReset = true }
                if newValue.backgroundMode == .none { vision.clearMask() }
                _settings = newValue
            }
        }
    }

    // MARK: Per-frame

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let input = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let (s, resetFramer): (ProcessingSettings, Bool) = lock.locked {
            defer { needsFramerReset = false }
            return (_settings, needsFramerReset)
        }
        if resetFramer { framer.reset() }
        frameCount &+= 1

        let sourceSize = CGSize(width: CVPixelBufferGetWidth(input), height: CVPixelBufferGetHeight(input))
        let outSize = s.outputResolution.size
        let aspect = outSize.width / outSize.height

        vision.submit(input, detect: s.autoFraming, segment: s.backgroundMode != .none)

        var image = CIImage(cvPixelBuffer: input)

        // 1. Background effect (in source coordinates, where the mask lives).
        if s.backgroundMode != .none, let maskBuffer = vision.latestMask {
            image = applyBackground(to: image, mask: maskBuffer, settings: s)
        }

        // 2. Framing: auto (Center Stage) or manual digital zoom/pan.
        let detection = s.autoFraming ? vision.latestDetection : nil
        let crop: CGRect
        if s.autoFraming {
            crop = framer.crop(source: sourceSize, aspect: aspect, settings: s, detection: detection,
                               now: CACurrentMediaTime())
        } else {
            crop = AutoFramer.manualCrop(source: sourceSize, aspect: aspect, zoom: s.digitalZoom, panX: s.panX, panY: s.panY)
        }
        lastCrop = crop
        image = scale(image, crop: crop, to: outSize)

        // 3. Colour grade on the (smaller) output-sized image.
        if !s.isColorNeutral {
            image = colorGrade(image, settings: s, size: outSize)
        }

        // 4. Orientation.
        if s.mirror || s.flipVertical {
            let t = CGAffineTransform(translationX: s.mirror ? outSize.width : 0, y: s.flipVertical ? outSize.height : 0)
                .scaledBy(x: s.mirror ? -1 : 1, y: s.flipVertical ? -1 : 1)
            image = image.transformed(by: t)
        }
        image = image.cropped(to: CGRect(origin: .zero, size: outSize))

        // 5. Render.
        guard let output = makeBuffer(size: outSize, pool: &pool, poolSize: &poolSize) else { return }
        ciContext.render(image, to: output, bounds: CGRect(origin: .zero, size: outSize), colorSpace: srgb)
        onFrame?(output, time)

        if virtualCameraEnabled, let onVirtualCameraFrame {
            let vSize = CGSize(width: Int(VirtualCameraConfig.width), height: Int(VirtualCameraConfig.height))
            if vSize == outSize {
                onVirtualCameraFrame(output, time)
            } else {
                var vPoolSize = vSize
                if let vbuf = makeBuffer(size: vSize, pool: &virtualPool, poolSize: &vPoolSize) {
                    let scaled = CIImage(cvPixelBuffer: output)
                        .transformed(by: CGAffineTransform(scaleX: vSize.width / outSize.width, y: vSize.height / outSize.height))
                    ciContext.render(scaled, to: vbuf, bounds: CGRect(origin: .zero, size: vSize), colorSpace: srgb)
                    onVirtualCameraFrame(vbuf, time)
                }
            }
        }

        if frameCount % 8 == 0 {
            // GPU readback for the histogram happens off the video thread so it can't stall frames.
            if let onHistogram, !histogramBusy {
                histogramBusy = true
                histogramQueue.async { [weak self] in
                    guard let self else { return }
                    onHistogram(self.histogram(of: output))
                    self.histogramBusy = false
                }
            }
            onStats?(FrameStats(sourceSize: sourceSize, outputSize: outSize, crop: crop,
                                zoom: Double(AutoFramer.fullCrop(source: sourceSize, aspect: aspect).height / max(1, crop.height)),
                                facesDetected: max(detection?.faces.count ?? 0, detection?.bodies.count ?? 0)))
        }
    }

    // MARK: Stages

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
            return f.outputImage ?? moved.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return moved.transformed(by: CGAffineTransform(scaleX: size.width / crop.width, y: scale))
    }

    private func applyBackground(to image: CIImage, mask maskBuffer: CVPixelBuffer, settings s: ProcessingSettings) -> CIImage {
        let extent = image.extent
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        mask = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                                      y: extent.height / mask.extent.height))
        // Feather the edge slightly so hair doesn't look cut out.
        mask = mask.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: extent)

        let background: CIImage
        switch s.backgroundMode {
        case .none:
            return image
        case .blur:
            // Blur at quarter resolution for speed, then scale back up.
            let down: CGFloat = 0.25
            let sigma = 4 + s.backgroundBlur * 26
            background = image.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: down, y: down))
                .applyingGaussianBlur(sigma: sigma)
                .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
                .cropped(to: extent)
        case .color:
            background = CIImage(color: CIColor(cgColor: NSColor(hex: s.backgroundColorHex).cgColor)).cropped(to: extent)
        case .image:
            if let bg = loadBackgroundImage(path: s.backgroundImagePath) {
                let scale = max(extent.width / bg.extent.width, extent.height / bg.extent.height)
                let scaled = bg.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let dx = (extent.width - scaled.extent.width) / 2 - scaled.extent.minX
                let dy = (extent.height - scaled.extent.height) / 2 - scaled.extent.minY
                background = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: extent)
            } else {
                background = CIImage(color: CIColor(red: 0.1, green: 0.12, blue: 0.16)).cropped(to: extent)
            }
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = background
        blend.maskImage = mask
        return blend.outputImage ?? image
    }

    private func loadBackgroundImage(path: String?) -> CIImage? {
        guard let path else { return nil }
        if path == backgroundImagePath, let backgroundImage { return backgroundImage }
        backgroundImagePath = path
        backgroundImage = CIImage(contentsOf: URL(fileURLWithPath: path))
        return backgroundImage
    }

    private func colorGrade(_ input: CIImage, settings s: ProcessingSettings, size: CGSize) -> CIImage {
        var image = input

        if s.denoise > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = image
            f.noiseLevel = Float(0.005 + s.denoise * 0.04)
            f.sharpness = 0.4
            image = f.outputImage ?? image
        }

        if s.warmth != 0 || s.tint != 0 {
            // Higher "neutral" temperature => the image is rendered warmer.
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500 + CGFloat(s.warmth) * 35, y: CGFloat(s.tint) * 1.0)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            image = f.outputImage ?? image
        }

        if s.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(s.exposure)
            image = f.outputImage ?? image
        }

        if s.highlights != 1 || s.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = Float(s.highlights)
            f.shadowAmount = Float(s.shadows)
            image = f.outputImage ?? image
        }

        if s.brightness != 0 || s.contrast != 1 || s.saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.brightness = Float(s.brightness)
            f.contrast = Float(s.contrast)
            f.saturation = Float(s.saturation)
            image = f.outputImage ?? image
        }

        if s.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = image
            f.amount = Float(s.vibrance)
            image = f.outputImage ?? image
        }

        if s.look != .none {
            let graded = applyLook(s.look, to: image)
            if s.lookIntensity >= 0.999 {
                image = graded
            } else {
                let f = CIFilter.dissolveTransition()
                f.inputImage = image
                f.targetImage = graded
                f.time = Float(s.lookIntensity)
                image = f.outputImage ?? graded
            }
        }

        if s.sharpen > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(s.sharpen * 0.8)
            f.radius = 1.5
            image = f.outputImage ?? image
        }

        if s.vignette > 0 {
            let f = CIFilter.vignette()
            f.inputImage = image
            f.intensity = Float(s.vignette * 1.2)
            f.radius = Float(max(size.width, size.height) / 900)
            image = f.outputImage ?? image
        }

        return image.cropped(to: input.extent)
    }

    private func applyLook(_ look: Look, to image: CIImage) -> CIImage {
        switch look {
        case .none:
            return image
        case .cinematic:
            // Teal shadows / warm highlights with a gentle S-curve.
            let curve = CIFilter.toneCurve()
            curve.inputImage = image
            curve.point0 = CGPoint(x: 0, y: 0.03)
            curve.point1 = CGPoint(x: 0.25, y: 0.21)
            curve.point2 = CGPoint(x: 0.5, y: 0.5)
            curve.point3 = CGPoint(x: 0.75, y: 0.80)
            curve.point4 = CGPoint(x: 1, y: 0.97)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = curve.outputImage ?? image
            matrix.rVector = CIVector(x: 1.06, y: 0.0, z: -0.02, w: 0)
            matrix.gVector = CIVector(x: 0.0, y: 1.0, z: 0.02, w: 0)
            matrix.bVector = CIVector(x: -0.04, y: 0.04, z: 0.98, w: 0)
            matrix.biasVector = CIVector(x: 0.0, y: 0.005, z: 0.02, w: 0)
            return matrix.outputImage ?? image
        case .warmFilm:
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 7600, y: 8)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            let fade = CIFilter.colorControls()
            fade.inputImage = f.outputImage ?? image
            fade.contrast = 0.94
            fade.saturation = 0.92
            fade.brightness = 0.015
            return fade.outputImage ?? image
        case .chrome: return image.applyingFilter("CIPhotoEffectChrome")
        case .fade: return image.applyingFilter("CIPhotoEffectFade")
        case .instant: return image.applyingFilter("CIPhotoEffectInstant")
        case .process: return image.applyingFilter("CIPhotoEffectProcess")
        case .transfer: return image.applyingFilter("CIPhotoEffectTransfer")
        case .mono: return image.applyingFilter("CIPhotoEffectMono")
        case .noir: return image.applyingFilter("CIPhotoEffectNoir")
        case .tonal: return image.applyingFilter("CIPhotoEffectTonal")
        }
    }

    // MARK: Buffers

    private func makeBuffer(size: CGSize, pool: inout CVPixelBufferPool?, poolSize: inout CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                                    attrs as CFDictionary, &newPool)
            pool = newPool
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        if let buffer {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        return buffer
    }

    // MARK: Histogram

    private func histogram(of buffer: CVPixelBuffer) -> [[Float]] {
        let bins = 64
        let image = CIImage(cvPixelBuffer: buffer)
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
