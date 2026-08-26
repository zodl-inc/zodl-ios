import CryptoKit
import Foundation

/// Hash-pinned static voting trust anchor.
///
/// The signed wallet binary pins the URL and SHA-256 of a published static
/// config. The fetched bytes are trusted only after the hash matches.
struct StaticVotingConfig: Codable, Equatable, Sendable {
    static let supportedVersions: Set<Int> = [1, 2]
    static let algEd25519 = "ed25519"
    static let configRequestTimeout: TimeInterval = 15
    private static let bundledSHA256 = "28fc9b631091ae8bc2f8635d8930489238ce144174cbd15a03efb0530b301ebe"
    /// Primary bundled pin — the canonical voting gateway origin. Shown in
    /// Settings as the Default source and kept first in the mirror walk.
    static let bundledPinnedSource =
        "https://voting.valargroup.dev/pins/prod/\(bundledSHA256)/v2-static-voting-config.json?checksum=sha256:\(bundledSHA256)"
    /// GitHub-hosted copy of the byte-identical pinned file. Trust is carried by
    /// the checksum, not the origin, so any mirror serving the pinned bytes is
    /// equally trustworthy — this one exists for networks where the gateway
    /// domain is blocked or broken.
    static let bundledPinnedSourceMirror =
        "https://raw.githubusercontent.com/valargroup/token-holder-voting-config/main/pins/prod/\(bundledSHA256)/v2-static-voting-config.json?checksum=sha256:\(bundledSHA256)"
    /// Ordered mirror walk for the bundled trust anchor, canonical origin first.
    static let bundledPinnedSources = [bundledPinnedSource, bundledPinnedSourceMirror]
    /// Parsed counterparts; `bundledSourcesPinTheSameV2Hash` pins the invariant
    /// that parsing never silently drops an entry.
    static let bundledParsedSources: [PinnedConfigSource] = bundledPinnedSources.compactMap { raw in
        try? PinnedConfigSource.parse(raw)
    }

    let staticConfigVersion: Int
    /// Ordered dynamic-config mirror list, canonical origin first.
    /// v1 documents carry a single `dynamic_config_url`, normalized here to a
    /// one-element list; v2 documents carry `dynamic_config_urls` verbatim.
    let dynamicConfigURLs: [URL]
    let trustedKeys: [TrustedKey]

    init(
        staticConfigVersion: Int,
        dynamicConfigURLs: [URL],
        trustedKeys: [TrustedKey]
    ) {
        self.staticConfigVersion = staticConfigVersion
        self.dynamicConfigURLs = dynamicConfigURLs
        self.trustedKeys = trustedKeys
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        staticConfigVersion = try container.decode(Int.self, forKey: .staticConfigVersion)
        trustedKeys = try container.decode([TrustedKey].self, forKey: .trustedKeys)
        switch staticConfigVersion {
        case 1:
            let url = try container.decode(URL.self, forKey: .dynamicConfigURL)
            dynamicConfigURLs = [url]
        case 2:
            dynamicConfigURLs = try container.decode([URL].self, forKey: .dynamicConfigURLs)
        default:
            // Unknown version: defer to validate() so the caller sees a precise
            // "unsupported static_config_version N" instead of a decode error.
            dynamicConfigURLs = []
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(staticConfigVersion, forKey: .staticConfigVersion)
        try container.encode(trustedKeys, forKey: .trustedKeys)
        switch staticConfigVersion {
        case 1:
            if let url = dynamicConfigURLs.first {
                try container.encode(url, forKey: .dynamicConfigURL)
            }
        default:
            try container.encode(dynamicConfigURLs, forKey: .dynamicConfigURLs)
        }
    }

    /// Admin key trusted to sign per-round dynamic config entries.
    ///
    /// Dynamic round entries reference these keys by `key_id`; they do not
    /// inline public keys. For v1, signatures are Ed25519 over the raw `ea_pk`
    /// bytes for a round.
    struct TrustedKey: Codable, Equatable, Sendable {
        let keyId: String
        let alg: String
        let pubkey: Data
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case keyId = "key_id"
            case alg
            case pubkey
            case notes
        }
    }

    enum CodingKeys: String, CodingKey {
        case staticConfigVersion = "static_config_version"
        case dynamicConfigURL = "dynamic_config_url"
        case dynamicConfigURLs = "dynamic_config_urls"
        case trustedKeys = "trusted_keys"
    }

    /// Fetch the static config from its hash-pinned URL and validate it before use.
    ///
    /// There is no fallback: a transport failure, decode failure, or hash
    /// mismatch blocks voting until the user can fetch a trusted config.
    /// `fetch` is injected by the caller so the request can be routed through
    /// Tor (`SDKSynchronizerClient.httpRequestOverTor`) when the user enabled
    /// Tor in Settings, and through the plain URLSession otherwise.
    static func loadFromNetwork(
        source: PinnedConfigSource,
        fetch: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> StaticVotingConfig {
        let data: Data
        let response: URLResponse
        do {
            var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = Self.configRequestTimeout
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            (data, response) = try await fetch(request)
        } catch {
            throw VotingConfigError.staticConfigFetchFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw VotingConfigError.staticConfigFetchFailed("HTTP \(http.statusCode)")
        }
        return try decodeAndVerify(data: data, expectedSHA256: source.sha256)
    }

    /// Walk `sources` in order and return the first mirror that yields a valid,
    /// hash-verified static config.
    ///
    /// Fall-through is availability-only: a transport failure, a non-200
    /// response, or a hash mismatch moves on to the next mirror (each mirror is
    /// independently hash-gated, so a mirror serving the wrong bytes is just a
    /// broken mirror, never a trust decision). A decode or validation failure
    /// *after* the hash matched is authoritative for every mirror — the pin
    /// guarantees identical bytes everywhere — so it surfaces immediately.
    static func loadFromNetworkWithFailover(
        sources: [PinnedConfigSource],
        fetch: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> StaticVotingConfig {
        try await VotingConfigMirrorWalk.run(
            mirrors: sources,
            walkLabel: "Static config",
            mirrorLabel: { source in source.url.host ?? "<unknown>" },
            emptyError: VotingConfigError.staticConfigSourceMalformed("no static config sources configured"),
            shouldTryNext: { error in
                switch error {
                case .staticConfigFetchFailed, .staticConfigHashMismatch:
                    return true
                default:
                    return false
                }
            },
            attempt: { source in try await loadFromNetwork(source: source, fetch: fetch) }
        )
    }

    /// Verify the raw bytes before decoding when a pin is provided.
    static func decodeAndVerify(data: Data, expectedSHA256: Data?) throws -> StaticVotingConfig {
        if let expectedSHA256 {
            let actualSHA256 = Data(SHA256.hash(data: data))
            guard actualSHA256 == expectedSHA256 else {
                throw VotingConfigError.staticConfigHashMismatch(
                    expected: expectedSHA256.lowercaseHexString,
                    actual: actualSHA256.lowercaseHexString
                )
            }
        }
        let config: StaticVotingConfig
        do {
            config = try JSONDecoder().decode(StaticVotingConfig.self, from: data)
        } catch {
            throw VotingConfigError.decodeFailed("static config decode failed: \(error.localizedDescription)")
        }

        try config.validate()
        return config
    }

    /// Validate only the static trust-anchor invariants.
    ///
    /// Dynamic endpoint reachability and round signatures are checked later when
    /// the dynamic config is fetched and a chain round is selected.
    func validate() throws {
        guard Self.supportedVersions.contains(staticConfigVersion) else {
            throw VotingConfigError.decodeFailed("unsupported static_config_version \(staticConfigVersion)")
        }
        guard !dynamicConfigURLs.isEmpty else {
            throw VotingConfigError.decodeFailed("dynamic_config_urls must contain at least one entry")
        }
        guard !trustedKeys.isEmpty else {
            throw VotingConfigError.decodeFailed("trusted_keys must contain at least one entry")
        }

        for key in trustedKeys {
            guard key.alg == Self.algEd25519 else {
                throw VotingConfigError.decodeFailed("trusted_keys[\(key.keyId)].alg unsupported: \(key.alg)")
            }
            guard key.pubkey.count == 32 else {
                throw VotingConfigError.decodeFailed("trusted_keys[\(key.keyId)].pubkey must decode to 32 bytes")
            }
        }

        // Every dynamic config mirror must be HTTPS. iOS App Transport Security
        // already blocks plaintext HTTP for this app, and the user-pasted
        // custom-chain path enforces https in `PinnedConfigSource.parse`.
        // Enforce the same here so a static-config rotation (the only place
        // where these URLs are decided) can't silently downgrade voting to an
        // unauthenticated transport.
        for url in dynamicConfigURLs {
            guard url.scheme?.lowercased() == "https" else {
                throw VotingConfigError.decodeFailed(
                    "dynamic_config_urls must use https; got \(url.absoluteString)"
                )
            }
        }
    }
}

/// Format: `URL` with an optional `?checksum=sha256:{lowercase-hex}` pin.
struct PinnedConfigSource: Equatable, Sendable {
    let url: URL
    let sha256: Data?

    static func parse(_ raw: String) throws -> PinnedConfigSource {
        guard var components = URLComponents(string: raw),
              components.scheme == "https",
              components.host != nil
        else {
            throw VotingConfigError.staticConfigSourceMalformed("not an HTTPS URL: \(raw)")
        }

        let queryItems = components.queryItems ?? []
        let sha256: Data?
        if let checksumItem = queryItems.first(where: { $0.name == "checksum" }) {
            guard let checksum = checksumItem.value else {
                throw VotingConfigError.staticConfigSourceMalformed("missing checksum value")
            }

            let prefix = "sha256:"
            guard checksum.hasPrefix(prefix) else {
                throw VotingConfigError.staticConfigSourceMalformed("checksum must start with sha256:")
            }

            let hex = String(checksum.dropFirst(prefix.count))
            guard hex.count == 64,
                  let parsedSHA256 = Data(lowercaseHexString: hex),
                  parsedSHA256.count == 32
            else {
                throw VotingConfigError.staticConfigSourceMalformed(
                    "sha256 must be 64 lowercase hex chars (32 bytes); got \(hex.count)"
                )
            }

            sha256 = parsedSHA256
            components.queryItems = queryItems.filter { $0.name != "checksum" }
            if components.queryItems?.isEmpty == true {
                components.queryItems = nil
            }
        } else {
            sha256 = nil
        }
        guard let url = components.url else {
            throw VotingConfigError.staticConfigSourceMalformed("could not rebuild URL after stripping checksum")
        }
        return PinnedConfigSource(url: url, sha256: sha256)
    }
}

private extension Data {
    init?(lowercaseHexString hex: String) {
        guard hex.count.isMultiple(of: 2),
              hex.utf8.allSatisfy({ byte in
                  (byte >= CharacterCode.zero && byte <= CharacterCode.nine) ||
                  (byte >= CharacterCode.lowercaseA && byte <= CharacterCode.lowercaseF)
              })
        else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        self.init(bytes)
    }

    var lowercaseHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    private enum CharacterCode {
        static let zero = UInt8(ascii: "0")
        static let nine = UInt8(ascii: "9")
        static let lowercaseA = UInt8(ascii: "a")
        static let lowercaseF = UInt8(ascii: "f")
    }
}
