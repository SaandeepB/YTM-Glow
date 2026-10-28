// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YTMGlow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "YTMGlow", targets: ["YTMGlow"]),
    ],
    targets: [
        // UI-free logic: bridge server, protocol, lyrics, palette, beat envelope.
        .target(name: "YTMGlowCore"),
        // Menu bar app: overlays, popover, settings.
        .executableTarget(name: "YTMGlow", dependencies: ["YTMGlowCore"]),
        .testTarget(
            name: "YTMGlowCoreTests",
            dependencies: ["YTMGlowCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
