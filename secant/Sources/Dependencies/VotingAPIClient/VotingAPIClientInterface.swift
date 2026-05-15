import ComposableArchitecture
import Foundation

// MARK: - Share Status Types

/// Result of polling a helper server for share confirmation status.
enum ShareConfirmationResult: Equatable, Sendable {
    case pending
    case confirmed
}

/// Info about which servers accepted a delegated share.
struct DelegatedShareInfo: Equatable, Sendable {
    let shareIndex: UInt32
    let proposalId: UInt32
    let acceptedByServers: [String]

    init(shareIndex: UInt32, proposalId: UInt32, acceptedByServers: [String]) {
        self.shareIndex = shareIndex
        self.proposalId = proposalId
        self.acceptedByServers = acceptedByServers
    }
}

/// Result from one active share delegation batch, including the server set that
/// remained usable after removing POST failures.
struct ShareDelegationResult: Equatable, Sendable {
    let delegatedShares: [DelegatedShareInfo]
    let remainingServerURLs: [String]

    init(delegatedShares: [DelegatedShareInfo], remainingServerURLs: [String]) {
        self.delegatedShares = delegatedShares
        self.remainingServerURLs = remainingServerURLs
    }
}

enum ShareDelegationError: LocalizedError, Equatable, Sendable {
    case noReachableVoteServers

    var errorDescription: String? {
        switch self {
        case .noReachableVoteServers:
            return String(localizable: .coinVoteStoreUserErrorNoReachableVoteServers)
        }
    }
}

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
    var submitDelegation: @Sendable (_ registration: DelegationRegistration) async throws -> TxResult
    var submitVoteCommitment: @Sendable (_ bundle: VoteCommitmentBundle, _ signature: CastVoteSignature) async throws -> TxResult
    /// Distribute shares across the provided active-submission vote server set.
    var delegateShares: @Sendable (
        _ payloads: [SharePayload],
        _ roundIdHex: String,
        _ serverURLs: [String]
    ) async throws -> ShareDelegationResult
    /// Poll a helper server for the confirmation status of a share identified by its nullifier.
    var fetchShareStatus: @Sendable (_ helperBaseURL: String, _ roundIdHex: String, _ nullifierHex: String) async throws -> ShareConfirmationResult
    /// Resubmit a single share to configured vote servers, preferring URLs that have not already accepted it.
    /// Returns the list of server URLs that accepted the share (empty if all failed).
    var resubmitShare: @Sendable (_ payload: SharePayload, _ roundIdHex: String, _ excludeURLs: [String]) async throws -> [String]
    var fetchProposalTally: @Sendable (_ roundId: Data, _ proposalId: UInt32) async throws -> TallyResult
    /// Query the Cosmos SDK TX endpoint for a confirmed transaction and its ABCI events.
    /// Returns nil if the TX is not yet in a block (404 or network error).
    var fetchTxConfirmation: @Sendable (_ txHash: String) async throws -> TxConfirmation?
}
