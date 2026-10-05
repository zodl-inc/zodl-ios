#if VOTING_ENABLED
import ComposableArchitecture
import Foundation

extension DependencyValues {
    var votingAPI: VotingAPIClient {
        get { self[VotingAPIClient.self] }
        set { self[VotingAPIClient.self] = newValue }
    }
}

@DependencyClient
struct VotingAPIClient {
    /// Fetch service config from the bundled static config, or a validated user override.
    var fetchServiceConfig: @Sendable (_ override: PinnedConfigSource?) async throws -> VotingServiceConfig
    /// Configure the API client to use URLs from the resolved service config.
    var configureURLs: @Sendable (_ config: VotingServiceConfig) async -> Void
    var fetchActiveVotingSession: @Sendable () async throws -> VotingSession
    var fetchAllRounds: @Sendable () async throws -> [VotingSession]
    var fetchRoundById: @Sendable (_ roundIdHex: String) async throws -> VotingSession
    var fetchTallyResults: @Sendable (_ roundIdHex: String) async throws -> [UInt32: TallyResult]
    /// Fetch the set of round ids (lowercase hex) that the `zodl` endorser has endorsed on-chain.
    /// Returns an empty set if the endorser is not configured.
    var fetchZodlEndorsedRoundIds: @Sendable () async throws -> Set<String>
    var fetchProposalTally: @Sendable (_ roundId: Data, _ proposalId: UInt32) async throws -> TallyResult
}
#endif
