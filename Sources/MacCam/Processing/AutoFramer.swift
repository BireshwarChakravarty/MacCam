import Foundation
import CoreGraphics
import QuartzCore

/// Software "Center Stage": turns face/body detections into a smoothly moving crop
/// of the full sensor image. A 4K sensor gives up to 2× lossless zoom into a 1080p output.
final class AutoFramer {
    private var current: CGRect?
    private var target: CGRect?
    private var lastSubjectTime: CFTimeInterval = 0
    private var lastStepTime: CFTimeInterval = 0
    private var lastDetectionTime: CFTimeInterval = 0

    /// Largest rect of the output aspect ratio that fits in the source.
    static func fullCrop(source: CGSize, aspect: CGFloat) -> CGRect {
        if source.width / source.height > aspect {
            let w = source.height * aspect
            return CGRect(x: (source.width - w) / 2, y: 0, width: w, height: source.height)
        } else {
            let h = source.width / aspect
            return CGRect(x: 0, y: (source.height - h) / 2, width: source.width, height: h)
        }
    }

    func reset() {
        current = nil
        target = nil
    }

    /// Manual digital zoom / pan when auto framing is off.
    static func manualCrop(source: CGSize, aspect: CGFloat, zoom: Double, panX: Double, panY: Double) -> CGRect {
        let full = fullCrop(source: source, aspect: aspect)
        let z = max(1.0, zoom)
        let w = full.width / z, h = full.height / z
        let slackX = (full.width - w) / 2, slackY = (full.height - h) / 2
        let cx = full.midX + slackX * panX
        let cy = full.midY + slackY * panY
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    func crop(source: CGSize, aspect: CGFloat, settings: ProcessingSettings,
              detection: VisionAnalyzer.Detection?) -> CGRect {
        let now = CACurrentMediaTime()
        let full = Self.fullCrop(source: source, aspect: aspect)
        let dt = lastStepTime == 0 ? 1.0 / 30.0 : min(0.25, now - lastStepTime)
        lastStepTime = now

        if current == nil || current!.width > full.width + 1 || current!.height > full.height + 1 {
            current = full
        }

        // Only reconsider the target when a new detection arrives.
        if let detection, detection.time != lastDetectionTime {
            lastDetectionTime = detection.time
            if let subject = subjectRect(detection, source: source, mode: settings.framingSubject) {
                lastSubjectTime = now
                let proposed = framing(for: subject, full: full, aspect: aspect, settings: settings)
                if let t = target, isWithinDeadZone(proposed, t) {
                    // Keep the shot steady for small movements.
                } else {
                    target = proposed
                }
            }
        }

        // Nobody in view for a while: drift back out to the full shot.
        if now - lastSubjectTime > 2.5 {
            target = full
        }

        guard let target, let cur = current else { return full }
        let rate = 1.2 + settings.framingSpeed * 5.0
        let alpha = CGFloat(1 - exp(-dt * rate))
        let next = CGRect(
            x: cur.minX + (target.minX - cur.minX) * alpha,
            y: cur.minY + (target.minY - cur.minY) * alpha,
            width: cur.width + (target.width - cur.width) * alpha,
            height: cur.height + (target.height - cur.height) * alpha)
        current = clamp(next, to: full)
        return current!
    }

    private func subjectRect(_ d: VisionAnalyzer.Detection, source: CGSize, mode: FramingSubject) -> CGRect? {
        func px(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * source.width, y: r.minY * source.height,
                   width: r.width * source.width, height: r.height * source.height)
        }
        let faces = d.faces.map(px)
        let bodies = d.bodies.map(px)

        switch mode {
        case .face:
            return faces.max { $0.width * $0.height < $1.width * $1.height }
                ?? bodies.max { $0.width * $0.height < $1.width * $1.height }
        case .upperBody:
            if let body = bodies.max(by: { $0.width * $0.height < $1.width * $1.height }) { return body }
            // Estimate shoulders from a face when the body detector misses.
            if let f = faces.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                return CGRect(x: f.midX - f.width * 1.6, y: f.minY - f.height * 1.6,
                              width: f.width * 3.2, height: f.height * 2.8)
            }
            return nil
        case .group:
            let all = faces + bodies
            guard var u = all.first else { return nil }
            for r in all.dropFirst() { u = u.union(r) }
            return u
        }
    }

    private func framing(for subject: CGRect, full: CGRect, aspect: CGFloat, settings: ProcessingSettings) -> CGRect {
        let loose = 1 - settings.framingTightness
        var h: CGFloat
        var centerY: CGFloat
        switch settings.framingSubject {
        case .face:
            h = subject.height * (2.4 + 3.0 * loose)
            centerY = subject.midY - h * 0.10          // eyes in the upper third
        case .upperBody:
            h = subject.height * (1.25 + 0.9 * loose)
            centerY = subject.midY + subject.height * 0.05
        case .group:
            h = subject.height * (1.35 + 0.8 * loose)
            centerY = subject.midY
        }
        var w = h * aspect
        let minWidth = subject.width * (1.25 + 0.6 * loose)
        if w < minWidth {
            w = minWidth
            h = w / aspect
        }

        let minHeight = full.height / CGFloat(max(1.0, settings.maxZoom))
        h = min(max(h, minHeight), full.height)
        w = h * aspect
        return clamp(CGRect(x: subject.midX - w / 2, y: centerY - h / 2, width: w, height: h), to: full)
    }

    private func isWithinDeadZone(_ a: CGRect, _ b: CGRect) -> Bool {
        let moveTolerance = b.height * 0.07
        let sizeTolerance = b.height * 0.10
        return abs(a.midX - b.midX) < moveTolerance
            && abs(a.midY - b.midY) < moveTolerance
            && abs(a.height - b.height) < sizeTolerance
    }

    private func clamp(_ r: CGRect, to bounds: CGRect) -> CGRect {
        var r = r
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }
}
