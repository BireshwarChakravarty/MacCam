// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MacCam",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "MacCam",
            path: "Sources/MacCam",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("SystemExtensions"),
                .linkedFramework("Vision"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
