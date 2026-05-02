import Foundation

/// CDN-hosted voting service configuration as specified in ZIP 1244 §"Vote Discovery".
///
/// A JSON document for service discovery; fetched at startup from the bundled static config's dynamic_config_url.
struct VotingServiceConfig: Codable, Equatable, Sendable {
    let configVersion: Int
    let voteServers: [ServiceEndpoint]
    let pirEndpoints: [ServiceEndpoint]
    let supportedVersions: SupportedVersions
    let rounds: [String: RoundEntry]

    struct ServiceEndpoint: Codable, Equatable, Sendable {
        let url: String
        let label: String

        init(url: String, label: String) {
            self.url = url
            self.label = label
        }
    }

    struct SupportedVersions: Codable, Equatable, Sendable {
        let pir: [String]
        let voteProtocol: String
        let tally: String
        let voteServer: String

        init(pir: [String], voteProtocol: String, tally: String, voteServer: String) {
            self.pir = pir
            self.voteProtocol = voteProtocol
            self.tally = tally
            self.voteServer = voteServer
        }

        enum CodingKeys: String, CodingKey {
            case pir
            case voteProtocol = "vote_protocol"
            case tally
            case voteServer = "vote_server"
        }
    }

    struct RoundEntry: Codable, Equatable, Sendable {
        let authVersion: Int
        let eaPk: Data
        let signatures: [Signature]

        enum CodingKeys: String, CodingKey {
            case authVersion = "auth_version"
            case eaPk = "ea_pk"
            case signatures
        }
    }

    struct Signature: Codable, Equatable, Sendable {
        let keyId: String
        let alg: String
        let sig: Data

        enum CodingKeys: String, CodingKey {
            case keyId = "key_id"
            case alg
            case sig
        }
    }

    init(
        configVersion: Int,
        voteServers: [ServiceEndpoint],
        pirEndpoints: [ServiceEndpoint],
        supportedVersions: SupportedVersions,
        rounds: [String: RoundEntry]
    ) {
        self.configVersion = configVersion
        self.voteServers = voteServers
        self.pirEndpoints = pirEndpoints
        self.supportedVersions = supportedVersions
        self.rounds = rounds
    }

    enum CodingKeys: String, CodingKey {
        case configVersion = "config_version"
        case voteServers = "vote_servers"
        case pirEndpoints = "pir_endpoints"
        case supportedVersions = "supported_versions"
        case rounds
    }

}

// MARK: - Wallet capabilities

/// Versions of each voting-protocol component this wallet build can handle.
/// Values MUST reflect what the app (including `VotingRustBackend`) actually implements —
/// not what it aspires to — or the wallet will reject valid configs and lock users out.
enum WalletCapabilities {
    static let voteServer: Set<String> = ["v1"]
    static let voteProtocol: Set<String> = ["v0"]
    static let tally: Set<String> = ["v0"]
    static let pir: Set<String> = ["v0"]
}

// MARK: - Errors

enum VotingConfigError: Error, Equatable, LocalizedError {
    case decodeFailed(String)
    case unsupportedVersion(component: String, advertised: String)

    var errorDescription: String? {
        switch self {
        case .decodeFailed(let detail):
            return String(localizable: .coinVoteConfigErrorDecodeFailed(detail))
        case .unsupportedVersion(let component, let advertised):
            return String(localizable: .coinVoteConfigErrorUnsupportedVersion(component, advertised))
        }
    }
}

// MARK: - Validation (ZIP 1244 §"Version Handling")

extension VotingServiceConfig {
    /// Throws `VotingConfigError.unsupportedVersion` on the first component the wallet doesn't support.
    func validate() throws {
        guard configVersion == 1 else {
            throw VotingConfigError.decodeFailed("unsupported config_version \(configVersion)")
        }
        guard !voteServers.isEmpty else {
            throw VotingConfigError.decodeFailed("vote_servers must contain at least one entry")
        }
        guard !pirEndpoints.isEmpty else {
            throw VotingConfigError.decodeFailed("pir_endpoints must contain at least one entry")
        }
        for roundId in rounds.keys where !Self.isLowercaseHexRoundId(roundId) {
            throw VotingConfigError.decodeFailed("rounds key must be 64 lowercase hex characters: \(roundId)")
        }
        if !WalletCapabilities.voteServer.contains(supportedVersions.voteServer) {
            throw VotingConfigError.unsupportedVersion(
                component: "vote_server",
                advertised: supportedVersions.voteServer
            )
        }
        if !WalletCapabilities.voteProtocol.contains(supportedVersions.voteProtocol) {
            throw VotingConfigError.unsupportedVersion(
                component: "vote_protocol",
                advertised: supportedVersions.voteProtocol
            )
        }
        if !WalletCapabilities.tally.contains(supportedVersions.tally) {
            throw VotingConfigError.unsupportedVersion(
                component: "tally",
                advertised: supportedVersions.tally
            )
        }
        if WalletCapabilities.pir.isDisjoint(with: supportedVersions.pir) {
            throw VotingConfigError.unsupportedVersion(
                component: "pir",
                advertised: supportedVersions.pir.joined(separator: ",")
            )
        }
    }

    static func isLowercaseHexRoundId(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= CharacterCode.zero && byte <= CharacterCode.nine) ||
            (byte >= CharacterCode.lowercaseA && byte <= CharacterCode.lowercaseF)
        }
    }

    private enum CharacterCode {
        static let zero = UInt8(ascii: "0")
        static let nine = UInt8(ascii: "9")
        static let lowercaseA = UInt8(ascii: "a")
        static let lowercaseF = UInt8(ascii: "f")
    }
}
