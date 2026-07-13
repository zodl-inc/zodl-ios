import Foundation

/// Written by `install-dev.sh` next to the installed binary. Keeps the helper free of
/// compiled-in identities: extension IDs and the wake target are deployment facts.
public struct BridgeConfig: Codable, Equatable {
    public var allowedExtensionIDs: [String]
    /// Bundle id used to wake Zodl when the socket is absent; nil = never launch.
    public var zodlBundleID: String?
    /// Dev override: wake by app PATH instead of bundle id. Needed when TestFlight
    /// and Xcode builds coexist under the SAME bundle id — LaunchServices resolves
    /// `open -b` to the (bridge-less) TestFlight copy; a path is unambiguous.
    public var zodlAppPath: String?
    /// Override for tests/dev; nil = `defaultSocketPath()`.
    public var socketPath: String?

    public init(
        allowedExtensionIDs: [String],
        zodlBundleID: String? = nil,
        zodlAppPath: String? = nil,
        socketPath: String? = nil
    ) {
        self.allowedExtensionIDs = allowedExtensionIDs
        self.zodlBundleID = zodlBundleID
        self.zodlAppPath = zodlAppPath
        self.socketPath = socketPath
    }

    /// Team-prefixed App Group shared with the sandboxed app (spec F6 — the app IS
    /// sandboxed; discovered in the 2026-07-09 live-fire). Must match
    /// `BridgeUDSServer.appGroupID` in the Zodl app.
    public static let appGroupID = "RLPRR8CPQG.zodl.bridge"

    /// Spec shared constant: the App Group container — short (sun_path-safe) and
    /// identical from the sandboxed app's and the unsandboxed helper's viewpoints.
    /// The helper constructs it literally: unsandboxed `NSHomeDirectory()` = real home.
    public static func defaultSocketPath() -> String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Group Containers/\(appGroupID)/bridge.sock")
    }

    public static func load(from url: URL) -> BridgeConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BridgeConfig.self, from: data)
    }

    public func resolvedSocketPath() -> String {
        socketPath ?? Self.defaultSocketPath()
    }
}
