// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Bridge",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Bridge", targets: ["Bridge"]),
    ],
    targets: [
        // libghostty, built from vendor/ghostty by scripts/build-ghostty.sh.
        .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework"),

        // The only module that talks to the libghostty C API: the app, its config and the
        // terminal surface view (Metal-rendered by libghostty on its own renderer thread).
        .target(
            name: "BridgeTerm",
            dependencies: ["GhosttyKit"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
        ),

        // Plain Swift models: settings, color schemes, the split tree. No AppKit, no libghostty.
        .target(name: "BridgeCore"),

        .executableTarget(
            name: "Bridge",
            dependencies: ["BridgeCore", "BridgeTerm"]
        ),

        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
    ]
)
