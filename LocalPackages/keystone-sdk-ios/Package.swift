// swift-tools-version: 6.0
import PackageDescription

// Local override of keystone-sdk-ios 0.8.6 (commit 7dbf7476) for the slipstream-macos branch.
// Identical to upstream EXCEPT the URRegistryFFI binaryTarget is a local `path:` pointing at a
// macOS-enabled xcframework (upstream ships iOS-only slices). See README.md for provenance.
let package = Package(
    name: "KeystoneSDK",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "KeystoneSDK", targets: ["KeystoneSDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/BlockchainCommons/URKit", from: "15.0.0")
    ],
    targets: [
        .target(name: "KeystoneSDK", dependencies: ["URRegistryFFI", "URKit"]),
        .binaryTarget(name: "URRegistryFFI", path: "URRegistryFFI.xcframework"),
    ],
    swiftLanguageVersions: [.v5]
)
