// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VotingRecovery",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "VotingRecovery", targets: ["VotingRecovery"])
    ],
    dependencies: [
        // The same checkout the app builds against; CI places it beside the repository.
        .package(path: "../../../zodl-swift-wallet-sdk"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "VotingRecovery",
            dependencies: [
                .product(name: "ZcashLightClientKit", package: "zodl-swift-wallet-sdk"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
