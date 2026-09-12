#if VOTING_ENABLED
//
//  VotingCoordFlowStore.swift
//  Zashi
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

@Reducer
struct VotingCoordFlow {
    @Reducer
    enum Path {
        case proposalList(ProposalList)
        case proposalDetail(ProposalDetail)
        case reviewVotes(ReviewVotes)
        case reviewDrafts(ReviewDrafts)
        case confirmSubmission(ConfirmSubmission)
        case delegationSigning(DelegationSigning)
        case tallying(Tallying)
        case results(Results)
        case ineligible(Ineligible)
        case configSettings(VotingConfigSettings)
    }

    @ObservableState
    struct State {
        /// The root screen shown beneath the NavigationStack. Pushed screens
        /// live in `path`; root replacements happen by mutating this field
        /// (e.g. transitioning from `.loading` to `.pollsList` after rounds
        /// load).
        enum RootScreen: Equatable {
            case loading
            case howToVote
            case noRounds
            case pollsList
            case walletSyncing
            case error(String)
            case configError(String)
        }

        var path = StackState<Path.State>()
        var rootScreen: RootScreen = .loading

        /// Per-round cached session data. Populated on first entry into a
        /// round (witness pipeline, hotkey, weight, etc.) and reused on
        /// re-entry. Evicted on `.dismissFlow`, wallet account switch, or
        /// voting service config change. See `RoundSession`.
        var roundCache: [String: RoundSession] = [:]

        /// Hex-encoded wallet account identifier, used to scope the voting
        /// SQLite DB and the encrypted voting metadata file to this wallet.
        var walletId: String = ""

        /// Whether the currently selected wallet account is a Keystone
        /// hardware wallet. Drives the signing path (Keystone QR flow vs
        /// in-app delegation).
        var isKeystoneUser: Bool = false

        /// Service config loaded from the pinned CDN (or a user override).
        /// Pins voting/PIR endpoints + the bundled round id allow-list.
        var serviceConfig: VotingServiceConfig?

        /// Rounds returned by the voting service, sorted by created_at_height.
        var allRounds: [RoundListItem] = []

        /// Per-round vote summaries persisted in the encrypted voting
        /// metadata file. Hydrated from disk once at `.initialize`; subsequent
        /// reads are O(1). Qualified with `Voting.` to distinguish from the
        /// top-level `VoteRecord` in `VotingModels` (which is the per-proposal
        /// Rust DB record).
        var voteRecords: [String: Voting.VoteRecord] = [:]

        /// True when the most recent rounds fetch failed (network/server).
        /// The polls list overlays a recoverable error sheet; the previously
        /// loaded list (if any) remains visible behind it.
        var pollsLoadError: Bool = false

        /// Round ids endorsed by Zodl (fetched from the bundled service
        /// config). On the default chain, only endorsed rounds are listed
        /// and any non-endorsed entry surfaces an unverified-poll warning.
        var zodlEndorsedRoundIds: Set<String> = []

        /// Process-lifetime proving caches should be warmed once when the
        /// flow opens. Failure is non-fatal; this only avoids cold proof
        /// latency for the first vote/delegation operation.
        var hasRequestedProvingCacheWarmup = false

        /// Whether the user is on the default (Zodl-bundled) voting service
        /// vs a custom override pinned via VotingConfigSettings. Drives the
        /// trust-indicator UI on the polls list cards.
        var isOnDefaultConfig: Bool { votingConfigOverrideURL.isEmpty }

        /// Current wallet scan progress, used by the WalletSyncing root
        /// screen. Updated by the sync-progress polling loop while the user
        /// waits for the wallet to reach a round's snapshot height.
        var walletScannedHeight: UInt64 = 0

        /// The roundId whose pipeline is gated on wallet sync. Restored once
        /// the wallet catches up so we re-trigger the pipeline for the right
        /// round.
        var pendingPipelineRoundId: String?

        /// Active "Insufficient Balance" sheet on the Polls List. Set when
        /// the active-round pipeline determines the wallet can't participate
        /// (no notes at snapshot, or all bundles dropped below ballotDivisor).
        /// Replaces the legacy full-screen IneligibleView so the user stays
        /// on the polls list and can pick a different round.
        var ineligibleSheet: IneligibleSheetData?

        /// Round id whose eligibility check is currently in flight, set when
        /// the user taps Enter Poll on an uncached active round. Drives the
        /// in-button spinner on the Polls List so navigation only happens
        /// after the pipeline confirms eligibility — avoiding a brief flash
        /// to the proposal list when the wallet turns out to be ineligible.
        var checkingEligibilityRoundId: String?

        /// Round id behind the "Wallet Syncing" sheet on the Polls List.
        /// Set when the active-round pipeline detects the wallet hasn't
        /// caught up to the round's snapshot height. Replaces the legacy
        /// full-screen `walletSyncing` root so the user stays on the polls
        /// list (and can try again later or pick a different round).
        var walletSyncingSheetRoundId: String?

        /// "Unanswered Questions" confirmation sheet shown when the user
        /// taps Next on the last proposal detail but some questions
        /// remain unanswered. The user can either confirm to proceed to
        /// the Review screen with those questions left blank, or go back
        /// to the Proposal List to fill them in. We never auto-select a
        /// choice on the user's behalf.
        var skippedQuestionsSheet: SkippedQuestionsSheetData?

        // MARK: - Submission flow-wide state (Stage 5)

        /// Signals that a run should start again without a second
        /// authentication prompt -- the continuation of a Confirm the voter has
        /// already authenticated, after the bundle rows it turned out to need
        /// were persisted. Cleared on success, retry, or flow dismiss.
        var pendingBatchSubmission: Bool = false

        /// Round id whose submission alert is currently surfaced. Drives
        /// the alert presentation; nil when no alert.
        var submissionAlertRoundId: String?

        /// Alert state for transient errors during submission setup (e.g.
        /// the not-yet-wired stub placeholder). Real submission errors are
        /// surfaced on the Confirm Submission screen via
        /// `RoundSession.batchSubmissionStatus`.
        @Presents var submissionAlert: AlertState<Never>?

        /// Blocking acknowledgement sheet for an invalid Keystone signed-PCZT
        /// scan during the multi-bundle signing loop. The message is fully
        /// composed up-front from the localized rejection-reason string.
        var keystoneSignatureRejectionSheet: KeystoneSignatureRejectionSheet?

        struct KeystoneSignatureRejectionSheet: Equatable {
            let message: String
        }

        /// Sheet state for the Keystone QR scan that captures the signed
        /// PCZT from the device. Lifecycle is bound to the delegation
        /// signing screen.
        @Presents var keystoneScan: Scan.State?

        /// Confirmation alert shown when the user taps "Skip remaining
        /// bundles" mid-Keystone-signing-loop. Shows locked-in vs.
        /// giving-up amounts so the decision is informed.
        @Presents var skipBundlesAlert: AlertState<Action>?

        /// Bottom sheet shown when an opened active round transitions to
        /// tallying or finalized while the user is still in voting / review /
        /// submission. Carries the round id and the new status so the action
        /// buttons can route to the right screen.
        var pollClosedSheet: PollClosedSheet?

        struct PollClosedSheet: Equatable {
            let roundId: String
            let status: SessionStatus
        }

        /// The generation to stamp the next round session with.
        ///
        /// Monotonic for the flow's lifetime and never reused: a run report or
        /// event carrying an older generation belongs to a session that has
        /// since been replaced, and writing it back would undo newer state.
        var votingSessionEpoch: UInt64 = 0

        /// The rounds this flow has opened a session for and not closed, in the
        /// order they were opened.
        ///
        /// The registry knows this too, but it is an actor: the reducer has to
        /// decide synchronously which rounds a wallet switch or a route change
        /// must fence, and this is that answer. Deliberately a superset -- a
        /// round whose open was refused stays on it, because fencing a round the
        /// registry holds no session for does nothing, while missing one it does
        /// hold leaves a session driving a wallet or a route that is gone.
        var openRoundSessionIds: [String] = []

        /// The transport the open sessions were opened on, or nil when none are
        /// open.
        ///
        /// A session's route is fixed for its whole life, so a wallet that
        /// changes its mind about Tor mid-round leaves every open session on the
        /// wrong transport. This is what a change is compared against -- the
        /// shared value's publisher replays the value it already has on
        /// subscription, and the wallet re-announces the route it already had on
        /// its own.
        var sessionRouteAccess: WalletStorage.SwapAPIAccess?

        /// Whether the crate's proving policy has been fixed for this process.
        ///
        /// Once per process, and first: warming the caches (or the first proof)
        /// starts the pool on the crate's own default policy, and a policy asked
        /// for after that is refused.
        var hasConfiguredProving = false

        /// Whether the rounds that still owe helper-share work have been read
        /// back for this initialize.
        ///
        /// The rounds list lands again on every refresh and on every turn of
        /// the new-round poll, and reopening a round's session on each of those
        /// would replace the session a tracking pass is already running on. So
        /// the sweep happens once per initialize and the later triggers --
        /// entering the flow, finishing a run -- carry it from there.
        var hasResumedPendingShareRounds = false

        @Shared(.inMemory(.selectedWalletAccount))
        var selectedWalletAccount: WalletAccount?

        /// Whether the wallet routes its API traffic through Tor. A round
        /// session is opened on the same terms, and `.tor` fails closed rather
        /// than quietly announcing the voter over a plain connection.
        @Shared(.inMemory(.swapAPIAccess))
        var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct

        @Shared(.appStorage(.hasSeenHowToVote))
        var hasSeenHowToVoteForZashi: Bool = false

        @Shared(.appStorage(.hasSeenHowToVoteKeystone))
        var hasSeenHowToVoteForKeystone: Bool = false

        @Shared(.appStorage(.votingConfigOverrideURL))
        var votingConfigOverrideURL: String = ""

        /// Whether the current wallet account has already seen the
        /// "How to vote" intro. Keystone and Zashi accounts have separate
        /// flags so a user switching wallets sees the intro once per side.
        var hasSeenHowToVoteForCurrentWallet: Bool {
            isKeystoneUser ? hasSeenHowToVoteForKeystone : hasSeenHowToVoteForZashi
        }

        init() {}
    }

    enum Action {
        case path(StackActionOf<Path>)
        case onAppear
        case warmProvingCaches
        case walletAccountChanged(WalletAccount?)
        /// The wallet's Tor preference changed while the flow was open. A
        /// session's route is fixed when it is opened, so every open session is
        /// fenced and closed and the next use of a round opens on the new route.
        case swapAPIAccessChanged(WalletStorage.SwapAPIAccess)
        /// A wallet reset or heal has begun: the sidecar is about to be closed and
        /// deleted. Everything this flow has open goes now, and ``VotingTeardown``
        /// refuses the opens that would otherwise recreate it.
        case votingTeardownBegan
        /// A config load that ended without asking for a proving policy -- it was
        /// refused by a teardown, or it failed before reaching the ask. The flag
        /// that makes the ask once-per-process is released so a later load can.
        case provingPolicyNotApplied
        /// A round entry abandoned before its session was opened, because a wallet
        /// teardown began while it was in flight. Not an error the voter did
        /// anything about: the entry state is cleared and the polls list stays.
        case roundEntryAbandoned(roundId: String)
        case dismissFlow
        /// Done CTA on the success screen — lands the user on the just-
        /// submitted round's read-only ProposalList instead of tearing the
        /// flow down completely. Share-recovery polling is intentionally
        /// kept running.
        case submissionDoneTapped(roundId: String)
        case howToVoteContinueTapped
        case retryLoadRounds
        case openConfigSettings
        case initialize
        case serviceConfigLoaded(VotingServiceConfig)
        case allRoundsLoaded([VotingSession])
        case roundsLoadFailed
        case zodlEndorsementsLoaded(Set<String>)
        case zodlEndorsementsFailed
        case configUnsupported(String)
        case initializeFailed(String)
        case roundTapped(String)
        case ineligibleForRound(roundId: String, reason: IneligibleReason)
        case earlyEligibilityConfirmed(roundId: String)
        case dismissIneligibleSheet
        case dismissWalletSyncingSheet
        case dismissProposalDetailStack
        case openReviewDraftsScreen(roundId: String)
        case proposalDetailNextTapped(roundId: String, currentProposalId: UInt32)
        case dismissSkippedQuestionsSheet
        /// "Go back" CTA on the unanswered-questions sheet — terminates the
        /// proposal-detail walk and returns the user to the active-voting
        /// ProposalList so the skipped questions are visible at a glance.
        case skippedQuestionsGoBackTapped
        case confirmSkippedQuestionsAndReview(roundId: String)
        case refreshActiveRoundsList
        case startRoundStatusPolling(roundId: String)
        case roundStatusUpdated(roundId: String, status: SessionStatus)
        case dismissPollClosedAlert
        case viewPollClosedResults
        case startNewRoundPolling
        /// The rounds the sidecar says still owe helper-share work, read once
        /// per initialize so a delivery interrupted by a kill or a crash
        /// resumes without the voter opening the round again.
        case pendingShareRoundsLoaded([VotingPendingShareRound])
        /// Drive the round's unconfirmed helper shares towards confirmation.
        /// One pass per send; the report it stops with decides whether another
        /// is scheduled.
        case pollShareStatus(roundId: String)
        /// One observation from a share-tracking pass, stamped with the session
        /// generation it came from so a replaced session's narration can be
        /// dropped rather than written back.
        case shareTrackingEvent(roundId: String, epoch: UInt64, event: VotingShareTrackingEvent)
        /// The report a share-tracking pass stopped with -- authoritative,
        /// where the events are a narration the SDK may drop.
        case shareTrackingFinished(roundId: String, epoch: UInt64, report: VotingShareTrackingRunReport)
        /// A tracking pass that could not run at all: the round's session went
        /// away under it, or a run holds the session.
        case shareTrackingFailed(roundId: String, epoch: UInt64, error: VotingError)
        case retryFetchTallyResults(roundId: String)
        case viewMyVotesTapped(roundId: String)
        case proposalTapped(roundId: String, proposalId: UInt32, mode: ProposalDetail.Mode = .voting)
        case startActiveRoundPipeline(roundId: String)
        case walletNotSynced(roundId: String, scannedHeight: UInt64, snapshotHeight: UInt64)
        case walletSyncProgressUpdated(height: UInt64)
        /// The round's bundle totals, from the layout bundle setup answered
        /// with or from an eligibility check on a round whose bundles already
        /// exist. Pure state: the voting power the ballot and confirmation
        /// screens show.
        case votingWeightLoaded(roundId: String, weight: UInt64, bundleCount: UInt32)
        case pipelineFailed(roundId: String, message: String)
        case submittedVotesLoaded(roundId: String, votes: [UInt32: VoteChoice])
        case draftVoteSet(roundId: String, proposalId: UInt32, choice: VoteChoice)
        case submitTapped(roundId: String)
        case fetchTallyResults(roundId: String)
        case tallyResultsLoaded(roundId: String, results: [UInt32: TallyResult])
        case tallyResultsFailed(roundId: String, message: String)
        case submissionAlert(PresentationAction<Never>)
        case dismissKeystoneSignatureRejectionSheet

        // MARK: - Stage 5: submission pipeline

        /// User tapped the Submit button on the Confirm Submission screen.
        /// Routes through local auth (Zashi) or directly into delegation
        /// signing (Keystone). Stage 5A: no-op stub.
        case submitAllDraftsTapped(roundId: String)

        /// User explicitly cleared a draft vote (from the Review screen
        /// edit affordance). Stage 5A: no-op stub; Stage 5B writes through
        /// to the encrypted metadata file.
        case clearDraftVote(roundId: String, proposalId: UInt32)

        /// Biometric / passcode auth gate succeeded; submission can proceed.
        /// For Keystone accounts the auth gate is the device itself, so
        /// `.submitAllDraftsTapped` dispatches this directly.
        case authenticationSucceeded(roundId: String)

        /// Biometric / passcode auth gate was declined or dismissed. Rolls
        /// the `.requested` CTA state back to `.idle`; declining is a
        /// choice, not an error, so nothing else is surfaced.
        case batchAuthenticationDeclined(roundId: String)

        /// Keystone only: ask the crate for the next bundle's redacted PCZT,
        /// which the QR signing screen shows the device. A software wallet's
        /// delegation happens inside the run, with no step for the host.
        case startDelegationProof(roundId: String)

        /// Zashi-only PIR precompute optimization. Runs in the background
        /// while the user is choosing votes so the actual ZKP doesn't
        /// start from cold.
        case maybeStartDelegationPrecompute(roundId: String)
        case delegationPrecomputeCompleted(roundId: String)
        case delegationPrecomputeFailed(roundId: String, error: String)

        // MARK: - Stage 5: the round session

        /// A session is open for the round and has answered with its plan --
        /// the driver's own view of what the round still owes.
        case roundSessionOpened(roundId: String, plan: VotingRoundPlan)
        /// The ballot is recorded with the session, which answered with the
        /// plan it leaves the round in.
        case ballotIntentsRecorded(roundId: String, plan: VotingRoundPlan)
        case roundSessionOpenFailed(roundId: String, error: VotingError)
        /// The round's bundle rows are persisted; the layout says how many and
        /// for how much voting power.
        case bundlesSetUp(roundId: String, layout: VotingBundleLayout)
        case bundleSetupFailed(roundId: String, error: VotingError)
        /// One step of the background delegation-proof precompute for a bundle.
        case precomputeProofEvent(roundId: String, bundleIndex: UInt32, event: VotingDelegationProofEvent)
        /// A precompute that failed. Recorded, never blocking: Confirm runs the
        /// proof itself if it has to.
        case precomputeProofFailed(roundId: String, bundleIndex: UInt32, error: VotingError)
        /// One element of a round run's stream, stamped with the session
        /// generation it came from so a replaced session's events can be
        /// dropped.
        case roundRunEvent(roundId: String, epoch: UInt64, event: VotingRoundRunEvent)
        case roundRunFailed(roundId: String, epoch: UInt64, error: VotingError)
        /// What the host owes the round now that one run has stopped.
        case roundRunDecision(roundId: String, decision: VotingRoundHostDecision)

        // MARK: - Stage 5: submission results

        case batchSubmissionCompleted(roundId: String, successCount: Int, failCount: Int)
        case batchAuthorizationFailed(roundId: String, error: String)
        case batchSubmissionFailed(roundId: String, error: String, submittedCount: Int, totalCount: Int)
        case retryBatchSubmission(roundId: String)
        case dismissBatchResults(roundId: String)

        // MARK: - Stage 5: Keystone delegation signing loop

        /// One bundle's redacted PCZT, as the crate built it for the device.
        case keystoneSigningPrepared(roundId: String, request: VotingKeystoneSigningRequest)
        case keystoneSigningFailed(roundId: String, error: String)
        case openKeystoneSignatureScan
        case keystoneScan(PresentationAction<Scan.Action>)
        /// The crate accepted the signed PCZT scanned back for this bundle and
        /// stored its signature.
        case keystoneBundleSignatureStored(roundId: String, bundleIndex: UInt32)
        case keystoneAllBundlesSigned(roundId: String)
        /// The bundles the crate already holds a signature for, read back on
        /// entry so the signing screen resumes where the voter left it.
        case keystoneSignaturesRestored(roundId: String, bundleIndices: [UInt32])
        case keystoneShowSigningScreen(roundId: String)
        case keystoneSignatureRejected(roundId: String, message: String)
        case skipRemainingKeystoneBundles(roundId: String)
        case skipRemainingKeystoneBundlesConfirmed(roundId: String)
        case skipBundlesAlert(PresentationAction<Action>)
        case delegationRejected(roundId: String)
    }

    @Dependency(\.backgroundTask) var backgroundTask
    @Dependency(\.continuousClock) var continuousClock
    @Dependency(\.databaseFiles) var databaseFiles
    @Dependency(\.keystoneHandler) var keystoneHandler
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.pasteboard) var pasteboard
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.votingAPI) var votingAPI
    @Dependency(\.votingCrypto) var votingCrypto
    @Dependency(\.votingMetadata) var votingMetadata
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    /// Cancellation id for the per-round pipeline (witness verify, hotkey
    /// derivation, voting weight). Phase 4b's `.startActiveRoundPipeline`
    /// effect attaches to this so a new round entry or `.dismissFlow` can
    /// cancel an in-flight pipeline.
    let cancelPipelineId = UUID()

    /// Cancellation id for the batch submission `.run` effect. `.dismissFlow`,
    /// account switch, and config change all cancel this so the submission
    /// loop doesn't outlive the flow.
    let cancelSubmissionId = UUID()

    /// Cancellation id for the delegation proof (ZKP #1) `.run` effect.
    let cancelDelegationProofId = UUID()

    /// Cancellation id for the backoff between two runs of a round. Its own id,
    /// not the submission's: a scheduled re-run must not cancel the run that
    /// scheduled it.
    let cancelRunRetryId = UUID()

    /// Cancellation id for Zashi's background delegation PIR precompute.
    let cancelDelegationPrecomputeId = UUID()

    /// Cancellation id for the opened-round status polling loop.
    let cancelStatusPollingId = UUID()

    /// Cancellation id for the post-finalization rounds-list polling loop.
    let cancelNewRoundPollingId = UUID()

    /// Cancellation id for one round's share-tracking pass.
    ///
    /// Per round rather than per flow: two rounds can be owed helper work at
    /// once, and cancelling a tracking pass finishes the session it runs on --
    /// so one id for all of them would take a second round's session down with
    /// the first. For the same reason nothing cancels in flight on this id:
    /// every deliberate cancel of it is a round whose session is going anyway,
    /// and a `cancelInFlight` would be the one path that reaches a session
    /// nobody is closing.
    func cancelShareTrackingId(_ roundId: String) -> VotingShareTrackingCancelID {
        VotingShareTrackingCancelID.pass(roundId)
    }

    /// Cancellation id for the backoff between two of a round's tracking
    /// passes. Its own id, so stopping a scheduled pass never reaches the
    /// session a pass in flight is driving.
    func cancelShareTrackingReArmId(_ roundId: String) -> VotingShareTrackingCancelID {
        VotingShareTrackingCancelID.reArm(roundId)
    }

    /// Cancellation id for the open that resumes one round's share tracking.
    /// Per round, so a sweep that resumes two of them does not have the second
    /// open cancel the first.
    func cancelShareTrackingResumeId(_ roundId: String) -> VotingShareTrackingCancelID {
        VotingShareTrackingCancelID.resume(roundId)
    }

    /// Cancellation id for the subscription to the wallet's Tor preference,
    /// which lives exactly as long as there is a session whose route it could
    /// invalidate.
    let cancelRouteObservationId = UUID()

    /// Cancellation id for the subscription to wallet teardowns, which lives for
    /// as long as the flow does: a reset can begin at any point after the flow
    /// has opened the sidecar, not only while a round session is open.
    let cancelTeardownObservationId = UUID()

    var body: some Reducer<State, Action> {
        coordinatorReduce()
            .forEach(\.path, action: \.path)
            .ifLet(\.$submissionAlert, action: \.submissionAlert)
            .ifLet(\.$keystoneScan, action: \.keystoneScan) {
                Scan()
            }
            .ifLet(\.$skipBundlesAlert, action: \.skipBundlesAlert)
    }
}

/// What a share-tracking effect is cancelled by, for one round.
enum VotingShareTrackingCancelID: Hashable {
    /// One pass over the round's unconfirmed shares.
    case pass(String)
    /// The wait before the next pass.
    case reArm(String)
    /// The session open that puts a round with interrupted delivery back in a
    /// position to be tracked.
    case resume(String)
}

/// Why a wallet cannot take part in a round.
///
/// The two are different statements about the voter's own money and are told
/// apart deliberately: the crate answers "no spendable notes" and "notes, but
/// under the divisor" as different kinds, and neither answer carries a figure
/// the sheet could quote. Saying "you held 0.000 ZEC" for the second would be a
/// wrong claim about a balance the wallet does have.
enum IneligibleReason: Equatable {
    /// No notes at all were spendable at the round's snapshot.
    case noSpendableNotes
    /// Notes existed, but every bundle fell below `ballotDivisor`.
    case belowMinimum
}

/// Data backing the Polls List "Insufficient Balance" sheet. Captured at
/// the moment the pipeline determines the wallet can't participate so the
/// sheet copy doesn't drift if state evolves while the sheet is up.
struct IneligibleSheetData: Equatable {
    /// Which of the two ineligibility statements the sheet makes.
    let reason: IneligibleReason

    /// Snapshot block height for the round, used by the sheet body to
    /// explain when the eligibility cutoff was taken.
    let snapshotHeight: UInt64

    /// Minimum balance required to participate (one `ballotDivisor` unit).
    let minimumZatoshi: UInt64
}

/// Backing data for the "Unanswered Questions" confirmation sheet shown
/// from the last Proposal Detail's Next CTA. Captures the round id (so
/// the confirm action knows which round to route into the Review
/// screen) and the 1-indexed positions of the unanswered proposals
/// (already humanized for display).
struct SkippedQuestionsSheetData: Equatable {
    let roundId: String
    let skippedDisplayIndices: [Int]
}
#endif
