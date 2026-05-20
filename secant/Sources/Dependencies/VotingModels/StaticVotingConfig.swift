import CryptoKit
import Foundation

/// Hash-pinned static voting trust anchor.
///
/// The signed wallet binary pins the URL and SHA-256 of a published static
/// config. The fetched bytes are trusted only after the hash matches.
struct StaticVotingConfig: Codable, Equatable, Sendable {
    static let supportedVersion = 1
    static let algEd25519 = "ed25519"
    static let bundledPinnedSource =
        "https://raw.githubusercontent.com/valargroup/token-holder-voting-config/5ed8d623e4150d383a4dac05dd6bfbdd126a5408/prod/static-voting-config.json" +
        "?checksum=sha256:5a6bc0dce85a8ee8d6585d2a180e62f145abcfee7768c15b88de47c9a01a5738"

    let staticConfigVersion: Int
    let dynamicConfigURL: URL
    let trustedKeys: [TrustedKey]

    init(
        staticConfigVersion: Int,
        dynamicConfigURL: URL,
        trustedKeys: [TrustedKey]
    ) {
        self.staticConfigVersion = staticConfigVersion
        self.dynamicConfigURL = dynamicConfigURL
        self.trustedKeys = trustedKeys
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
        case trustedKeys = "trusted_keys"
    }

    /// Fetch the static config from its hash-pinned URL and validate it before use.
    ///
    /// There is no fallback: a transport failure, decode failure, or hash
    /// mismatch blocks voting until the user can fetch a trusted config.
    static func loadFromNetwork(
        source: PinnedConfigSource,
        session: URLSession
    ) async throws -> StaticVotingConfig {
        let data: Data
        let response: URLResponse
        do {
            var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            (data, response) = try await session.data(for: request)
        } catch {
            throw VotingConfigError.staticConfigFetchFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw VotingConfigError.staticConfigFetchFailed("HTTP \(http.statusCode)")
        }
        return try decodeAndVerify(data: data, expectedSHA256: source.sha256)
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
        guard staticConfigVersion == Self.supportedVersion else {
            throw VotingConfigError.decodeFailed("unsupported static_config_version \(staticConfigVersion)")
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
