import SwiftUI

/// Diagnostics for power users: what the camera reports about itself.
struct InfoPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controls: UVCControlStore
    @State private var showRaw = false

    var body: some View {
        Form {
            Section("Stream") {
                LabeledContent("Camera", value: model.camera.activeDevice?.localizedName ?? "—")
                LabeledContent("Capture format", value: model.camera.formats.first { $0.id == model.camera.activeFormatID }?.label ?? "—")
                LabeledContent("Measured frame rate", value: String(format: "%.1f fps", model.camera.measuredFPS))
                if let stats = model.stats {
                    LabeledContent("Processing time", value: String(format: "%.1f ms avg · %.1f ms p95", stats.pipelineMs, stats.pipelineP95Ms))
                    LabeledContent("Frame budget used", value: String(format: "%.0f%% of %.0f ms",
                                                                      stats.pipelineMs / (1000 / max(model.camera.measuredFPS, 1)) * 100,
                                                                      1000 / max(model.camera.measuredFPS, 1)))
                    LabeledContent("GPU", value: stats.gpuName)
                    LabeledContent("Sensor image", value: "\(Int(stats.sourceSize.width))×\(Int(stats.sourceSize.height))")
                    LabeledContent("Output", value: "\(Int(stats.outputSize.width))×\(Int(stats.outputSize.height))")
                    LabeledContent("Current zoom", value: String(format: "%.2f×", stats.zoom))
                    LabeledContent("Crop", value: String(format: "%.0f,%.0f  %.0f×%.0f", stats.crop.minX, stats.crop.minY,
                                                         stats.crop.width, stats.crop.height))
                }
            }

            Section {
                Text("Framelight --benchmark --out ~/Desktop/framelight-benchmark.md")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("Benchmark")
            } footer: {
                Text("Run the app binary (Framelight.app/Contents/MacOS/Framelight) with this flag in Terminal to measure speed and quality on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let device = controls.device {
                Section("USB / UVC") {
                    LabeledContent("Product", value: device.name)
                    LabeledContent("Vendor:Product ID", value: device.idString)
                    LabeledContent("Location ID", value: String(format: "0x%08X", device.locationID))
                    if let serial = device.serialNumber { LabeledContent("Serial", value: serial) }
                    LabeledContent("UVC version", value: device.topology.versionString)
                    LabeledContent("Control interface", value: "#\(device.interfaceNumber)")
                    if let ct = device.topology.cameraTerminalID {
                        LabeledContent("Camera Terminal", value: String(format: "ID %d · controls 0x%06llX", ct, device.topology.cameraControls))
                    }
                    if let pu = device.topology.processingUnitID {
                        LabeledContent("Processing Unit", value: String(format: "ID %d · controls 0x%06llX", pu, device.topology.processingControls))
                    }
                    LabeledContent("Supported controls", value: "\(controls.supportedStates.count)")
                }

                if !device.topology.extensionUnits.isEmpty {
                    Section {
                        ForEach(device.topology.extensionUnits) { xu in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unit \(xu.unitID) · \(xu.numControls) controls")
                                Text(xu.guid.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    } header: {
                        Text("Vendor Extension Units")
                    } footer: {
                        Text("Vendor-specific features (e.g. HDR or face-AE on some chipsets) live here. Their meaning is undocumented per manufacturer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Probe All Controls (ignore descriptor)") {
                        Task { await controls.load(probeAll: true) }
                    }
                    .help("Some cameras under-report their controls. This tries every standard control directly.")
                    DisclosureGroup("Raw Video Control descriptor", isExpanded: $showRaw) {
                        Text(device.topology.rawDescriptor.hexString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
