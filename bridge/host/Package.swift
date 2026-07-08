// swift-tools-version:5.9
import PackageDescription

// zodl-bridge-host — the native-messaging helper of the Zodl Bridge (spec:
// docs/macos/ZODL_BRIDGE_SPEC.md). Deliberately outside the Xcode project:
// builds with SPM alone, no pbxproj involvement (plan §Phase A).
let package = Package(
    name: "zodl-bridge-host",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BridgeCore"),
        .executableTarget(name: "zodl-bridge-host", dependencies: ["BridgeCore"]),
        // Dev-only stand-in for Zodl's UDS listener (Phase B replaces it with the app).
        .executableTarget(name: "mock-zodl", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
    ]
)
