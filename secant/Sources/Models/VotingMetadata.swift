//
//  VotingMetadata.swift
//  Zashi
//

import Foundation

/// On-disk shape for per-account encrypted voting state.
///
/// Carries the user's in-flight draft votes, submitted choices, and per-round
/// completion records.
/// Encrypted at rest using the same per-account keys as the user-metadata
/// file, but stored in a separate file with a different filename so the two
/// concerns stay isolated and the cross-platform user-metadata schema doesn't
/// have to learn about voting.
///
/// Lives only on this device — no iCloud sync, no remote merge strategy.
struct VotingMetadata: Codable, Equatable, Sendable {
    enum Constants {
        /// Bumped when the on-disk shape changes incompatibly. Future loaders
        /// branch on this value; v1 is the initial encrypted-file release.
        static let version = 1
    }

    /// `[roundIdHex: [proposalIdString: optionIndex]]`. Mirrors the
    /// in-memory `draftVotes` dictionary that `VotingCoordFlow.State` holds.
    var drafts: [String: [String: UInt32]]

    /// `[roundIdHex: [proposalIdString: optionIndex]]`. Mirrors submitted
    /// per-proposal choices after they move out of drafts.
    var submittedVotes: [String: [String: UInt32]]

    /// Cryptographic inputs locked before the first cast-vote build.
    var submissionIntents: [String: [String: PersistedVoteSubmissionIntent]]

    /// The share mode locked before the first cast-vote build for each round.
    var singleShareModes: [String: Bool]

    /// `[roundIdHex: VoteRecord]`. One record per round the user has fully
    /// submitted.
    var records: [String: PersistedVotingRecord]

    /// Latest schema version this file was written with.
    var schemaVersion: Int

    init(
        drafts: [String: [String: UInt32]] = [:],
        submittedVotes: [String: [String: UInt32]] = [:],
        submissionIntents: [String: [String: PersistedVoteSubmissionIntent]] = [:],
        singleShareModes: [String: Bool] = [:],
        records: [String: PersistedVotingRecord] = [:],
        schemaVersion: Int = Constants.version
    ) {
        self.drafts = drafts
        self.submittedVotes = submittedVotes
        self.submissionIntents = submissionIntents
        self.singleShareModes = singleShareModes
        self.records = records
        self.schemaVersion = schemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case drafts
        case submittedVotes
        case submissionIntents
        case singleShareModes
        case records
        case schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.drafts = try container.decodeIfPresent(
            [String: [String: UInt32]].self,
            forKey: .drafts
        ) ?? [:]
        self.submittedVotes = try container.decodeIfPresent(
            [String: [String: UInt32]].self,
            forKey: .submittedVotes
        ) ?? [:]
        self.submissionIntents = try container.decodeIfPresent(
            [String: [String: PersistedVoteSubmissionIntent]].self,
            forKey: .submissionIntents
        ) ?? [:]
        self.singleShareModes = try container.decodeIfPresent(
            [String: Bool].self,
            forKey: .singleShareModes
        ) ?? [:]
        self.records = try container.decodeIfPresent(
            [String: PersistedVotingRecord].self,
            forKey: .records
        ) ?? [:]
        self.schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? Constants.version
    }
}

struct PersistedVoteSubmissionIntent: Codable, Equatable, Sendable {
    let choice: UInt32
    let numOptions: UInt32
}

/// Persisted shape of `Voting.VoteRecord`. Kept as a separate Codable type so
/// the in-memory `Voting.VoteRecord` (which uses `Date`) can stay free of any
/// Codable concerns while this on-disk form serialises `votedAt` as a Unix
/// timestamp.
struct PersistedVotingRecord: Codable, Equatable, Sendable {
    let votedAt: Double
    let votingWeight: UInt64
    let proposalCount: Int
    let eligibleVotingWeight: UInt64?
    let submittedBundleCount: UInt32?
    let totalBundleCount: UInt32?
}
