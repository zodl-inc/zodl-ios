//
//  VotingCoordFlowCoordinator.swift
//  Zashi
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension VotingCoordFlow {
    /// Handles all action dispatch. Matches the
    /// `<Name>CoordFlowCoordinator.swift` convention used elsewhere in the
    /// codebase (e.g. `RestoreWalletCoordFlowCoordinator`).
    // swiftlint:disable:next cyclomatic_complexity
    func coordinatorReduce() -> Reduce<State, Action> {
        Reduce { state, action in
            switch action {

                // MARK: - Path

            case .path(.element(id: _, action: .configSettings(.delegate(.dismiss)))):
                // VotingConfigSettings emits `.delegate(.dismiss)` from its
                // back button; pop the settings push so the user returns to
                // the polls list. Re-fetch is handled by `.delegate(.saved)`
                // separately (Phase 4+).
                if !state.path.isEmpty {
                    state.path.removeLast()
                }
                return .none

            case .path(.element(id: _, action: .configSettings(.delegate(.saved)))):
                // Save closes the settings screen and re-runs initialize so
                // the new pinned config takes effect. Voting state from the
                // previous source has to go: round ids can collide across
                // sources, cached per-round pipeline output (hotkey, weight,
                // witnesses, drafts) is keyed only by round id and would
                // happily serve stale data after the switch. Cancel the
                // in-flight pipeline too so it doesn't race the new init.
                if !state.path.isEmpty {
                    state.path.removeLast()
                }
                state.allRounds = []
                state.roundCache.removeAll()
                state.voteRecords.removeAll()
                state.zodlEndorsedRoundIds = []
                state.pendingPipelineRoundId = nil
                state.serviceConfig = nil
                state.pollsLoadError = false
                state.rootScreen = .loading
                state.pollClosedSheet = nil
                return .merge(
                    .cancel(id: cancelPipelineId),
                    .cancel(id: cancelDelegationPrecomputeId),
                    .cancel(id: cancelStatusPollingId),
                    .cancel(id: cancelNewRoundPollingId),
                    .cancel(id: cancelShareTrackingId),
                    .send(.initialize)
                )

            case .path:
                return .none

                // MARK: - Lifecycle

            case .onAppear:
                // Re-entry from a nested screen pop = no-op. The user just
                // navigated back to the polls list root; we already have
                // rounds + service config loaded, so don't flip rootScreen
                // back to `.loading` and re-fetch.
                //
                // Without this guard, NavigationStack's pop fires `.onAppear`
                // again on the root content, which would briefly show the
                // loading screen before the polls list re-renders.
                if state.serviceConfig != nil {
                    return .none
                }

                // First-time entry: show the intro before initializing the
                // round-loading pipeline. The intro's continue button drives
                // `.howToVoteContinueTapped` which re-enters `.onAppear` with
                // the flag set.
                guard state.hasSeenHowToVoteForCurrentWallet else {
                    state.rootScreen = .howToVote
                    return .none
                }
                state.rootScreen = .loading
                return .send(.initialize)

            case .warmProvingCaches:
                guard !state.hasRequestedProvingCacheWarmup else {
                    return .none
                }
                state.hasRequestedProvingCacheWarmup = true
                return .run { [votingCrypto] _ in
                    do {
                        try await votingCrypto.warmProvingCaches()
                    } catch {
                        LoggerProxy.warn("Voting proving cache warm-up failed: \(error)")
                    }
                }

            case let .walletAccountChanged(account):
                return reduceWalletAccountChanged(&state, account: account)

            case .initialize:
                // Sweep legacy plaintext keys from a prior internal-build
                // persistence shape. Idempotent and cheap; safe to keep.
                Voting.sweepLegacyUserDefaultsVotingKeys()

                // Defensively reset the process-wide encrypted metadata cache
                // before loading the current account, so a nil-account window
                // can't surface a previous account's data.
                votingMetadata.reset()
                if let account = state.selectedWalletAccount?.account {
                    try? votingMetadata.load(account)
                }

                // Read straight from UserDefaults rather than from
                // `state.votingConfigOverrideURL` so this picks up the value
                // VotingConfigSettings just wrote, even when the @Shared
                // change has not yet propagated to parent state at dismiss
                // time. Otherwise the first save after a chain switch refetches
                // with the previous override.
                let overrideURLString = UserDefaults.standard
                    .string(forKey: .votingConfigOverrideURL) ?? ""

                return .run { [votingAPI] send in
                    let override: PinnedConfigSource?
                    if overrideURLString.isEmpty {
                        override = nil
                    } else {
                        override = try? PinnedConfigSource.parse(overrideURLString)
                    }
                    let config = try await votingAPI.fetchServiceConfig(override)
                    await send(.serviceConfigLoaded(config))
                } catch: { error, send in
                    LoggerProxy.error("Service config unavailable: \(error)")
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    await send(.configUnsupported(message))
                }

            case .serviceConfigLoaded(let config):
                state.serviceConfig = config
                let walletId = state.walletId
                return .run { [votingAPI, votingCrypto] send in
                    // 1. Configure API client URLs from the loaded config.
                    await votingAPI.configureURLs(config)

                    // 2. Open the voting DB and scope it to this wallet.
                    let dbPath = FileManager.default
                        .urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("voting.sqlite3").path
                    try await votingCrypto.openDatabase(dbPath)
                    try await votingCrypto.setWalletId(walletId)

                    // 3. Fetch rounds. Network failures surface as a
                    //    recoverable sheet on the polls list rather than the
                    //    blocking error screen.
                    do {
                        let rounds = try await votingAPI.fetchAllRounds()
                        await send(.allRoundsLoaded(rounds))
                    } catch {
                        LoggerProxy.error("Failed to fetch rounds: \(error)")
                        await send(.roundsLoadFailed)
                    }
                } catch: { error, send in
                    LoggerProxy.error("Voting initialization failed: \(error)")
                    await send(.initializeFailed(error.localizedDescription))
                }

            case .allRoundsLoaded(let sessions):
                state.pollsLoadError = false

                // Stable creation-order numbering.
                let sorted = sessions.sorted { $0.createdAtHeight < $1.createdAtHeight }
                state.allRounds = sorted.enumerated().map { index, session in
                    RoundListItem(roundNumber: index + 1, session: session)
                }

                // Hydrate per-round vote records from the encrypted metadata
                // file so the polls list can render the Voted state for any
                // rounds the user has fully submitted on this device.
                let account = state.selectedWalletAccount?.account
                var records: [String: Voting.VoteRecord] = [:]
                for item in state.allRounds {
                    if let record = Voting.loadCompletedVoteRecord(
                        roundId: item.id,
                        account: account
                    ) {
                        records[item.id] = record
                    }
                }
                state.voteRecords = records

                // On default config, defer the pollsList-vs-noRounds decision
                // until `.zodlEndorsementsLoaded` (or `.zodlEndorsementsFailed`)
                // resolves; otherwise this branch would compute the empty-state
                // against an as-yet-unpopulated endorsement set and lock the
                // user on noRounds even when endorsed rounds arrive a moment
                // later. Only fall back to `.loading` when no round-derived
                // screen is currently showing — on a refresh while the user is
                // already on `.pollsList` or `.noRounds`, keep that visible
                // until `.zodlEndorsementsLoaded` re-evaluates, so a slow or
                // failed endorsement refresh can't blank the list. On custom
                // config there's no endorsement filter, so we decide
                // immediately from `allRounds`.
                if state.isOnDefaultConfig {
                    if state.rootScreen != .pollsList && state.rootScreen != .noRounds {
                        state.rootScreen = .loading
                    }
                } else {
                    state.rootScreen = state.allRounds.isEmpty ? .noRounds : .pollsList
                }

                // If the user is currently on TallyingView for a round whose
                // status just flipped to .finalized, swap the topmost path
                // entry for ResultsView so the 30 s auto-poll on
                // TallyingView lands them on the right screen without a
                // manual back tap. Same for proposal list → results when a
                // previously-active round finalized out from under them.
                let finalizedRoundFromPath = finalizedTopOfPath(state)
                if let topRoundId = finalizedRoundFromPath {
                    _ = state.path.popLast()
                    state.path.append(.results(Results.State(roundId: topRoundId)))
                }

                // Fetch the Zodl endorsement list right after the rounds
                // list lands. PollsListView filters bundled rounds by this
                // set when `isOnDefaultConfig` is true, so without the
                // fetch the list would be empty on the default source.
                let endorsements: Effect<Action> = .run { [votingAPI] send in
                    do {
                        let ids = try await votingAPI.fetchZodlEndorsedRoundIds()
                        await send(.zodlEndorsementsLoaded(ids))
                    } catch {
                        LoggerProxy.error("Failed to fetch zodl endorsements: \(error)")
                        await send(.zodlEndorsementsFailed)
                    }
                }
                guard let finalizedRoundFromPath else {
                    return endorsements
                }
                return .merge(
                    endorsements,
                    .send(.fetchTallyResults(roundId: finalizedRoundFromPath)),
                    .send(.startNewRoundPolling)
                )

            case let .zodlEndorsementsLoaded(ids):
                state.zodlEndorsedRoundIds = ids
                // Resolve the pollsList-vs-noRounds decision now that the
                // endorsement set is known. We only override `rootScreen`
                // when it's one of the three round-derived states — leaving
                // `.howToVote`, `.walletSyncing`, `.error`, and `.configError`
                // intact so the endorsement landing doesn't yank the user
                // out of an unrelated branch.
                if state.rootScreen == .loading
                    || state.rootScreen == .pollsList
                    || state.rootScreen == .noRounds {
                    state.rootScreen = visibleRoundCount(state: state) == 0 ? .noRounds : .pollsList
                }
                return .none

            case .zodlEndorsementsFailed:
                // The fetch failed; treat as empty endorsement set. If we're
                // still waiting on the round-derived decision, fall through
                // to noRounds rather than spinning on the loading skeleton.
                // On custom config the decision was already made at
                // `.allRoundsLoaded`, so this is a no-op there.
                if state.rootScreen == .loading {
                    state.rootScreen = visibleRoundCount(state: state) == 0 ? .noRounds : .pollsList
                }
                return .none

            case .roundsLoadFailed:
                state.pollsLoadError = true
                // Keep any previously loaded rounds visible behind the error
                // sheet. If nothing was ever loaded, the empty list shows
                // blank chrome underneath; the sheet still offers retry.
                state.rootScreen = .pollsList
                return .none

            case .configUnsupported(let message):
                state.rootScreen = .configError(message)
                return .none

            case .initializeFailed(let message):
                state.rootScreen = .error(message)
                return .none

                // MARK: - User actions

            case .dismissFlow:
                state.roundCache.removeAll()
                state.path.removeAll()
                state.pendingBatchSubmission = false
                state.pollClosedSheet = nil
                state.ineligibleSheet = nil
                state.checkingEligibilityRoundId = nil
                state.walletSyncingSheetRoundId = nil
                state.skippedQuestionsSheet = nil
                return .merge(
                    .cancel(id: cancelPipelineId),
                    .cancel(id: cancelSubmissionId),
                    .cancel(id: cancelDelegationProofId),
                    .cancel(id: cancelDelegationPrecomputeId),
                    .cancel(id: cancelStatusPollingId),
                    .cancel(id: cancelNewRoundPollingId),
                    .cancel(id: cancelShareTrackingId)
                )

            case .submissionDoneTapped:
                // Pop the entire ConfirmSubmission/Review stack back to the
                // polls list and let the user decide what to do next — tap
                // into the now-Voted round to see their review, or visit a
                // different poll. Round cache and share-tracking poll stay
                // alive so unconfirmed shares keep recovering.
                state.path.removeAll()
                state.pendingBatchSubmission = false
                state.skippedQuestionsSheet = nil
                return .none

            case .howToVoteContinueTapped:
                if state.isKeystoneUser {
                    state.$hasSeenHowToVoteForKeystone.withLock { $0 = true }
                } else {
                    state.$hasSeenHowToVoteForZashi.withLock { $0 = true }
                }
                return .send(.onAppear)

            case .retryLoadRounds:
                state.rootScreen = .loading
                return .send(.initialize)

            case .openConfigSettings:
                state.path.append(.configSettings(VotingConfigSettings.State()))
                return .none

            case .roundTapped(let roundId):
                // Route by round status. Voted rounds in active phase
                // surface read-only review; not-yet-voted rounds go to the
                // voting list; tallying/finalized rounds skip the proposal
                // list entirely and land on the status screen.
                guard let item = state.allRounds.first(where: { $0.id == roundId }) else {
                    return .none
                }
                let cancelShareTracking = cancelShareTrackingIfSwitchingRound(state, to: roundId)
                switch item.session.status {
                case .active:
                    hydratePersistedRoundChoices(&state, roundId: roundId)

                    if state.voteRecords[roundId] != nil {
                        // Already submitted — review-mode read-only, no
                        // pipeline needed.
                        state.path.append(.reviewVotes(ReviewVotes.State(roundId: roundId)))
                        return .merge(
                            cancelShareTracking,
                            .cancel(id: cancelNewRoundPollingId),
                            .send(.startRoundStatusPolling(roundId: roundId)),
                            loadSubmittedVotesFromDb(roundId: roundId)
                        )
                    }
                    // Cache hit (hotkey + bundles ready): eligibility is
                    // already proven for this session, push the proposal
                    // list immediately — no spinner needed.
                    if let cached = state.roundCache[roundId],
                       cached.hotkeyAddress != nil,
                       cached.bundleCount > 0 {
                        state.path.append(.proposalList(ProposalList.State(roundId: roundId)))
                        return .merge(
                            cancelShareTracking,
                            .cancel(id: cancelNewRoundPollingId),
                            .send(.startRoundStatusPolling(roundId: roundId)),
                            loadSubmittedVotesFromDb(roundId: roundId)
                        )
                    }
                    // No cache: keep the user on the polls list with an
                    // in-button spinner on this row while the pipeline
                    // resolves eligibility. The push to `.proposalList`
                    // happens in `.votingWeightLoaded`; ineligibility opens
                    // the sheet via `.ineligibleForRound`.
                    state.checkingEligibilityRoundId = roundId
                    return .merge(
                        cancelShareTracking,
                        .cancel(id: cancelNewRoundPollingId),
                        .send(.startRoundStatusPolling(roundId: roundId)),
                        .send(.startActiveRoundPipeline(roundId: roundId)),
                        loadSubmittedVotesFromDb(roundId: roundId)
                    )
                case .tallying:
                    state.path.append(.tallying(Tallying.State(roundId: roundId)))
                    return cancelShareTracking
                case .finalized:
                    // Hydrate the user's persisted per-proposal choices so
                    // ResultsView can render the "Voted: <option>" footer
                    // on each card — same pattern as the active-and-voted
                    // branch above. Without this, `RoundSession.votes` is
                    // empty for rounds the user voted in on a previous
                    // session.
                    hydratePersistedRoundChoices(&state, roundId: roundId)
                    state.path.append(.results(Results.State(roundId: roundId)))
                    return .merge(
                        cancelShareTracking,
                        .cancel(id: cancelStatusPollingId),
                        .send(.fetchTallyResults(roundId: roundId)),
                        .send(.startNewRoundPolling),
                        loadSubmittedVotesFromDb(roundId: roundId)
                    )
                case .unspecified:
                    return .none
                }

            case .viewMyVotesTapped(let roundId):
                // Explicit user intent to view submitted votes in read-only
                // form. Always routes to reviewVotes regardless of round
                // status (active or finalized — both have a vote record).
                let cancelShareTracking = cancelShareTrackingIfSwitchingRound(state, to: roundId)
                hydratePersistedRoundChoices(&state, roundId: roundId)
                state.path.append(.reviewVotes(ReviewVotes.State(roundId: roundId)))
                let statusPolling: Effect<Action>
                if state.allRounds.first(where: { $0.id == roundId })?.session.status == .active {
                    statusPolling = .send(.startRoundStatusPolling(roundId: roundId))
                } else {
                    statusPolling = .none
                }
                return .merge(
                    cancelShareTracking,
                    statusPolling,
                    loadSubmittedVotesFromDb(roundId: roundId)
                )

            case let .proposalTapped(roundId, proposalId, mode):
                state.path.append(
                    .proposalDetail(
                        ProposalDetail.State(roundId: roundId, proposalId: proposalId, mode: mode)
                    )
                )
                return .none

            case let .submitTapped(roundId):
                // Partial ballots are allowed: the user has acknowledged any
                // skipped questions via the ProposalDetail skipped-questions
                // sheet. Only require a non-empty drafts set and a ready
                // submission pipeline.
                guard let session = state.roundCache[roundId],
                      canStartSubmission(session)
                else { return .none }
                state.path.append(.confirmSubmission(ConfirmSubmission.State(roundId: roundId)))
                return .none

            case let .submitAllDraftsTapped(roundId):
                return reduceSubmitAllDraftsTapped(&state, roundId: roundId)

            case let .clearDraftVote(roundId, proposalId):
                let account = state.selectedWalletAccount?.account
                guard var session = state.roundCache[roundId] else { return .none }
                session.draftVotes.removeValue(forKey: proposalId)
                do {
                    try Voting.persistDrafts(session.draftVotes, roundId: roundId, account: account)
                    state.roundCache[roundId] = session
                } catch {
                    LoggerProxy.error("Failed to clear persisted voting draft: \(error)")
                    state.submissionAlert = .votingMetadataPersistenceFailed(error)
                }
                return .none

            case .submissionAlert:
                return .none

            case .dismissKeystoneSignatureRejectionSheet:
                state.keystoneSignatureRejectionSheet = nil
                return .none

            // MARK: - Stage 5: submission pipeline

            case let .authenticationSucceeded(roundId):
                return reduceAuthenticationSucceeded(&state, roundId: roundId)

            case let .startDelegationProof(roundId):
                return reduceStartDelegationProof(&state, roundId: roundId)

            case let .delegationProofProgress(roundId, progress):
                return reduceDelegationProofProgress(&state, roundId: roundId, progress: progress)

            case let .delegationProofCompleted(roundId):
                return reduceDelegationProofCompleted(&state, roundId: roundId)

            case let .delegationProofFailed(roundId, error):
                return reduceDelegationProofFailed(&state, roundId: roundId, error: error)

            case let .maybeStartDelegationPrecompute(roundId):
                return reduceMaybeStartDelegationPrecompute(&state, roundId: roundId)

            case let .delegationPrecomputeCompleted(roundId):
                mutateSession(&state, roundId: roundId) { roundSession in
                    roundSession.delegationPrecomputeStatus = .ready
                    roundSession.isDelegationPrecomputeInFlight = false
                }
                if state.pendingBatchSubmission && !state.isKeystoneUser {
                    state.pendingBatchSubmission = false
                    mutateSession(&state, roundId: roundId) {
                        $0.batchSubmissionStatus = .idle
                    }
                    return .send(.authenticationSucceeded(roundId: roundId))
                }
                return .none

            case let .delegationPrecomputeFailed(roundId, error):
                let message = VotingErrorMapper.userFriendlyMessage(from: error)
                mutateSession(&state, roundId: roundId) { roundSession in
                    roundSession.delegationPrecomputeStatus = .failed(message)
                    roundSession.isDelegationPrecomputeInFlight = false
                }
                if state.pendingBatchSubmission && !state.isKeystoneUser {
                    state.pendingBatchSubmission = false
                    mutateSession(&state, roundId: roundId) {
                        $0.batchSubmissionStatus = .idle
                    }
                    return .send(.authenticationSucceeded(roundId: roundId))
                }
                return .none

            case let .batchSubmissionProgress(roundId, currentIndex, totalCount, proposalId):
                return reduceBatchSubmissionProgress(
                    &state,
                    roundId: roundId,
                    currentIndex: currentIndex,
                    totalCount: totalCount,
                    proposalId: proposalId
                )

            case let .voteSubmissionBundleStarted(roundId, bundleIndex):
                return reduceVoteSubmissionBundleStarted(&state, roundId: roundId, bundleIndex: bundleIndex)

            case let .voteSubmissionStepUpdated(roundId, step):
                return reduceVoteSubmissionStepUpdated(&state, roundId: roundId, step: step)

            case let .batchVoteSubmitted(roundId, proposalId, choice):
                return reduceBatchVoteSubmitted(&state, roundId: roundId, proposalId: proposalId, choice: choice)

            case let .batchVoteFailed(roundId, proposalId, error):
                return reduceBatchVoteFailed(&state, roundId: roundId, proposalId: proposalId, error: error)

            case let .batchSubmissionCompleted(roundId, successCount, failCount):
                return reduceBatchSubmissionCompleted(
                    &state,
                    roundId: roundId,
                    successCount: successCount,
                    failCount: failCount
                )

            case let .batchAuthorizationFailed(roundId, error):
                return reduceBatchAuthorizationFailed(&state, roundId: roundId, error: error)

            case let .batchSubmissionFailed(roundId, error, submittedCount, totalCount):
                return reduceBatchSubmissionFailed(
                    &state,
                    roundId: roundId,
                    error: error,
                    submittedCount: submittedCount,
                    totalCount: totalCount
                )

            case let .retryBatchSubmission(roundId):
                return reduceRetryBatchSubmission(&state, roundId: roundId)

            case let .dismissBatchResults(roundId):
                mutateSession(&state, roundId: roundId) {
                    $0.batchSubmissionStatus = .idle
                    $0.batchVoteErrors = [:]
                }
                return .none

            // MARK: - Stage 5C: Keystone signing loop

            case let .keystoneSigningPrepared(roundId, govPczt, unsignedPczt):
                return reduceKeystoneSigningPrepared(
                    &state,
                    roundId: roundId,
                    govPczt: govPczt,
                    unsignedPczt: unsignedPczt
                )

            case let .keystoneSigningFailed(roundId, error):
                mutateSession(&state, roundId: roundId) {
                    $0.isDelegationProofInFlight = false
                    $0.keystoneSigningStatus = .failed(VotingErrorMapper.userFriendlyMessage(from: error))
                }
                return .none

            case .openKeystoneSignatureScan:
                keystoneHandler.resetQRDecoder()
                var scanState = Scan.State.initial
                scanState.instructions = String(localizable: .coinVoteDelegationSigningScanInstructions)
                scanState.checkers = [.keystoneVotingDelegationPCZTScanChecker]
                state.keystoneScan = scanState
                return .none

            case let .keystoneScan(.presented(.foundVotingDelegationPCZT(signedPczt))):
                return reduceKeystoneScanFound(&state, signedPczt: signedPczt)

            case .keystoneScan(.presented(.cancelTapped)),
                 .keystoneScan(.dismiss):
                state.keystoneScan = nil
                return .none

            case .keystoneScan:
                return .none

            case let .spendAuthSignatureExtracted(roundId, sig, sighash):
                return reduceSpendAuthSignatureExtracted(
                    &state,
                    roundId: roundId,
                    sig: sig,
                    sighash: sighash
                )

            case let .keystoneBundleSignatureStored(roundId, signature, bundleIndex, bundleCount):
                return reduceKeystoneBundleSignatureStored(
                    &state,
                    roundId: roundId,
                    signature: signature,
                    bundleIndex: bundleIndex,
                    bundleCount: bundleCount
                )

            case let .keystoneAllBundlesSigned(roundId):
                return reduceKeystoneAllBundlesSigned(&state, roundId: roundId)

            case let .delegationBundlesRecovered(roundId, bundleIndices):
                mutateSession(&state, roundId: roundId) { roundSession in
                    roundSession.completedKeystoneDelegationBundleIndices = bundleIndices
                        .filter { roundSession.bundleCount == 0 || $0 < roundSession.bundleCount }
                    roundSession.currentKeystoneBundleIndex =
                        roundSession.firstIncompleteKeystoneBundleIndex ?? 0
                }
                return .none

            case let .keystoneSignaturesRestored(roundId, signatures):
                guard let session = state.roundCache[roundId],
                      let validSignatures = Self.validKeystoneSignatures(
                        signatures,
                        bundleCount: session.bundleCount
                      ),
                      !validSignatures.isEmpty
                else {
                    return .none
                }
                mutateSession(&state, roundId: roundId) { roundSession in
                    roundSession.keystoneBundleSignatures = validSignatures.map {
                        KeystoneBundleSignature(
                            bundleIndex: $0.bundleIndex,
                            sig: $0.sig,
                            sighash: $0.sighash,
                            rk: $0.rk
                        )
                    }
                    roundSession.currentKeystoneBundleIndex =
                        roundSession.firstIncompleteKeystoneBundleIndex ?? 0
                    roundSession.pendingVotingPczt = nil
                    roundSession.pendingUnsignedDelegationPczt = nil
                    roundSession.keystoneSigningStatus = Self.allKeystoneBundlesResolved(roundSession)
                        ? .finalizingAuthorization
                        : .idle
                }
                if state.roundCache[roundId].map(Self.allKeystoneBundlesResolved) == true {
                    mutateSession(&state, roundId: roundId) { roundSession in
                        roundSession.delegationProofStatus = .generating(progress: 0)
                        roundSession.isDelegationProofInFlight = true
                        roundSession.batchSubmissionStatus = .authorizing
                        roundSession.voteSubmissionStep = .authorizingVote
                    }
                    if case .delegationSigning = state.path.last {
                        _ = state.path.popLast()
                    }
                    return .send(.keystoneAllBundlesSigned(roundId: roundId))
                }
                if !hasKeystoneSigningRound(state: state, roundId: roundId) {
                    state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
                }
                return .send(.startDelegationProof(roundId: roundId))

            case let .keystoneSignatureRejected(roundId, message):
                mutateSession(&state, roundId: roundId) { roundSession in
                    roundSession.keystoneSigningStatus = .awaitingSignature
                }
                state.keystoneSignatureRejectionSheet = State.KeystoneSignatureRejectionSheet(message: message)
                return .none

            case let .keystoneShowSigningScreen(roundId):
                if !hasKeystoneSigningRound(state: state) {
                    state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
                }
                return .send(.startDelegationProof(roundId: roundId))

            case let .skipRemainingKeystoneBundles(roundId):
                guard let session = state.roundCache[roundId],
                      session.resolvedKeystonePrefixCount > 0
                else { return .none }
                state.skipBundlesAlert = .confirmSkip(
                    roundId: roundId,
                    lockedIn: signedBundlesZECString(session),
                    givingUp: skippedBundlesZECString(session)
                )
                return .none

            case let .skipRemainingKeystoneBundlesConfirmed(roundId):
                return reduceSkipRemainingKeystoneBundles(&state, roundId: roundId)

            case let .skipBundlesAlert(.presented(.skipRemainingKeystoneBundlesConfirmed(roundId))):
                state.skipBundlesAlert = nil
                return .send(.skipRemainingKeystoneBundlesConfirmed(roundId: roundId))

            case .skipBundlesAlert(.dismiss):
                state.skipBundlesAlert = nil
                return .none

            case .skipBundlesAlert:
                return .none

            case let .delegationRejected(roundId):
                // User backed out of the signing screen mid-loop. Reset
                // Keystone-side state so a fresh attempt starts clean. Drafts
                // and submitted votes are preserved.
                mutateSession(&state, roundId: roundId) { roundSession in
                    resetKeystoneSigningLoop(&roundSession)
                    if case .authorizing = roundSession.batchSubmissionStatus {
                        roundSession.batchSubmissionStatus = .idle
                    }
                }
                state.pendingBatchSubmission = false
                if case .delegationSigning = state.path.last {
                    _ = state.path.popLast()
                }
                return .cancel(id: cancelDelegationProofId)

                // MARK: - Tally results

            case let .fetchTallyResults(roundId):
                // Cache hit on finalized round = no refetch. Tally results
                // are immutable post-finalization.
                if let cached = state.roundCache[roundId],
                   cached.tallyFetched,
                   cached.tallyError == nil {
                    return .none
                }
                if state.roundCache[roundId] == nil {
                    state.roundCache[roundId] = RoundSession(roundId: roundId)
                }
                state.roundCache[roundId]?.tallyError = nil
                return .run { [votingAPI] send in
                    do {
                        let results = try await votingAPI.fetchTallyResults(roundId)
                        await send(.tallyResultsLoaded(roundId: roundId, results: results))
                    } catch {
                        LoggerProxy.error("Failed to fetch tally results: \(error)")
                        await send(.tallyResultsFailed(roundId: roundId, message: error.localizedDescription))
                    }
                }

            case let .tallyResultsLoaded(roundId, results):
                state.roundCache[roundId, default: RoundSession(roundId: roundId)]
                    .tallyResults = results
                state.roundCache[roundId, default: RoundSession(roundId: roundId)]
                    .tallyFetched = true
                return .none

            case let .tallyResultsFailed(roundId, message):
                // Surface the failure on ResultsView so the user sees a
                // retry button instead of an indefinite loading spinner.
                if state.roundCache[roundId] == nil {
                    state.roundCache[roundId] = RoundSession(roundId: roundId)
                }
                state.roundCache[roundId]?.tallyError = message
                return .none

            case let .draftVoteSet(roundId, proposalId, choice):
                // Write through to cache + disk so the choice survives both
                // navigation pops and app restarts. Snapshot the drafts
                // before persisting so the disk call runs without holding
                // the inout state reference.
                if state.roundCache[roundId]?.votes[proposalId] != nil {
                    return .none
                }
                var session = state.roundCache[roundId] ?? RoundSession(roundId: roundId)
                session.draftVotes[proposalId] = choice
                let account = state.selectedWalletAccount?.account
                do {
                    try Voting.persistDrafts(session.draftVotes, roundId: roundId, account: account)
                    state.roundCache[roundId] = session
                } catch {
                    LoggerProxy.error("Failed to persist voting draft: \(error)")
                    state.submissionAlert = .votingMetadataPersistenceFailed(error)
                }
                return .none

                // MARK: - Per-round pipeline

            case .startActiveRoundPipeline(let roundId):
                guard let item = state.allRounds.first(where: { $0.id == roundId }),
                      item.session.status == .active else {
                    return .none
                }
                let session = item.session
                let snapshotHeight = session.snapshotHeight
                let network = zcashSDKEnvironment.network()
                let walletDbPath = databaseFiles.dataDbURLFor(network).path
                let networkId: UInt32 = network.networkType.votingRustNetworkId
                let accountId = state.selectedWalletAccount?.id
                let accountUUID: [UInt8] = accountId?.id ?? []
                let isKeystoneUser = state.isKeystoneUser

                // Seed the cache entry so subsequent re-entries see an
                // in-progress session and don't trigger duplicate pipelines.
                if state.roundCache[roundId] == nil {
                    state.roundCache[roundId] = RoundSession(roundId: roundId)
                }
                state.pendingPipelineRoundId = roundId
                state.ineligibleSheet = nil
                state.walletSyncingSheetRoundId = nil

                return .run { [votingCrypto, votingAPI, mnemonic, walletStorage, sdkSynchronizer] send in
                    // 1. Wallet sync gate.
                    //
                    // Spend-before-Sync scans both head-first and birthday-
                    // first in parallel — a `latestScannedHeight` past the
                    // snapshot from the head doesn't imply the snapshot
                    // itself has been scanned. We need the contiguous-from-
                    // birthday `fullyScannedHeight` instead. The SDK
                    // synchronizer may report 0 briefly on cold start before
                    // it hydrates state — retry a few times.
                    var walletScannedHeight = UInt64(sdkSynchronizer.latestState().fullyScannedHeight)
                    if walletScannedHeight == 0 {
                        for _ in 0..<5 {
                            try await Task.sleep(for: .seconds(1))
                            walletScannedHeight = UInt64(sdkSynchronizer.latestState().fullyScannedHeight)
                            if walletScannedHeight > 0 { break }
                        }
                    }
                    if walletScannedHeight < snapshotHeight {
                        await send(
                            .walletNotSynced(
                                roundId: roundId,
                                scannedHeight: walletScannedHeight,
                                snapshotHeight: snapshotHeight
                            )
                        )
                        return
                    }

                    // 2. Notes + local voting DB setup. The Rust backend
                    // needs a round row, bundle rows, tree state, and
                    // witnesses before Keystone PCZT prep or inline
                    // delegation can build authorization inputs.
                    let notes = try await votingCrypto.getWalletNotes(
                        walletDbPath,
                        snapshotHeight,
                        networkId,
                        accountUUID
                    )
                    if notes.isEmpty {
                        await send(.ineligibleForRound(roundId: roundId, heldZatoshi: 0))
                        return
                    }

                    let heldZatoshi = notes.reduce(UInt64(0)) { $0 + $1.value }
                    let existingState = try? await votingCrypto.getRoundState(roundId)
                    let existingBundleCount = (try? await votingCrypto.getBundleCount(roundId)) ?? 0
                    var preClearKeystoneSignatures: [KeystoneBundleSignatureInfo] = []
                    var resolvedBundleCount: UInt32 = 0
                    var shouldRestoreKeystoneSignatures = isKeystoneUser
                    var didPrepareFreshRound = false
                    if existingState?.proofGenerated == true {
                        let bundleCount = existingBundleCount
                        resolvedBundleCount = bundleCount
                        shouldRestoreKeystoneSignatures = false
                        let eligibleWeight = Self.votingWeight(for: notes, bundleCount: bundleCount)
                        guard bundleCount > 0, eligibleWeight > 0 else {
                            await send(.ineligibleForRound(roundId: roundId, heldZatoshi: heldZatoshi))
                            return
                        }
                        await send(.earlyEligibilityConfirmed(roundId: roundId))
                        await send(.votingWeightLoaded(
                            roundId: roundId,
                            weight: eligibleWeight,
                            notes: notes,
                            witnesses: [],
                            bundleCount: bundleCount,
                            delegationReady: true
                        ))
                    } else if existingBundleCount > 0 {
                        resolvedBundleCount = existingBundleCount
                        var recoveredBundleCount: UInt32 = 0
                        var recoveredBundleIndices: Set<UInt32> = []
                        for bundleIndex: UInt32 in 0..<existingBundleCount {
                            if let vanPosition = try? await Self.recoverDelegationVanPosition(
                                roundId: roundId,
                                bundleIndex: bundleIndex,
                                votingCrypto: votingCrypto,
                                votingAPI: votingAPI,
                                confirmationTimeout: 0,
                                retryDelay: .zero
                            ) {
                                LoggerProxy.debug(
                                    "Recovered delegation bundle \(bundleIndex) VAN position: \(vanPosition)"
                                )
                                recoveredBundleCount += 1
                                recoveredBundleIndices.insert(bundleIndex)
                            }
                        }

                        if recoveredBundleCount >= existingBundleCount {
                            try await votingCrypto.clearRecoveryState(roundId)
                        }

                        if recoveredBundleCount > 0 {
                            if isKeystoneUser {
                                await send(.delegationBundlesRecovered(
                                    roundId: roundId,
                                    bundleIndices: recoveredBundleIndices
                                ))
                            }
                            let eligibleWeight = Self.votingWeight(for: notes, bundleCount: existingBundleCount)
                            guard eligibleWeight > 0 else {
                                await send(.ineligibleForRound(roundId: roundId, heldZatoshi: heldZatoshi))
                                return
                            }
                            await send(.earlyEligibilityConfirmed(roundId: roundId))
                            await send(.votingWeightLoaded(
                                roundId: roundId,
                                weight: eligibleWeight,
                                notes: notes,
                                witnesses: [],
                                bundleCount: existingBundleCount,
                                delegationReady: recoveredBundleCount >= existingBundleCount
                            ))
                        } else {
                            if isKeystoneUser {
                                preClearKeystoneSignatures = try await votingCrypto.loadKeystoneBundleSignatures(roundId)
                            }
                            guard try await Self.prepareFreshRound(
                                roundId: roundId,
                                session: session,
                                snapshotHeight: snapshotHeight,
                                walletDbPath: walletDbPath,
                                notes: notes,
                                votingCrypto: votingCrypto,
                                sdkSynchronizer: sdkSynchronizer,
                                send: send
                            ) else { return }
                            didPrepareFreshRound = true
                            resolvedBundleCount = (try? await votingCrypto.getBundleCount(roundId)) ?? 0
                        }
                    } else {
                        if isKeystoneUser {
                            preClearKeystoneSignatures = try await votingCrypto.loadKeystoneBundleSignatures(roundId)
                        }
                        guard try await Self.prepareFreshRound(
                            roundId: roundId,
                            session: session,
                            snapshotHeight: snapshotHeight,
                            walletDbPath: walletDbPath,
                            notes: notes,
                            votingCrypto: votingCrypto,
                            sdkSynchronizer: sdkSynchronizer,
                            send: send
                        ) else { return }
                        didPrepareFreshRound = true
                        resolvedBundleCount = (try? await votingCrypto.getBundleCount(roundId)) ?? 0
                    }

                    // 3. Hotkey: load or generate the per-account hotkey
                    // mnemonic, then derive this round's hotkey address.
                    guard let accountId else {
                        LoggerProxy.error("No selected account; skipping voting hotkey generation")
                        return
                    }
                    let phrase: String
                    if let stored = try? walletStorage.exportVotingHotkey(accountId) {
                        phrase = stored.seedPhrase.value()
                    } else {
                        phrase = try mnemonic.randomMnemonic()
                        try walletStorage.importVotingHotkey(phrase, accountId)
                    }
                    let seed = try mnemonic.toSeed(phrase)
                    let hotkey = try await votingCrypto.generateHotkey(roundId, seed)
                    await send(.hotkeyLoaded(roundId: roundId, address: hotkey.address))

                    if shouldRestoreKeystoneSignatures {
                        let savedSignatures = didPrepareFreshRound
                            ? preClearKeystoneSignatures
                            : try await votingCrypto.loadKeystoneBundleSignatures(roundId)
                        guard let validSignatures = Self.validKeystoneSignatures(
                            savedSignatures,
                            bundleCount: resolvedBundleCount
                        ) else {
                            LoggerProxy.warn("Ignoring inconsistent Keystone signing recovery state")
                            return
                        }
                        if !validSignatures.isEmpty {
                            if didPrepareFreshRound {
                                for signature in validSignatures {
                                    try await votingCrypto.storeKeystoneBundleSignature(roundId, signature)
                                }
                            }
                            await send(.keystoneSignaturesRestored(
                                roundId: roundId,
                                signatures: validSignatures
                            ))
                        }
                    }
                } catch: { error, send in
                    LoggerProxy.error("Active round pipeline failed: \(error)")
                    await send(.pipelineFailed(roundId: roundId, message: error.localizedDescription))
                }
                .cancellable(id: cancelPipelineId, cancelInFlight: true)

            case let .walletNotSynced(roundId, scannedHeight, _):
                // Pop any pushed screens (none expected with deferred-nav,
                // but defensive) and surface the explanation as a bottom
                // sheet on the polls list. The user dismisses with "Got it"
                // and can re-tap Enter Poll later; we deliberately don't
                // background-poll the SDK sync state from here — the SDK
                // continues catching up on its own, and the next Enter Poll
                // tap re-runs the pipeline.
                state.path.removeAll()
                state.walletScannedHeight = scannedHeight
                state.checkingEligibilityRoundId = nil
                state.pendingPipelineRoundId = nil
                state.walletSyncingSheetRoundId = roundId
                return .cancel(id: cancelPipelineId)

            case .walletSyncProgressUpdated(let height):
                state.walletScannedHeight = height
                // When sync catches up while user is on the walletSyncing
                // screen, restore the polls-list root and push the proposal
                // list before the pipeline action lands (visually the user
                // sees the polls list briefly then the proposal list).
                if state.rootScreen == .walletSyncing,
                   let roundId = state.pendingPipelineRoundId,
                   let item = state.allRounds.first(where: { $0.id == roundId }),
                   height >= item.session.snapshotHeight {
                    state.rootScreen = .pollsList
                    state.path.append(.proposalList(ProposalList.State(roundId: roundId)))
                }
                return .none

            case let .votingWeightLoaded(roundId, weight, notes, witnesses, bundleCount, delegationReady):
                let eligibleTotals = Self.eligibleTotals(for: notes)
                var roundSession = state.roundCache[roundId] ?? RoundSession(roundId: roundId)
                roundSession.votingWeight = weight
                roundSession.eligibleVotingWeight = eligibleTotals.weight > 0 ? eligibleTotals.weight : weight
                roundSession.walletNotes = notes
                roundSession.cachedWitnesses = witnesses
                roundSession.bundleCount = bundleCount
                roundSession.eligibleBundleCount = eligibleTotals.bundleCount > 0
                    ? eligibleTotals.bundleCount
                    : bundleCount
                roundSession.completedKeystoneDelegationBundleIndices =
                    roundSession.completedKeystoneDelegationBundleIndices.filter { $0 < bundleCount }
                if delegationReady {
                    roundSession.delegationProofStatus = .complete
                    roundSession.completedKeystoneDelegationBundleIndices = []
                } else {
                    roundSession.delegationProofStatus = .notStarted
                    roundSession.isDelegationProofInFlight = false
                    roundSession.delegationPrecomputeStatus = .notStarted
                    roundSession.isDelegationPrecomputeInFlight = false
                    if state.isKeystoneUser {
                        roundSession.currentKeystoneBundleIndex =
                            roundSession.firstIncompleteKeystoneBundleIndex ?? 0
                    }
                }
                state.roundCache[roundId] = roundSession
                if state.roundCache[roundId]?.hotkeyAddress != nil {
                    return .send(.maybeStartDelegationPrecompute(roundId: roundId))
                }
                return .none

            case let .earlyEligibilityConfirmed(roundId):
                // Fast-path handoff: the pipeline has just confirmed the
                // wallet has at least one viable bundle for this round. Push
                // the proposal list now (its own "Preparing your voting
                // power…" indicator covers the remaining 30–120 s witness
                // / tree-state work). No spinner on the polls list button is
                // needed because reaching this point is a local DB + Rust
                // bundling decision — sub-second under normal conditions.
                if state.checkingEligibilityRoundId == roundId {
                    state.checkingEligibilityRoundId = nil
                    state.path.append(.proposalList(ProposalList.State(roundId: roundId)))
                }
                return .none

            case let .hotkeyLoaded(roundId, address):
                state.roundCache[roundId, default: RoundSession(roundId: roundId)].hotkeyAddress = address
                if state.pendingPipelineRoundId == roundId {
                    state.pendingPipelineRoundId = nil
                }
                return .send(.maybeStartDelegationPrecompute(roundId: roundId))

            case let .pipelineFailed(roundId, message):
                // Pop the proposal list back to the polls list and surface
                // the error as the blocking error root. Cache stays around
                // (we just won't claim a hotkey was loaded); user can retry
                // by tapping the round again.
                if state.pendingPipelineRoundId == roundId {
                    state.pendingPipelineRoundId = nil
                }
                if state.checkingEligibilityRoundId == roundId {
                    state.checkingEligibilityRoundId = nil
                }
                state.path.removeAll()
                state.rootScreen = .error(message)
                return .none

            case let .submittedVotesLoaded(roundId, votes):
                guard !votes.isEmpty else { return .none }
                let account = state.selectedWalletAccount?.account
                var session = state.roundCache[roundId] ?? RoundSession(roundId: roundId)
                session.votes.merge(votes) { current, _ in current }
                let mergedVotes = session.votes
                let filteredDrafts = session.draftVotes
                    .filter { mergedVotes[$0.key] == nil }
                session.draftVotes = filteredDrafts
                let shouldStartShareTracking = !mergedVotes.isEmpty
                    && session.shareTrackingStatus == .idle
                    && !session.isSubmittingVote
                if shouldStartShareTracking {
                    session.shareTrackingStatus = .loading
                }
                do {
                    try Voting.persistRoundChoices(
                        drafts: filteredDrafts,
                        submittedVotes: mergedVotes,
                        roundId: roundId,
                        account: account
                    )
                    state.roundCache[roundId] = session
                } catch {
                    LoggerProxy.error("Failed to persist submitted voting choices: \(error)")
                    state.submissionAlert = .votingMetadataPersistenceFailed(error)
                    state.roundCache[roundId] = session
                }
                if shouldStartShareTracking {
                    return .send(.loadShareDelegations(roundId: roundId))
                }
                return .none

            case let .ineligibleForRound(roundId, heldZatoshi):
                // No eligible notes at the snapshot height (no notes at all,
                // or every bundle dropped below ballotDivisor). With the
                // deferred-navigation flow we typically never pushed the
                // proposal list — but pop defensively in case the pipeline
                // landed here from the wallet-sync resume path which does
                // push proactively.
                state.checkingEligibilityRoundId = nil
                if case .proposalList = state.path.last {
                    _ = state.path.popLast()
                }
                let snapshotHeight = state.allRounds
                    .first { $0.id == roundId }?
                    .session.snapshotHeight ?? 0
                state.ineligibleSheet = IneligibleSheetData(
                    heldZatoshi: heldZatoshi,
                    snapshotHeight: snapshotHeight,
                    minimumZatoshi: ballotDivisor
                )
                return .cancel(id: cancelPipelineId)

            case let .startRoundStatusPolling(roundId):
                guard let item = state.allRounds.first(where: { $0.id == roundId }),
                      item.session.status == .active
                else {
                    return .none
                }
                return .run { [votingAPI] send in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .seconds(5))
                            let updated = try await votingAPI.fetchRoundById(roundId)
                            await send(
                                .roundStatusUpdated(
                                    roundId: roundId,
                                    status: updated.status
                                )
                            )
                        } catch is CancellationError {
                            return
                        } catch {
                            LoggerProxy.warn("Voting round status polling fetch failed: \(error)")
                        }
                    }
                } catch: { error, _ in
                    LoggerProxy.warn("Voting round status polling failed: \(error)")
                }
                .cancellable(id: cancelStatusPollingId, cancelInFlight: true)

            case let .roundStatusUpdated(roundId, status):
                guard let index = state.allRounds.firstIndex(where: { $0.id == roundId }) else {
                    return .none
                }
                let current = state.allRounds[index].session.status
                guard current != status else { return .none }

                let item = state.allRounds[index]
                state.allRounds[index] = RoundListItem(
                    roundNumber: item.roundNumber,
                    session: session(item.session, withStatus: status)
                )

                // "Poll Closed" sheet is suppressed if the user has already
                // submitted a ballot for this round — telling someone "your
                // vote can no longer be submitted" right after they voted is
                // jarring. In that case we silently swap their current screen
                // for the appropriate status screen instead.
                let hasVoted = state.voteRecords[roundId] != nil
                    || state.roundCache[roundId]?.voteRecord != nil

                switch status {
                case .tallying:
                    let isCurrentRound = topPathRoundId(state) == roundId
                    if activeVotingFlowRoundId(state) == roundId, !hasVoted {
                        state.pollClosedSheet = State.PollClosedSheet(roundId: roundId, status: status)
                    } else if isCurrentRound {
                        replacePathWithStatusScreen(&state, roundId: roundId, status: status)
                    }
                    return isCurrentRound
                        ? .merge(
                            .cancel(id: cancelStatusPollingId),
                            .cancel(id: cancelShareTrackingId)
                        )
                        : .none

                case .finalized:
                    let isCurrentRound = topPathRoundId(state) == roundId
                    if activeVotingFlowRoundId(state) == roundId, !hasVoted {
                        state.pollClosedSheet = State.PollClosedSheet(roundId: roundId, status: status)
                    } else if isCurrentRound {
                        replacePathWithStatusScreen(&state, roundId: roundId, status: status)
                    }
                    return isCurrentRound
                        ? .merge(
                            .cancel(id: cancelStatusPollingId),
                            .cancel(id: cancelShareTrackingId),
                            .send(.fetchTallyResults(roundId: roundId)),
                            .send(.startNewRoundPolling)
                        )
                        : .none

                case .active, .unspecified:
                    return .none
                }

            case .dismissPollClosedAlert:
                state.pollClosedSheet = nil
                state.path.removeAll()
                return .none

            case .viewPollClosedResults:
                let sheet = state.pollClosedSheet
                state.pollClosedSheet = nil
                let roundId = sheet?.roundId ?? activeVotingFlowRoundId(state)
                guard let roundId,
                      let status = state.allRounds.first(where: { $0.id == roundId })?.session.status
                else {
                    state.path.removeAll()
                    return .none
                }
                replacePathWithStatusScreen(&state, roundId: roundId, status: status)
                if status == .finalized {
                    return .merge(
                        .send(.fetchTallyResults(roundId: roundId)),
                        .send(.startNewRoundPolling)
                    )
                }
                return .none

            case .startNewRoundPolling:
                return .run { [votingAPI] send in
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(30))
                        let sessions = try await votingAPI.fetchAllRounds()
                        let hasOpenRound = sessions.contains {
                            $0.status == .active || $0.status == .tallying
                        }
                        if hasOpenRound {
                            await send(.allRoundsLoaded(sessions))
                        }
                    }
                } catch: { error, _ in
                    LoggerProxy.warn("Voting new-round polling failed: \(error)")
                }
                .cancellable(id: cancelNewRoundPollingId, cancelInFlight: true)

            case let .loadShareDelegations(roundId):
                mutateSession(&state, roundId: roundId) {
                    $0.shareTrackingStatus = .loading
                }
                return .run { [votingCrypto] send in
                    let delegations = try await votingCrypto.getShareDelegations(roundId)
                    await send(.shareDelegationsLoaded(
                        roundId: roundId,
                        delegations: delegations
                    ))
                } catch: { error, _ in
                    LoggerProxy.warn("Failed to load share delegations: \(error)")
                }

            case let .shareDelegationsLoaded(roundId, delegations):
                updateShareTrackingState(&state, roundId: roundId, delegations: delegations)
                guard state.roundCache[roundId]?.shareTrackingStatus == .tracking else {
                    return .none
                }
                return .run { send in
                    try await Task.sleep(for: .seconds(1))
                    await send(.pollShareStatus(roundId: roundId))
                }
                .cancellable(id: cancelShareTrackingId, cancelInFlight: true)

            case let .shareDelegationsRefreshed(roundId, delegations):
                updateShareTrackingState(&state, roundId: roundId, delegations: delegations)
                return .none

            case let .pollShareStatus(roundId):
                return reducePollShareStatus(&state, roundId: roundId)

            case .dismissIneligibleSheet:
                state.ineligibleSheet = nil
                return .none

            case .dismissWalletSyncingSheet:
                state.walletSyncingSheetRoundId = nil
                return .none

            case .dismissProposalDetailStack:
                // Pops every `.proposalDetail` entry off the top of the
                // navigation stack so the X close button on
                // ProposalDetailView returns the user to the Proposal List
                // (or ReviewVotes) in one tap regardless of how deep the
                // chain of details they walked through with Next is.
                while case .proposalDetail = state.path.last {
                    _ = state.path.popLast()
                }
                return .none

            case let .openReviewDraftsScreen(roundId):
                state.path.append(.reviewDrafts(ReviewDrafts.State(roundId: roundId)))
                return .none

            case let .proposalDetailNextTapped(roundId, currentProposalId):
                // Drives the sticky Next CTA on ProposalDetailView:
                //   - if there's a next proposal → push it
                //   - else if every proposal has an answer → route to the
                //     "Review and submit vote" screen
                //   - else → surface the unanswered-questions sheet so the
                //     user can choose to continue without those answers or
                //     go back to fill them in. We never auto-select a
                //     choice on their behalf.
                guard let proposals = state.allRounds
                    .first(where: { $0.id == roundId })?
                    .session.proposals,
                    let currentIndex = proposals.firstIndex(where: { $0.id == currentProposalId })
                else {
                    return .none
                }
                let nextIndex = currentIndex + 1
                if nextIndex < proposals.count {
                    let detailMode: ProposalDetail.Mode
                    if case .proposalDetail(let scoped) = state.path.last {
                        detailMode = scoped.mode
                    } else {
                        detailMode = .voting
                    }
                    state.path.append(
                        .proposalDetail(
                            ProposalDetail.State(
                                roundId: roundId,
                                proposalId: proposals[nextIndex].id,
                                mode: detailMode
                            )
                        )
                    )
                    return .none
                }
                let session = state.roundCache[roundId]
                let drafts = session?.draftVotes ?? [:]
                let submitted = session?.votes ?? [:]
                let answered: (UInt32) -> Bool = { proposalId in
                    drafts[proposalId] != nil || submitted[proposalId] != nil
                }
                let unansweredPositions = proposals.enumerated().compactMap { offset, proposal in
                    answered(proposal.id) ? nil : offset + 1
                }
                if unansweredPositions.isEmpty {
                    state.path.append(.reviewDrafts(ReviewDrafts.State(roundId: roundId)))
                } else {
                    state.skippedQuestionsSheet = SkippedQuestionsSheetData(
                        roundId: roundId,
                        skippedDisplayIndices: unansweredPositions
                    )
                }
                return .none

            case .dismissSkippedQuestionsSheet:
                state.skippedQuestionsSheet = nil
                return .none

            case .skippedQuestionsGoBackTapped:
                // "Go back" on the unanswered-questions sheet terminates the
                // proposal-detail walk and returns the user to the active-
                // voting ProposalList so they can see at a glance which
                // questions are still unanswered. Plain sheet dismissal is
                // handled by `.dismissSkippedQuestionsSheet` (drag-dismiss).
                state.skippedQuestionsSheet = nil
                while case .proposalDetail = state.path.last {
                    _ = state.path.popLast()
                }
                return .none

            case let .confirmSkippedQuestionsAndReview(roundId):
                guard state.roundCache[roundId]?.draftVotes.isEmpty == false else {
                    state.skippedQuestionsSheet = nil
                    return .none
                }
                // Push the Review screen on top of the current detail stack
                // rather than popping the details first — popping made the
                // transition look like a "back" animation followed by a
                // push, which read as an accidental rewind to the user.
                state.skippedQuestionsSheet = nil
                state.path.append(.reviewDrafts(ReviewDrafts.State(roundId: roundId)))
                return .none

            case .refreshActiveRoundsList:
                // Lightweight re-fetch used by the tallying-status poll.
                // Reuses the same allRoundsLoaded path so we pick up any
                // status transition (active → tallying → finalized) without
                // disturbing rootScreen.
                return .run { [votingAPI] send in
                    do {
                        let sessions = try await votingAPI.fetchAllRounds()
                        await send(.allRoundsLoaded(sessions))
                    } catch {
                        LoggerProxy.warn("Tallying poll: rounds re-fetch failed: \(error)")
                    }
                }

            case let .retryFetchTallyResults(roundId):
                // Manual retry from ResultsView when the previous fetch
                // errored. Clear the error and re-trigger the fetch.
                if state.roundCache[roundId] != nil {
                    state.roundCache[roundId]?.tallyError = nil
                }
                return .send(.fetchTallyResults(roundId: roundId))
            }
        }
    }

    func reduceWalletAccountChanged(
        _ state: inout State,
        account: WalletAccount?
    ) -> Effect<Action> {
        let nextWalletId = walletId(for: account)
        let nextIsKeystoneUser = account?.vendor.isHWWallet() ?? false
        guard state.walletId != nextWalletId
            || state.isKeystoneUser != nextIsKeystoneUser
        else {
            return .none
        }

        state.walletId = nextWalletId
        state.isKeystoneUser = nextIsKeystoneUser
        resetAccountScopedVotingState(&state)
        votingMetadata.reset()

        let cancellation: Effect<Action> = .merge(
            .cancel(id: cancelPipelineId),
            .cancel(id: cancelSubmissionId),
            .cancel(id: cancelDelegationProofId),
            .cancel(id: cancelDelegationPrecomputeId),
            .cancel(id: cancelStatusPollingId),
            .cancel(id: cancelNewRoundPollingId),
            .cancel(id: cancelShareTrackingId)
        )

        guard account != nil else {
            state.rootScreen = .loading
            return cancellation
        }
        guard state.hasSeenHowToVoteForCurrentWallet else {
            state.rootScreen = .howToVote
            return cancellation
        }

        state.rootScreen = .loading
        return .merge(cancellation, .send(.initialize))
    }

    private func resetAccountScopedVotingState(_ state: inout State) {
        state.path.removeAll()
        state.roundCache.removeAll()
        state.voteRecords.removeAll()
        state.allRounds.removeAll()
        state.zodlEndorsedRoundIds.removeAll()
        state.pendingPipelineRoundId = nil
        state.pendingBatchSubmission = false
        state.submissionAlertRoundId = nil
        state.submissionAlert = nil
        state.keystoneScan = nil
        state.skipBundlesAlert = nil
        state.pollClosedSheet = nil
        state.pollsLoadError = false
        state.serviceConfig = nil
        state.walletScannedHeight = 0
        state.ineligibleSheet = nil
        state.checkingEligibilityRoundId = nil
        state.walletSyncingSheetRoundId = nil
        state.skippedQuestionsSheet = nil
    }

    private func walletId(for account: WalletAccount?) -> String {
        account?.id.id.map { String(format: "%02x", $0) }.joined() ?? ""
    }

    /// Returns the topmost path element's round id when it's a
    /// `.tallying` / `.proposalList` entry whose round status just flipped
    /// to `.finalized`, otherwise nil. Used by the tallying-status auto-
    /// poll to redirect the user onto ResultsView.
    private func finalizedTopOfPath(_ state: State) -> String? {
        guard let top = state.path.last else { return nil }
        let candidate: String?
        switch top {
        case let .tallying(scoped):
            candidate = scoped.roundId
        case let .proposalList(scoped):
            candidate = scoped.roundId
        default:
            candidate = nil
        }
        guard let roundId = candidate,
              let item = state.allRounds.first(where: { $0.id == roundId }),
              item.session.status == .finalized
        else { return nil }
        return roundId
    }

    private func topPathRoundId(_ state: State) -> String? {
        guard let top = state.path.last else { return nil }
        switch top {
        case let .proposalList(scoped):
            return scoped.roundId
        case let .proposalDetail(scoped):
            return scoped.roundId
        case let .reviewVotes(scoped):
            return scoped.roundId
        case let .reviewDrafts(scoped):
            return scoped.roundId
        case let .confirmSubmission(scoped):
            return scoped.roundId
        case let .delegationSigning(scoped):
            return scoped.roundId
        case let .tallying(scoped):
            return scoped.roundId
        case let .results(scoped):
            return scoped.roundId
        case let .ineligible(scoped):
            return scoped.roundId
        case .configSettings:
            return nil
        }
    }

    private func cancelShareTrackingIfSwitchingRound(
        _ state: State,
        to roundId: String
    ) -> Effect<Action> {
        topPathRoundId(state).map { $0 != roundId } == true
            ? .cancel(id: cancelShareTrackingId)
            : .none
    }

    private func activeVotingFlowRoundId(_ state: State) -> String? {
        guard let top = state.path.last else { return nil }
        switch top {
        case let .proposalList(scoped):
            return scoped.roundId
        case let .proposalDetail(scoped):
            return scoped.roundId
        case let .reviewVotes(scoped):
            return scoped.roundId
        case let .reviewDrafts(scoped):
            return scoped.roundId
        case let .confirmSubmission(scoped):
            return scoped.roundId
        case let .delegationSigning(scoped):
            return scoped.roundId
        case .tallying, .results, .ineligible, .configSettings:
            return nil
        }
    }

    private func replacePathWithStatusScreen(
        _ state: inout State,
        roundId: String,
        status: SessionStatus
    ) {
        state.path.removeAll()
        switch status {
        case .tallying:
            state.path.append(.tallying(Tallying.State(roundId: roundId)))
        case .finalized:
            state.path.append(.results(Results.State(roundId: roundId)))
        case .active, .unspecified:
            break
        }
    }

    private func session(_ session: VotingSession, withStatus status: SessionStatus) -> VotingSession {
        VotingSession(
            voteRoundId: session.voteRoundId,
            snapshotHeight: session.snapshotHeight,
            snapshotBlockhash: session.snapshotBlockhash,
            proposalsHash: session.proposalsHash,
            voteEndTime: session.voteEndTime,
            ceremonyStart: session.ceremonyStart,
            eaPK: session.eaPK,
            vkZkp1: session.vkZkp1,
            vkZkp2: session.vkZkp2,
            vkZkp3: session.vkZkp3,
            ncRoot: session.ncRoot,
            nullifierIMTRoot: session.nullifierIMTRoot,
            creator: session.creator,
            description: session.description,
            discussionURL: session.discussionURL,
            proposals: session.proposals,
            status: status,
            createdAtHeight: session.createdAtHeight,
            title: session.title
        )
    }

    // MARK: - Entry point

    /// `.submitAllDraftsTapped` handler. Gates the request, prompts for
    /// local auth (Zashi), and dispatches `.authenticationSucceeded`.
    /// Keystone users skip the local auth gate (the device itself is the
    /// auth surface).
    func reduceSubmitAllDraftsTapped(_ state: inout State, roundId: String) -> Effect<Action> {
        guard let session = state.roundCache[roundId] else { return .none }
        guard canStartSubmission(session) else { return .none }
        guard activeSession(in: state, roundId: roundId) != nil else { return .none }
        // Partial ballots are explicitly allowed: the user has already
        // acknowledged any skipped questions via the ProposalDetail
        // skipped-questions sheet. We submit only what they drafted —
        // skipped proposals have no entry in `session.draftVotes` and are
        // therefore never iterated by the submission loop, never marked as
        // abstain, never auto-filled.

        if !state.isKeystoneUser && !state.pendingBatchSubmission {
            return .run { [localAuthentication] send in
                guard await localAuthentication.authenticate() else { return }
                await send(.authenticationSucceeded(roundId: roundId))
            }
        }
        return .send(.authenticationSucceeded(roundId: roundId))
    }

    /// `.authenticationSucceeded` handler. Branches on Keystone vs. Zashi,
    /// honors a Zashi precompute-in-flight wait, and otherwise kicks off
    /// the batch submission `.run` effect.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func reduceAuthenticationSucceeded(_ state: inout State, roundId: String) -> Effect<Action> {
        guard let session = state.roundCache[roundId] else { return .none }
        guard canStartSubmission(session) || isBatchSubmitting(session) else { return .none }
        guard let activeSession = activeSession(in: state, roundId: roundId) else { return .none }
        // Partial ballots are intentional — see `reduceSubmitAllDraftsTapped`.

        // Keystone: route into the per-bundle QR signing screen first.
        // The actual submission resumes via `pendingBatchSubmission` after
        // all bundles are signed.
        if state.isKeystoneUser && !isDelegationReady(session) {
            state.pendingBatchSubmission = true
            mutateSession(&state, roundId: roundId) { roundSession in
                roundSession.batchSubmissionStatus = .authorizing
                roundSession.voteSubmissionStep = .authorizingVote
            }
            if !hasKeystoneSigningRound(state: state, roundId: roundId) {
                state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
            }
            return .send(.startDelegationProof(roundId: roundId))
        }

        // Zashi only: if a precompute is in flight, mark submission as
        // pending and let `.delegationPrecomputeCompleted` resume.
        if !state.isKeystoneUser
            && !isDelegationReady(session)
            && session.isDelegationPrecomputeInFlight {
            state.pendingBatchSubmission = true
            mutateSession(&state, roundId: roundId) { roundSession in
                roundSession.batchSubmissionStatus = .authorizing
                roundSession.voteSubmissionStep = .authorizingVote
                roundSession.delegationProofStatus = .generating(progress: 0)
            }
            return .none
        }

        let drafts = session.draftVotes.sorted { $0.key < $1.key }
        guard !drafts.isEmpty else { return .none }
        let totalCount = drafts.count
        let delegationDone = isDelegationReady(session)
        let delegationPrepared = session.delegationPrecomputeStatus == .ready

        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.batchSubmissionStatus = delegationDone
                ? .submitting(currentIndex: 0, totalCount: totalCount, currentProposalId: drafts[0].key)
                : .authorizing
            roundSession.voteSubmissionStep = delegationDone ? nil : .authorizingVote
            if !delegationDone {
                roundSession.delegationProofStatus = .generating(progress: 0)
            }
            roundSession.batchVoteErrors = [:]
        }

        let network = zcashSDKEnvironment.network()
        let networkId: UInt32 = network.networkType.votingRustNetworkId
        let accountIndex = votingAccountIndex(for: state.selectedWalletAccount)
        let seedFingerprint = votingSeedFingerprint(for: state.selectedWalletAccount)
        guard
            let chainNodeUrl = state.serviceConfig?.voteServers.first?.url,
            let voteServerURLs = state.serviceConfig?.voteServers.map(\.url).nonEmpty,
            let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url).nonEmpty,
            let accountId = state.selectedWalletAccount?.id
        else {
            LoggerProxy.error("serviceConfig/activeSession/selectedAccount unexpectedly nil during vote submission; aborting")
            return .none
        }
        let expectedSnapshotHeight = activeSession.snapshotHeight
        let bundleCount = session.bundleCount
        let singleShare = activeSession.isLastMoment
        let proposals = activeSession.proposals
        let cachedNotes = session.walletNotes
        let roundName = activeSession.title

        let submitAtDeadline: Double?
        if singleShare {
            submitAtDeadline = nil
        } else if let buffer = activeSession.lastMomentBuffer {
            submitAtDeadline = activeSession.voteEndTime.timeIntervalSince1970 - buffer
        } else {
            submitAtDeadline = nil
        }

        return .run { [backgroundTask, votingAPI, votingCrypto, mnemonic, walletStorage] send in
            let bgTaskId = await backgroundTask.beginTask("Batch vote submission")
            _ = await backgroundTask.beginContinuedProcessing(
                "co.zodl.voting.*",
                String(localizable: .coinVoteSubmissionContinuedProcessingTitle),
                totalCount == 1
                    ? String(localizable: .coinVoteSubmissionContinuedProcessingMessageSingle(String(totalCount)))
                    : String(localizable: .coinVoteSubmissionContinuedProcessingMessageMultiple(String(totalCount)))
            )
            defer {
                Task {
                    await backgroundTask.endContinuedProcessing()
                    await backgroundTask.endTask(bgTaskId)
                }
            }

            let hotkeyPhrase = try walletStorage.exportVotingHotkey(accountId).seedPhrase.value()
            let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)

            // --- Delegation (ZKP #1) — run inline if not already done ---
            if !delegationDone {
                do {
                    let senderPhrase = try walletStorage.exportWallet().seedPhrase.value()
                    let senderSeed = try mnemonic.toSeed(senderPhrase)
                    try await Self.runDelegationPipeline(
                        roundId: roundId,
                        cachedNotes: cachedNotes,
                        senderSeed: senderSeed,
                        hotkeySeed: hotkeySeed,
                        networkId: networkId,
                        accountIndex: accountIndex,
                        roundName: roundName,
                        pirEndpoints: pirEndpoints,
                        expectedSnapshotHeight: expectedSnapshotHeight,
                        delegationPrepared: delegationPrepared,
                        seedFingerprint: seedFingerprint,
                        votingCrypto: votingCrypto,
                        votingAPI: votingAPI,
                        send: send
                    )
                } catch {
                    LoggerProxy.error("Delegation pipeline failed (raw): \(error.localizedDescription)")
                    await send(.batchAuthorizationFailed(
                        roundId: roundId,
                        error: VotingErrorMapper.userFriendlyMessage(from: error.localizedDescription)
                    ))
                    return
                }
            }

            // Transition from .authorizing to .submitting now that delegation is done.
            await send(.batchSubmissionProgress(
                roundId: roundId,
                currentIndex: 0,
                totalCount: totalCount,
                proposalId: drafts[0].key
            ))

            var successCount = 0
            var failCount = 0
            var shareServerURLs = voteServerURLs

            draftLoop: for (draftIndex, draft) in drafts.enumerated() {
                let proposalId = draft.key
                let choice = draft.value
                let proposal = proposals.first { $0.id == proposalId }
                let numOptions = UInt32(proposal?.options.count ?? 3)

                await send(.batchSubmissionProgress(
                    roundId: roundId,
                    currentIndex: draftIndex,
                    totalCount: totalCount,
                    proposalId: proposalId
                ))

                // Synthetic abstain: no on-chain submission, just mark done.
                if Voting.isSyntheticAbstain(choice: choice, proposal: proposal) {
                    successCount += 1
                    await send(.batchVoteSubmitted(roundId: roundId, proposalId: proposalId, choice: choice))
                    continue
                }

                do {
                    let existingVotes = try await votingCrypto.getVotes(roundId)
                    let submittedBundles = Set(
                        existingVotes
                            .filter { $0.proposalId == proposalId && $0.submitted }
                            .map(\.bundleIndex)
                    )

                    for bundleIndex: UInt32 in 0..<bundleCount {
                        if submittedBundles.contains(bundleIndex) {
                            LoggerProxy.debug("Batch: bundle \(bundleIndex + 1)/\(bundleCount) already submitted for proposal \(proposalId)")
                            continue
                        }

                        await send(.voteSubmissionBundleStarted(roundId: roundId, bundleIndex: bundleIndex))
                        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .preparingProof))

                        // Crash recovery: if this bundle's TX already landed on-chain,
                        // skip to share delegation rather than re-proving.
                        if try await Self.tryRecoverInflightVote(
                            roundId: roundId,
                            bundleIndex: bundleIndex,
                            proposalId: proposalId,
                            choice: choice,
                            numOptions: numOptions,
                            singleShare: singleShare,
                            submitAtDeadline: submitAtDeadline,
                            shareServerURLs: &shareServerURLs,
                            votingCrypto: votingCrypto,
                            votingAPI: votingAPI,
                            send: send,
                            roundIdAction: { roundId }
                        ) {
                            continue
                        }

                        let anchorHeight = try await votingCrypto.syncVoteTree(roundId, chainNodeUrl)
                        let vanWitness = try await votingCrypto.generateVanWitness(roundId, bundleIndex, anchorHeight)

                        var builtBundle: VoteCommitmentBundle?
                        for try await event in votingCrypto.buildVoteCommitment(
                            roundId, bundleIndex, hotkeySeed, networkId, proposalId, choice,
                            numOptions, vanWitness.authPath, vanWitness.position, vanWitness.anchorHeight, singleShare
                        ) {
                            if case .completed(let bundle) = event {
                                builtBundle = bundle
                            }
                        }
                        guard let builtBundle else {
                            throw VotingFlowError.missingVoteCommitmentBundle
                        }

                        try await votingCrypto.storeVoteCommitmentBundle(roundId, bundleIndex, proposalId, builtBundle, 0)

                        let castVoteSig = try await votingCrypto.signCastVote(hotkeySeed, networkId, builtBundle)

                        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .confirming))
                        let txResult = try await votingAPI.submitVoteCommitment(builtBundle, castVoteSig)
                        try await votingCrypto.storeVoteTxHash(roundId, bundleIndex, proposalId, txResult.txHash)

                        let voteDeadline = Date().addingTimeInterval(90)
                        var voteConfirmation: TxConfirmation?
                        repeat {
                            voteConfirmation = try? await votingAPI.fetchTxConfirmation(txResult.txHash)
                            if voteConfirmation != nil { break }
                            try await Task.sleep(for: .seconds(2))
                        } while Date() < voteDeadline

                        guard let voteConfirmation, voteConfirmation.code == 0,
                              let leafPair = voteConfirmation.event(ofType: "cast_vote")?.attribute(forKey: "leaf_index")
                        else {
                            throw VotingFlowError.voteCommitmentTxFailed(
                                code: voteConfirmation?.code ?? 0,
                                log: voteConfirmation?.log ?? ""
                            )
                        }
                        let leafParts = leafPair.split(separator: ",")
                        guard leafParts.count == 2,
                              let vanIdx = UInt32(leafParts[0]),
                              let vcIdx = UInt64(leafParts[1])
                        else {
                            throw VotingFlowError.voteCommitmentTxFailed(
                                code: 0,
                                log: "malformed cast_vote leaf_index: \(leafPair)"
                            )
                        }

                        try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanIdx)

                        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .sendingShares))
                        var payloads = try await votingCrypto.buildSharePayloads(
                            builtBundle.encShares, builtBundle, choice, numOptions, vcIdx, singleShare
                        )
                        let nowSec = Date().timeIntervalSince1970
                        for i in payloads.indices {
                            if let deadline = submitAtDeadline, deadline > nowSec {
                                payloads[i].submitAt = UInt64(nowSec + Double.random(in: 0..<(deadline - nowSec)))
                            } else {
                                payloads[i].submitAt = 0
                            }
                        }
                        try await votingCrypto.storeVoteCommitmentBundle(roundId, bundleIndex, proposalId, builtBundle, vcIdx)
                        let batchDelegationResult = try await Voting.delegateSharesWithFallback(
                            payloads,
                            roundId: roundId,
                            votingAPI: votingAPI,
                            serverURLs: shareServerURLs
                        )
                        shareServerURLs = batchDelegationResult.remainingServerURLs
                        for info in batchDelegationResult.delegatedShares {
                            guard let payload = payloads.first(where: {
                                $0.encShare.shareIndex == info.shareIndex && $0.proposalId == info.proposalId
                            }) else { continue }
                            let blindIndex = Int(info.shareIndex)
                            guard blindIndex < builtBundle.shareBlindFactors.count else { continue }
                            do {
                                let nullifierHex = try votingCrypto.computeShareNullifier(
                                    [UInt8](builtBundle.voteCommitment),
                                    info.shareIndex,
                                    [UInt8](builtBundle.shareBlindFactors[blindIndex])
                                )
                                try await votingCrypto.recordShareDelegation(
                                    roundId, bundleIndex, info.proposalId,
                                    info.shareIndex, info.acceptedByServers,
                                    [UInt8](votingDataFromHex(nullifierHex)), payload.submitAt
                                )
                            } catch {
                                LoggerProxy.warn("Batch: failed to record share delegation for share \(info.shareIndex): \(error)")
                            }
                        }
                        try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId)
                    }

                    successCount += 1
                    await send(.batchVoteSubmitted(roundId: roundId, proposalId: proposalId, choice: choice))
                } catch {
                    failCount += 1
                    LoggerProxy.error("Batch vote failed for proposal \(proposalId): \(error)")
                    let shouldStopBatch = error as? ShareDelegationError == .noReachableVoteServers
                    if shouldStopBatch {
                        shareServerURLs = []
                    }
                    await send(.batchVoteFailed(
                        roundId: roundId,
                        proposalId: proposalId,
                        error: VotingErrorMapper.userFriendlyMessage(from: error)
                    ))
                    if shouldStopBatch {
                        break draftLoop
                    }
                }
            }

            await send(.batchSubmissionCompleted(
                roundId: roundId,
                successCount: successCount,
                failCount: failCount
            ))
        } catch: { error, send in
            LoggerProxy.error("Batch submission failed at top level: \(error)")
            await send(.batchSubmissionFailed(
                roundId: roundId,
                error: VotingErrorMapper.userFriendlyMessage(from: error.localizedDescription),
                submittedCount: 0,
                totalCount: totalCount
            ))
        }
        .cancellable(id: cancelSubmissionId, cancelInFlight: true)
    }

    // MARK: - Delegation precompute

    func reduceMaybeStartDelegationPrecompute(_ state: inout State, roundId: String) -> Effect<Action> {
        guard !state.isKeystoneUser else { return .none }
        guard let session = state.roundCache[roundId] else { return .none }
        guard !isDelegationReady(session) else { return .none }
        guard !session.isDelegationProofInFlight,
              !session.isDelegationPrecomputeInFlight
        else { return .none }
        guard session.delegationPrecomputeStatus == .notStarted else { return .none }
        guard session.hotkeyAddress != nil else { return .none }
        guard session.bundleCount > 0, !session.walletNotes.isEmpty else { return .none }
        guard let activeSession = activeSession(in: state, roundId: roundId),
              activeSession.status == .active
        else { return .none }
        guard
            let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url).nonEmpty,
            let seedFingerprint = votingSeedFingerprint(for: state.selectedWalletAccount),
            let accountId = state.selectedWalletAccount?.id
        else {
            return .none
        }

        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.delegationPrecomputeStatus = .inProgress
            roundSession.isDelegationPrecomputeInFlight = true
        }

        let expectedSnapshotHeight = activeSession.snapshotHeight
        let cachedNotes = session.walletNotes
        let bundleCount = session.bundleCount
        let network = zcashSDKEnvironment.network()
        let networkId: UInt32 = network.networkType.votingRustNetworkId
        let accountIndex = votingAccountIndex(for: state.selectedWalletAccount)
        let roundName = activeSession.title

        return .run { [votingCrypto, mnemonic, walletStorage] send in
            let hotkeyPhrase = try walletStorage.exportVotingHotkey(accountId).seedPhrase.value()
            let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
            let noteChunks = cachedNotes.smartBundles().bundles
            guard Int(bundleCount) <= noteChunks.count else {
                throw VotingFlowError.inconsistentBundleSetup(
                    bundleCount: bundleCount,
                    noteChunkCount: noteChunks.count
                )
            }

            var totalCached: UInt32 = 0
            var totalFetched: UInt32 = 0
            for bundleIndex: UInt32 in 0..<bundleCount {
                try Task.checkCancellation()
                if case .present? = try? await votingCrypto.getDelegationTxHash(roundId, bundleIndex) {
                    continue
                }

                let bundleNotes = noteChunks[Int(bundleIndex)]
                guard let firstNote = bundleNotes.first else { continue }
                let orchardFvk = try votingCrypto.extractOrchardFvkFromUfvk(
                    firstNote.ufvkStr,
                    networkId
                )

                _ = try await votingCrypto.buildVotingPczt(
                    roundId,
                    bundleIndex,
                    bundleNotes,
                    emptySenderSeed,
                    hotkeySeed,
                    networkId,
                    accountIndex,
                    roundName,
                    orchardFvk,
                    seedFingerprint
                )

                let result = try await votingCrypto.precomputeDelegationPir(
                    roundId,
                    bundleIndex,
                    bundleNotes,
                    pirEndpoints,
                    expectedSnapshotHeight,
                    networkId
                )
                totalCached += result.cachedCount
                totalFetched += result.fetchedCount
                LoggerProxy.info(
                    "Delegation PIR precompute bundle \(bundleIndex + 1)/\(bundleCount): " +
                        "cached=\(result.cachedCount) fetched=\(result.fetchedCount)"
                )
            }

            LoggerProxy.info(
                "Delegation PIR precompute complete: cached=\(totalCached) fetched=\(totalFetched)"
            )
            await send(.delegationPrecomputeCompleted(roundId: roundId))
        } catch: { error, send in
            await send(.delegationPrecomputeFailed(roundId: roundId, error: error.localizedDescription))
        }
        .cancellable(id: cancelDelegationPrecomputeId, cancelInFlight: true)
    }

    // MARK: - Share tracking

    func reducePollShareStatus(_ state: inout State, roundId: String) -> Effect<Action> {
        guard let session = state.roundCache[roundId],
              session.shareTrackingStatus == .tracking,
              let activeSession = activeSession(in: state, roundId: roundId)
        else {
            return .none
        }

        let votes = session.votes
        let proposals = activeSession.proposals
        let singleShare = activeSession.isLastMoment
        let voteEndTime = UInt64(activeSession.voteEndTime.timeIntervalSince1970)

        return .run { [votingAPI, votingCrypto] send in
            let freshDelegations = (try? await votingCrypto.getShareDelegations(roundId)) ?? []
            let unconfirmed = freshDelegations.filter { !$0.confirmed }
            let now = UInt64(Date().timeIntervalSince1970)

            let readyShares = unconfirmed.filter {
                Self.isShareReadyForStatusCheck($0, now: now)
            }
            let pollResult = await Self.pollShareStatusesForRecovery(
                readyShares: readyShares,
                roundId: roundId,
                now: now,
                voteEndTime: voteEndTime,
                fetchShareStatus: votingAPI.fetchShareStatus
            )

            for key in pollResult.confirmedShares {
                do {
                    try await votingCrypto.markShareConfirmed(
                        roundId,
                        key.bundleIndex,
                        key.proposalId,
                        key.shareIndex
                    )
                } catch {
                    LoggerProxy.warn("Failed to mark share confirmed: \(error)")
                }
            }

            let grouped = Dictionary(grouping: pollResult.resubmissionShares) {
                "\($0.bundleIndex):\($0.proposalId)"
            }
            for (_, shares) in grouped {
                guard let first = shares.first else { continue }
                let bundleIndex = first.bundleIndex
                let proposalId = first.proposalId
                guard
                    let result = try? await votingCrypto.getVoteCommitmentBundleWithPosition(
                        roundId,
                        bundleIndex,
                        proposalId
                    ),
                    let choice = votes[proposalId]
                else {
                    continue
                }

                let numOptions = UInt32(proposals.first { $0.id == proposalId }?.options.count ?? 3)
                do {
                    var payloads = try await votingCrypto.buildSharePayloads(
                        result.bundle.encShares,
                        result.bundle,
                        choice,
                        numOptions,
                        result.vcTreePosition,
                        singleShare
                    )
                    for index in payloads.indices {
                        payloads[index].submitAt = 0
                    }

                    for share in shares {
                        guard let payload = payloads.first(where: {
                            $0.encShare.shareIndex == share.shareIndex
                        }) else {
                            continue
                        }
                        let acceptedServers = try await votingAPI.resubmitShare(
                            payload,
                            roundId,
                            share.sentToURLs
                        )
                        let newServers = acceptedServers.filter {
                            !share.sentToURLs.contains($0)
                        }
                        if !newServers.isEmpty {
                            try await votingCrypto.addSentServers(
                                roundId,
                                bundleIndex,
                                proposalId,
                                share.shareIndex,
                                newServers
                            )
                        }
                    }
                } catch {
                    LoggerProxy.warn("Share resubmission failed: \(error)")
                }
            }

            let updatedDelegations = (try? await votingCrypto.getShareDelegations(roundId))
                ?? freshDelegations
            await send(.shareDelegationsRefreshed(
                roundId: roundId,
                delegations: updatedDelegations
            ))

            let refreshedNow = UInt64(Date().timeIntervalSince1970)
            let stillUnconfirmed = updatedDelegations.filter { !$0.confirmed }
            guard !stillUnconfirmed.isEmpty else { return }

            let futureCheckTimes = stillUnconfirmed.compactMap { share -> UInt64? in
                let readyAt = Self.shareRecoveryBaseTime(share) + Self.shareCheckGrace
                return readyAt > refreshedNow ? readyAt : nil
            }
            let sleepSeconds: UInt64
            if let soonest = futureCheckTimes.min() {
                sleepSeconds = min(soonest - refreshedNow, 30)
            } else {
                sleepSeconds = 15
            }
            try await Task.sleep(for: .seconds(max(sleepSeconds, 3)))
            await send(.pollShareStatus(roundId: roundId))
        } catch: { error, _ in
            LoggerProxy.warn("Share tracking poll failed: \(error)")
        }
        .cancellable(id: cancelShareTrackingId, cancelInFlight: true)
    }

    private func updateShareTrackingState(
        _ state: inout State,
        roundId: String,
        delegations: [VotingShareDelegation]
    ) {
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.shareDelegations = delegations
            let allConfirmed = !delegations.isEmpty && delegations.allSatisfy(\.confirmed)
            if delegations.isEmpty {
                roundSession.shareTrackingStatus = .idle
            } else if allConfirmed {
                roundSession.shareTrackingStatus = .fullyConfirmed
            } else {
                roundSession.shareTrackingStatus = .tracking
            }
        }
    }

    static let shareCheckGrace: UInt64 = 10

    static func shareRecoveryBaseTime(_ share: VotingShareDelegation) -> UInt64 {
        share.submitAt > 0 ? share.submitAt : share.createdAt
    }

    static func isShareReadyForStatusCheck(
        _ share: VotingShareDelegation,
        now: UInt64
    ) -> Bool {
        now >= shareRecoveryBaseTime(share) + shareCheckGrace
    }

    static func shouldResubmitShare(
        _ share: VotingShareDelegation,
        now: UInt64,
        voteEndTime: UInt64
    ) -> Bool {
        let baseTime = shareRecoveryBaseTime(share)
        let remainingWindow = voteEndTime > baseTime ? voteEndTime - baseTime : 0
        let overdueThreshold: UInt64 = max(30, min(3_600, remainingWindow / 4))

        return now >= baseTime + overdueThreshold && voteEndTime > now + 10
    }

    static func pollShareStatusesForRecovery(
        readyShares: [VotingShareDelegation],
        roundId: String,
        now: UInt64,
        voteEndTime: UInt64,
        fetchShareStatus: @escaping @Sendable (
            _ helperBaseURL: String,
            _ roundIdHex: String,
            _ nullifierHex: String
        ) async throws -> ShareConfirmationResult
    ) async -> ShareRecoveryPollResult {
        var confirmedShares: [ShareDelegationKey] = []
        var resubmissionShares: [VotingShareDelegation] = []
        var queriedCount = 0

        for share in readyShares {
            var confirmed = false
            for helperURL in share.sentToURLs {
                queriedCount += 1
                do {
                    let result = try await fetchShareStatus(helperURL, roundId, share.nullifier)
                    if result == .confirmed {
                        confirmedShares.append(ShareDelegationKey(
                            bundleIndex: share.bundleIndex,
                            proposalId: share.proposalId,
                            shareIndex: share.shareIndex
                        ))
                        confirmed = true
                        break
                    }
                } catch {
                    LoggerProxy.warn("Share status check failed: \(error)")
                }
            }

            if !confirmed && shouldResubmitShare(share, now: now, voteEndTime: voteEndTime) {
                resubmissionShares.append(share)
            }
        }

        return ShareRecoveryPollResult(
            confirmedShares: confirmedShares,
            resubmissionShares: resubmissionShares,
            queriedCount: queriedCount
        )
    }

    // MARK: - Per-action state updates

    func reduceBatchSubmissionProgress(
        _ state: inout State,
        roundId: String,
        currentIndex: Int,
        totalCount: Int,
        proposalId: UInt32
    ) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.batchSubmissionStatus = .submitting(
                currentIndex: currentIndex,
                totalCount: totalCount,
                currentProposalId: proposalId
            )
            roundSession.submittingProposalId = proposalId
            roundSession.isSubmittingVote = true
            roundSession.voteSubmissionStep = nil
            roundSession.currentVoteBundleIndex = nil
        }
        return .none
    }

    func reduceVoteSubmissionBundleStarted(
        _ state: inout State,
        roundId: String,
        bundleIndex: UInt32
    ) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { $0.currentVoteBundleIndex = bundleIndex }
        return .none
    }

    func reduceVoteSubmissionStepUpdated(
        _ state: inout State,
        roundId: String,
        step: VoteSubmissionStep
    ) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { $0.voteSubmissionStep = step }
        return .none
    }

    func reduceBatchVoteSubmitted(
        _ state: inout State,
        roundId: String,
        proposalId: UInt32,
        choice: VoteChoice
    ) -> Effect<Action> {
        let account = state.selectedWalletAccount?.account
        guard var session = state.roundCache[roundId] else { return .none }
        var nextVotes = session.votes
        var nextDrafts = session.draftVotes
        nextVotes[proposalId] = choice
        nextDrafts.removeValue(forKey: proposalId)

        do {
            try Voting.persistRoundChoices(
                drafts: nextDrafts,
                submittedVotes: nextVotes,
                roundId: roundId,
                account: account
            )
            session.votes = nextVotes
            session.draftVotes = nextDrafts
        } catch {
            LoggerProxy.error("Failed to persist submitted voting choice: \(error)")
            session.batchVoteErrors[proposalId] = votingMetadataPersistenceMessage(error)
            state.submissionAlert = .votingMetadataPersistenceFailed(error)
        }
        state.roundCache[roundId] = session
        return .none
    }

    func reduceBatchVoteFailed(
        _ state: inout State,
        roundId: String,
        proposalId: UInt32,
        error: String
    ) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { $0.batchVoteErrors[proposalId] = error }
        return .none
    }

    func reduceBatchSubmissionCompleted(
        _ state: inout State,
        roundId: String,
        successCount: Int,
        failCount: Int
    ) -> Effect<Action> {
        let account = state.selectedWalletAccount?.account
        guard var session = state.roundCache[roundId] else { return .none }
        let persistedFailureCount = session.batchVoteErrors.count
        let submittedVoteCount = session.votes.count
        let outstandingDraftCount = session.draftVotes.count
        let submittedOrOutstandingCount = submittedVoteCount + outstandingDraftCount

        session.isSubmittingVote = false
        session.submittingProposalId = nil
        session.voteSubmissionStep = nil
        session.currentVoteBundleIndex = nil

        if failCount > 0 || persistedFailureCount > 0 {
            let error = session.batchVoteErrors.values.first
                ?? String(localizable: .coinVoteSubmissionGenericBatchFailure)
            session.batchSubmissionStatus = .submissionFailed(
                error: error,
                submittedCount: submittedVoteCount,
                totalCount: max(successCount + failCount, submittedOrOutstandingCount)
            )
            state.roundCache[roundId] = session
            return .none
        }

        // Partial ballots are valid. Completion means every draft the user
        // chose to submit was accepted and moved out of `draftVotes`; skipped
        // proposals intentionally never receive entries in `session.votes`.
        guard outstandingDraftCount == 0, submittedVoteCount > 0 else {
            session.batchSubmissionStatus = .submissionFailed(
                error: String(localizable: .coinVoteSubmissionGenericBatchFailure),
                submittedCount: submittedVoteCount,
                totalCount: submittedOrOutstandingCount
            )
            state.roundCache[roundId] = session
            return .none
        }

        if session.voteRecord == nil {
            let record = Voting.VoteRecord(
                votedAt: Date(),
                votingWeight: session.votingWeight,
                proposalCount: submittedVoteCount,
                eligibleVotingWeight: state.isKeystoneUser
                    ? completedEligibleVotingWeight(session)
                    : nil,
                submittedBundleCount: state.isKeystoneUser ? session.bundleCount : nil,
                totalBundleCount: state.isKeystoneUser
                    ? completedEligibleBundleCount(session)
                    : nil
            )
            do {
                try Voting.persistCompletedRound(record, roundId: roundId, account: account)
                session.voteRecord = record
            } catch {
                LoggerProxy.error("Failed to persist voting completion record: \(error)")
                if session.draftVotes.isEmpty {
                    session.draftVotes = session.votes
                }
                session.batchSubmissionStatus = .submissionFailed(
                    error: votingMetadataPersistenceMessage(error),
                    submittedCount: submittedVoteCount,
                    totalCount: max(submittedVoteCount, session.draftVotes.count)
                )
                state.submissionAlert = .votingMetadataPersistenceFailed(error)
                state.roundCache[roundId] = session
                return .none
            }
        }
        session.batchSubmissionStatus = .completed(successCount: submittedVoteCount)
        state.roundCache[roundId] = session

        if let record = session.voteRecord {
            state.voteRecords[roundId] = record
        }
        if session.shareTrackingStatus == .idle {
            mutateSession(&state, roundId: roundId) {
                $0.shareTrackingStatus = .loading
            }
            return .send(.loadShareDelegations(roundId: roundId))
        }
        return .none
    }

    func reduceBatchAuthorizationFailed(
        _ state: inout State,
        roundId: String,
        error: String
    ) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.isSubmittingVote = false
            roundSession.submittingProposalId = nil
            roundSession.voteSubmissionStep = nil
            roundSession.currentVoteBundleIndex = nil
            roundSession.batchSubmissionStatus = .authorizationFailed(error: error)
        }
        return .none
    }

    func reduceBatchSubmissionFailed(
        _ state: inout State,
        roundId: String,
        error: String,
        submittedCount: Int,
        totalCount: Int
    ) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.isSubmittingVote = false
            roundSession.submittingProposalId = nil
            roundSession.voteSubmissionStep = nil
            roundSession.currentVoteBundleIndex = nil
            roundSession.batchSubmissionStatus = .submissionFailed(
                error: error,
                submittedCount: submittedCount,
                totalCount: totalCount
            )
        }
        return .none
    }

    func reduceRetryBatchSubmission(_ state: inout State, roundId: String) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.batchSubmissionStatus = .idle
            roundSession.batchVoteErrors = [:]
        }
        return .send(.submitAllDraftsTapped(roundId: roundId))
    }

    // MARK: - Delegation proof effect plumbing

    // swiftlint:disable:next function_body_length
    func reduceStartDelegationProof(_ state: inout State, roundId: String) -> Effect<Action> {
        // The Zashi inline path runs delegation from inside the batch
        // submission `.run` block. This case is reachable directly only for
        // the Keystone flow, which builds one voting PCZT per bundle and
        // hands it off to the QR signing screen.
        guard state.isKeystoneUser else { return .none }
        guard let session = state.roundCache[roundId] else { return .none }
        guard !session.isDelegationProofInFlight, session.delegationProofStatus != .complete else {
            return .none
        }
        guard let nextBundleIndex = session.firstIncompleteKeystoneBundleIndex else {
            mutateSession(&state, roundId: roundId) { roundSession in
                roundSession.keystoneSigningStatus = .finalizingAuthorization
                roundSession.delegationProofStatus = .generating(progress: 0)
                roundSession.isDelegationProofInFlight = true
                roundSession.batchSubmissionStatus = .authorizing
                roundSession.voteSubmissionStep = .authorizingVote
            }
            return .send(.keystoneAllBundlesSigned(roundId: roundId))
        }
        guard case .idle = session.keystoneSigningStatus else {
            return .none
        }
        guard let activeSession = state.allRounds.first(where: { $0.id == roundId })?.session else {
            return .none
        }

        let keystoneMetadata: (seedFingerprint: Data, accountIndex: UInt32)?
        if let account = state.selectedWalletAccount {
            guard
                let zip32AccountIndex = account.zip32AccountIndex,
                let seedFingerprint = account.seedFingerprint,
                seedFingerprint.count == 32
            else {
                return .send(.delegationProofFailed(
                    roundId: roundId,
                    error: VotingFlowError.missingSigningAccount.localizedDescription
                ))
            }
            keystoneMetadata = (Data(seedFingerprint), UInt32(zip32AccountIndex.index))
        } else {
            keystoneMetadata = nil
        }

        let cachedNotes = session.walletNotes
        let network = zcashSDKEnvironment.network()
        let networkId: UInt32 = network.networkType.votingRustNetworkId
        let accountIndex: UInt32 = keystoneMetadata?.accountIndex ?? 0
        let keystoneSeedFingerprint = keystoneMetadata?.seedFingerprint
        let roundName = activeSession.title
        let keystoneBundleIndex = nextBundleIndex
        let bundleCount = session.bundleCount
        let noteChunks = cachedNotes.smartBundles().bundles

        guard bundleCount > 0,
              Int(keystoneBundleIndex) < Int(bundleCount),
              Int(keystoneBundleIndex) < noteChunks.count
        else {
            return .send(.delegationProofFailed(
                roundId: roundId,
                error: "Keystone signing state is inconsistent."
            ))
        }

        guard
            let accountId = state.selectedWalletAccount?.id
        else {
            LoggerProxy.error("selectedAccount unexpectedly nil during Keystone delegation; aborting")
            return .none
        }

        mutateSession(&state, roundId: roundId) {
            $0.currentKeystoneBundleIndex = keystoneBundleIndex
            $0.isDelegationProofInFlight = true
            $0.keystoneSigningStatus = .preparingRequest
        }

        return .run { [backgroundTask, sdkSynchronizer, votingCrypto, mnemonic, walletStorage] send in
            let bgTaskId = await backgroundTask.beginTask("Keystone PCZT prep")
            do {
                let hotkeyPhrase = try walletStorage.exportVotingHotkey(accountId).seedPhrase.value()
                let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
                let bundleNotes = noteChunks[Int(keystoneBundleIndex)]
                let orchardFvk = try votingCrypto.extractOrchardFvkFromUfvk(
                    bundleNotes[0].ufvkStr, networkId
                )
                LoggerProxy.info("Keystone: preparing PCZT for bundle \(keystoneBundleIndex + 1)/\(bundleCount)")
                let govPczt = try await votingCrypto.buildVotingPczt(
                    roundId,
                    keystoneBundleIndex,
                    bundleNotes,
                    emptySenderSeed,
                    hotkeySeed,
                    networkId,
                    accountIndex,
                    roundName,
                    orchardFvk,
                    keystoneSeedFingerprint
                )
                let redactedPczt = try await sdkSynchronizer.redactPCZTForSigner(govPczt.pcztBytes)
                await backgroundTask.endTask(bgTaskId)
                await send(.keystoneSigningPrepared(roundId: roundId, govPczt: govPczt, unsignedPczt: redactedPczt))
            } catch {
                await backgroundTask.endTask(bgTaskId)
                throw error
            }
        } catch: { error, send in
            await send(.keystoneSigningFailed(roundId: roundId, error: error.localizedDescription))
        }
        .cancellable(id: cancelDelegationProofId, cancelInFlight: true)
    }

    // MARK: - Keystone signing handlers

    func reduceKeystoneSigningPrepared(
        _ state: inout State,
        roundId: String,
        govPczt: VotingPcztResult,
        unsignedPczt: Pczt
    ) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.pendingVotingPczt = govPczt
            roundSession.pendingUnsignedDelegationPczt = unsignedPczt
            roundSession.isDelegationProofInFlight = false
            roundSession.keystoneSigningStatus = .awaitingSignature
        }
        return .none
    }

    func reduceKeystoneScanFound(_ state: inout State, signedPczt: Pczt) -> Effect<Action> {
        // The scan sheet is presented from the delegation signing screen,
        // which only exists for the currently in-flight Keystone round.
        // Resolve the round id from the topmost delegationSigning path entry.
        state.keystoneScan = nil
        guard let (roundId, govPczt) = currentKeystoneSigningTarget(state: state) else {
            return .none
        }
        mutateSession(&state, roundId: roundId) {
            $0.keystoneSigningStatus = .parsingSignature
        }
        let actionIndex = govPczt.actionIndex
        let session = state.roundCache[roundId]
        let existingSignatures = session?.keystoneBundleSignatures ?? []
        let currentBundleIndex = session?.currentKeystoneBundleIndex ?? 0
        let bundleCount = session?.bundleCount ?? 0
        return .run { [votingCrypto] send in
            let scannedSighash = try votingCrypto.extractPcztSighash(signedPczt)
            if let rejectionMessage = Self.keystoneScanRejectionMessage(
                scannedSighash: scannedSighash,
                expectedSighash: govPczt.pcztSighash,
                existingSignatures: existingSignatures,
                currentBundleIndex: currentBundleIndex,
                bundleCount: bundleCount
            ) {
                await send(.keystoneSignatureRejected(
                    roundId: roundId,
                    message: rejectionMessage
                ))
                return
            }

            let spendAuthSig = try votingCrypto.extractSpendAuthSignatureFromSignedPczt(
                signedPczt,
                actionIndex
            )
            await send(.spendAuthSignatureExtracted(roundId: roundId, sig: spendAuthSig, sighash: scannedSighash))
        } catch: { error, send in
            await send(.keystoneSigningFailed(roundId: roundId, error: error.localizedDescription))
        }
    }

    func reduceSpendAuthSignatureExtracted(
        _ state: inout State,
        roundId: String,
        sig: Data,
        sighash: Data
    ) -> Effect<Action> {
        guard let rk = state.roundCache[roundId]?.pendingVotingPczt?.rk else {
            return .send(.delegationProofFailed(
                roundId: roundId,
                error: VotingFlowError.missingPendingUnsignedPczt.localizedDescription
            ))
        }
        let currentIndex = state.roundCache[roundId]?.currentKeystoneBundleIndex ?? 0
        let bundleCount = state.roundCache[roundId]?.bundleCount ?? 0
        return .send(.keystoneBundleSignatureStored(
            roundId: roundId,
            signature: KeystoneBundleSignature(bundleIndex: currentIndex, sig: sig, sighash: sighash, rk: rk),
            bundleIndex: currentIndex,
            bundleCount: bundleCount
        ))
    }

    func reduceKeystoneBundleSignatureStored(
        _ state: inout State,
        roundId: String,
        signature: KeystoneBundleSignature,
        bundleIndex: UInt32,
        bundleCount: UInt32
    ) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.keystoneBundleSignatures.removeAll { $0.bundleIndex == bundleIndex }
            roundSession.keystoneBundleSignatures.append(signature)
            roundSession.keystoneBundleSignatures.sort { $0.bundleIndex < $1.bundleIndex }
            roundSession.pendingVotingPczt = nil
            roundSession.pendingUnsignedDelegationPczt = nil
        }

        let sigInfo = KeystoneBundleSignatureInfo(
            bundleIndex: bundleIndex,
            sig: signature.sig,
            sighash: signature.sighash,
            rk: signature.rk
        )
        let persistEffect: Effect<Action> = .run { [votingCrypto] _ in
            try await votingCrypto.storeKeystoneBundleSignature(roundId, sigInfo)
        }

        if let nextBundleIndex = state.roundCache[roundId]?.firstIncompleteKeystoneBundleIndex {
            // Advance to the next bundle and auto-start its PCZT build.
            mutateSession(&state, roundId: roundId) { roundSession in
                roundSession.currentKeystoneBundleIndex = nextBundleIndex
                roundSession.isDelegationProofInFlight = false
                roundSession.keystoneSigningStatus = .idle
            }
            return .merge(persistEffect, .send(.startDelegationProof(roundId: roundId)))
        } else {
            mutateSession(&state, roundId: roundId) { roundSession in
                roundSession.keystoneSigningStatus = .finalizingAuthorization
                roundSession.delegationProofStatus = .generating(progress: 0)
                roundSession.isDelegationProofInFlight = true
                roundSession.batchSubmissionStatus = .authorizing
                roundSession.voteSubmissionStep = .authorizingVote
            }
            // Pop the delegation signing screen so the user lands back on
            // Confirm Submission while the proof + delegation TX runs.
            if case .delegationSigning = state.path.last {
                _ = state.path.popLast()
            }
            return .merge(persistEffect, .send(.keystoneAllBundlesSigned(roundId: roundId)))
        }
    }

    // swiftlint:disable:next function_body_length
    func reduceKeystoneAllBundlesSigned(_ state: inout State, roundId: String) -> Effect<Action> {
        guard let session = state.roundCache[roundId] else { return .none }
        guard let activeSession = state.allRounds.first(where: { $0.id == roundId })?.session else {
            return .send(.delegationProofFailed(
                roundId: roundId,
                error: VotingFlowError.missingActiveSession.localizedDescription
            ))
        }

        let expectedSnapshotHeight = activeSession.snapshotHeight
        let cachedNotes = session.walletNotes
        let network = zcashSDKEnvironment.network()
        let networkId: UInt32 = network.networkType.votingRustNetworkId
        let accountIndex: UInt32 = state.selectedWalletAccount
            .flatMap(\.zip32AccountIndex)
            .map { UInt32($0.index) } ?? 0
        guard
            let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url),
            !pirEndpoints.isEmpty,
            let accountId = state.selectedWalletAccount?.id
        else {
            LoggerProxy.error("serviceConfig/selectedAccount unexpectedly nil during Keystone delegation proof")
            return .none
        }
        let bundleCount = session.bundleCount
        let storedSignatures = session.keystoneBundleSignatures.sorted { $0.bundleIndex < $1.bundleIndex }
        let initiallyCompletedBundles = session.completedKeystoneDelegationBundleIndices
        let noteChunks = cachedNotes.smartBundles().bundles
        guard bundleCount > 0,
              Int(bundleCount) <= noteChunks.count
        else {
            return .send(.delegationProofFailed(
                roundId: roundId,
                error: "Keystone signature state is inconsistent."
            ))
        }

        return .run { [backgroundTask, votingCrypto, votingAPI, mnemonic, walletStorage] send in
            let bgTaskId = await backgroundTask.beginTask("Keystone delegation proof")
            do {
                let senderPhrase = try walletStorage.exportWallet().seedPhrase.value()
                let senderSeed = try mnemonic.toSeed(senderPhrase)
                let hotkeyPhrase = try walletStorage.exportVotingHotkey(accountId).seedPhrase.value()
                let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
                let normalizedInitialCompletedBundles = initiallyCompletedBundles.filter { $0 < bundleCount }
                var completedBundles = normalizedInitialCompletedBundles
                for idx: UInt32 in 0..<bundleCount {
                    if let vanPosition = try await Self.recoverKeystoneDelegationVanPosition(
                        roundId: roundId,
                        bundleIndex: idx,
                        votingCrypto: votingCrypto,
                        votingAPI: votingAPI
                    ) {
                        LoggerProxy.debug("Recovered Keystone delegation bundle \(idx) VAN position: \(vanPosition)")
                        completedBundles.insert(idx)
                    }
                }
                if completedBundles != normalizedInitialCompletedBundles {
                    await send(.delegationBundlesRecovered(
                        roundId: roundId,
                        bundleIndices: completedBundles
                    ))
                }

                let resolvedBundleIndices = completedBundles
                    .union(storedSignatures.map(\.bundleIndex))
                    .filter { $0 < bundleCount }
                let missingBundleIndices = (0..<bundleCount).filter { !resolvedBundleIndices.contains($0) }
                guard missingBundleIndices.isEmpty else {
                    throw VotingFlowError.missingKeystoneBundleSignature
                }
                let totalWorkCount = max(resolvedBundleIndices.count, 1)

                for sig in storedSignatures {
                    let bundleIdx = sig.bundleIndex
                    guard bundleIdx < bundleCount else {
                        throw VotingFlowError.invalidDelegationSignature
                    }
                    if completedBundles.contains(bundleIdx) {
                        let overallProgress = Double(completedBundles.count) / Double(totalWorkCount)
                        await send(.delegationProofProgress(roundId: roundId, progress: overallProgress))
                        continue
                    }
                    let bundleNotes = noteChunks[Int(bundleIdx)]
                    let completedBeforeBundle = completedBundles.count
                    LoggerProxy.info("Keystone batch: proving bundle \(bundleIdx + 1)/\(bundleCount)")

                    for try await event in votingCrypto.buildAndProveDelegation(
                        roundId,
                        bundleIdx,
                        bundleNotes,
                        senderSeed,
                        hotkeySeed,
                        networkId,
                        accountIndex,
                        pirEndpoints,
                        expectedSnapshotHeight
                    ) {
                        switch event {
                        case .progress(let progress):
                            let overallProgress = (Double(completedBeforeBundle) + progress) / Double(totalWorkCount)
                            await send(.delegationProofProgress(roundId: roundId, progress: overallProgress))
                        case .completed(let proof):
                            LoggerProxy.info("ZKP #1 bundle \(bundleIdx) COMPLETE — proof size: \(proof.count) bytes")
                        }
                    }

                    let registration = try await votingCrypto.getDelegationSubmissionWithKeystoneSig(
                        roundId, bundleIdx, sig.sig, sig.sighash
                    )
                    if registration.rk != sig.rk ||
                        registration.spendAuthSig != sig.sig ||
                        registration.sighash != sig.sighash {
                        throw VotingFlowError.invalidDelegationSignature
                    }
                    let delegTxResult = try await votingAPI.submitDelegation(registration)
                    try await votingCrypto.storeDelegationTxHash(roundId, bundleIdx, delegTxResult.txHash)
                    let vanPosition = try await Self.requireKeystoneDelegationVanPosition(
                        txHash: delegTxResult.txHash,
                        votingAPI: votingAPI
                    )
                    try await votingCrypto.storeVanPosition(roundId, bundleIdx, vanPosition)
                    completedBundles.insert(bundleIdx)
                    await send(.delegationBundlesRecovered(
                        roundId: roundId,
                        bundleIndices: completedBundles
                    ))
                }
                await send(.delegationProofCompleted(roundId: roundId))
            } catch {
                await backgroundTask.endTask(bgTaskId)
                throw error
            }
            await backgroundTask.endTask(bgTaskId)
        } catch: { error, send in
            await send(.delegationProofFailed(
                roundId: roundId,
                error: VotingErrorMapper.userFriendlyMessage(from: error.localizedDescription)
            ))
        }
        .cancellable(id: cancelDelegationProofId, cancelInFlight: true)
    }

    func reduceSkipRemainingKeystoneBundles(_ state: inout State, roundId: String) -> Effect<Action> {
        guard let session = state.roundCache[roundId] else { return .none }
        let signedCount = session.resolvedKeystonePrefixCount
        guard signedCount > 0 else { return .none }

        let bundles = session.walletNotes.smartBundles().bundles
        let signedWeight = (0..<Int(signedCount)).reduce(UInt64(0)) { total, index in
            guard index < bundles.count else { return total }
            let raw = bundles[index].reduce(UInt64(0)) { $0 + $1.value }
            return total + quantizeWeight(raw)
        }

        mutateSession(&state, roundId: roundId) { roundSession in
            if roundSession.eligibleBundleCount == 0 {
                roundSession.eligibleBundleCount = session.bundleCount
            }
            if roundSession.eligibleVotingWeight == 0 {
                roundSession.eligibleVotingWeight = session.votingWeight
            }
            roundSession.bundleCount = signedCount
            roundSession.votingWeight = signedWeight
            roundSession.keystoneBundleSignatures.removeAll { $0.bundleIndex >= signedCount }
            roundSession.completedKeystoneDelegationBundleIndices =
                roundSession.completedKeystoneDelegationBundleIndices.filter { $0 < signedCount }
            roundSession.pendingVotingPczt = nil
            roundSession.pendingUnsignedDelegationPczt = nil
            roundSession.keystoneSigningStatus = .finalizingAuthorization
            roundSession.delegationProofStatus = .generating(progress: 0)
            roundSession.isDelegationProofInFlight = true
            roundSession.batchSubmissionStatus = .authorizing
            roundSession.voteSubmissionStep = .authorizingVote
        }
        if case .delegationSigning = state.path.last {
            _ = state.path.popLast()
        }

        return .run { [votingCrypto] send in
            try await votingCrypto.deleteSkippedBundles(roundId, signedCount)
            await send(.keystoneAllBundlesSigned(roundId: roundId))
        } catch: { error, send in
            await send(.delegationProofFailed(
                roundId: roundId,
                error: VotingErrorMapper.userFriendlyMessage(from: error.localizedDescription)
            ))
        }
    }

    // MARK: - Keystone helpers

    private func currentKeystoneSigningTarget(state: State) -> (roundId: String, govPczt: VotingPcztResult)? {
        // The signing screen is always pushed for one round at a time. We
        // look up the topmost delegationSigning path entry and read the
        // round's cached pending PCZT.
        guard case let .delegationSigning(signingState) = state.path.last else {
            return nil
        }
        guard let govPczt = state.roundCache[signingState.roundId]?.pendingVotingPczt else {
            return nil
        }
        return (signingState.roundId, govPczt)
    }

    private static func validKeystoneSignatures(
        _ signatures: [KeystoneBundleSignatureInfo],
        bundleCount: UInt32
    ) -> [KeystoneBundleSignatureInfo]? {
        guard bundleCount > 0 else { return [] }
        let sorted = signatures.sorted { $0.bundleIndex < $1.bundleIndex }
        guard sorted.count <= Int(bundleCount) else { return nil }
        var seen = Set<UInt32>()
        for signature in sorted {
            guard signature.bundleIndex < bundleCount, seen.insert(signature.bundleIndex).inserted else {
                return nil
            }
            guard signature.sig.count == 64, signature.sighash.count == 32, signature.rk.count == 32 else {
                return nil
            }
        }
        return sorted
    }

    private static func allKeystoneBundlesResolved(_ session: RoundSession) -> Bool {
        session.bundleCount > 0 && session.firstIncompleteKeystoneBundleIndex == nil
    }

    static func keystoneScanRejectionMessage(
        scannedSighash: Data,
        expectedSighash: Data,
        existingSignatures: [KeystoneBundleSignature],
        currentBundleIndex: UInt32,
        bundleCount: UInt32
    ) -> String? {
        let totalBundleCount = String(max(Int(bundleCount), 1))
        if let duplicate = existingSignatures.first(where: { $0.sighash == scannedSighash }) {
            return String(
                localizable: .coinVoteDelegationSigningDuplicateSignature(
                    String(duplicate.bundleIndex + 1),
                    totalBundleCount
                )
            )
        }

        guard scannedSighash == expectedSighash else {
            return String(
                localizable: .coinVoteDelegationSigningWrongSignature(
                    String(Int(currentBundleIndex) + 1),
                    totalBundleCount
                )
            )
        }

        return nil
    }

    /// Crash-recovery lookup for a Keystone delegation TX hash.
    static func recoverKeystoneDelegationVanPosition(
        roundId: String,
        bundleIndex: UInt32,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient
    ) async throws -> UInt32? {
        guard case let .present(txHash) = try? await votingCrypto.getDelegationTxHash(roundId, bundleIndex) else {
            return nil
        }
        if let confirmation = try? await votingAPI.fetchTxConfirmation(txHash),
           confirmation.code == 0,
           let leafValue = confirmation.event(ofType: "delegate_vote")?.attribute(forKey: "leaf_index"),
           let vanPosition = UInt32(leafValue) {
            try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanPosition)
            return vanPosition
        }
        return nil
    }

    static func requireKeystoneDelegationVanPosition(
        txHash: String,
        votingAPI: VotingAPIClient
    ) async throws -> UInt32 {
        let deadline = Date().addingTimeInterval(90)
        repeat {
            if let confirmation = try? await votingAPI.fetchTxConfirmation(txHash) {
                guard confirmation.code == 0 else {
                    throw VotingFlowError.delegationTxFailed(code: confirmation.code, log: confirmation.log)
                }
                guard
                    let leafValue = confirmation.event(ofType: "delegate_vote")?.attribute(forKey: "leaf_index"),
                    let vanPosition = UInt32(leafValue)
                else {
                    throw VotingFlowError.delegationTxFailed(code: 0, log: "missing delegate_vote leaf_index")
                }
                return vanPosition
            }
            guard Date() < deadline else {
                throw VotingFlowError.delegationTxFailed(code: 0, log: "")
            }
            try await Task.sleep(for: .seconds(2))
        } while true
    }

    func reduceDelegationProofProgress(
        _ state: inout State,
        roundId: String,
        progress: Double
    ) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.delegationProofStatus = .generating(progress: progress)
        }
        return .none
    }

    func reduceDelegationProofCompleted(_ state: inout State, roundId: String) -> Effect<Action> {
        let isKeystoneUser = state.isKeystoneUser
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.delegationProofStatus = .complete
            roundSession.isDelegationProofInFlight = false
            if isKeystoneUser {
                resetKeystoneSigningLoop(&roundSession, clearRecoveredBundles: true)
            }
        }
        // If the user tapped Submit while delegation was still in flight,
        // resume the batch now that authorization is done.
        if state.pendingBatchSubmission {
            state.pendingBatchSubmission = false
            return .send(.authenticationSucceeded(roundId: roundId))
        }
        return .none
    }

    func reduceDelegationProofFailed(
        _ state: inout State,
        roundId: String,
        error: String
    ) -> Effect<Action> {
        let isKeystoneUser = state.isKeystoneUser
        let keystoneSigningFailureStatus: KeystoneSigningStatus = isCurrentKeystoneSigningRound(
            state: state,
            roundId: roundId
        ) ? .failed(error) : .idle
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.delegationProofStatus = .failed(error)
            roundSession.isDelegationProofInFlight = false
            if isKeystoneUser {
                resetKeystoneSigningLoop(&roundSession, status: keystoneSigningFailureStatus)
            }
            if case .authorizing = roundSession.batchSubmissionStatus {
                roundSession.isSubmittingVote = false
                roundSession.submittingProposalId = nil
                roundSession.voteSubmissionStep = nil
                roundSession.currentVoteBundleIndex = nil
                roundSession.batchSubmissionStatus = .authorizationFailed(error: error)
            }
        }
        if isKeystoneUser {
            state.pendingBatchSubmission = false
        }
        return .none
    }

    // MARK: - Helpers (state-shape adapters)

    private func hydratePersistedRoundChoices(_ state: inout State, roundId: String) {
        var submittedVotes = state.roundCache[roundId]?.votes ?? [:]
        submittedVotes.merge(Voting.loadSubmittedVotes(roundId: roundId)) { current, _ in current }
        let drafts = Voting.loadDrafts(roundId: roundId).filter {
            submittedVotes[$0.key] == nil
        }
        let account = state.selectedWalletAccount?.account
        let voteRecord = state.voteRecords[roundId]

        if state.roundCache[roundId] == nil {
            state.roundCache[roundId] = RoundSession(roundId: roundId)
        }
        state.roundCache[roundId]?.draftVotes = drafts
        state.roundCache[roundId]?.votes = submittedVotes
        state.roundCache[roundId]?.voteRecord = voteRecord

        do {
            try Voting.persistDrafts(drafts, roundId: roundId, account: account)
        } catch {
            LoggerProxy.error("Failed to persist hydrated voting drafts: \(error)")
            state.submissionAlert = .votingMetadataPersistenceFailed(error)
        }
    }

    private func loadSubmittedVotesFromDb(roundId: String) -> Effect<Action> {
        .run { [votingCrypto] send in
            let records = try await votingCrypto.getVotes(roundId)
            let bundleCount = (try? await votingCrypto.getBundleCount(roundId)) ?? 0
            let votes = submittedVotesByProposal(records, bundleCount: bundleCount)
            await send(.submittedVotesLoaded(roundId: roundId, votes: votes))
        } catch: { error, _ in
            LoggerProxy.warn("Failed to load submitted voting choices: \(error)")
        }
    }

    private func canStartSubmission(_ session: RoundSession) -> Bool {
        guard !session.draftVotes.isEmpty else { return false }
        guard session.bundleCount > 0 else { return false }
        switch session.batchSubmissionStatus {
        case .idle, .authorizationFailed, .submissionFailed:
            return true
        case .authorizing, .submitting, .completed:
            return false
        }
    }

    private func isBatchSubmitting(_ session: RoundSession) -> Bool {
        switch session.batchSubmissionStatus {
        case .authorizing, .submitting:
            return true
        default:
            return false
        }
    }

    private func isDelegationReady(_ session: RoundSession) -> Bool {
        session.delegationProofStatus == .complete
    }

    private func resetKeystoneSigningLoop(
        _ session: inout RoundSession,
        status: KeystoneSigningStatus = .idle,
        clearRecoveredBundles: Bool = false
    ) {
        session.keystoneBundleSignatures = []
        if clearRecoveredBundles {
            session.completedKeystoneDelegationBundleIndices = []
        } else {
            session.completedKeystoneDelegationBundleIndices = session.completedKeystoneDelegationBundleIndices
                .filter { $0 < session.bundleCount }
        }
        session.currentKeystoneBundleIndex = session.firstIncompleteKeystoneBundleIndex ?? 0
        session.pendingVotingPczt = nil
        session.pendingUnsignedDelegationPczt = nil
        session.keystoneSigningStatus = status
    }

    private func isCurrentKeystoneSigningRound(state: State, roundId: String) -> Bool {
        guard case let .delegationSigning(signingState) = state.path.last else {
            return false
        }
        return signingState.roundId == roundId
    }

    private func hasKeystoneSigningRound(state: State, roundId: String? = nil) -> Bool {
        state.path.contains {
            guard case let .delegationSigning(signingState) = $0 else {
                return false
            }
            guard let roundId else {
                return true
            }
            return signingState.roundId == roundId
        }
    }

    private static func eligibleTotals(for notes: [NoteInfo]) -> (weight: UInt64, bundleCount: UInt32) {
        let bundleResult = notes.smartBundles()
        return (bundleResult.eligibleWeight, UInt32(bundleResult.bundles.count))
    }

    private static func votingWeight(for notes: [NoteInfo], bundleCount: UInt32) -> UInt64 {
        let allBundles = notes.smartBundles().bundles
        guard bundleCount > 0, Int(bundleCount) < allBundles.count else {
            return notes.smartBundles().eligibleWeight
        }

        return (0..<Int(bundleCount)).reduce(UInt64(0)) { total, index in
            let raw = allBundles[index].reduce(UInt64(0)) { $0 + $1.value }
            return total + quantizeWeight(raw)
        }
    }

    private static func prepareFreshRound(
        roundId: String,
        session: VotingSession,
        snapshotHeight: UInt64,
        walletDbPath: String,
        notes: [NoteInfo],
        votingCrypto: VotingCryptoClient,
        sdkSynchronizer: SDKSynchronizerClient,
        send: Send<Action>
    ) async throws -> Bool {
        try? await votingCrypto.clearRound(roundId)
        try await votingCrypto.clearRecoveryState(roundId)

        let params = VotingRoundParams(
            voteRoundId: session.voteRoundId,
            snapshotHeight: snapshotHeight,
            eaPK: session.eaPK,
            ncRoot: session.ncRoot,
            nullifierIMTRoot: session.nullifierIMTRoot
        )
        try await votingCrypto.initRound(params, nil)

        let setupResult = try await votingCrypto.setupBundles(roundId, notes)
        let bundleCount = setupResult.bundleCount
        let eligibleWeight = setupResult.eligibleWeight
        guard bundleCount > 0, eligibleWeight > 0 else {
            let heldZatoshi = notes.reduce(UInt64(0)) { $0 + $1.value }
            await send(.ineligibleForRound(roundId: roundId, heldZatoshi: heldZatoshi))
            return false
        }

        // Early-eligibility signal: setupBundles passed, the wallet qualifies.
        // Hand navigation off to the proposal list now so the user isn't
        // staring at a frozen polls list while the witness / tree-state work
        // (the slow part of the pipeline) completes.
        await send(.earlyEligibilityConfirmed(roundId: roundId))

        let treeStateBytes = try await sdkSynchronizer.getTreeState(snapshotHeight)
        try await votingCrypto.storeTreeState(roundId, treeStateBytes)

        let noteChunks = notes.smartBundles().bundles
        guard Int(bundleCount) <= noteChunks.count else {
            throw VotingFlowError.inconsistentBundleSetup(
                bundleCount: bundleCount,
                noteChunkCount: noteChunks.count
            )
        }

        var allWitnesses: [WitnessData] = []
        for bundleIndex: UInt32 in 0..<bundleCount {
            let witnesses = try await votingCrypto.generateNoteWitnesses(
                roundId,
                bundleIndex,
                walletDbPath,
                noteChunks[Int(bundleIndex)]
            )
            allWitnesses.append(contentsOf: witnesses)
        }

        await send(.votingWeightLoaded(
            roundId: roundId,
            weight: eligibleWeight,
            notes: notes,
            witnesses: allWitnesses,
            bundleCount: bundleCount,
            delegationReady: false
        ))
        return true
    }

    /// Look up the live `VotingSession` for a round id by scoping into
    /// `state.allRounds`. The legacy flat state cached this as
    /// `activeSession`; in the coordinator we keep a single source of
    /// truth (the rounds list) and look it up at use sites.
    private func activeSession(in state: State, roundId: String) -> VotingSession? {
        state.allRounds.first { $0.id == roundId }?.session
    }

    /// Mirror of `PollsListView.visiblePolls` so the coordinator can route
    /// to `.noRounds` when the user-visible list is empty — not just when
    /// the raw `allRounds` array is. On the default config we surface only
    /// Zodl-endorsed rounds; a chain returning rounds with zero
    /// endorsements would otherwise leave the polls list stuck on the
    /// loading skeleton forever.
    private func visibleRoundCount(state: State) -> Int {
        guard state.isOnDefaultConfig else { return state.allRounds.count }
        return state.allRounds.filter { state.zodlEndorsedRoundIds.contains($0.id) }.count
    }

    private func completedEligibleVotingWeight(_ session: RoundSession) -> UInt64 {
        session.eligibleVotingWeight > 0
            ? session.eligibleVotingWeight
            : session.votingWeight
    }

    private func completedEligibleBundleCount(_ session: RoundSession) -> UInt32 {
        session.eligibleBundleCount > 0
            ? session.eligibleBundleCount
            : session.bundleCount
    }

    private func votingMetadataPersistenceMessage(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty
            ? String(localizable: .coinVoteSubmissionGenericBatchFailure)
            : message
    }

    private func signedBundlesZECString(_ session: RoundSession) -> String {
        let bundles = session.walletNotes.smartBundles().bundles
        let signedWeight = (0..<Int(session.resolvedKeystonePrefixCount)).reduce(UInt64(0)) { total, index in
            guard index < bundles.count else { return total }
            let raw = bundles[index].reduce(UInt64(0)) { $0 + $1.value }
            return total + quantizeWeight(raw)
        }
        return String(format: "%.3f", Double(signedWeight) / 100_000_000.0)
    }

    private func skippedBundlesZECString(_ session: RoundSession) -> String {
        let bundles = session.walletNotes.smartBundles().bundles
        let countedBundleCount = min(Int(session.bundleCount), bundles.count)
        let signedPrefixCount = Int(session.resolvedKeystonePrefixCount)

        let skippedWeight = (0..<countedBundleCount).reduce(UInt64(0)) { total, index in
            guard index >= signedPrefixCount else { return total }
            let raw = bundles[index].reduce(UInt64(0)) { $0 + $1.value }
            return total + quantizeWeight(raw)
        }
        return String(format: "%.3f", Double(skippedWeight) / 100_000_000.0)
    }

    /// Mutate the round's cached session in place. No-op if the round
    /// hasn't been entered yet (cache miss).
    func mutateSession(
        _ state: inout State,
        roundId: String,
        _ body: (inout RoundSession) -> Void
    ) {
        guard var session = state.roundCache[roundId] else { return }
        body(&session)
        state.roundCache[roundId] = session
    }

    // MARK: - Crash recovery for in-flight votes

    /// If we have a cached vote TX hash for `(roundId, bundleIndex, proposalId)`
    /// that confirmed on-chain, finish the share delegation step without
    /// rebuilding the commitment. Returns true if the bundle was resumed
    /// from cache.
    // swiftlint:disable:next function_body_length cyclomatic_complexity function_parameter_count
    static func tryRecoverInflightVote(
        roundId: String,
        bundleIndex: UInt32,
        proposalId: UInt32,
        choice: VoteChoice,
        numOptions: UInt32,
        singleShare: Bool,
        submitAtDeadline: Double?,
        shareServerURLs: inout [String],
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        send: Send<Action>,
        roundIdAction: () -> String
    ) async throws -> Bool {
        guard case let .present(cachedTxHash)? = try? await votingCrypto.getVoteTxHash(roundId, bundleIndex, proposalId) else {
            return false
        }
        guard let confirmation = try? await votingAPI.fetchTxConfirmation(cachedTxHash),
              confirmation.code == 0,
              let leafPair = confirmation.event(ofType: "cast_vote")?.attribute(forKey: "leaf_index") else {
            return false
        }
        let leafParts = leafPair.split(separator: ",")
        guard leafParts.count == 2,
              let vanIdx = UInt32(leafParts[0]),
              let vcIdx = UInt64(leafParts[1]) else {
            return false
        }

        try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanIdx)

        guard let savedBundle = try? await votingCrypto.getVoteCommitmentBundle(roundId, bundleIndex, proposalId) else {
            LoggerProxy.error(
                """
                Recovered on-chain vote \(proposalId) for bundle \(bundleIndex), \
                but the saved commitment bundle is missing; cannot delegate tally shares.
                """
            )
            throw VotingFlowError.missingVoteCommitmentBundle
        }

        try await votingCrypto.storeVoteCommitmentBundle(roundId, bundleIndex, proposalId, savedBundle, vcIdx)
        await send(.voteSubmissionStepUpdated(roundId: roundIdAction(), step: .sendingShares))

        var payloads = try await votingCrypto.buildSharePayloads(
            savedBundle.encShares, savedBundle, choice, numOptions, vcIdx, singleShare
        )
        let now = Date().timeIntervalSince1970
        for i in payloads.indices {
            if let deadline = submitAtDeadline, deadline > now {
                payloads[i].submitAt = UInt64(now + Double.random(in: 0..<(deadline - now)))
            } else {
                payloads[i].submitAt = 0
            }
        }

        let recoveryResult = try await Voting.delegateSharesWithFallback(
            payloads,
            roundId: roundId,
            votingAPI: votingAPI,
            serverURLs: shareServerURLs
        )
        shareServerURLs = recoveryResult.remainingServerURLs
        for info in recoveryResult.delegatedShares {
            guard let payload = payloads.first(where: {
                $0.encShare.shareIndex == info.shareIndex && $0.proposalId == info.proposalId
            }) else { continue }
            let blindIdx = Int(info.shareIndex)
            guard blindIdx < savedBundle.shareBlindFactors.count else { continue }
            do {
                let nfHex = try votingCrypto.computeShareNullifier(
                    [UInt8](savedBundle.voteCommitment),
                    info.shareIndex,
                    [UInt8](savedBundle.shareBlindFactors[blindIdx])
                )
                try await votingCrypto.recordShareDelegation(
                    roundId, bundleIndex, info.proposalId,
                    info.shareIndex, info.acceptedByServers,
                    [UInt8](votingDataFromHex(nfHex)), payload.submitAt
                )
            } catch {
                LoggerProxy.warn("Batch recovery: failed to record share delegation for share \(info.shareIndex): \(error)")
            }
        }
        try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId)
        return true
    }

    // MARK: - Delegation pipeline (Zashi inline)

    /// Mirrors `Voting.runDelegationPipeline` but sends back to
    /// `VotingCoordFlow.Action`. The legacy version targets `Voting.Action`,
    /// so cross-type dispatching is the only reason we duplicate this here.
    // swiftlint:disable:next function_body_length function_parameter_count
    static func runDelegationPipeline(
        roundId: String,
        cachedNotes: [NoteInfo],
        senderSeed: [UInt8],
        hotkeySeed: [UInt8],
        networkId: UInt32,
        accountIndex: UInt32,
        roundName: String,
        pirEndpoints: [String],
        expectedSnapshotHeight: UInt64,
        delegationPrepared: Bool = false,
        seedFingerprint: Data? = nil,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        send: Send<Action>,
        delegationConfirmationTimeout: TimeInterval = 90,
        delegationConfirmationRetryDelay: Duration = .seconds(2)
    ) async throws {
        let noteChunks = cachedNotes.smartBundles().bundles
        let bundleCount = UInt32(noteChunks.count)
        var completedBundles = Set<UInt32>()
        for idx: UInt32 in 0..<bundleCount {
            if let vanPosition = try await recoverDelegationVanPosition(
                roundId: roundId,
                bundleIndex: idx,
                votingCrypto: votingCrypto,
                votingAPI: votingAPI,
                confirmationTimeout: delegationConfirmationTimeout,
                retryDelay: delegationConfirmationRetryDelay
            ) {
                LoggerProxy.debug("Recovered delegation bundle \(idx) VAN position: \(vanPosition)")
                completedBundles.insert(idx)
            }
        }

        for bundleIndex: UInt32 in 0..<bundleCount {
            if completedBundles.contains(bundleIndex) {
                LoggerProxy.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) already submitted, skipping")
                continue
            }
            let bundleNotes = noteChunks[Int(bundleIndex)]
            LoggerProxy.info("Delegation bundle \(bundleIndex + 1)/\(bundleCount) (\(bundleNotes.count) notes)")

            let registration: DelegationRegistration
            if let cachedRegistration = try? await votingCrypto.getDelegationSubmission(
                roundId, bundleIndex, senderSeed, networkId, accountIndex
            ) {
                LoggerProxy.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) using cached submission")
                registration = cachedRegistration
            } else {
                if delegationPrepared {
                    LoggerProxy.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) using precomputed PIR data")
                } else {
                    let orchardFvk = try seedFingerprint.map { _ in
                        try votingCrypto.extractOrchardFvkFromUfvk(bundleNotes[0].ufvkStr, networkId)
                    }
                    _ = try await votingCrypto.buildVotingPczt(
                        roundId, bundleIndex, bundleNotes,
                        senderSeed, hotkeySeed, networkId, accountIndex, roundName,
                        orchardFvk, seedFingerprint
                    )
                }

                for try await event in votingCrypto.buildAndProveDelegation(
                    roundId, bundleIndex, bundleNotes,
                    senderSeed, hotkeySeed, networkId, accountIndex,
                    pirEndpoints, expectedSnapshotHeight
                ) {
                    switch event {
                    case .progress(let progress):
                        let overallProgress = (Double(bundleIndex) + progress) / Double(bundleCount)
                        LoggerProxy.debug("ZKP #1 bundle \(bundleIndex) progress: \(Int(progress * 100))%")
                        await send(.delegationProofProgress(roundId: roundId, progress: overallProgress))
                    case .completed(let proof):
                        LoggerProxy.info("ZKP #1 bundle \(bundleIndex) COMPLETE — proof size: \(proof.count) bytes")
                    }
                }

                registration = try await votingCrypto.getDelegationSubmission(
                    roundId, bundleIndex, senderSeed, networkId, accountIndex
                )
            }
            let delegTxResult = try await votingAPI.submitDelegation(registration)
            LoggerProxy.info("Delegation TX \(bundleIndex) submitted: \(delegTxResult.txHash)")

            try await votingCrypto.storeDelegationTxHash(roundId, bundleIndex, delegTxResult.txHash)

            let vanPosition = try await requireDelegationVanPosition(
                txHash: delegTxResult.txHash,
                votingAPI: votingAPI,
                confirmationTimeout: delegationConfirmationTimeout,
                retryDelay: delegationConfirmationRetryDelay
            )
            try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanPosition)
            LoggerProxy.debug("VAN position stored for bundle \(bundleIndex): \(vanPosition)")
        }

        await send(.delegationProofCompleted(roundId: roundId))
    }

    private static func recoverDelegationVanPosition(
        roundId: String,
        bundleIndex: UInt32,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        confirmationTimeout: TimeInterval = 90,
        retryDelay: Duration = .seconds(2)
    ) async throws -> UInt32? {
        guard case let .present(txHash) = try? await votingCrypto.getDelegationTxHash(roundId, bundleIndex) else {
            return nil
        }

        switch try await delegationTxConfirmationStatus(
            txHash: txHash,
            votingAPI: votingAPI,
            confirmationTimeout: confirmationTimeout,
            retryDelay: retryDelay
        ) {
        case let .confirmed(vanPosition):
            try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanPosition)
            return vanPosition

        case let .failed(code, log):
            LoggerProxy.warn(
                "Cached delegation TX \(txHash) for bundle \(bundleIndex) is not reusable: code=\(code) log=\(log)"
            )
            return nil

        case .notFound:
            LoggerProxy.debug("Cached delegation TX \(txHash) for bundle \(bundleIndex) is not confirmed yet")
            return nil
        }
    }

    private static func requireDelegationVanPosition(
        txHash: String,
        votingAPI: VotingAPIClient,
        confirmationTimeout: TimeInterval = 90,
        retryDelay: Duration = .seconds(2)
    ) async throws -> UInt32 {
        switch try await delegationTxConfirmationStatus(
            txHash: txHash,
            votingAPI: votingAPI,
            confirmationTimeout: confirmationTimeout,
            retryDelay: retryDelay
        ) {
        case let .confirmed(vanPosition):
            return vanPosition

        case let .failed(code, log):
            throw VotingFlowError.delegationTxFailed(code: code, log: log)

        case .notFound:
            throw VotingFlowError.delegationTxFailed(code: 0, log: "")
        }
    }

    private static func delegationTxConfirmationStatus(
        txHash: String,
        votingAPI: VotingAPIClient,
        confirmationTimeout: TimeInterval = 90,
        retryDelay: Duration = .seconds(2)
    ) async throws -> DelegationTxConfirmationStatus {
        let deadline = Date().addingTimeInterval(confirmationTimeout)

        repeat {
            if let confirmation = try? await votingAPI.fetchTxConfirmation(txHash) {
                guard confirmation.code == 0 else {
                    return .failed(code: confirmation.code, log: confirmation.log)
                }
                guard
                    let leafValue = confirmation.event(ofType: "delegate_vote")?.attribute(forKey: "leaf_index"),
                    let vanPosition = UInt32(leafValue)
                else {
                    return .failed(code: 0, log: "missing delegate_vote leaf_index")
                }
                return .confirmed(vanPosition: vanPosition)
            }

            guard Date() < deadline else {
                return .notFound
            }

            try await Task.sleep(for: retryDelay)
        } while true
    }
}

// MARK: - Share delegation recovery

struct ShareDelegationKey: Equatable, Sendable {
    let bundleIndex: UInt32
    let proposalId: UInt32
    let shareIndex: UInt32
}

struct ShareRecoveryPollResult: Equatable, Sendable {
    let confirmedShares: [ShareDelegationKey]
    let resubmissionShares: [VotingShareDelegation]
    let queriedCount: Int
}

// MARK: - Alerts

extension AlertState where Action == Never {
    static func votingMetadataPersistenceFailed(_ error: Error) -> AlertState {
        AlertState {
            TextState(String(localizable: .coinVoteErrorTitle))
        } message: {
            TextState(error.localizedDescription)
        }
    }

}

extension AlertState where Action == VotingCoordFlow.Action {
    static func confirmSkip(roundId: String, lockedIn: String, givingUp: String) -> AlertState {
        AlertState {
            TextState(String(localizable: .coinVoteDelegationSigningSkipAlertTitle))
        } actions: {
            ButtonState(role: .destructive, action: .skipRemainingKeystoneBundlesConfirmed(roundId: roundId)) {
                TextState(String(localizable: .coinVoteDelegationSigningSkipAlertPrimary))
            }
            ButtonState(role: .cancel, action: .skipBundlesAlert(.dismiss)) {
                TextState(String(localizable: .coinVoteDelegationSigningSkipAlertCancel))
            }
        } message: {
            TextState(String(localizable: .coinVoteDelegationSigningSkipAlertMessage(lockedIn, givingUp)))
        }
    }

}

// MARK: - Array helper

private extension Array where Element == String {
    /// `[]` -> `nil`, otherwise self. Reads cleanly inside guard chains.
    var nonEmpty: [String]? {
        isEmpty ? nil : self
    }
}

// MARK: - Delegation TX confirmation status

/// Result of polling for a delegation TX's confirmation. The legacy file
/// has a private copy; we redeclare it here because cross-file access
/// would require widening the legacy declaration. Stage 5D removes one of
/// them when the legacy reducer is deleted.
private enum DelegationTxConfirmationStatus: Sendable {
    case confirmed(vanPosition: UInt32)
    case failed(code: UInt32, log: String)
    case notFound
}
