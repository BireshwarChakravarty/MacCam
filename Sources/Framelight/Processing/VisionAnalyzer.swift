import Foundation
import Vision
import CoreVideo
import QuartzCore

/// Runs face / body detection and person segmentation off the capture thread.
/// Results are slightly behind the live frame, which is fine for framing and masks.
final class VisionAnalyzer: @unchecked Sendable {
    typealias Detection = FramingDetection

    private let detectQueue = DispatchQueue(label: "framelight.vision.detect", qos: .userInitiated)
    private let segmentQueue = DispatchQueue(label: "framelight.vision.segment", qos: .userInitiated)
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
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
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

    func submit(_ pixelBuffer: CVPixelBuffer, detect: Bool, segment: Bool, hands: Bool = false) {
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
                    try? handler.perform(hands ? [faceRequest, bodyRequest, handRequest] : [faceRequest, bodyRequest])
                    let faces = (faceRequest.results ?? []).filter { $0.confidence > 0.5 }.map(\.boundingBox)
                    let bodies = (bodyRequest.results ?? []).filter { $0.confidence > 0.4 }.map(\.boundingBox)
                    let poses = hands ? (handRequest.results ?? []).compactMap(VisionAnalyzer.handPose) : []
                    lock.locked {
                        _detection = Detection(faces: faces, bodies: bodies, time: CACurrentMediaTime(), hands: poses)
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

    private static func handPose(_ o: VNHumanHandPoseObservation) -> HandPose? {
        guard let points = try? o.recognizedPoints(.all) else { return nil }
        func p(_ j: VNHumanHandPoseObservation.JointName) -> HandPose.Point? {
            guard let v = points[j] else { return nil }
            return HandPose.Point(x: Double(v.location.x), y: Double(v.location.y), confidence: Double(v.confidence))
        }
        return HandPose(wrist: p(.wrist), thumbTip: p(.thumbTip), thumbMP: p(.thumbMP),
                        indexTip: p(.indexTip), indexPIP: p(.indexPIP),
                        middleTip: p(.middleTip), middlePIP: p(.middlePIP),
                        ringTip: p(.ringTip), ringPIP: p(.ringPIP),
                        littleTip: p(.littleTip), littlePIP: p(.littlePIP))
    }
}
