import Combine
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import os

let votingLogger = Logger(subsystem: "co.zodl.voting", category: "VotingStore")

enum VotingFlowError: LocalizedError {
    case missingActiveSession
    case missingSigningAccount
    case missingHotkeyAddress
    case missingPendingUnsignedPczt
    case invalidDelegationSignature
    case missingVoteCommitmentBundle
    case delegationTxFailed(code: UInt32, log: String)
    case voteCommitmentTxFailed(code: UInt32, log: String)

    var errorDescription: String? {
        switch self {
        case .missingActiveSession:
            return String(localizable: .coinVoteStoreErrorMissingActiveSession)
        case .missingSigningAccount:
            return String(localizable: .coinVoteStoreErrorMissingSigningAccount)
        case .missingHotkeyAddress:
            return String(localizable: .coinVoteStoreErrorMissingHotkeyAddress)
        case .missingPendingUnsignedPczt:
            return String(localizable: .coinVoteStoreErrorMissingPendingUnsignedPczt)
        case .invalidDelegationSignature:
            return String(localizable: .coinVoteStoreErrorInvalidDelegationSignature)
        case .missingVoteCommitmentBundle:
            return String(localizable: .coinVoteStoreErrorMissingVoteCommitmentBundle)
        case .delegationTxFailed(let code, let log):
            let suffix = log.isEmpty ? "" : ": \(log)"
            return String(localizable: .coinVoteStoreErrorDelegationTxFailed(String(code), suffix))
        case .voteCommitmentTxFailed(let code, let log):
            let suffix = log.isEmpty ? "" : ": \(log)"
            return String(localizable: .coinVoteStoreErrorVoteCommitmentTxFailed(String(code), suffix))
        }
    }
}

enum VotingErrorMapper {
    static func userFriendlyMessage(from error: Error) -> String {
        if let shareError = error as? ShareDelegationError {
            switch shareError {
            case .noReachableVoteServers:
                return String(localizable: .coinVoteStoreUserErrorNoReachableVoteServers)
            }
        }
        return userFriendlyMessage(from: error.localizedDescription)
    }

    static func userFriendlyMessage(from rawError: String) -> String {
        if rawError.contains("nullifier already spent") {
            return String(localizable: .coinVoteStoreUserErrorNullifierAlreadySpent)
        }
        if rawError.contains("vote round is not active") {
            return String(localizable: .coinVoteStoreUserErrorRoundNotActive)
        }
        if rawError.contains("vote round not found") {
            return String(localizable: .coinVoteStoreUserErrorRoundNotFound)
        }
        if rawError.contains("No active voting round") {
            return String(localizable: .coinVoteStoreUserErrorRoundNotActive)
        }
        if rawError.contains("PIR proof root mismatch") {
            return String(localizable: .coinVoteStoreUserErrorPirSnapshotMismatch)
        }
        if rawError.contains("PIR proof verification failed") {
            return String(localizable: .coinVoteStoreUserErrorPirInvalidProofData)
        }
        if rawError.contains("PIR server connect failed") || rawError.contains("PIR parallel fetch failed") {
            return String(localizable: .coinVoteStoreUserErrorPirUnavailable)
        }
        // PirSnapshotResolverError.noMatchingEndpoint — no configured PIR
        // endpoint is serving the round's exact snapshot height (some are
        // behind catching up, some may be ahead, others unreachable), so the
        // SDK refuses to delegate against a mismatched tree. There's nothing
        // the user can do besides wait.
        if rawError.contains("No PIR server matches") {
            return String(localizable: .coinVoteStoreUserErrorPirSnapshotMismatch)
        }
        // PirSnapshotResolverError.noEndpointsConfigured — the voting config
        // shipped without any PIR endpoints; this is a config-side bug, not
        // something the user can fix on-device.
        if rawError.contains("No PIR endpoints are configured") {
            return String(localizable: .coinVoteStoreUserErrorPirEndpointsMissing)
        }
        if rawError.contains("Commitment tree did not grow") {
            return String(localizable: .coinVoteStoreUserErrorCommitmentTreeNotGrown)
        }
        if rawError.contains("invalid commitment tree anchor height") {
            return String(localizable: .coinVoteStoreUserErrorInvalidAnchorHeight)
        }
        if rawError.contains("invalid zero-knowledge proof") {
            return String(localizable: .coinVoteStoreUserErrorInvalidProof)
        }
        if rawError.contains("delegation bundle build failed") || rawError.contains("create_proof failed") {
            return String(localizable: .coinVoteStoreUserErrorProofGenerationFailed)
        }
        if rawError.contains("NoTreeState") || rawError.contains("no tree state") {
            return String(localizable: .coinVoteStoreUserErrorNoTreeState)
        }
        if rawError.contains("HTTP 5") {
            return String(localizable: .coinVoteStoreUserErrorHttp5)
        }
        if rawError.contains("GRPCStatus") || rawError.contains("RPC timed out") || rawError.contains("Transport became inactive") {
            return String(localizable: .coinVoteStoreUserErrorLightwalletdUnavailable)
        }
        return rawError
    }
}

@Reducer
struct Voting {
    @Dependency(\.backgroundTask)
    var backgroundTask
    @Dependency(\.databaseFiles)
    var databaseFiles
    @Dependency(\.keystoneHandler)
    var keystoneHandler
    @Dependency(\.mnemonic)
    var mnemonic
    @Dependency(\.pasteboard)
    var pasteboard
    @Dependency(\.sdkSynchronizer)
    var sdkSynchronizer
    @Dependency(\.votingAPI)
    var votingAPI
    @Dependency(\.votingCrypto)
    var votingCrypto
    @Dependency(\.localAuthentication)
    var localAuthentication
    @Dependency(\.walletStorage)
    var walletStorage
    @Dependency(\.zcashSDKEnvironment)
    var zcashSDKEnvironment
    @ObservableState
    struct State: Equatable {
        enum Screen: Equatable {
            case howToVote
            case loading
            case noRounds
            case pollsList
            case delegationSigning
            case proposalList
            case proposalDetail(id: UInt32)
            case ineligible
            case tallying
            case results
            case reviewVotes
            case confirmSubmission
            case error(String)
            case configError(String)
            case configSettings
            case walletSyncing
        }

        struct RoundListItem: Equatable, Identifiable {
            var id: String { session.voteRoundId.hexString }
            let roundNumber: Int
            let session: VotingSession
            var title: String {
                session.title.isEmpty
                    ? String(localizable: .coinVoteStoreRoundTitle(String(roundNumber)))
                    : session.title
            }
        }

        struct NoteWitnessResult: Equatable, Identifiable {
            var id: UInt64 { position }
            let position: UInt64
            let value: UInt64
            let verified: Bool
        }

        enum WitnessStatus: Equatable {
            case notStarted
            case inProgress
            case completed
            case failed(String)
        }

        enum DelegationPrecomputeStatus: Equatable {
            case notStarted
            case inProgress
            case ready
            case failed(String)
        }

        struct WitnessTiming: Equatable {
            let treeStateFetchMs: UInt64
            let witnessGenerationMs: UInt64
            let verificationMs: UInt64
            var totalMs: UInt64 { treeStateFetchMs + witnessGenerationMs + verificationMs }
        }

        enum KeystoneSigningStatus: Equatable {
            case idle
            case preparingRequest
            case awaitingSignature
            case parsingSignature
            case failed(String)
        }

        enum IneligibilityReason: Equatable {
            case noNotes
            case balanceTooLow
        }

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

        var screenStack: [Screen] = [.howToVote]
        var votingRound: VotingRound
        var votes: [UInt32: VoteChoice] = [:]
        var votingWeight: UInt64
        var isKeystoneUser: Bool
        var walletId: String
        var roundId: String
        var activeSession: VotingSession?

        /// All rounds fetched from the server, sorted by snapshot height and numbered.
        var allRounds: [RoundListItem] = []
        /// Computed: rounds that are active or tallying (newest first).
        var activeRounds: [RoundListItem] {
            allRounds.filter { $0.session.status == .active || $0.session.status == .tallying }.reversed()
        }

        /// Computed: rounds that are finalized (newest first).
        var completedRounds: [RoundListItem] {
            allRounds.filter { $0.session.status == .finalized }.reversed()
        }

        /// Resolved service config from CDN or local override.
        var serviceConfig: VotingServiceConfig?

        /// Tally results for finalized rounds (proposalId -> TallyResult).
        var tallyResults: [UInt32: TallyResult] = [:]
        var isLoadingTallyResults: Bool = false

        /// Reason the user can't participate (set when navigating to .ineligible).
        var ineligibilityReason: IneligibilityReason?

        /// Wallet sync progress info for the walletSyncing screen.
        var walletScannedHeight: UInt64 = 0

        /// Per-proposal share confirmation tracking (proposalId -> confirmed count 0-5).

        // Share delegation tracking (DB-backed, per-round)
        var shareTrackingStatus: ShareTrackingStatus = .idle
        var shareDelegations: [VotingShareDelegation] = []
        var showShareInfoSheet: Bool = false
        var shareInfoProposalId: UInt32?

        enum ShareTrackingStatus: Equatable {
            case idle
            case loading
            case tracking
            case fullyConfirmed
        }

        /// Cached wallet notes from the snapshot query, used by delegation proof.
        var walletNotes: [NoteInfo] = []

        /// Number of note bundles (groups of up to 5 notes). Set by setupBundles.
        var bundleCount: UInt32 = 0

        /// Hotkey address derived from keychain mnemonic, shown on delegation signing screen.
        var hotkeyAddress: String?

        @Shared(.inMemory(.selectedWalletAccount))
        var selectedWalletAccount: WalletAccount?
        @Shared(.inMemory(.toast))
        var toast: Toast.Edge?
        @Shared(.appStorage(.hasSeenHowToVote))
        var hasSeenHowToVote: Bool = false
        @Shared(.appStorage(.hasSeenHowToVoteKeystone))
        var hasSeenHowToVoteKeystone: Bool = false
        @Shared(.appStorage(.votingConfigOverrideURL))
        var votingConfigOverrideURL: String = ""

        var hasSeenHowToVoteForCurrentWallet: Bool {
            isKeystoneUser ? hasSeenHowToVoteKeystone : hasSeenHowToVote
        }

        var isOnDefaultConfig: Bool {
            votingConfigOverrideURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Persisted record of when the current round finished submitting,
        /// loaded from UserDefaults in `roundTapped`. Used by Results to
        /// render "Voted MMM d - Voting Power X.XXX ZEC" days after submission.
        var voteRecord: VoteRecord?

        /// Per-round persisted vote records keyed by round ID, populated by a
        /// one-time scan of UserDefaults during `allRoundsLoaded`. The polls
        /// list uses this to render the Voted pill on active-round cards
        /// without re-querying UserDefaults from the view. A record exists only
        /// once the round has no remaining draft votes to edit or retry.
        var voteRecords: [String: VoteRecord] = [:]

        /// Round ids (lowercase hex) endorsed by the on-chain `zodl` endorser.
        /// Used to render a small endorsement icon on finalized round cards and the Results header.
        var zodlEndorsedRoundIds: Set<String> = []

        var selectedProposalId: UInt32?

        // MARK: - Batch voting

        /// Draft votes (batch mode): proposal ID -> chosen option. Persisted to
        /// UserDefaults to survive app termination. Drafts are not submitted
        /// until the user explicitly triggers batch submission.
        var draftVotes: [UInt32: VoteChoice] = [:]

        /// Snapshot of the edited proposal's draft at the moment the user
        /// opened it from the Review screen. `.cancelEdit` writes this back
        /// to `draftVotes` so any option taps made during the session are
        /// discarded. `nil` whenever the user isn't in an edit-from-review
        /// session.
        struct EditingFromReviewSnapshot: Equatable {
            let proposalId: UInt32
            /// The draft value at entry. `nil` means the proposal had no prior
            /// draft — Cancel should remove whatever was drafted.
            let priorDraft: VoteChoice?
        }

        var editingFromReview: EditingFromReviewSnapshot?

        enum BatchSubmissionStatus: Equatable {
            case idle
            case authorizing
            case submitting(currentIndex: Int, totalCount: Int, currentProposalId: UInt32)
            case completed(successCount: Int)
            /// Delegation (ZKP #1) failed before any vote was submitted.
            /// Successful drafts are still in `draftVotes` because the auth
            /// phase runs before the per-proposal submission loop.
            case authorizationFailed(error: String)
            /// One or more proposal submissions failed after delegation
            /// succeeded. Successful proposals have already been removed from
            /// `draftVotes`, so a retry naturally resumes with only the
            /// remaining unsent proposals.
            case submissionFailed(error: String, submittedCount: Int, totalCount: Int)
        }

        var batchSubmissionStatus: BatchSubmissionStatus = .idle
        /// Per-proposal error messages from the last batch submission run.
        var batchVoteErrors: [UInt32: String] = [:]

        /// True while the "Poll Closed" bottom sheet is visible. Set when the
        /// active round transitions to tallying/finalized while the user is
        /// in an in-flow screen (voting/review/confirm/delegation) so we do
        /// not yank them out of context without explanation. Cleared by
        /// either `.dismissPollClosedSheet` or `.viewPollClosedResults`.
        var showPollClosedSheet: Bool = false

        /// Shown before entering a poll that isn't Zodl-endorsed while a custom chain config is selected.
        var showUnverifiedPollWarning: Bool = false
        /// Round id (hex) captured when `.roundTapped` is gated behind the sheet.
        var pendingUnverifiedRoundTapId: String?

        /// True while the "Couldn't load polls" bottom sheet is visible —
        /// driven by a failed `fetchAllRounds` call. Cleared by
        /// `.retryLoadRounds` (on success) or by dismissing the flow.
        var pollsLoadError: Bool = false

        /// True while the "Couldn't load results" bottom sheet is visible —
        /// driven by a failed `fetchTallyResults` call. Cleared by
        /// `.retryLoadTallyResults` (on success) or by dismissing the flow.
        var resultsLoadError: Bool = false

        /// Signals that batch submission should resume after Keystone signing completes.
        var pendingBatchSubmission: Bool = false

        /// Prevents repeated screen appearances from starting duplicate cache warm-up work.
        var hasStartedProvingCacheWarmup: Bool = false

        // Witness verification results
        var noteWitnessResults: [NoteWitnessResult] = []
        var witnessStatus: WitnessStatus = .notStarted
        /// Cached witness data from verification, used as inclusion proofs for delegation proof.
        var cachedWitnesses: [WitnessData] = []
        /// Timing breakdown from the last witness generation run.
        var witnessTiming: WitnessTiming?

        // ZKP #1 (delegation) — on-chain authorization readiness
        var delegationProofStatus: ProofStatus = .notStarted
        /// True while the delegation proof `.run` effect is in-flight. Guards against
        /// re-entrant `.startDelegationProof` dispatches from round polling re-triggers.
        var isDelegationProofInFlight: Bool = false
        var delegationPrecomputeStatus: DelegationPrecomputeStatus = .notStarted
        var isDelegationPrecomputeInFlight: Bool = false
        var keystoneSigningStatus: KeystoneSigningStatus = .idle

        /// Which bundle the Keystone signing loop is currently processing (0-based).
        var currentKeystoneBundleIndex: UInt32 = 0

        /// Per-bundle Keystone signature data collected during the multi-bundle signing loop.
        struct KeystoneBundleSignature: Equatable {
            let sig: Data
            let sighash: Data
            let rk: Data // swiftlint:disable:this identifier_name
        }

        /// Collected Keystone signatures for each bundle, accumulated during the signing loop.
        var keystoneBundleSignatures: [KeystoneBundleSignature] = []

        /// Voting PCZT result for Keystone signing flow (contains metadata + pczt_bytes).
        var pendingVotingPczt: VotingPcztResult?
        /// Unsigned delegation PCZT request shown as QR and used for signature extraction.
        var pendingUnsignedDelegationPczt: Pczt?
        var configSettings: VotingConfigSettings.State?
        @Presents var keystoneScan: Scan.State?
        @Presents var skipBundlesAlert: AlertState<Action>?

        /// Whether a vote commitment is being built and submitted to chain.
        var isSubmittingVote: Bool = false
        /// Current step in the vote submission pipeline.
        var voteSubmissionStep: VoteSubmissionStep?
        /// Which bundle is currently being voted (0-based), nil when not submitting.
        var currentVoteBundleIndex: UInt32?
        /// Which proposal is currently being submitted, nil when idle.
        var submittingProposalId: UInt32?

        /// Label for the current vote submission step, with bundle progress when applicable.
        var voteSubmissionStepLabel: String? {
            guard let step = voteSubmissionStep else { return nil }
            // Show delegation proof percentage during authorization step.
            if step == .authorizingVote, case .generating(let progress) = delegationProofStatus {
                return String(localizable: .coinVoteStoreSubmissionAuthorizingVoteProgress(String(Int(progress * 100))))
            }
            if bundleCount > 1, let idx = currentVoteBundleIndex {
                switch step {
                case .authorizingVote: return step.label
                case .preparingProof:
                    return String(localizable: .coinVoteStoreSubmissionPreparingProofProgress(String(idx + 1), String(bundleCount)))
                case .confirming:
                    return String(localizable: .coinVoteStoreSubmissionWaitingForConfirmationProgress(String(idx + 1), String(bundleCount)))
                case .sendingShares:
                    return String(localizable: .coinVoteStoreSubmissionSendingSharesProgress(String(idx + 1), String(bundleCount)))
                }
            }
            return step.label
        }

        var currentScreen: Screen {
            screenStack.last ?? .pollsList
        }

        /// True when the current screen is part of the active voting flow — the
        /// screens where a mid-flow round close would disrupt work in progress.
        /// Consumed by `.roundStatusUpdated` to decide between showing the
        /// "Poll Closed" sheet and silently force-navigating to the terminal
        /// screen.
        var isInActiveVotingFlow: Bool {
            switch currentScreen {
            case .delegationSigning, .proposalList, .proposalDetail, .reviewVotes, .confirmSubmission:
                return true
            default:
                return false
            }
        }

        var votingWeightZECString: String {
            let zec = Double(votingWeight) / 100_000_000.0
            return String(format: "%.3f", zec)
        }

        /// Quantized ZEC value for the current Keystone bundle.
        var currentBundleZECString: String? {
            guard isKeystoneUser, bundleCount > 1 else { return nil }
            let bundles = walletNotes.smartBundles().bundles
            let idx = Int(currentKeystoneBundleIndex)
            guard idx < bundles.count else { return nil }
            let raw = bundles[idx].reduce(UInt64(0)) { $0 + $1.value }
            let weight = quantizeWeight(raw)
            return String(format: "%.3f", Double(weight) / 100_000_000.0)
        }

        /// Quantized ZEC weight already signed across collected Keystone bundle signatures.
        var signedBundlesZECString: String {
            let bundles = walletNotes.smartBundles().bundles
            let signedWeight = keystoneBundleSignatures.indices.reduce(UInt64(0)) { total, i in
                guard i < bundles.count else { return total }
                let raw = bundles[i].reduce(UInt64(0)) { $0 + $1.value }
                return total + quantizeWeight(raw)
            }
            return String(format: "%.3f", Double(signedWeight) / 100_000_000.0)
        }

        /// Quantized ZEC weight in unsigned bundles that would be given up by skipping.
        var skippedBundlesZECString: String {
            let bundles = walletNotes.smartBundles().bundles
            let signedCount = keystoneBundleSignatures.count
            let skippedWeight = (signedCount..<bundles.count).reduce(UInt64(0)) { total, i in
                let raw = bundles[i].reduce(UInt64(0)) { $0 + $1.value }
                return total + quantizeWeight(raw)
            }
            return String(format: "%.3f", Double(skippedWeight) / 100_000_000.0)
        }

        /// Raw ZEC weight for the memo — per-bundle for Keystone multi-bundle, total otherwise.
        var memoWeightZatoshi: UInt64 {
            if isKeystoneUser, bundleCount > 1 {
                let bundles = walletNotes.smartBundles().bundles
                let idx = Int(currentKeystoneBundleIndex)
                if idx < bundles.count {
                    return bundles[idx].reduce(UInt64(0)) { $0 + $1.value }
                }
            }
            return walletNotes.reduce(UInt64(0)) { $0 + $1.value }
        }

        var isBatchSubmitting: Bool {
            switch batchSubmissionStatus {
            case .authorizing, .submitting: return true
            default: return false
            }
        }

        /// Whether the user can start a submission: bundles resolved,
        /// no other submission in-flight, and at least one draft exists.
        /// Delegation (ZKP #1) runs at submission time, not upfront.
        var canSubmitBatch: Bool {
            bundleCount > 0 && !isSubmittingVote && !isBatchSubmitting && !draftVotes.isEmpty
        }

        var votedCount: Int {
            votes.count
        }

        var totalProposals: Int {
            votingRound.proposals.count
        }

        var allVoted: Bool {
            votedCount == totalProposals
        }

        var isDelegationReady: Bool {
            delegationProofStatus == .complete
        }

        var isDelegationPrecomputeReady: Bool {
            delegationPrecomputeStatus == .ready
        }

        /// Whether all share delegations have been confirmed on-chain.
        var allSharesConfirmed: Bool {
            !shareDelegations.isEmpty && shareDelegations.allSatisfy(\.confirmed)
        }

        /// Per-proposal share delegation progress from the local DB.
        /// Uses a helper struct because tuple values don't conform to Equatable.
        struct ShareDelegationProgress: Equatable {
            let confirmed: Int
            let total: Int
        }

        var shareDelegationProgressByProposal: [UInt32: ShareDelegationProgress] {
            var result: [UInt32: ShareDelegationProgress] = [:]
            for delegation in shareDelegations {
                let key = delegation.proposalId
                let current = result[key] ?? ShareDelegationProgress(confirmed: 0, total: 0)
                result[key] = ShareDelegationProgress(
                    confirmed: current.confirmed + (delegation.confirmed ? 1 : 0),
                    total: current.total + 1
                )
            }
            return result
        }

        /// Estimated time when all pending shares will have been submitted by helpers.
        var estimatedCompletionDate: Date? {
            estimatedCompletion(for: shareDelegations)
        }

        /// Estimated completion scoped to the proposal currently shown in the info sheet.
        var shareInfoEstimatedCompletion: Date? {
            guard let pid = shareInfoProposalId else { return estimatedCompletionDate }
            return estimatedCompletion(for: shareDelegations.filter { $0.proposalId == pid })
        }

        private func estimatedCompletion(for delegations: [VotingShareDelegation]) -> Date? {
            let unconfirmed = delegations.filter { !$0.confirmed }
            guard let maxSubmitAt = unconfirmed.map(\.submitAt).max(), maxSubmitAt > 0 else {
                return nil
            }
            return Date(timeIntervalSince1970: Double(maxSubmitAt))
        }

        var nextUnvotedProposalId: UInt32? {
            votingRound.proposals.first { votes[$0.id] == nil }?.id
        }

        var nextUndraftedProposalId: UInt32? {
            votingRound.proposals.first { draftVotes[$0.id] == nil }?.id
        }

        var allDrafted: Bool {
            !votingRound.proposals.isEmpty &&
            votingRound.proposals.allSatisfy { draftVotes[$0.id] != nil }
        }

        /// Display-time choice per proposal. Prefers the draft, then the
        /// submitted vote. Once voteRecord is set, falls back to the
        /// synthesized Abstain index — the submission flow guarantees every
        /// proposal is either explicitly voted or abstained, so a missing
        /// entry post-submit is always an abstain (either one we skipped on
        /// the wire, or one dropped from state.votes by a DB resync).
        var effectiveChoices: [UInt32: VoteChoice] {
            let hasSubmitted = voteRecord != nil
            var result: [UInt32: VoteChoice] = [:]
            for proposal in votingRound.proposals {
                if let explicit = draftVotes[proposal.id] ?? votes[proposal.id] {
                    result[proposal.id] = explicit
                } else if hasSubmitted {
                    let fallbackIndex: UInt32
                    if let abstain = proposal.options.first(where: {
                        $0.label.localizedCaseInsensitiveContains("abstain")
                    }) {
                        fallbackIndex = abstain.index
                    } else {
                        fallbackIndex = (proposal.options.map(\.index).max() ?? 0) + 1
                    }
                    result[proposal.id] = .option(fallbackIndex)
                }
            }
            return result
        }

        /// Whether the current proposal detail was opened from the review screen.
        var isEditingFromReview: Bool {
            guard case .proposalDetail = screenStack.last else { return false }
            return screenStack.dropLast().last == .reviewVotes
        }

        var activeProposalId: UInt32? {
            selectedProposalId ?? nextUnvotedProposalId
        }

        var selectedProposal: VotingProposal? {
            if case .proposalDetail(let id) = currentScreen {
                return votingRound.proposals.first { $0.id == id }
            }
            return nil
        }

        // Index of the proposal currently shown in detail
        var detailProposalIndex: Int? {
            if case .proposalDetail(let id) = currentScreen {
                return votingRound.proposals.firstIndex { $0.id == id }
            }
            return nil
        }

        init(
            votingRound: VotingRound = VotingRound(
                id: "",
                title: "",
                description: "",
                snapshotHeight: 0,
                snapshotDate: .now,
                votingStart: .now,
                votingEnd: .now,
                proposals: []
            ),
            votingWeight: UInt64 = 0,
            isKeystoneUser: Bool = false,
            walletId: String = "",
            roundId: String = ""
        ) {
            self.votingRound = votingRound
            self.votingWeight = votingWeight
            self.isKeystoneUser = isKeystoneUser
            self.walletId = walletId
            self.roundId = roundId
        }
    }

    let cancelStateStreamId = UUID()
    let cancelStatusPollingId = UUID()
    let cancelPipelineId = UUID()
    let cancelDelegationProofId = UUID()
    let cancelDelegationPrecomputeId = UUID()
    let cancelNewRoundPollingId = UUID()
    let cancelShareTrackingId = UUID()

    enum Action: Equatable {
        // Navigation
        case dismissFlow
        case goBack
        case backToRoundsList
        case howToVoteContinueTapped
        case openConfigSettings
        case configSettings(VotingConfigSettings.Action)
        case viewMyVotesTapped(roundId: String)

        // Rounds list
        case allRoundsLoaded([VotingSession])
        case roundTapped(String)
        case unverifiedPollWarningProceedTapped
        case openPendingUnverifiedRound
        case openPendingUnverifiedRoundNow(String)
        case unverifiedPollWarningGoBackTapped
        case startNewRoundPolling
        case roundsLoadFailed
        case retryLoadRounds

        // Initialization (DB, wallet notes, hotkey)
        case initialize
        case warmProvingCaches
        case serviceConfigLoaded(VotingServiceConfig)
        case configUnsupported(String)
        case activeSessionLoaded(VotingSession)
        case noActiveRound
        case votingWeightLoaded(UInt64, [NoteInfo])
        case initializeFailed(String)
        case walletNotSynced(scannedHeight: UInt64, snapshotHeight: UInt64)
        case walletSyncProgressUpdated(UInt64)
        case hotkeyLoaded(String)
        case startActiveRoundPipeline

        // DB state stream (single source of truth)
        case votingDbStateChanged(VotingDbState)

        // Witness verification
        case verifyWitnesses
        case witnessPreparationStarted
        case rerunWitnessVerification
        case witnessVerificationCompleted([State.NoteWitnessResult], [WitnessData], State.WitnessTiming, UInt32)
        case witnessVerificationFailed(String)

        // Round resume check (skip delegation screen if already authorized)
        case roundResumeChecked(alreadyAuthorized: Bool)
        case bundleCountRestored(UInt32)

        // Delegation signing
        case copyHotkeyAddress
        case delegationApproved
        case delegationRejected
        case keystoneSigningPrepared(roundId: String, VotingPcztResult, Pczt)
        case keystoneSigningFailed(roundId: String, error: String)
        case openKeystoneSignatureScan
        case retryKeystoneSigning
        case spendAuthSignatureExtracted(Data, Data)
        case spendAuthSignatureExtractionFailed(String)
        case keystoneBundleAdvance
        case keystoneBundleSignatureStored(State.KeystoneBundleSignature, bundleIndex: UInt32, bundleCount: UInt32)
        case keystoneAllBundlesSigned
        case keystoneSignaturesRestored([KeystoneBundleSignatureInfo])
        case keystoneShowSigningScreen
        case skipRemainingKeystoneBundles
        case skipBundlesAlert(PresentationAction<Action>)
        case skipRemainingKeystoneBundlesConfirmed
        case keystoneScan(PresentationAction<Scan.Action>)

        // ZKP delegation
        case startDelegationProof
        case maybeStartDelegationPrecompute
        case delegationPrecomputeCompleted(roundId: String)
        case delegationPrecomputeFailed(roundId: String, error: String)
        case delegationProofProgress(roundId: String, progress: Double)
        case delegationProofCompleted(roundId: String)
        case delegationProofFailed(roundId: String, error: String)

        // Proposal list
        case proposalTapped(UInt32)

        // Proposal detail
        case castVote(proposalId: UInt32, choice: VoteChoice)
        case voteSubmissionBundleStarted(UInt32)
        case voteSubmissionStepUpdated(State.VoteSubmissionStep)
        case advanceAfterVote
        case backToList
        case nextProposalDetail
        case previousProposalDetail
        case confirmUnanswered
        case dismissUnanswered
        case navigateToConfirmation
        case cancelEdit
        case saveEdit

        // Round status polling
        case startRoundStatusPolling
        case roundStatusUpdated(roundId: Data, SessionStatus)

        // Poll Closed mid-flow sheet
        case dismissPollClosedSheet
        case viewPollClosedResults

        // Tally results
        case fetchTallyResults
        case tallyResultsLoaded([UInt32: TallyResult])
        case tallyResultsLoadFailed
        case retryLoadTallyResults
        case fetchZodlEndorsements
        case zodlEndorsementsLoaded(Set<String>)

        // Share info sheet
        case showShareInfo(UInt32)
        case hideShareInfo

        // Governance tab lifecycle
        case governanceTabAppeared
        case governanceTabDisappeared

        // Share delegation tracking (DB-backed polling)
        case loadShareDelegations
        case shareDelegationsLoaded([VotingShareDelegation])
        // Updates state from poll loop WITHOUT starting a new poll (avoids fork bomb).
        case shareDelegationsRefreshed([VotingShareDelegation])
        case pollShareStatus

        // Batch voting
        case setDraftVote(proposalId: UInt32, choice: VoteChoice)
        case clearDraftVote(proposalId: UInt32)
        case submitAllDrafts
        case authenticationSucceeded
        case batchSubmissionProgress(currentIndex: Int, totalCount: Int, proposalId: UInt32)
        case batchVoteSubmitted(proposalId: UInt32, choice: VoteChoice)
        case batchVoteFailed(proposalId: UInt32, error: String)
        case batchSubmissionCompleted(successCount: Int, failCount: Int)
        case batchAuthorizationFailed(error: String)
        case batchSubmissionFailed(error: String, submittedCount: Int, totalCount: Int)
        case retryBatchSubmission
        case dismissBatchResults

        // Complete
        case doneTapped
    }

    init() {}

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            // MARK: - Navigation
            case .dismissFlow,
                .goBack,
                .howToVoteContinueTapped,
                .openConfigSettings,
                .configSettings,
                .viewMyVotesTapped,
                .backToRoundsList,
                .doneTapped:
                return reduceNavigation(&state, action)

            // MARK: - Rounds List
            case .allRoundsLoaded,
                .roundTapped,
                .unverifiedPollWarningProceedTapped,
                .openPendingUnverifiedRound,
                .openPendingUnverifiedRoundNow,
                .unverifiedPollWarningGoBackTapped,
                .startNewRoundPolling,
                .roundsLoadFailed,
                .retryLoadRounds:
                return reduceSession(&state, action)

            // MARK: - Initialization
            case .initialize,
                .warmProvingCaches,
                .serviceConfigLoaded,
                .configUnsupported,
                .startActiveRoundPipeline,
                .activeSessionLoaded,
                .noActiveRound,
                .votingWeightLoaded,
                .initializeFailed,
                .walletNotSynced,
                .walletSyncProgressUpdated,
                .hotkeyLoaded:
                return reduceSession(&state, action)

            // MARK: - Round Status Polling
            case .startRoundStatusPolling,
                .roundStatusUpdated,
                .dismissPollClosedSheet,
                .viewPollClosedResults:
                return reduceSession(&state, action)

            // MARK: - Tally Results
            case .fetchTallyResults,
                .tallyResultsLoaded,
                .tallyResultsLoadFailed,
                .retryLoadTallyResults,
                .fetchZodlEndorsements,
                .zodlEndorsementsLoaded:
                return reduceSession(&state, action)

            // MARK: - DB State Stream
            case .votingDbStateChanged:
                return reduceSession(&state, action)

            // MARK: - Governance Tab Lifecycle
            case .governanceTabAppeared,
                .governanceTabDisappeared:
                return reduceSession(&state, action)

            // MARK: - Share Info Sheet
            case .showShareInfo,
                .hideShareInfo:
                return reduceNavigation(&state, action)

            // MARK: - Share Delegation Tracking
            case .loadShareDelegations,
                .shareDelegationsLoaded,
                .shareDelegationsRefreshed,
                .pollShareStatus:
                return reduceNavigation(&state, action)

            // MARK: - Witness Verification
            case .verifyWitnesses,
                .witnessPreparationStarted,
                .rerunWitnessVerification,
                .witnessVerificationCompleted,
                .witnessVerificationFailed:
                return reduceDelegation(&state, action)

            // MARK: - Round Resume
            case .roundResumeChecked,
                .bundleCountRestored:
                return reduceDelegation(&state, action)

            // MARK: - Delegation Signing
            case .copyHotkeyAddress,
                .delegationApproved,
                .delegationRejected,
                .retryKeystoneSigning:
                return reduceDelegation(&state, action)

            // MARK: - ZKP Delegation
            case .startDelegationProof,
                .maybeStartDelegationPrecompute,
                .delegationPrecomputeCompleted,
                .delegationPrecomputeFailed,
                .keystoneSigningPrepared,
                .keystoneSigningFailed,
                .openKeystoneSignatureScan,
                .keystoneScan,
                .spendAuthSignatureExtracted,
                .spendAuthSignatureExtractionFailed,
                .keystoneBundleSignatureStored,
                .keystoneAllBundlesSigned,
                .keystoneSignaturesRestored,
                .keystoneShowSigningScreen,
                .skipRemainingKeystoneBundles,
                .skipBundlesAlert,
                .skipRemainingKeystoneBundlesConfirmed,
                .keystoneBundleAdvance,
                .delegationProofProgress,
                .delegationProofCompleted,
                .delegationProofFailed:
                return reduceDelegation(&state, action)

            // MARK: - Proposal List + Detail
            case .proposalTapped,
                .castVote,
                .voteSubmissionBundleStarted,
                .voteSubmissionStepUpdated,
                .advanceAfterVote,
                .backToList,
                .nextProposalDetail,
                .previousProposalDetail,
                .confirmUnanswered,
                .dismissUnanswered,
                .navigateToConfirmation,
                .cancelEdit,
                .saveEdit:
                return reduceNavigation(&state, action)

            // MARK: - Batch Voting
            case .setDraftVote,
                .clearDraftVote,
                .submitAllDrafts,
                .authenticationSucceeded,
                .batchSubmissionProgress,
                .batchVoteSubmitted,
                .batchVoteFailed,
                .batchSubmissionCompleted,
                .batchAuthorizationFailed,
                .batchSubmissionFailed,
                .retryBatchSubmission,
                .dismissBatchResults:
                return reduceSubmission(&state, action)
            }
        }
        .ifLet(\.configSettings, action: \.configSettings) {
            VotingConfigSettings()
        }
        .ifLet(\.$keystoneScan, action: \.keystoneScan) {
            Scan()
        }
    }

    func sessionBackedRound(from session: VotingSession, title: String, fallback: VotingRound) -> VotingRound {
        let proposals = session.proposals.isEmpty ? fallback.proposals : session.proposals
        // Prefer the on-chain title, then the caller-provided title, then the fallback
        let resolvedTitle = !session.title.isEmpty ? session.title : (!title.isEmpty ? title : fallback.title)
        return VotingRound(
            id: session.voteRoundId.hexString,
            title: resolvedTitle,
            description: session.description.isEmpty ? fallback.description : session.description,
            discussionURL: session.discussionURL ?? fallback.discussionURL,
            snapshotHeight: session.snapshotHeight,
            snapshotDate: fallback.snapshotDate,
            votingStart: fallback.votingStart,
            votingEnd: session.voteEndTime,
            proposals: proposals
        )
    }

    func reconcileProposalState(_ state: inout State) {
        let validProposalIDs = Set(state.votingRound.proposals.map(\.id))
        state.votes = state.votes.filter { validProposalIDs.contains($0.key) }

        if let selectedProposalId = state.selectedProposalId,
            !validProposalIDs.contains(selectedProposalId) {
            state.selectedProposalId = nil
        }

        if case .proposalDetail(let proposalId) = state.currentScreen,
            !validProposalIDs.contains(proposalId) {
            if !state.screenStack.isEmpty {
                state.screenStack.removeLast()
            }
            state.screenStack.append(.proposalList)
        }
    }
}
