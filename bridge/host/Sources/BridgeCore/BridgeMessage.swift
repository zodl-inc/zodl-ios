import Foundation

/// The one message the bridge carries (spec BR-5, one-way): a payment request
/// pointer plus its browser-attested origin. No wallet data ever rides here.
public struct BridgeMessage: Codable, Equatable {
    public let v: Int
    public let id: String
    public let type: String
    public let uri: String
    public let origin: String
    /// BR-7 Tier 1: optional same-origin URL the app re-fetches natively.
    public let requestSrc: String?

    public init(v: Int, id: String, type: String, uri: String, origin: String, requestSrc: String? = nil) {
        self.v = v
        self.id = id
        self.type = type
        self.uri = uri
        self.origin = origin
        self.requestSrc = requestSrc
    }
}

public enum MessageValidationError: Error, Equatable {
    case badVersion
    case badType
    case badID
    case badURI
    case uriTooLong
    case badOrigin
    case badRequestSrc
}

extension BridgeMessage {
    public static let maxURILength = 2048
    public static let maxRequestSrcLength = 1024
    /// The popup's manual paste box has no page origin; it is labeled as manual in-app.
    public static let popupOrigin = "popup:"

    /// Structural validation only — ZIP-321 semantics are Zodl's job (URIParser.checkRP).
    public func validate() -> MessageValidationError? {
        guard v == 1 else { return .badVersion }
        guard type == "payRequest" else { return .badType }
        guard !id.isEmpty, id.count <= 64 else { return .badID }
        guard uri.count <= Self.maxURILength else { return .uriTooLong }
        guard uri.hasPrefix("zcash:") else { return .badURI }
        if origin != Self.popupOrigin {
            guard Self.isAcceptableOrigin(origin) else { return .badOrigin }
        }
        if let src = requestSrc {
            // Same https/loopback rule as origins (loopback = the demo fixture only);
            // the production Tier-1 FETCH stays https-only, enforced Zodl-side (BR-7).
            guard src.count <= Self.maxRequestSrcLength, Self.isAcceptableOrigin(src) else {
                return .badRequestSrc
            }
        }
        return nil
    }

    /// https origins only — except plain-http loopback, which the demo fixture uses.
    static func isAcceptableOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host, !host.isEmpty else { return false }
        if url.scheme == "https" { return true }
        if url.scheme == "http" { return host == "localhost" || host == "127.0.0.1" }
        return false
    }
}
