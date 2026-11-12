// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Framelight",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Framelight",
            path: "Sources/Framelight",
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
