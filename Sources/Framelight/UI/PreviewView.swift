import SwiftUI
import MetalKit
import CoreImage

/// GPU preview of the processed output, drawn at display refresh rate.
struct PreviewView: NSViewRepresentable {
    let frames: FrameStore
    let context: CIContext
    let device: MTLDevice?

    func makeCoordinator() -> PreviewRenderer {
        PreviewRenderer(frames: frames, context: context, device: device)
    }

    func makeNSView(context ctx: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: ctx.coordinator.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.layer?.isOpaque = true
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.delegate = ctx.coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}

final class PreviewRenderer: NSObject, MTKViewDelegate {
    let frames: FrameStore
    let context: CIContext
    let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var lastGeneration = -1
    private var lastBuffer: CVPixelBuffer?
    private var needsRedraw = true
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(frames: FrameStore, context: CIContext, device: MTLDevice?) {
        self.frames = frames
        self.context = context
        self.device = device ?? MTLCreateSystemDefaultDevice()
        self.commandQueue = self.device?.makeCommandQueue()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsRedraw = true
    }

    func draw(in view: MTKView) {
        if let next = frames.take(after: lastGeneration) {
            lastBuffer = next.0
            lastGeneration = next.1
        } else if !needsRedraw {
            return
        }
        guard let buffer = lastBuffer,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        needsRedraw = false

        let size = view.drawableSize
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(size.width / image.extent.width, size.height / image.extent.height)
        let w = image.extent.width * scale, h = image.extent.height * scale
        let fitted = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (size.width - w) / 2, y: (size.height - h) / 2))
        let canvas = CGRect(origin: .zero, size: size)
        let composed = fitted.composited(over: CIImage(color: .black).cropped(to: canvas))

        let destination = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                              pixelFormat: view.colorPixelFormat, commandBuffer: commandBuffer) {
            drawable.texture
        }
        destination.colorSpace = colorSpace
        _ = try? context.startTask(toRender: composed, to: destination)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// Rule-of-thirds grid drawn over the fitted video rect.
struct GridOverlay: View {
    let aspect: CGFloat

    var body: some View {
        GeometryReader { geo in
            let rect = fittedRect(in: geo.size)
            Path { p in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                    p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let scale = min(size.width / aspect, size.height)
        let w = scale * aspect, h = scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// Live RGB + luma histogram.
struct HistogramView: View {
    let channels: [[Float]]

    var body: some View {
        Canvas { ctx, size in
            guard channels.count == 4 else { return }
            let colors: [Color] = [.red, .green, .blue, .white]
            for (i, data) in channels.enumerated() where !data.isEmpty {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (j, v) in data.enumerated() {
                    let x = size.width * CGFloat(j) / CGFloat(max(1, data.count - 1))
                    path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(v))))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(colors[i].opacity(i == 3 ? 0.25 : 0.4)))
            }
        }
        .frame(width: 200, height: 70)
        .padding(8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        .allowsHitTesting(false)
    }
}
