import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One round of face / body detection. Rects are normalized (0–1) with a bottom-left origin,
/// as Vision and Core Image use.
struct FramingDetection {
    var faces: [CGRect]
    var bodies: [CGRect]
    var time: Double
    var hands: [HandPose] = []
}

/// Software "Center Stage": turns face/body detections into a smoothly moving crop of the
/// full sensor image. A 4K sensor gives up to 2× lossless zoom into a 1080p output.
///
/// Framing is anchored on the face: it's what Vision finds most reliably, and its size says
/// how far away you are. At desk distance a webcam's body box already fills most of the
/// frame, so sizing the shot from the body alone would never zoom in.
final class AutoFramer {
    /// Critically damped spring: eases in and out with no overshoot and no velocity jumps.
    private struct Spring {
        var value: Double
        var velocity: Double = 0

        mutating func step(toward target: Double, omega: Double, dt: Double) {
            var remaining = dt
            while remaining > 1e-6 {                       // sub-step for stability on dropped frames
                let h = min(remaining, 1.0 / 240.0)
                let accel = omega * omega * (target - value) - 2 * omega * velocity
                velocity += accel * h
                value += velocity * h
                remaining -= h
            }
        }
    }

    private var centerX: Spring?
    private var centerY: Spring?
    private var height: Spring?
    /// Measurement-smoothed ideal shot (filters Vision's box noise).
    private var desired: CGRect?
    /// The shot the springs are heading to; only changes when you clearly move.
    private(set) var target: CGRect?
    private var lastSubjectTime: Double = -.infinity
    private var lastStepTime: Double?
    private var lastDetectionTime: Double?

    var current: CGRect? {
        guard let cx = centerX, let cy = centerY, let h = height else { return nil }
        return CGRect(x: cx.value - h.value * lastAspect / 2, y: cy.value - h.value / 2,
                      width: h.value * lastAspect, height: h.value)
    }
    private var lastAspect: CGFloat = 16.0 / 9.0

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
        centerX = nil
        centerY = nil
        height = nil
        desired = nil
        target = nil
        lastSubjectTime = -.infinity
        lastStepTime = nil
        lastDetectionTime = nil
    }

    /// Forgets the auto-framing target but keeps the camera "moving" smoothly from where it is.
    func clearTarget() {
        desired = nil
        target = nil
        lastSubjectTime = -.infinity
        lastDetectionTime = nil
    }

    /// Glides to an explicit crop (manual zoom/pan, shot presets) on the same springs.
    func follow(_ goal: CGRect, source: CGSize, aspect: CGFloat, now: Double, snappy: Bool) -> CGRect {
        let full = Self.fullCrop(source: source, aspect: aspect)
        let dt = min(0.25, max(0, now - (lastStepTime ?? (now - 1.0 / 30.0))))
        lastStepTime = now
        let aspectChanged = abs(lastAspect - aspect) > 0.001
        lastAspect = aspect
        if centerX == nil || height == nil || height!.value > Double(full.height) + 1 || aspectChanged {
            centerX = Spring(value: Double(goal.midX))
            centerY = Spring(value: Double(goal.midY))
            height = Spring(value: Double(goal.height))
        }
        let omega = snappy ? 14.0 : 4.5
        centerX!.step(toward: Double(goal.midX), omega: omega, dt: dt)
        centerY!.step(toward: Double(goal.midY), omega: omega, dt: dt)
        height!.step(toward: Double(goal.height), omega: omega * 0.8, dt: dt)
        let h = min(CGFloat(height!.value), full.height)
        return Self.clamp(CGRect(x: CGFloat(centerX!.value) - h * aspect / 2, y: CGFloat(centerY!.value) - h / 2,
                                 width: h * aspect, height: h), to: full)
    }

    /// Manual digital zoom / pan when auto framing is off.
    static func manualCrop(source: CGSize, aspect: CGFloat, zoom: Double, panX: Double, panY: Double) -> CGRect {
        let full = fullCrop(source: source, aspect: aspect)
        let z = CGFloat(max(1.0, zoom))
        let w = full.width / z, h = full.height / z
        let slackX = (full.width - w) / 2, slackY = (full.height - h) / 2
        let cx = full.midX + slackX * CGFloat(panX)
        let cy = full.midY + slackY * CGFloat(panY)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// Advances the smoothed crop by one frame. `now` is in seconds (any monotonic clock).
    func crop(source: CGSize, aspect: CGFloat, settings: ProcessingSettings,
              detection: FramingDetection?, now: Double) -> CGRect {
        let full = Self.fullCrop(source: source, aspect: aspect)
        let dt = min(0.25, max(0, now - (lastStepTime ?? (now - 1.0 / 30.0))))
        lastStepTime = now
        lastAspect = aspect

        if centerX == nil || height == nil || height!.value > Double(full.height) + 1 {
            centerX = Spring(value: Double(full.midX))
            centerY = Spring(value: Double(full.midY))
            height = Spring(value: Double(full.height))
        }

        // New detection: blend it into the smoothed ideal shot.
        if let detection, detection.time != lastDetectionTime {
            lastDetectionTime = detection.time
            if let proposed = Self.framing(for: detection, source: source, full: full, aspect: aspect, settings: settings) {
                lastSubjectTime = now
                if let d = desired, now - lastSubjectTimeBeforeGap < 1.0 {
                    desired = Self.lerp(d, proposed, 0.35)
                } else {
                    desired = proposed
                }
                lastSubjectTimeBeforeGap = now
            }
        }

        // Hold the shot until the ideal one is clearly different (hysteresis).
        if now - lastSubjectTime > 2.0 {
            target = full
            desired = nil
        } else if let d = desired {
            if let t = target, t != full, Self.isWithinDeadZone(d, t) {
                // Keep the shot steady.
            } else {
                target = d
            }
        }

        let goal = target ?? full
        let omega = 1.8 + settings.framingSpeed * 4.2           // rad/s: ~1.6 s to settle at default
        centerX!.step(toward: Double(goal.midX), omega: omega, dt: dt)
        centerY!.step(toward: Double(goal.midY), omega: omega, dt: dt)
        height!.step(toward: Double(goal.height), omega: omega * 0.65, dt: dt)   // zoom moves gentler than pan

        let h = min(max(CGFloat(height!.value), full.height / CGFloat(max(1.0, settings.maxZoom)) - 1), full.height)
        let rect = CGRect(x: CGFloat(centerX!.value) - h * aspect / 2, y: CGFloat(centerY!.value) - h / 2,
                          width: h * aspect, height: h)
        return Self.clamp(rect, to: full)
    }

    private var lastSubjectTimeBeforeGap: Double = -.infinity

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    // MARK: Shot composition

    /// The ideal crop for one detection, or nil when nobody was found.
    static func framing(for d: FramingDetection, source: CGSize, full: CGRect, aspect: CGFloat,
                        settings: ProcessingSettings) -> CGRect? {
        func px(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * source.width, y: r.minY * source.height,
                   width: r.width * source.width, height: r.height * source.height)
        }
        let area: (CGRect) -> CGFloat = { $0.width * $0.height }
        var faces = d.faces.map(px).filter { $0.width > 4 && $0.height > 4 }
        let bodies = d.bodies.map(px).filter { $0.width > 4 && $0.height > 4 }

        // No face (turned away, backlit): estimate the head from the top of the body box.
        if faces.isEmpty {
            faces = bodies.map { b in
                let h = min(b.height * 0.22, b.width * 0.40)
                return CGRect(x: b.midX - h * 0.4, y: b.maxY - h * 1.05, width: h * 0.8, height: h)
            }
        }
        guard !faces.isEmpty else { return nil }

        let loose = CGFloat(1 - settings.framingTightness)    // 0 = tight, 1 = loose
        let subject: CGRect                                     // the face(s) to compose around
        let heightInFaces: CGFloat                              // crop height in face heights
        let faceLine: CGFloat                                   // face centre, as a fraction of crop height from the bottom
        let faceH: CGFloat

        switch settings.framingSubject {
        case .face:
            subject = faces.max { area($0) < area($1) }!
            faceH = subject.height
            heightInFaces = 1.9 + 1.2 * loose                   // head with a little shoulder
            faceLine = 0.60
        case .upperBody:
            subject = faces.max { area($0) < area($1) }!
            faceH = subject.height
            heightInFaces = 2.7 + 1.2 * loose                   // head, shoulders and chest
            faceLine = 0.68
        case .group:
            subject = faces.dropFirst().reduce(faces[0]) { $0.union($1) }
            faceH = faces.map(\.height).reduce(0, +) / CGFloat(faces.count)
            heightInFaces = 2.8 + 1.4 * loose
            faceLine = 0.64
        }

        var h = subject.height - faceH + faceH * heightInFaces
        var w = h * aspect
        // Leave room at the sides for shoulders / everyone in a group.
        let minWidth = subject.width + faceH * (2.4 + 1.6 * loose)
        if w < minWidth {
            w = minWidth
            h = w / aspect
        }

        let minHeight = full.height / CGFloat(max(1.0, settings.maxZoom))
        h = min(max(h, minHeight), full.height)
        w = h * aspect

        let rect = CGRect(x: subject.midX - w / 2, y: subject.midY - h * faceLine, width: w, height: h)
        return clamp(rect, to: full)
    }

    static func isWithinDeadZone(_ a: CGRect, _ b: CGRect) -> Bool {
        let moveTolerance = b.height * 0.07
        let sizeTolerance = b.height * 0.10
        return abs(a.midX - b.midX) < moveTolerance
            && abs(a.midY - b.midY) < moveTolerance
            && abs(a.height - b.height) < sizeTolerance
    }

    static func clamp(_ r: CGRect, to bounds: CGRect) -> CGRect {
        var r = r
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }
}
