import SwiftUI

/// The processed video alone: no overlays, controls, compare split or histogram.
/// OBS captures this window and sends it to every app through "OBS Virtual Camera",
/// the way to use Framelight in FaceTime, Zoom or Meet without an Apple developer account.
struct OutputWindowView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black
            PreviewView(frames: model.outputs, device: model.processor.metalDevice)
                .aspectRatio(model.settings.outputSize.width / model.settings.outputSize.height, contentMode: .fit)
        }
        .ignoresSafeArea()
        .frame(minWidth: 320, minHeight: 180)
        .navigationTitle("Framelight Output")
    }
}

/// Step-by-step setup shown in the Studio tab.
struct OBSBridgeSteps: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Use in FaceTime, Zoom or Meet without a developer account").font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text("1. Open the Output window (button below) and leave it open. It can sit behind other windows.")
                Text("2. In OBS Studio (free, obsproject.com) add a source: **macOS Screen Capture → Window → Framelight Output**.")
                Text("3. Right-click the source → **Transform → Fit to Screen**, then click **Start Virtual Camera**.")
                Text("4. In FaceTime choose **Video → OBS Virtual Camera** (Zoom/Meet: pick it as the camera).")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Open Output Window") { openWindow(id: "output") }
        }
        .padding(.vertical, 2)
    }
}
