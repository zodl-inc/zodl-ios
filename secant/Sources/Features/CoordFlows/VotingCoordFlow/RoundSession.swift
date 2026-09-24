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

    /// Original eligible power before automatic trimming or Keystone bundle
    /// skipping. For untrimmed submissions this matches `votingWeight`; when
    /// bundles are omitted, `votingWeight` is reduced and this remains the
    /// original value for persisted transparency metadata.
    var eligibleVotingWeight: UInt64 = 0

    /// Number of note bundles (groups of up to 5 notes). Set by the
    /// bundling step in the active-round pipeline. Drives both the
    /// delegation proof loop and the per-bundle vote submission loop.
    var bundleCount: UInt32 = 0

    /// Original eligible bundle count before automatic trimming or a Keystone
    /// skip. Kept so a completed vote record can explain reduced power later.
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

    /// State of the Keystone QR signing loop. Idle for Zashi users.
    var keystoneSigningStatus: KeystoneSigningStatus = .idle

    /// Index of the bundle whose QR is on the signing screen (0-based), from
    /// the crate's own signing request rather than a count kept on this side.
    var currentKeystoneBundleIndex: UInt32 = 0

    /// Bundles the crate holds a signature for: restored from its stored rows
    /// on entry, added to as each scan is stored. Indices only -- the signature
    /// material is lifted off the signed PCZT inside the crate and never comes
    /// back here.
    var keystoneSignedBundles: Set<UInt32> = []

    /// What each bundle delegates, as the signing request for it reported.
    ///
    /// The crate quantizes bundles, so this is the only honest answer to what a
    /// signed prefix is worth; a bundle signed in an earlier entry into the
    /// round has no entry here, and ``keystoneWeight(ofFirst:)`` says so rather
    /// than counting it as nothing.
    var keystoneBundleWeights: [UInt32: UInt64] = [:]

    /// On a successful batch run we persist a one-line record (date, weight,
    /// proposal count) into the encrypted voting metadata file. The Results
    /// screen uses this to render "Voted MMM d - Voting Power X.XXX ZEC".
    var voteRecord: Voting.VoteRecord?

    /// Where the round's helper shares stand, as the session's share-tracking
    /// driver last reported them. The UI workstream owns presentation; the
    /// coordinator keeps this current so My Votes/review surfaces can read it.
    var shareTrackingStatus: ShareTrackingStatus = .idle

    /// Whether a tracking pass is running on this round's session right now.
    ///
    /// A run and a tracking pass are exclusive per session, and two passes over
    /// one round would contend for its rows, so nothing starts a second one.
    var isTrackingShares: Bool = false

    /// How many tracking passes have stopped short of confirming this round's
    /// shares. Drives the re-arm backoff, and is reset the moment a pass
    /// confirms them.
    var shareTrackingAttempt: Int = 0

    // MARK: - Round session state (the session-driven round)

    /// The last plan the round's session answered with: the driver's own view
    /// of what the round still owes. Read this rather than re-deriving work
    /// from drafts and vote rows — the planner computes its flags from an
    /// exhaustive match, so a step kind the app cannot name still counts as
    /// work here.
    var roundPlan: VotingRoundPlan?

    /// Latched `true` the moment a plan for this round ever reported
    /// `hasLegacyInFlightSubmission` -- an older build dispatched a delegation
    /// or vote for this round and never saw it confirmed, so it is shown and
    /// never driven. Set once, by the gate in `reduceRoundSessionOpened`, and
    /// never cleared for the life of this cached round session.
    ///
    /// A dedicated flag rather than re-reading `roundPlan?.hasLegacyInFlightSubmission`:
    /// `roundPlan` is also overwritten by plans embedded in drive events and
    /// run reports, which the SDK never stamps with this flag (they decode it
    /// as `false` even for a legacy-in-flight round -- see the SDK's migration
    /// guide).
    /// Those writers currently sit behind the gate this flag protects, so the
    /// difference is latent, but every guard reads the latch rather than
    /// depend on that staying true.
    var isLegacyInFlight: Bool = false

    /// What the current (or last) run has done so far, folded from the
    /// session's event stream.
    var progress = VotingRoundProgressSnapshot()

    /// What the current submission has measured, as the Confirm screen shows
    /// it. Fresh for every submission the voter starts; kept across the
    /// automatic re-runs the flow schedules on its own.
    var submissionProgress = VotingSubmissionProgress()

    /// Which session generation this cached state belongs to. The registry
    /// moves it on every time the round's session is reopened, so a run report
    /// or event arriving from a session that has since been replaced can be
    /// recognised as stale and dropped instead of writing back over newer
    /// state.
    var sessionEpoch: UInt64 = 0

    /// Whether this round has a session the flow can act on right now, and what
    /// that session was bound with.
    ///
    /// `VotingCoordFlow.State.openRoundSessionIds` is deliberately a superset --
    /// a round whose open was refused stays on it, because that list is what a
    /// fence closes -- so it answers "which rounds must be fenced", never "which
    /// rounds have a working session". This answers the second question, and it
    /// is the one every caller that is about to *use* a session reads.
    ///
    /// ``LiveSessionState/open(binding:)`` on its own is not permission to drive
    /// the round: a session opened to confirm helper shares holds no hotkey and
    /// can sign nothing, so anything that leads to a ballot asks for
    /// ``LiveSessionBinding/voting`` as well.
    var liveSession: LiveSessionState = .none

    /// Per-bundle result of the standalone delegation-proof precompute:
    /// whether that bundle's proof was generated or reused from the shared
    /// cache. Absent means no precompute has answered for the bundle yet.
    var precomputeStatus: [UInt32: VotingDelegationProofStatus] = [:]

    /// The redacted PCZT currently on screen as a Keystone QR, if any. One
    /// bundle at a time: the device signs per bundle, never a batch.
    var pendingKeystoneRequest: VotingKeystoneSigningRequest?

    /// Bundles the session says still await the voter's signature, ascending —
    /// the order the Keystone loop walks them in.
    var keystoneBundlesToSign: [UInt32] = []

    /// The ballot the host recorded with the session for the run now in flight.
    ///
    /// The authoritative record of what this run was asked to decide: the
    /// plan's completed display carries only proposals with a choice, so a
    /// deliberate skip appears nowhere in it, and a draft the voter skipped
    /// would otherwise survive a finished round and keep it looking unvoted.
    var castBallotIntents: [VotingBallotIntent] = []

    /// Whether this entry into the round has already asked the session to
    /// persist its bundle plan. One attempt per entry: a plan that still
    /// reports no bundle rows after a setup answered is a disagreement to
    /// surface, not a loop to run.
    var didAttemptBundleSetup: Bool = false

    /// How many times a run has been re-scheduled for this round after stopping
    /// with work still to do. Bounded, because a backoff the voter cannot see
    /// is indistinguishable from the app doing nothing.
    var runRetryCount: Int = 0

    /// What the last run isolated or skipped, when it finished with work it
    /// could not do. Nil when the run was clean; a completed run with this set
    /// is a partial success, and saying otherwise would be a lie about where
    /// the voter's ballot went.
    var lastRunFailureSummary: String?
}

// MARK: - Submission state machine types

/// Top-level state for the batch submission flow.
///
/// The successful path is `.idle` → `.requested` → `.authorizing` →
/// `.submitting` → `.completed`. Two terminal failure states exist because
/// they require different recovery UX:
/// - `.authorizationFailed` — delegation (ZKP #1) failed before any vote
///   was committed. All drafts are still in `draftVotes`; a single retry
///   re-runs delegation + all votes.
/// - `.submissionFailed` — delegation succeeded but one or more per-proposal
///   votes failed. Successful proposals have already been moved out of
///   `draftVotes`; a retry naturally resumes with only the remaining drafts.
enum BatchSubmissionStatus: Equatable {
    case idle
    /// Confirm was tapped; local auth (and any remaining prep) has not
    /// finished. No work has started. UI shows the Confirm CTA disabled
    /// with a spinner.
    case requested
    case authorizing
    /// A run is driving the round and has reported at least one event. What
    /// it has measured lives in `RoundSession.submissionProgress`.
    case submitting
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
        case .idle, .requested, .authorizing, .submitting, .completed:
            return false
        }
    }
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

/// Whether a round has a session to act on, and if not, what is being done
/// about it.
///
/// ``open(binding:)`` licenses a call that needs a session, on the terms its
/// binding allows. The other three are the ways a round can be without one:
/// nothing has been started, an open is in flight, or an open was refused and
/// another is scheduled. Telling them apart is what stops a second open being
/// started beside the first, and what stops a round whose open was refused
/// being treated as though it had succeeded.
enum LiveSessionState: Equatable {
    /// No session: never opened, refused for good, fenced, closed, ended, or
    /// lost to an open that was cancelled or stopped before it opened anything.
    case none
    /// An open is in flight. Nothing may use the session yet, and nothing may
    /// start a second open.
    case opening
    /// A session is open, bound to ``RoundSession/sessionEpoch``, and can do
    /// what `binding` says it can.
    case open(binding: LiveSessionBinding)
    /// An open was refused and the next attempt is waiting out its backoff.
    /// `attempt` counts the refusals so far, from zero.
    case backingOff(attempt: Int)

    /// Whether a session is open at all, whatever it was bound with. What the
    /// share-tracking paths ask, because confirming a share needs no key.
    var isOpen: Bool {
        if case .open = self {
            return true
        }
        return false
    }
}

/// What a round's session was bound with when it was opened, and so what it can
/// be asked to do.
///
/// A session's binding is fixed for its whole life, the same way its route and
/// its generation are: the two open paths pass different bindings and neither
/// can be upgraded afterwards.
///
/// Which is only an answer to "what can this round do" because the two opens
/// are kept from finishing over each other. Entering a round cancels the
/// sweep's open, and that open checks its own cancellation immediately before
/// it opens anything, so a session the round has stopped wanting is not built
/// in the first place. What a round is left holding is what the path that won
/// asked for.
///
/// Including when the sweep's open is already inside the SDK call, where no
/// cancellation reaches it. The registry refuses to hand an open to a caller
/// that asked for a different binding, route or epoch: it gives that attempt
/// up, closes whatever the SDK still answers it with, and builds the caller's
/// own -- so there is no window in which a round is left holding a session
/// bound differently from the path that opened it.
enum LiveSessionBinding: Equatable {
    /// The round's roster and nothing else. It can confirm the round's helper
    /// shares; holding no hotkey, it can sign nothing. What the pending-share
    /// sweep opens.
    case sharesOnly
    /// The voter's hotkey is bound too, so the round can be driven: a ballot
    /// recorded, a run started, a Keystone loop resumed. What entering the
    /// round opens.
    case voting
}

/// Where a round's helper shares stand.
///
/// Written only from what the session's share-tracking driver says: a pass
/// narrates itself through ``tracking(pass:)``, and the report it stops with
/// decides the rest. A pass that could not take the round -- another one
/// already holds it -- says nothing, and this stays where it was.
enum ShareTrackingStatus: Equatable {
    case idle
    /// A pass is under way; `pass` counts from 1.
    case tracking(pass: UInt32)
    /// A pass stopped short of confirming, and another is scheduled.
    case retrying
    /// Every share the round owed is confirmed.
    case confirmed
    /// The vote ended with shares still unconfirmed. Terminal: no later pass
    /// can confirm them.
    case ended
}

extension RoundSession {
    /// True when the submission CTA has a drafted choice to cast.
    ///
    /// Work the round owes beyond the drafts — a delivery a run stopped
    /// part-way through — is the session plan's answer rather than this one's;
    /// the coordinator's `canStartSubmission` reads both.
    var hasPendingSubmissionWork: Bool {
        !draftVotes.isEmpty
    }

    /// Signed bundles that still belong to this round, ignoring any index past
    /// its bundle count -- which a round whose tail was skipped has.
    var resolvedKeystoneBundleIndices: Set<UInt32> {
        keystoneSignedBundles.filter { $0 < bundleCount }
    }

    /// How many bundles are signed counting from the first.
    ///
    /// The prefix rather than the total, because it is the only count "use
    /// signed bundles only" can act on: the crate keeps the first `keepCount`
    /// bundles and deletes the rest, so a gap cannot be skipped over.
    var resolvedKeystonePrefixCount: UInt32 {
        let resolvedIndices = resolvedKeystoneBundleIndices
        var count: UInt32 = 0
        while count < bundleCount, resolvedIndices.contains(count) {
            count += 1
        }
        return count
    }

    /// The next bundle the device still owes: the first one this run asked for
    /// that the crate does not already hold a signature for.
    var nextKeystoneBundleToSign: UInt32? {
        keystoneBundlesToSign.first { !keystoneSignedBundles.contains($0) }
    }

    /// What the first `count` bundles delegate, when every one of them has a
    /// weight the crate named; nil when one does not, because inventing it
    /// would put a number the round never had on the voter's receipt.
    func keystoneWeight(ofFirst count: UInt32) -> UInt64? {
        var total: UInt64 = 0
        for bundleIndex in 0..<count {
            guard let weight = keystoneBundleWeights[bundleIndex] else { return nil }
            total += weight
        }
        return total
    }
}
#endif
