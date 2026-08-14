#if VOTING_ENABLED
//
//  RoundSession.swift
//  Zashi
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// Cached per-round state that survives navigation within the voting flow.
///
/// Populated on first entry into a round (witness verification, hotkey
/// derivation, vote weight computation). Re-entering the same round uses
/// this cache instead of re-running the 30–120 s pipeline.
///
/// Evicted on `.dismissFlow`, wallet-account switch, or voting-service-config
/// change. All other navigation pops leave the cache intact — the rule that
/// makes "back" feel like a real pop instead of a teardown.
struct RoundSession: Equatable {
    let roundId: String

    // MARK: - Pipeline outputs (Phase 4b populates)

    /// Total voting power for this wallet at the round's snapshot height,
    /// derived from eligible notes after bundling (5-note bundles, dropped
    /// if below `ballotDivisor`). Constant across navigation for a given
    /// (wallet, round) pair until a new snapshot or wallet rescan.
    var votingWeight: UInt64 = 0

    /// Original eligible power before any Keystone bundle skipping. For
    /// Zashi and full Keystone submissions this matches `votingWeight`; when
    /// Keystone users skip unsigned bundles, `votingWeight` is reduced and
    /// this remains the pre-skip value for persisted transparency metadata.
    var eligibleVotingWeight: UInt64 = 0

    /// Eligible notes at the round's snapshot height. Cached because the
    /// SDK query is non-trivial and the snapshot is immutable.
    var walletNotes: [NoteInfo] = []

    /// Inclusion proofs for each note, generated during witness verification.
    /// Used as authPath input during vote commitment build (Stage 5B).
    var cachedWitnesses: [WitnessData] = []

    /// Number of note bundles (groups of up to 5 notes). Set by the
    /// bundling step in the active-round pipeline. Drives both the
    /// delegation proof loop and the per-bundle vote submission loop.
    var bundleCount: UInt32 = 0

    /// Original eligible bundle count before any Keystone skip. Kept so a
    /// completed vote record can explain reduced power later.
    var eligibleBundleCount: UInt32 = 0

    /// Per-round hotkey address derived deterministically from the per-
    /// account hotkey mnemonic (in the Keychain) and the round id. Same
    /// address every time for a given (wallet, round) pair.
    var hotkeyAddress: String?

    /// Draft votes the user has selected but not yet submitted. Keyed by
    /// proposal id. Hydrated from the encrypted voting metadata file on
    /// round entry; mutations write through to disk so drafts survive an
    /// app restart.
    var draftVotes: [UInt32: VoteChoice] = [:]

    /// Successfully submitted votes (post-`.batchVoteSubmitted`). Distinct
    /// from `draftVotes` so the UI can render "Voted" pills on individual
    /// proposals while others are still being processed in the batch loop.
    /// Hydrated from the votingCrypto DB on round entry.
    var votes: [UInt32: VoteChoice] = [:]

    /// Per-proposal tally results from the voting service. Cached for
    /// finalized rounds — these are immutable post-finalization, so we
    /// never refetch them once populated.
    var tallyResults: [UInt32: TallyResult] = [:]

    /// True when a tally fetch has been initiated for this round (so the
    /// Results view doesn't show "loading" indefinitely after the response
    /// arrives empty).
    var tallyFetched: Bool = false

    /// Last tally-fetch failure message, set by `.tallyResultsFailed`.
    /// Non-nil = ResultsView renders a retry surface instead of the
    /// "Loading results…" spinner. Cleared by `.retryFetchTallyResults`.
    var tallyError: String?

    // MARK: - Submission pipeline state (Stage 5)

    /// On-chain authorization (ZKP #1) readiness. The vote-submission loop
    /// is gated on `.complete`. Failing here yields `.failed` and surfaces
    /// an authorization-error sheet on the Confirm Submission screen.
    var delegationProofStatus: ProofStatus = .notStarted

    /// True while the delegation proof `.run` effect is in-flight. Guards
    /// against re-entrant `.startDelegationProof` dispatches from round
    /// polling re-triggers.
    var isDelegationProofInFlight: Bool = false

    /// Zashi-only optimization: precompute PIR proof material in the
    /// background while the user is still choosing votes, so when they hit
    /// Submit the ZKP doesn't start from cold.
    var delegationPrecomputeStatus: DelegationPrecomputeStatus = .notStarted

    /// True while the precompute task is in-flight (deduplication guard).
    var isDelegationPrecomputeInFlight: Bool = false

    /// Top-level state machine for the batch submission flow. Drives the
    /// Confirm Submission view (progress, authorization error sheet,
    /// partial-success error sheet, completion checkmark).
    var batchSubmissionStatus: BatchSubmissionStatus = .idle

    /// Per-proposal error messages from the last batch run. Cleared on retry.
    var batchVoteErrors: [UInt32: String] = [:]

    /// True while a vote commitment build/submit cycle is in-flight. Gates
    /// re-entrant vote submissions during round polling re-triggers.
    var isSubmittingVote: Bool = false

    /// Substep within the current proposal's submission. Renders as a
    /// 4-step progress indicator on the Confirm Submission view.
    var voteSubmissionStep: VoteSubmissionStep?

    /// Which note bundle the vote-submission loop is currently processing
    /// (0-based). Nil when no vote is in-flight. Used for UI progress.
    var currentVoteBundleIndex: UInt32?

    /// Proposal id currently being submitted. Nil when idle.
    var submittingProposalId: UInt32?

    /// State of the Keystone QR signing loop. Idle for Zashi users.
    var keystoneSigningStatus: KeystoneSigningStatus = .idle

    /// Index of the bundle being signed in the Keystone QR loop (0-based).
    /// Incremented after each successful scan; compared to `bundleCount` to
    /// know when signing is done.
    var currentKeystoneBundleIndex: UInt32 = 0

    /// Per-bundle Keystone signatures accumulated during the multi-bundle
    /// signing loop. Persisted to the votingCrypto recovery store on each
    /// scan so a crash mid-loop doesn't lose signed bundles.
    var keystoneBundleSignatures: [KeystoneBundleSignature] = []

    /// Delegation bundles recovered as already submitted on-chain.
    var completedKeystoneDelegationBundleIndices: Set<UInt32> = []

    /// Voting PCZT result (metadata + pczt_bytes) for the bundle currently
    /// being shown as a QR on the Keystone signing screen.
    var pendingVotingPczt: VotingPcztResult?

    /// Unsigned delegation PCZT request rendered as the QR payload. Cleared
    /// once the signed PCZT comes back from the scan.
    var pendingUnsignedDelegationPczt: Pczt?

    /// On a successful batch run we persist a one-line record (date, weight,
    /// proposal count) into the encrypted voting metadata file. The Results
    /// screen uses this to render "Voted MMM d - Voting Power X.XXX ZEC".
    var voteRecord: Voting.VoteRecord?

    /// DB-backed helper-server share confirmation tracking. The UI
    /// workstream owns presentation; the coordinator keeps this state
    /// current so My Votes/review surfaces can read it.
    var shareTrackingStatus: ShareTrackingStatus = .idle
    var shareDelegations: [VotingShareDelegation] = []
}

// MARK: - Submission state machine types

/// Top-level state for the batch submission flow.
///
/// The successful path is `.idle` → `.authorizing` → `.submitting` →
/// `.completed`. Two terminal failure states exist because they require
/// different recovery UX:
/// - `.authorizationFailed` — delegation (ZKP #1) failed before any vote
///   was committed. All drafts are still in `draftVotes`; a single retry
///   re-runs delegation + all votes.
/// - `.submissionFailed` — delegation succeeded but one or more per-proposal
///   votes failed. Successful proposals have already been moved out of
///   `draftVotes`; a retry naturally resumes with only the remaining drafts.
enum BatchSubmissionStatus: Equatable {
    case idle
    case authorizing
    case submitting(currentIndex: Int, totalCount: Int, currentProposalId: UInt32)
    case completed(successCount: Int)
    case authorizationFailed(error: String)
    case submissionFailed(error: String, submittedCount: Int, totalCount: Int)

    /// True for `.authorizationFailed` and `.submissionFailed`. Retry and
    /// dismiss affordances key off this rather than pattern-matching the
    /// two cases everywhere.
    var isFailureState: Bool {
        switch self {
        case .authorizationFailed, .submissionFailed:
            return true
        case .idle, .authorizing, .submitting, .completed:
            return false
        }
    }
}

/// Substep of the per-proposal vote submission cycle. Renders as a 4-step
/// progress indicator on the Confirm Submission view.
enum VoteSubmissionStep: Equatable {
    case authorizingVote    // delegation proof (ZKP #1)
    case preparingProof     // syncVoteTree + generateVanWitness + buildVoteCommitment + signCastVote + submitVoteCommitment
    case confirming         // fetchTxConfirmation poll
    case sendingShares      // buildSharePayloads + delegateShares

    var label: String {
        switch self {
        case .authorizingVote: return String(localizable: .coinVoteStoreSubmissionAuthorizingVote)
        case .preparingProof: return String(localizable: .coinVoteStoreSubmissionPreparingProof)
        case .confirming: return String(localizable: .coinVoteStoreSubmissionWaitingForConfirmation)
        case .sendingShares: return String(localizable: .coinVoteStoreSubmissionSendingShares)
        }
    }

    var stepNumber: Int {
        switch self {
        case .authorizingVote: return 1
        case .preparingProof: return 2
        case .confirming: return 3
        case .sendingShares: return 4
        }
    }

    static let totalSteps = 4
}

/// Zashi-only readiness for the PIR precompute optimization (see
/// `RoundSession.delegationPrecomputeStatus`).
enum DelegationPrecomputeStatus: Equatable {
    case notStarted
    case inProgress
    case ready
    case failed(String)
}

/// State of the Keystone QR signing loop (one round-trip per bundle).
enum KeystoneSigningStatus: Equatable {
    case idle
    case preparingRequest
    case awaitingSignature
    case parsingSignature
    case finalizingAuthorization
    case failed(String)
}

/// Captured signature material for one Keystone-signed bundle.
struct KeystoneBundleSignature: Equatable {
    let bundleIndex: UInt32
    let sig: Data
    let sighash: Data
    let rk: Data // swiftlint:disable:this identifier_name
}

enum ShareTrackingStatus: Equatable {
    case idle
    case loading
    case tracking
    case fullyConfirmed
}

extension RoundSession {
    var resolvedKeystoneBundleIndices: Set<UInt32> {
        var indices = completedKeystoneDelegationBundleIndices
        indices.formUnion(keystoneBundleSignatures.map(\.bundleIndex))
        return indices.filter { $0 < bundleCount }
    }

    var resolvedKeystoneBundleCount: Int {
        resolvedKeystoneBundleIndices.count
    }

    var resolvedKeystonePrefixCount: UInt32 {
        let resolvedIndices = resolvedKeystoneBundleIndices
        var count: UInt32 = 0
        while count < bundleCount, resolvedIndices.contains(count) {
            count += 1
        }
        return count
    }

    var firstIncompleteKeystoneBundleIndex: UInt32? {
        Self.firstIncompleteKeystoneBundleIndex(
            bundleCount: bundleCount,
            resolvedIndices: resolvedKeystoneBundleIndices
        )
    }

    static func firstIncompleteKeystoneBundleIndex(
        bundleCount: UInt32,
        resolvedIndices: Set<UInt32>
    ) -> UInt32? {
        for bundleIndex in 0..<bundleCount where !resolvedIndices.contains(bundleIndex) {
            return bundleIndex
        }
        return nil
    }
}
#endif
