// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Bridge",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Bridge", targets: ["Bridge"]),
        .executable(name: "bridge-helper", targets: ["BridgeHelper"]),
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

        // Plain Swift models and logic: settings, projects, layouts, history, shell integration,
        // sandbox policies, SSH commands. No AppKit, no libghostty; unit-tested.
        .target(name: "BridgeCore"),

        // Argon2 (the reference implementation), for Vaultwarden accounts that use Argon2id.
        .target(
            name: "CArgon2",
            exclude: ["LICENSE", "README.md"],
            cSettings: [.define("ARGON2_NO_THREADS")]
        ),

        // Talking to the rest of the system: the shells' socket, processes, the Keychain,
        // Vaultwarden.
        .target(name: "BridgeSystem", dependencies: ["BridgeCore", "CArgon2"]),

        .executableTarget(
            name: "Bridge",
            dependencies: ["BridgeCore", "BridgeSystem", "BridgeTerm"]
        ),

        // Bundled as Contents/Helpers/bridge-helper: messages from bash, SSH password prompts,
        // and the guard that ends child processes when the app goes away.
        .executableTarget(name: "BridgeHelper"),

        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore", "BridgeSystem"]),
    ]
)
