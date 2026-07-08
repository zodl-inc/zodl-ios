import Foundation

/// Second half of the mutual pinning (spec §2): the host manifest's `allowed_origins`
/// makes the browser refuse foreign extensions; this check makes the HELPER refuse
/// them too (defense in depth — the browser passes the caller origin as argv).
public struct Allowlist {
    public let allowedExtensionIDs: [String]

    public init(allowedExtensionIDs: [String]) {
        self.allowedExtensionIDs = allowedExtensionIDs
    }

    /// Chromium invokes the host with the caller as `chrome-extension://<32 a-p chars>/`.
    public func permits(callerOrigin: String) -> Bool {
        let prefix = "chrome-extension://"
        guard callerOrigin.hasPrefix(prefix) else { return false }
        var id = String(callerOrigin.dropFirst(prefix.count))
        if id.hasSuffix("/") { id.removeLast() }
        guard id.count == 32, id.allSatisfy({ $0 >= "a" && $0 <= "p" }) else { return false }
        return allowedExtensionIDs.contains(id)
    }
}
