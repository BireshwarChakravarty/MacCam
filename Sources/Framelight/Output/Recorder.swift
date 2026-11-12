import Foundation
import AVFoundation

/// Records the processed video (what you see in the preview) to a movie file.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var url: URL?

    var isRecording: Bool { lock.locked { writer != nil } }

    func start(url: URL, size: CGSize, hevc: Bool) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let bitrate = Int(size.width * size.height * 30 * (hevc ? 0.10 : 0.16))
        let settings: [String: Any] = [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw CameraError("Can't record with these settings.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CameraError("Couldn't start recording.") }
        lock.locked {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.sessionStarted = false
            self.url = url
        }
    }

    func append(_ buffer: CVPixelBuffer, time: CMTime) {
        lock.locked {
            guard let writer, let input, let adaptor, writer.status == .writing else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: time)
                sessionStarted = true
            }
            if input.isReadyForMoreMediaData {
                adaptor.append(buffer, withPresentationTime: time)
            }
        }
    }

    func stop(completion: @escaping (URL?) -> Void) {
        let (writer, input, url): (AVAssetWriter?, AVAssetWriterInput?, URL?) = lock.locked {
            defer { self.writer = nil; self.input = nil; self.adaptor = nil }
            return (self.writer, self.input, self.url)
        }
        guard let writer, let input else { completion(nil); return }
        input.markAsFinished()
        writer.finishWriting {
            completion(writer.status == .completed ? url : nil)
        }
    }
}
