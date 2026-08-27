#if VOTING_ENABLED
//
//  VotingMetadataProviderInterface.swift
//  Zashi
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var votingMetadata: VotingMetadataProviderClient {
        get { self[VotingMetadataProviderClient.self] }
        set { self[VotingMetadataProviderClient.self] = newValue }
    }
}

/// Per-account encrypted storage for the voting flow's drafts, submitted
/// choices, locked submission inputs, and per-round vote records. Mirrors
/// `UserMetadataProviderClient` but with a scope limited to voting and no
/// remote/iCloud sync.
@DependencyClient
struct VotingMetadataProviderClient {
    /// Load encrypted file (if any) into the in-memory cache.
    var load: @Sendable (Account) throws -> Void
    /// Encrypt and write the current in-memory cache to disk.
    var store: @Sendable (Account) throws -> Void
    /// Delete the on-disk file for this account (does not touch the cache).
    var resetAccount: @Sendable (Account) throws -> Void
    /// Clear the in-memory cache. Disk is untouched.
    var reset: @Sendable () -> Void

    /// Per-round draft votes (proposalId → optionIndex), keyed by `roundId`.
    var loadDrafts: @Sendable (_ roundId: String) -> [String: UInt32] = { _ in [:] }
    var setDrafts: @Sendable (_ drafts: [String: UInt32], _ roundId: String) -> Void
    var clearDrafts: @Sendable (_ roundId: String) -> Void

    /// Per-round submitted votes (proposalId -> optionIndex), keyed by `roundId`.
    var loadSubmittedVotes: @Sendable (_ roundId: String) -> [String: UInt32] = { _ in [:] }
    var setSubmittedVotes: @Sendable (_ votes: [String: UInt32], _ roundId: String) -> Void
    var clearSubmittedVotes: @Sendable (_ roundId: String) -> Void

    /// Cast-vote inputs locked per proposal when commitment construction begins.
    var loadSubmissionIntents: @Sendable (
        _ roundId: String
    ) -> [String: PersistedVoteSubmissionIntent] = { _ in [:] }
    var setSubmissionIntents: @Sendable (
        _ intents: [String: PersistedVoteSubmissionIntent],
        _ roundId: String
    ) -> Void
    var clearSubmissionIntents: @Sendable (_ roundId: String) -> Void
    var singleShareMode: @Sendable (_ roundId: String) -> Bool? = { _ in nil }
    var setSingleShareMode: @Sendable (_ singleShare: Bool, _ roundId: String) -> Void
    var clearSingleShareMode: @Sendable (_ roundId: String) -> Void

    /// Per-round completed-vote record.
    var record: @Sendable (_ roundId: String) -> PersistedVotingRecord? = { _ in nil }
    var allRecords: @Sendable () -> [String: PersistedVotingRecord] = { [:] }
    var setRecord: @Sendable (_ record: PersistedVotingRecord, _ roundId: String) -> Void
    var clearRecord: @Sendable (_ roundId: String) -> Void
}
#endif
