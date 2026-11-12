import Foundation
import Vision
import CoreVideo
import QuartzCore

/// Runs face / body detection and person segmentation off the capture thread.
/// Results are slightly behind the live frame, which is fine for framing and masks.
final class VisionAnalyzer: @unchecked Sendable {
    struct Detection {
        var faces: [CGRect]      // normalized, bottom-left origin
        var bodies: [CGRect]     // normalized, bottom-left origin
        var time: CFTimeInterval
    }

    private let detectQueue = DispatchQueue(label: "maccam.vision.detect", qos: .userInitiated)
    private let segmentQueue = DispatchQueue(label: "maccam.vision.segment", qos: .userInitiated)
    private let lock = NSLock()

    private var detecting = false
    private var segmenting = false
    private var lastDetectTime: CFTimeInterval = 0
    private var _detection: Detection?
    private var _mask: CVPixelBuffer?

    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let bodyRequest: VNDetectHumanRectanglesRequest = {
        let r = VNDetectHumanRectanglesRequest()
        r.upperBodyOnly = true
        return r
    }()
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()

    var latestDetection: Detection? { lock.locked { _detection } }
    var latestMask: CVPixelBuffer? { lock.locked { _mask } }

    func clearMask() { lock.locked { _mask = nil } }

    func submit(_ pixelBuffer: CVPixelBuffer, detect: Bool, segment: Bool) {
        let now = CACurrentMediaTime()

        if detect {
            let start: Bool = lock.locked {
                guard !detecting, now - lastDetectTime > 1.0 / 12.0 else { return false }
                detecting = true
                lastDetectTime = now
                return true
            }
            if start {
                detectQueue.async { [self] in
                    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
                    try? handler.perform([faceRequest, bodyRequest])
                    let faces = (faceRequest.results ?? []).filter { $0.confidence > 0.5 }.map(\.boundingBox)
                    let bodies = (bodyRequest.results ?? []).filter { $0.confidence > 0.4 }.map(\.boundingBox)
                    lock.locked {
                        _detection = Detection(faces: faces, bodies: bodies, time: CACurrentMediaTime())
                        detecting = false
                    }
                }
            }
        }

        if segment {
            let start: Bool = lock.locked {
                guard !segmenting else { return false }
                segmenting = true
                return true
            }
            if start {
                segmentQueue.async { [self] in
                    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
                    try? handler.perform([segmentationRequest])
                    let mask = segmentationRequest.results?.first?.pixelBuffer
                    lock.locked {
                        if let mask { _mask = mask }
                        segmenting = false
                    }
                }
            }
        }
    }
}
