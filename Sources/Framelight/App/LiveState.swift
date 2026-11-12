import SwiftUI

/// Fast-changing readouts (histogram, framing stats, frame rate, look thumbnails).
/// Kept apart from AppModel so they only redraw the small views that show them,
/// not the whole window and its sidebar of controls.
@MainActor
final class LiveState: ObservableObject {
    @Published var histogram: [[Float]] = []
    @Published var stats: FrameProcessor.FrameStats?
    @Published var lookThumbnails: [LookStyle: NSImage] = [:]
    @Published var fps: Double = 0

    /// Publishes stats only when something visible changed, so overlays don't redraw for noise.
    func update(_ new: FrameProcessor.FrameStats) {
        guard let old = stats else { stats = new; return }
        let changed = abs(old.zoom - new.zoom) > 0.01
            || old.facesDetected != new.facesDetected
            || abs(old.autoExposure - new.autoExposure) > 0.03
            || old.skinCorrection != new.skinCorrection
            || abs(old.pipelineMs - new.pipelineMs) > 0.3
            || old.outputSize != new.outputSize
            || old.sourceSize != new.sourceSize
        if changed { stats = new }
    }
}

/// Status pills over the video.
struct StatusChips: View {
    @ObservedObject var live: LiveState
    let autoFraming: Bool
    let privacy: Bool
    let virtualCameraLive: Bool

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Text(String(format: "%.0f fps", live.fps))
                    .monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                if privacy {
                    Label("Privacy on", systemImage: "eye.slash.fill")
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassEffect(.regular.tint(.orange.opacity(0.35)), in: Capsule())
                }
                if virtualCameraLive {
                    Label("Virtual Cam Live", systemImage: "dot.radiowaves.left.and.right")
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassEffect(.regular.tint(.green.opacity(0.35)), in: Capsule())
                }
                if autoFraming {
                    framingChip
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                }
            }
            .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder private var framingChip: some View {
        if let stats = live.stats {
            if stats.facesDetected > 0 && stats.zoom < 1.06 {
                Label("Auto Framing · you're close to the camera: sit back a little for room to follow",
                      systemImage: "arrow.down.backward.and.arrow.up.forward")
            } else if stats.facesDetected > 0 {
                Text(String(format: "Auto Framing · %.2f× · %@", stats.zoom,
                            stats.facesDetected == 1 ? "1 person" : "\(stats.facesDetected) people"))
                    .monospacedDigit()
            } else {
                Label("Auto Framing · looking for a face", systemImage: "person.fill.questionmark")
            }
        } else {
            Label("Auto Framing", systemImage: "person.crop.square.filled.and.at.rectangle")
        }
    }
}

struct HistogramOverlay: View {
    @ObservedObject var live: LiveState
    var body: some View {
        if !live.histogram.isEmpty { HistogramView(channels: live.histogram) }
    }
}

/// A caption that depends on live stats (e.g. "Correcting +0.4 EV").
struct LiveCaption: View {
    @ObservedObject var live: LiveState
    let text: (FrameProcessor.FrameStats?) -> String
    var body: some View {
        Text(text(live.stats)).font(.caption).foregroundStyle(.secondary)
    }
}
