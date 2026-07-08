import Foundation

/// Written by `install-dev.sh` next to the installed binary. Keeps the helper free of
/// compiled-in identities: extension IDs and the wake target are deployment facts.
public struct BridgeConfig: Codable, Equatable {
    public var allowedExtensionIDs: [String]
    /// Bundle id used to wake Zodl when the socket is absent; nil = never launch.
    public var zodlBundleID: String?
    /// Override for tests/dev; nil = `defaultSocketPath()`.
    public var socketPath: String?

    public init(allowedExtensionIDs: [String], zodlBundleID: String? = nil, socketPath: String? = nil) {
        self.allowedExtensionIDs = allowedExtensionIDs
        self.zodlBundleID = zodlBundleID
        self.socketPath = socketPath
    }

    /// Spec shared constant: `~/Library/Application Support/Zodl/bridge.sock`.
    /// Chosen App-Group-relocatable for the day the app sandboxes (spec F6).
    public static func defaultSocketPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Zodl/bridge.sock")
    }

    public static func load(from url: URL) -> BridgeConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BridgeConfig.self, from: data)
    }

    public func resolvedSocketPath() -> String {
        socketPath ?? Self.defaultSocketPath()
    }
}
