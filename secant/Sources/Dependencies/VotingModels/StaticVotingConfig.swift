import Foundation

/// Wallet-bundled voting trust anchor.
///
/// This file is shipped inside the signed app bundle, so changing it requires a
/// wallet release. It intentionally contains only slow-moving trust material and
/// the URL for the dynamic config; vote/PIR endpoints and rounds live in the
/// fetched dynamic config.
struct StaticVotingConfig: Codable, Equatable, Sendable {
    static let bundleResourceName = "static-voting-config"
    static let supportedVersion = 1
    static let algEd25519 = "ed25519"

    let staticConfigVersion: Int
    let dynamicConfigURL: URL
    let trustedKeys: [TrustedKey]

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

    /// Load the static config from the app bundle and validate it before use.
    ///
    /// A missing or malformed static config is a release/configuration error.
    /// There is no network fallback because this document is the wallet's trust
    /// anchor for voting.
    static func loadFromBundle(_ bundle: Bundle = .main) throws -> StaticVotingConfig {
        guard let url = bundle.url(forResource: bundleResourceName, withExtension: "json") else {
            throw VotingConfigError.decodeFailed("static config resource missing: \(bundleResourceName).json")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VotingConfigError.decodeFailed("static config unreadable: \(error.localizedDescription)")
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
