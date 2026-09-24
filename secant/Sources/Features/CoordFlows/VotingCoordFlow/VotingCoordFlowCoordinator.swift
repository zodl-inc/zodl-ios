#if VOTING_ENABLED
//
//  VotingCoordFlowCoordinator.swift
//  Zashi
//

import Foundation
import ComposableArchitecture
import VotingRecovery
@preconcurrency import ZODLSwiftWalletSDK

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
                cancelSubmissionAttempts(state)
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
                    if error is CancellationError
                        || (error as? URLError)?.code == URLError.Code.cancelled {
                        return
                    }
                    LoggerProxy.error("Service config unavailable: \(error)")
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    if case VotingConfigError.staticConfigFetchFailed = error {
                        await send(.roundsLoadFailed)
                    } else if let configError = error as? VotingConfigError,
                              VotingConfigMirrorWalk.shouldTryNextDynamicMirror(configError) {
                        await send(.roundsLoadFailed)
                    } else {
                        await send(.configUnsupported(message))
                    }
                }

            case .serviceConfigLoaded(let config):
                state.serviceConfig = config
                let walletId = state.walletId
                let network = zcashSDKEnvironment.network()
                let networkId: UInt32 = network.networkType.votingRustNetworkId
                return .run { [votingAPI, votingCrypto, networkId] send in
                    // 1. Configure API client URLs from the loaded config.
                    await votingAPI.configureURLs(config)

                    // 2. Open the voting DB and scope it to this wallet.
                    let dbPath = FileManager.default
                        .urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("voting.sqlite3").path
                    try await votingCrypto.openDatabase(dbPath, networkId)
                    try await votingCrypto.setWalletId(walletId)

                    // 3. Fetch rounds. Network failures surface as a
                    //    recoverable sheet on the polls list rather than the
                    //    blocking error screen.
                    do {
                        let rounds = try await votingAPI.fetchAllRounds()
                        await send(.allRoundsLoaded(rounds))
                    } catch is CancellationError {
                        return
                    } catch let error as URLError where error.code == .cancelled {
                        return
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
                    } catch is CancellationError {
                        return
                    } catch let error as URLError where error.code == .cancelled {
                        return
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
                // A failed default-source endorsement request is part of poll
                // discovery, so surface the same recoverable sheet as a round
                // list failure while the initial loading screen is visible.
                if state.rootScreen == .loading {
                    state.pollsLoadError = true
                    state.rootScreen = .pollsList
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
                cancelSubmissionAttempts(state)
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

                    // MOB-1810: operator health checks start here — in the
                    // background, at poll entry — instead of blocking the polls
                    // list load. Their results are advisory ordering input for
                    // the share-resubmission walk; nothing awaits them.
                    let startHealthSweep: Effect<Action> = .run { [votingAPI] _ in
                        await votingAPI.startHealthProbeSweep()
                    }

                    if state.voteRecords[roundId] != nil {
                        // Already submitted — review-mode read-only, no
                        // pipeline needed.
                        state.path.append(.reviewVotes(ReviewVotes.State(roundId: roundId)))
                        return .merge(
                            startHealthSweep,
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
                            startHealthSweep,
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
                        startHealthSweep,
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
                // MOB-1810: this entry point lands on the same active-round
                // review screen as `.roundTapped`'s voted branch, so it needs
                // the same background health sweep at poll entry — advisory
                // ordering input for the share-resubmission walk; nothing
                // awaits it.
                let startHealthSweep: Effect<Action>
                if state.allRounds.first(where: { $0.id == roundId })?.session.status == .active {
                    startHealthSweep = .run { [votingAPI] _ in
                        await votingAPI.startHealthProbeSweep()
                    }
                } else {
                    startHealthSweep = .none
                }
                return .merge(
                    cancelShareTracking,
                    statusPolling,
                    startHealthSweep,
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

            case let .batchAuthenticationDeclined(roundId):
                // Only unwind the pre-auth CTA state; a stray decline landing
                // after work has started must not disturb the pipeline.
                mutateSession(&state, roundId: roundId) { roundSession in
                    if case .requested = roundSession.batchSubmissionStatus {
                        roundSession.batchSubmissionStatus = .idle
                    }
                }
                return .none

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

            case let .delegationPrecomputeProgress(roundId, progress):
                return reduceDelegationPrecomputeProgress(&state, roundId: roundId, progress: progress)

            case let .delegationPrecomputeCompleted(roundId):
                mutateSession(&state, roundId: roundId) { roundSession in
                    roundSession.delegationPrecomputeStatus = .ready
                    roundSession.isDelegationPrecomputeInFlight = false
                    roundSession.delegationPrecomputeProgress = nil
                }
                // The run is over: disarm the shared promotion before anything resumes.
                let disarm: Effect<Action> = .run { [votingCrypto] _ in
                    votingCrypto.resetDelegationProvingPromotion()
                }
                if state.pendingBatchSubmission && !state.isKeystoneUser {
                    // Resume the pending submission. The ticket is consumed by
                    // `.authenticationSucceeded` itself; resetting the status
                    // here would flash `.idle` for one action-cycle.
                    return .concatenate(disarm, .send(.authenticationSucceeded(roundId: roundId)))
                }
                return disarm

            case let .delegationPrecomputeFailed(roundId, error):
                let message = VotingErrorMapper.userFriendlyMessage(from: error)
                mutateSession(&state, roundId: roundId) { roundSession in
                    roundSession.delegationPrecomputeStatus = .failed(message)
                    roundSession.isDelegationPrecomputeInFlight = false
                    roundSession.delegationPrecomputeProgress = nil
                }
                let disarm: Effect<Action> = .run { [votingCrypto] _ in
                    votingCrypto.resetDelegationProvingPromotion()
                }
                if state.pendingBatchSubmission && !state.isKeystoneUser {
                    // Same resume/no-reset rule as `.delegationPrecomputeCompleted`;
                    // the batch effect re-runs delegation inline from cold.
                    return .concatenate(disarm, .send(.authenticationSucceeded(roundId: roundId)))
                }
                return disarm

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

            case let .submissionAttemptSettled(roundId, attemptId, successCount):
                guard let session = state.roundCache[roundId],
                      let attempt = session.submissionAttempt, attempt.id == attemptId
                else { return .none }
                switch session.batchSubmissionStatus {
                case .completed:
                    attempt.finish(.completed)
                case .submissionFailed:
                    attempt.finish(successCount > 0 ? .partial : .failed)
                default:
                    attempt.finish(.failed)
                }
                return .none

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
                    var (existingState, existingBundleCount) = try await Self.loadExistingRoundSetup(
                        roundId: roundId,
                        votingCrypto: votingCrypto
                    )
                    // VotingRecovery: a delegation carved out of a wiped
                    // database goes back in here, before any branch below can
                    // rebuild the round over it. The SDK clears nothing unless
                    // the round provably holds nothing the wallet could use.
                    if case .restored = await Self.restoreRecoveredDelegation(
                        roundId: roundId,
                        session: session,
                        networkId: networkId,
                        accountId: accountId,
                        walletStorage: walletStorage
                    ) {
                        (existingState, existingBundleCount) = try await Self.loadExistingRoundSetup(
                            roundId: roundId,
                            votingCrypto: votingCrypto
                        )
                    }
                    var resolvedBundleCount: UInt32 = 0
                    var didPrepareFreshRound = false
                    if existingState?.proofGenerated == true {
                        let bundleCount = existingBundleCount
                        resolvedBundleCount = bundleCount
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
                    } else if Self.shouldResumePersistedRound(existingBundleCount: existingBundleCount) {
                        resolvedBundleCount = existingBundleCount
                        // A delegation TX hash cached locally means this device already
                        // broadcast a registration for the round, whatever the chain is
                        // able to tell us about it right now.
                        var anyLocalDelegationTxHash = false
                        for bundleIndex: UInt32 in 0..<existingBundleCount {
                            if case .present? = try? await votingCrypto.getDelegationTxHash(roundId, bundleIndex) {
                                anyLocalDelegationTxHash = true
                                break
                            }
                        }
                        var probes: [UInt32: DelegationRegistrationProbe] = [:]
                        for bundleIndex: UInt32 in 0..<existingBundleCount {
                            probes[bundleIndex] = await Self.probeDelegationRegistration(
                                roundId: roundId,
                                bundleIndex: bundleIndex,
                                votingCrypto: votingCrypto,
                                votingAPI: votingAPI,
                                confirmationTimeout: 0,
                                retryDelay: .zero
                            )
                        }
                        // A failed read is not evidence of "no signatures": swallowing it would
                        // report zero, route a Keystone round to `.freshRound`, and destroy rows
                        // that may back an on-chain registration. Let it throw into `catch:`
                        // instead — `.pipelineFailed` is non-destructive and the user can retry.
                        var savedSignatures: [KeystoneBundleSignatureInfo] = []
                        if isKeystoneUser {
                            savedSignatures = try await votingCrypto.loadKeystoneBundleSignatures(roundId)
                            // A signature that no longer matches the bundle's stored sighash
                            // (or whose setup is incomplete) is provably unusable, and its
                            // persisted row shields the bundle from `resetSessionState`'s
                            // guarded cleanup — wedging it permanently. Clear such rows now,
                            // before the resume paths run that reset, so the reset can free
                            // those bundles for a rebuild. The decision below still counts
                            // the loaded signatures: even a stale one proves an interrupted
                            // signing session on this device, and the resume path's
                            // reset-and-rebuild is the audited recovery for that state —
                            // `prepareFreshRound`'s re-setup over surviving bundle rows is not.
                            _ = try await Self.reconcileStoredSignatures(
                                savedSignatures,
                                storedSighash: { try await votingCrypto.getStoredDelegationSighash(roundId, $0) },
                                clearSignature: { try await votingCrypto.clearKeystoneSignature(roundId, $0) }
                            )
                        }

                        switch Self.roundResumeDecision(
                            probes: probes,
                            savedSignatureCount: savedSignatures.count,
                            anyLocalDelegationTxHash: anyLocalDelegationTxHash
                        ) {
                        case let .reuseRecovered(recoveredIndices):
                            LoggerProxy.debug(
                                "Recovered delegation bundle VAN positions for bundles \(recoveredIndices.sorted())"
                            )
                            let delegationReady = recoveredIndices.count >= Int(existingBundleCount)
                            if delegationReady {
                                try await votingCrypto.clearRecoveryState(roundId)
                            } else {
                                // Partially registered: clear the per-session leftovers of
                                // the bundles that never made it, without touching the
                                // delegation material the registered ones depend on.
                                try await votingCrypto.resetSessionState(roundId)
                            }
                            if isKeystoneUser, !recoveredIndices.isEmpty {
                                await send(.delegationBundlesRecovered(
                                    roundId: roundId,
                                    bundleIndices: recoveredIndices
                                ))
                            }
                            let eligibleWeight = Self.votingWeight(for: notes, bundleCount: existingBundleCount)
                            guard eligibleWeight > 0 else {
                                await send(.ineligibleForRound(roundId: roundId, heldZatoshi: heldZatoshi))
                                return
                            }
                            await send(.earlyEligibilityConfirmed(roundId: roundId))
                            let witnesses: [WitnessData]
                            if delegationReady {
                                witnesses = []
                            } else {
                                witnesses = try await Self.completeDeterministicRoundSetup(
                                    roundId: roundId,
                                    snapshotHeight: snapshotHeight,
                                    walletDbPath: walletDbPath,
                                    networkId: networkId,
                                    notes: notes,
                                    bundleCount: existingBundleCount,
                                    votingCrypto: votingCrypto,
                                    sdkSynchronizer: sdkSynchronizer
                                )
                            }
                            await send(.votingWeightLoaded(
                                roundId: roundId,
                                weight: eligibleWeight,
                                notes: notes,
                                witnesses: witnesses,
                                bundleCount: existingBundleCount,
                                delegationReady: delegationReady
                            ))

                        case .resumeInPlace:
                            // Nothing conclusive says this round is dead, and there is local
                            // material worth keeping. Resume on the existing rows: alpha, rk
                            // and the stored PCZT sighash stay exactly as the interrupted run
                            // left them, and only the per-session leftovers go.
                            try await votingCrypto.resetSessionState(roundId)
                            let eligibleWeight = Self.votingWeight(for: notes, bundleCount: existingBundleCount)
                            guard eligibleWeight > 0 else {
                                await send(.ineligibleForRound(roundId: roundId, heldZatoshi: heldZatoshi))
                                return
                            }
                            await send(.earlyEligibilityConfirmed(roundId: roundId))
                            // `resetSessionState` dropped the round's cached vote tree and the
                            // unsigned setup, so the witnesses have to be rebuilt before the
                            // interrupted signing run can continue.
                            let witnesses = try await Self.completeDeterministicRoundSetup(
                                roundId: roundId,
                                snapshotHeight: snapshotHeight,
                                walletDbPath: walletDbPath,
                                networkId: networkId,
                                notes: notes,
                                bundleCount: existingBundleCount,
                                votingCrypto: votingCrypto,
                                sdkSynchronizer: sdkSynchronizer
                            )
                            await send(.votingWeightLoaded(
                                roundId: roundId,
                                weight: eligibleWeight,
                                notes: notes,
                                witnesses: witnesses,
                                bundleCount: existingBundleCount,
                                delegationReady: false
                            ))

                        case .freshRound:
                            guard try await Self.prepareFreshRound(
                                roundId: roundId,
                                existingState: existingState,
                                existingBundleCount: existingBundleCount,
                                session: session,
                                snapshotHeight: snapshotHeight,
                                walletDbPath: walletDbPath,
                                networkId: networkId,
                                notes: notes,
                                votingCrypto: votingCrypto,
                                sdkSynchronizer: sdkSynchronizer,
                                send: send
                            ) else { return }
                            didPrepareFreshRound = true
                            resolvedBundleCount = try await votingCrypto.getBundleCount(roundId)
                        }
                    } else {
                        guard try await Self.prepareFreshRound(
                            roundId: roundId,
                            existingState: existingState,
                            existingBundleCount: existingBundleCount,
                            session: session,
                            snapshotHeight: snapshotHeight,
                            walletDbPath: walletDbPath,
                            networkId: networkId,
                            notes: notes,
                            votingCrypto: votingCrypto,
                            sdkSynchronizer: sdkSynchronizer,
                            send: send
                        ) else { return }
                        didPrepareFreshRound = true
                        resolvedBundleCount = try await votingCrypto.getBundleCount(roundId)
                    }

                    // 3. Hotkey: load or generate the per-account hotkey
                    // mnemonic, then derive this round's hotkey address.
                    guard let accountId else {
                        LoggerProxy.error("No selected account; skipping voting hotkey generation")
                        return
                    }
                    let storedSecret: Data
                    if let stored = try? walletStorage.exportVotingHotkey(accountId) {
                        storedSecret = stored.storedSecret.value()
                    } else {
                        let hotkey = try await votingCrypto.generateHotkey(networkId)
                        storedSecret = hotkey.storedSecret
                        try walletStorage.importVotingHotkey(storedSecret, accountId)
                    }
                    await send(.hotkeyLoaded(roundId: roundId, address: ""))

                    // Every path that reaches here with `didPrepareFreshRound == false` left
                    // the round's signature rows intact, so the DB is the only source: we
                    // never re-store signatures the pipeline itself just wiped. The
                    // proof-generated shortcut has nothing left to restore.
                    if isKeystoneUser && !didPrepareFreshRound && existingState?.proofGenerated != true {
                        let storedSignatures = (try? await votingCrypto.loadKeystoneBundleSignatures(roundId)) ?? []
                        // A stored signature is only usable if the bundle row still holds the
                        // delegation data (alpha/pczt_sighash) it was created against — the
                        // signature covers that exact sighash. Trusting a stale one routes
                        // straight into `build_and_prove_delegation`, which dies on the missing
                        // data. Validate against the stored sighash before the shape check below
                        // ever sees these signatures, so a mismatch or an incomplete setup drops
                        // the signature instead of being trusted.
                        var verifiedSignatures: [KeystoneBundleSignatureInfo] = []
                        if !storedSignatures.isEmpty {
                            verifiedSignatures = await Self.validatedStoredSignatures(storedSignatures) { bundleIndex in
                                try await votingCrypto.getStoredDelegationSighash(roundId, bundleIndex)
                            }
                            if verifiedSignatures.count < storedSignatures.count {
                                let droppedCount = storedSignatures.count - verifiedSignatures.count
                                LoggerProxy.warn(
                                    "Dropped \(droppedCount) stored Keystone signature(s) that no longer match their bundle's delegation data"
                                )
                            }
                        }
                        if let validSignatures = Self.validKeystoneSignatures(
                            verifiedSignatures,
                            bundleCount: resolvedBundleCount
                        ), !validSignatures.isEmpty {
                            await send(.keystoneSignaturesRestored(
                                roundId: roundId,
                                signatures: validSignatures
                            ))
                        } else if !storedSignatures.isEmpty {
                            LoggerProxy.warn("Ignoring inconsistent Keystone signing recovery state")
                        }
                    }
                } catch: { error, send in
                    LoggerProxy.error("Active round pipeline failed: \(error)")
                    await send(.pipelineFailed(
                        roundId: roundId,
                        message: await Self.pipelineFailureMessage(
                            error: error,
                            roundId: roundId,
                            crypto: votingCrypto
                        )
                    ))
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
                    roundSession.delegationPrecomputeProgress = nil
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

            case let .submittedVotesLoaded(roundId, votes, undeliveredShareProposalIds):
                guard !votes.isEmpty else { return .none }
                let account = state.selectedWalletAccount?.account
                var session = state.roundCache[roundId] ?? RoundSession(roundId: roundId)
                session.votes.merge(votes) { current, _ in current }
                // Finding #8 (CHP.md): fresh authoritative read every hydration —
                // replace, don't merge, matching `shareDelegations` below.
                session.undeliveredShareProposalIds = undeliveredShareProposalIds
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
        cancelSubmissionAttempts(state)
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

        // Flip the CTA into its disabled/spinner state before the local-auth
        // round-trip so the tap registers instantly; `.requested` also makes
        // re-taps no-ops (`canStartSubmission`), so only one auth effect can
        // ever be in flight.
        mutateSession(&state, roundId: roundId) {
            $0.batchSubmissionStatus = .requested
        }

        if !state.isKeystoneUser && !state.pendingBatchSubmission {
            return .run { [localAuthentication] send in
                guard await localAuthentication.authenticate() else {
                    await send(.batchAuthenticationDeclined(roundId: roundId))
                    return
                }
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
        // Idempotent entry: a fresh `.requested` tap (or a retryable status)
        // may start the pipeline, and an in-flight status may only be
        // re-entered by a resume holding the `pendingBatchSubmission` ticket.
        // A stray duplicate — a stale auth effect, a double dispatch — falls
        // through to `.none` instead of restarting (and thereby cancelling)
        // the in-flight batch effect.
        let isResume = state.pendingBatchSubmission
        guard session.batchSubmissionStatus == .requested
            || canStartSubmission(session)
            || (isResume && isBatchSubmitting(session))
        else { return .none }
        state.pendingBatchSubmission = false
        guard let activeSession = activeSession(in: state, roundId: roundId) else {
            session.submissionAttempt?.finish(.failed)
            return .none
        }
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

        let attemptPath: VotingSubmissionAttempt.Path = state.isKeystoneUser ? .keystone : .software
        let attempt = beginSubmissionAttempt(&state, roundId: roundId, path: attemptPath)
        let timing = votingSubmissionTiming

        // Zashi only: if a precompute is in flight, mark submission as
        // pending and let `.delegationPrecomputeCompleted` resume.
        if !state.isKeystoneUser
            && !isDelegationReady(session)
            && session.isDelegationPrecomputeInFlight {
            attempt.enter(.delegation)
            state.pendingBatchSubmission = true
            mutateSession(&state, roundId: roundId) { roundSession in
                roundSession.batchSubmissionStatus = .authorizing
                roundSession.voteSubmissionStep = .authorizingVote
                roundSession.delegationProofStatus = .generating(progress: 0)
            }
            // MOB-1929: the precompute is no longer only fetching PIR material — it is
            // running the authorization proof itself, at speculative priority so it never
            // competes with the UI. Someone is now waiting on it, so raise that proof (and
            // every later bundle of this run) to the interactive proving pool instead of
            // leaving the user behind a deliberately throttled one. The precompute effect
            // disarms the promotion again when it finishes.
            return .run { [votingCrypto] _ in
                await votingCrypto.promoteDelegationProving()
            }
        }

        // Finding #8 (CHP.md): a proposal whose vote landed on-chain but whose
        // shares never reached the helper servers has already been moved out
        // of `draftVotes` by `.submittedVotesLoaded`, so the draft list alone
        // would never revisit it. Fold `undeliveredShareProposalIds` in as
        // synthetic "drafts" — the on-chain choice is already known from
        // `session.votes` — so the batch loop below gets a chance to run
        // Task 8F's `tryRecoverInflightVote` lane for it again. The two id
        // sets shouldn't overlap (`.submittedVotesLoaded` always filters
        // `draftVotes` against the merged `votes`), but `subtracting` keeps
        // this correct even if that invariant ever slips.
        let recoveryDrafts = session.undeliveredShareProposalIds
            .subtracting(session.draftVotes.keys)
            .sorted()
            .compactMap { proposalId -> (key: UInt32, value: VoteChoice)? in
                session.votes[proposalId].map { (key: proposalId, value: $0) }
            }
        let drafts = session.draftVotes.sorted { $0.key < $1.key } + recoveryDrafts
        guard !drafts.isEmpty else {
            attempt.finish(.failed)
            return .none
        }
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
            let pirLayout = state.serviceConfig?.pirLayout,
            let accountId = state.selectedWalletAccount?.id
        else {
            attempt.finish(.failed)
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

        return .run { [backgroundTask, votingAPI, votingCrypto, mnemonic, walletStorage, pirLayout] send in
            defer { attempt.finishIfCancelled() }
            // MOB-1810: refresh operator health in the background so the
            // share-resubmission walk's ordering reflects the present rather
            // than poll entry. Fire-and-forget — it overlaps the delegation
            // proof; nothing in this effect awaits probe results.
            await votingAPI.startHealthProbeSweep()

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

            let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())

            // --- Delegation (ZKP #1) — run inline if not already done ---
            if !delegationDone {
                attempt.enter(.delegation)
                do {
                    // Fail closed before any FFI call when the dynamic config predates
                    // `pir_layout.poly_len` (see `missingPolyLenConfigError`). Votes on an
                    // already-delegated round never reach this branch and stay unaffected.
                    guard let polyLen = pirLayout.polyLen else {
                        throw Self.missingPolyLenConfigError
                    }
                    let senderPhrase = try walletStorage.exportWallet().seedPhrase.value()
                    let senderSeed = try mnemonic.toSeed(senderPhrase)
                    try await Self.runDelegationPipeline(
                        roundId: roundId,
                        cachedNotes: cachedNotes,
                        bundleCount: bundleCount,
                        senderSeed: senderSeed,
                        hotkeySeed: hotkeySeed,
                        networkId: networkId,
                        accountIndex: accountIndex,
                        roundName: roundName,
                        pirEndpoints: pirEndpoints,
                        expectedSnapshotHeight: expectedSnapshotHeight,
                        pirDepth: pirLayout.pirDepth,
                        tier0Layers: pirLayout.tier0Layers,
                        tier1Layers: pirLayout.tier1Layers,
                        polyLen: polyLen,
                        delegationPrepared: delegationPrepared,
                        seedFingerprint: seedFingerprint,
                        votingCrypto: votingCrypto,
                        votingAPI: votingAPI,
                        send: send
                    )
                } catch {
                    attempt.finish(error: error)
                    LoggerProxy.error("Delegation pipeline failed (raw): \(error.localizedDescription)")
                    await send(.batchAuthorizationFailed(
                        roundId: roundId,
                        error: VotingErrorMapper.userFriendlyMessage(from: error.localizedDescription)
                    ))
                    return
                }
            }

            attempt.enter(.votes)

            // Transition from .authorizing to .submitting now that delegation is done.
            await send(.batchSubmissionProgress(
                roundId: roundId,
                currentIndex: 0,
                totalCount: totalCount,
                proposalId: drafts[0].key
            ))

            // MOB-1930: the ballot is walked question-major by `maxConcurrentVoteLanes` lanes. A
            // bundle's authority note chains one of its votes to the next, so a bundle's own
            // questions go in ballot order and never overlap; across bundles there is no such
            // constraint, so the lanes cast every bundle's vote for one question before moving
            // to the next. One bundle's wait for the chain and its share delivery overlap another
            // bundle's proof, and each question is fully cast — and reported — as the walk passes
            // it, instead of all of them landing when the last bundle finishes. The proofs
            // themselves still serialize behind the SDK's handle lock; that is the intended memory
            // profile, not an accident of this shape.
            //
            // MOB-1928: helper-share delivery does not block a lane either. Each bundle's
            // shares go into a window of two and the lane moves straight on to its next task
            // while they travel; the tracker below is what finally decides each question's
            // outcome, so a question is reported submitted only once every bundle has cast it and
            // all of those bundles' shares were accepted. The pool is the live helper-server set
            // those deliveries share: one delivery pruning a dead server spares every later one
            // from retrying it.
            let submissionStarted = timing.now()
            let traceContext = "\(VotingSubmissionTrace.context(roundId: roundId)) attempt=\(attempt.id.uuidString)"
            let deliveryWindow = VotingHelperDeliveryWindow<ShareDelegationResult>()
            let serverPool = VotingShareServerPool(urls: voteServerURLs)

            // The skip rule, read once for the whole ballot instead of once per question, because
            // the lanes that consume it now run at the same time.
            let plan = Self.planVoteBundleWork(
                drafts: drafts,
                proposals: proposals,
                bundleCount: bundleCount,
                existingVotes: try await votingCrypto.getVotes(roundId),
                recordedShares: try await votingCrypto.getShareDelegations(roundId)
            )
            let tracker = VotingProposalCompletionTracker(proposals: plan.proposals)
            let context = VoteBatchContext(
                roundId: roundId,
                totalCount: totalCount,
                chainNodeUrl: chainNodeUrl,
                hotkeySeed: hotkeySeed,
                networkId: networkId,
                singleShare: singleShare,
                submitAtDeadline: submitAtDeadline,
                serverPool: serverPool,
                deliveryWindow: deliveryWindow,
                tracker: tracker,
                treeQueue: VotingSerialQueue(),
                trace: VotingSubmissionTrace.Totals(),
                timing: timing,
                votingCrypto: votingCrypto,
                votingAPI: votingAPI
            )

            // A synthetic abstain, and a question every bundle has already submitted with its
            // shares recorded, carry no bundle work at all: they are done before the walk starts.
            // The check is what the old loop's first-iteration `checkCancellation` did for them:
            // a cancellation landing here must not still report abstains as submitted, which
            // `batchVoteSubmitted` would also persist.
            try Task.checkCancellation()
            for resolution in await tracker.resolveProposalsWithoutWork() {
                await Self.announceProposalResolution(resolution, context: context, send: send)
            }

            let settlement: ShareDeliverySettlement
            do {
                // MOB-1928: one handler covers the whole walk, not just the drain. The window owns
                // unstructured tasks, so cancelling this effect never reaches them on its own, and
                // nothing below would notice a cancellation either — the lanes would keep proving
                // and broadcasting votes for a flow the user has already left. `onCancel` cancels
                // and joins the deliveries, each lane re-checks cancellation on every task it is
                // handed and ends its walk, and the `catch` awaits that same cancel so the effect
                // can never return while a delivery is still writing share records.
                settlement = try await withTaskCancellationHandler {
                    try await VotingSubmissionTrace.measure("votes", traceContext, totals: context.trace, sink: timing.sink, now: timing.now) {
                        await Self.runVoteLanes(plan, context: context, send: send)
                    }
                    // A lane reports a cancellation back rather than throwing it, so that one
                    // lane stopping never tears the group down while another sits between a
                    // broadcast and its confirmation. The effect's own cancellation is raised here
                    // instead, once: a cancelled batch must not mark its remaining questions failed
                    // and must not report itself complete.
                    try Task.checkCancellation()
                    attempt.enter(.sharesJoin)
                    return try await VotingSubmissionTrace.measure(
                        "sharesJoin",
                        traceContext,
                        totals: context.trace,
                        sink: timing.sink,
                        now: timing.now
                    ) {
                        try await Self.settleDeliveries(
                            roundId: roundId,
                            awaiting: await tracker.awaitingDeliveries(),
                            deliveryWindow: deliveryWindow,
                            send: send
                        )
                    }
                } onCancel: {
                    Task { await deliveryWindow.cancelAndDrain() }
                }
            } catch {
                await deliveryWindow.cancelAndDrain()
                throw error
            }

            let summary = await VotingSubmissionTrace.submissionSummary(
                context: traceContext,
                bundleCount: bundleCount,
                questionCount: totalCount,
                totalMilliseconds: VotingSubmissionTrace.milliseconds(since: submissionStarted, until: timing.now()),
                totals: context.trace
            )
            timing.sink(summary)
            let walk = await tracker.tallies()
            await send(.batchSubmissionCompleted(
                roundId: roundId,
                successCount: walk.successCount + settlement.successCount,
                failCount: walk.failCount + settlement.failCount
            ))
            // Resolve the diagnostic outcome after the reducer's persistence/completion guards.
            await send(.submissionAttemptSettled(
                roundId: roundId, attemptId: attempt.id, successCount: walk.successCount + settlement.successCount
            ))
        } catch: { error, send in
            attempt.finish(error: error)
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

    private func beginSubmissionAttempt(
        _ state: inout State,
        roundId: String,
        path: VotingSubmissionAttempt.Path,
        scope: VotingSubmissionAttempt.Scope = .submission
    ) -> VotingSubmissionAttempt {
        if let existing = state.roundCache[roundId]?.submissionAttempt, !existing.isFinished { return existing }
        let session = state.roundCache[roundId]
        let prepared = session?.delegationProofStatus == .complete || session?.delegationPrecomputeStatus == .ready
        let attempt = VotingSubmissionAttempt(roundId: roundId, path: path, scope: scope, prepared: prepared, client: votingSubmissionTiming)
        state.roundCache[roundId]?.submissionAttempt = attempt
        return attempt
    }

    private func cancelSubmissionAttempts(_ state: State) {
        for session in state.roundCache.values {
            session.submissionAttempt?.finish(.cancelled)
        }
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
            let pirLayout = state.serviceConfig?.pirLayout,
            let seedFingerprint = votingSeedFingerprint(for: state.selectedWalletAccount),
            let accountId = state.selectedWalletAccount?.id
        else {
            return .none
        }
        // Fail closed before any FFI call when the dynamic config predates
        // `pir_layout.poly_len` (see `missingPolyLenConfigError`).
        guard let polyLen = pirLayout.polyLen else {
            LoggerProxy.error("Delegation precompute refused: dynamic config lacks pir_layout.poly_len")
            return .send(.delegationPrecomputeFailed(
                roundId: roundId,
                error: Self.missingPolyLenConfigError.localizedDescription
            ))
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
        // A Confirm may already be parked on this run (a restart after `.votingWeightLoaded`,
        // for instance); it promoted a run that no longer exists, so this one promotes itself.
        let confirmWaiting = state.pendingBatchSubmission && !state.isKeystoneUser

        return .run { [votingCrypto, walletStorage, pirLayout] send in
            // MOB-1929: the promotion `.authenticationSucceeded` may arm lives on one object
            // shared by the whole flow. Every run starts by disarming whatever the previous one
            // left behind (a Confirm landing in its last instant can arm it after the fact), and
            // the completion and failure reducers disarm it again at the end. A cancelled run
            // deliberately resets nothing: its native proof may return long after a newer run
            // has started, and a late reset would strip that run of a legitimate promotion.
            votingCrypto.resetDelegationProvingPromotion()
            if confirmWaiting {
                await votingCrypto.promoteDelegationProving()
            }

            let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())
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
                guard !bundleNotes.isEmpty else { continue }

                let result = try await Self.precomputeBundle(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    bundleCount: bundleCount,
                    bundleNotes: bundleNotes,
                    hotkeySeed: hotkeySeed,
                    seedFingerprint: seedFingerprint,
                    networkId: networkId,
                    accountIndex: accountIndex,
                    roundName: roundName,
                    pirEndpoints: pirEndpoints,
                    expectedSnapshotHeight: expectedSnapshotHeight,
                    pirLayout: pirLayout,
                    polyLen: polyLen,
                    votingCrypto: votingCrypto,
                    send: send
                )
                totalCached += result.cachedCount
                totalFetched += result.fetchedCount
                LoggerProxy.info(
                    "Delegation PIR precompute bundle \(bundleIndex + 1)/\(bundleCount): " +
                        "cached=\(result.cachedCount) fetched=\(result.fetchedCount)"
                )
            }

            LoggerProxy.info(
                "Delegation precompute complete: cached=\(totalCached) fetched=\(totalFetched)"
            )
            await send(.delegationPrecomputeCompleted(roundId: roundId))
        } catch: { error, send in
            await send(.delegationPrecomputeFailed(roundId: roundId, error: error.localizedDescription))
        }
        .cancellable(id: cancelDelegationPrecomputeId, cancelInFlight: true)
    }

    /// One bundle's share of the background precompute: persist its PCZT setup, warm its PIR
    /// material, then prove it speculatively.
    ///
    /// The proof reads only viewing material — the Orchard FVK, the stored hotkey secret and
    /// the seed fingerprint — so the wallet seed stays in the keychain and nothing here signs
    /// or broadcasts anything. Progress is reported as the run's overall fraction, which is
    /// why `bundleCount` is a parameter and not derived from `bundleNotes`.
    // swiftlint:disable:next function_parameter_count
    static func precomputeBundle(
        roundId: String,
        bundleIndex: UInt32,
        bundleCount: UInt32,
        bundleNotes: [NoteInfo],
        hotkeySeed: [UInt8],
        seedFingerprint: Data,
        networkId: UInt32,
        accountIndex: UInt32,
        roundName: String,
        pirEndpoints: [String],
        expectedSnapshotHeight: UInt64,
        pirLayout: VotingServiceConfig.PirLayout,
        polyLen: UInt32,
        votingCrypto: VotingCryptoClient,
        send: Send<Action>
    ) async throws -> DelegationPirPrecomputeResult {
        let orchardFvk = try votingCrypto.extractOrchardFvkFromUfvk(
            bundleNotes[0].ufvkStr,
            networkId
        )
        let traceContext = VotingSubmissionTrace.context(roundId: roundId, bundleIndex: bundleIndex)

        try await VotingSubmissionTrace.measure("pczt", traceContext) {
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
        }

        let pirResult = try await VotingSubmissionTrace.measure("pir", traceContext) {
            try await votingCrypto.precomputeDelegationPir(
                roundId,
                bundleIndex,
                bundleNotes,
                pirEndpoints,
                expectedSnapshotHeight,
                networkId,
                pirLayout.pirDepth,
                pirLayout.tier0Layers,
                pirLayout.tier1Layers,
                polyLen
            )
        }

        try await VotingSubmissionTrace.measure("specprove", traceContext) {
            for try await event in votingCrypto.precomputeDelegationProof(
                roundId,
                bundleIndex,
                bundleNotes,
                orchardFvk,
                hotkeySeed,
                seedFingerprint,
                accountIndex,
                roundName,
                pirEndpoints,
                expectedSnapshotHeight,
                pirLayout.pirDepth,
                pirLayout.tier0Layers,
                pirLayout.tier1Layers,
                polyLen
            ) {
                switch event {
                case let .progress(progress):
                    await send(.delegationPrecomputeProgress(
                        roundId: roundId,
                        progress: (Double(bundleIndex) + progress) / Double(bundleCount)
                    ))
                case let .completed(proof):
                    LoggerProxy.info(
                        "Speculative ZKP #1 bundle \(bundleIndex + 1)/\(bundleCount) COMPLETE — " +
                            "proof size: \(proof.count) bytes"
                    )
                }
            }
        }

        return pirResult
    }

    /// `.delegationPrecomputeProgress` handler. The precompute's progress is its own
    /// bookkeeping — it is not an authorization — so it only reaches `delegationProofStatus`
    /// while a Confirm is parked on this very proof (`pendingBatchSubmission`), which is the
    /// one moment the user is watching a progress bar that has nothing else to move it.
    /// Keystone never runs this lane. `.complete` is never set from here: only the delegation
    /// pipeline may say that, and only after the chain confirms.
    func reduceDelegationPrecomputeProgress(
        _ state: inout State,
        roundId: String,
        progress: Double
    ) -> Effect<Action> {
        let isConfirmWaiting = state.pendingBatchSubmission && !state.isKeystoneUser
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.delegationPrecomputeProgress = progress
            if isConfirmWaiting {
                roundSession.delegationProofStatus = .generating(progress: progress)
            }
        }
        return .none
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
                guard let stored = try? await votingCrypto.getCommitmentBundleJson(roundId, bundleIndex, proposalId) else {
                    continue
                }

                do {
                    for share in shares {
                        let wireJson = try await votingCrypto.recoverWireJson(
                            stored.bundleJson, proposalId, share.shareIndex, stored.vcTreePosition, 0
                        )
                        let payload = SharePayload(wireJson: wireJson, shareIndex: share.shareIndex)
                        let acceptedServers = try await votingAPI.resubmitShare(
                            payload,
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
                eligibleVotingWeight: completedEligibleVotingWeight(session),
                submittedBundleCount: session.bundleCount,
                totalBundleCount: completedEligibleBundleCount(session)
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
        state.roundCache[roundId]?.submissionAttempt?.finish(.cancelled)
        state.roundCache[roundId]?.submissionAttempt = nil
        // "Try again" on both the authorizationFailed and submissionFailed
        // votingSheets (ConfirmSubmissionView) sends .retryBatchSubmission, which lands here.
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
                let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())
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
        // The signed-input event can be delivered twice. It must not restart automated work.
        guard session.submissionAttempt?.isFinished != false else { return .none }
        let attemptScope: VotingSubmissionAttempt.Scope = state.pendingBatchSubmission ? .submission : .delegation
        let attempt = beginSubmissionAttempt(&state, roundId: roundId, path: .keystone, scope: attemptScope)
        guard let activeSession = state.allRounds.first(where: { $0.id == roundId })?.session else {
            attempt.finish(.failed)
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
            let pirLayout = state.serviceConfig?.pirLayout,
            let accountId = state.selectedWalletAccount?.id
        else {
            attempt.finish(.failed)
            LoggerProxy.error("serviceConfig/selectedAccount unexpectedly nil during Keystone delegation proof")
            return .none
        }
        // Fail closed before any FFI call when the dynamic config predates
        // `pir_layout.poly_len` (see `missingPolyLenConfigError`).
        guard let polyLen = pirLayout.polyLen else {
            LoggerProxy.error("Keystone delegation proof refused: dynamic config lacks pir_layout.poly_len")
            attempt.finish(.failed)
            return .send(.delegationProofFailed(
                roundId: roundId,
                error: VotingErrorMapper.userFriendlyMessage(from: Self.missingPolyLenConfigError.localizedDescription)
            ))
        }
        let bundleCount = session.bundleCount
        let roundName = activeSession.title
        let storedSignatures = session.keystoneBundleSignatures.sorted { $0.bundleIndex < $1.bundleIndex }
        let initiallyCompletedBundles = session.completedKeystoneDelegationBundleIndices
        let noteChunks = cachedNotes.smartBundles().bundles
        guard bundleCount > 0,
              Int(bundleCount) <= noteChunks.count
        else {
            attempt.finish(.failed)
            return .send(.delegationProofFailed(
                roundId: roundId,
                error: "Keystone signature state is inconsistent."
            ))
        }

        return .run { [backgroundTask, votingCrypto, votingAPI, mnemonic, walletStorage, pirLayout] send in
            defer { attempt.finishIfCancelled() }
            let bgTaskId = await backgroundTask.beginTask("Keystone delegation proof")
            do {
                let senderPhrase = try walletStorage.exportWallet().seedPhrase.value()
                let senderSeed = try mnemonic.toSeed(senderPhrase)
                let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())
                attempt.enter(.delegation)
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
                        roundName,
                        pirEndpoints,
                        expectedSnapshotHeight,
                        pirLayout.pirDepth,
                        pirLayout.tier0Layers,
                        pirLayout.tier1Layers,
                        polyLen
                    ) {
                        switch event {
                        case .progress(let progress):
                            let overallProgress = (Double(completedBeforeBundle) + progress) / Double(totalWorkCount)
                            await send(.delegationProofProgress(roundId: roundId, progress: overallProgress))
                        case .completed(let proof):
                            LoggerProxy.info("ZKP #1 bundle \(bundleIdx) COMPLETE — proof size: \(proof.count) bytes")
                        }
                    }

                    let registration = try await votingCrypto.getDelegationSubmission(
                        roundId, bundleIdx, sig.sig, sig.sighash
                    )
                    if registration.rk != sig.rk ||
                        registration.spendAuthSig != sig.sig ||
                        registration.sighash != sig.sighash {
                        throw VotingFlowError.invalidDelegationSignature
                    }
                    let delegTxResult = try await votingAPI.submitDelegation(registration)
                    guard try await Self.isAcceptedVotingTransaction(delegTxResult, votingAPI: votingAPI) else {
                        throw VotingFlowError.delegationTxFailed(code: delegTxResult.code, log: delegTxResult.log)
                    }
                    try await votingCrypto.storeDelegationTxHash(roundId, bundleIdx, delegTxResult.txHash)
                    let vanPosition = try await Self.requireKeystoneDelegationVanPosition(
                        txHash: delegTxResult.txHash,
                        preferredServerURL: delegTxResult.code == 0 ? delegTxResult.acceptedByServerURL : nil,
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
                attempt.finishStandaloneDelegation()
            } catch {
                await backgroundTask.endTask(bgTaskId)
                throw error
            }
            await backgroundTask.endTask(bgTaskId)
        } catch: { error, send in
            attempt.finish(error: error)
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

    /// Keeps a stored Keystone signature only when `storedSighash` still reports the exact
    /// ZIP-244 sighash the signature was produced against. A signature covers one specific
    /// sighash; if the bundle's delegation setup was rebuilt (or never completed) since the
    /// signature was captured, trusting it routes straight into `build_and_prove_delegation`
    /// with missing alpha/pczt_sighash data. A thrown lookup (delegation setup incomplete) and
    /// a mismatch are both dropped — never kept by default — because dropping is always the
    /// fail-safe outcome: the bundle simply re-enters the signing queue via
    /// `firstIncompleteKeystoneBundleIndex`. Survivors keep their relative order.
    static func validatedStoredSignatures(
        _ signatures: [KeystoneBundleSignatureInfo],
        storedSighash: (UInt32) async throws -> Data
    ) async -> [KeystoneBundleSignatureInfo] {
        var validated: [KeystoneBundleSignatureInfo] = []
        for signature in signatures {
            guard let sighash = try? await storedSighash(signature.bundleIndex), sighash == signature.sighash else {
                continue
            }
            validated.append(signature)
        }
        return validated
    }

    /// Validates stored Keystone signatures via ``validatedStoredSignatures`` and
    /// deletes the persisted rows of the ones that fail, returning the survivors.
    /// A failed signature's row must go: `resetSessionState` leaves signed bundles
    /// untouched, so the stale row would otherwise shield its bundle's dead setup
    /// from cleanup and wedge the bundle permanently. A failing delete throws — the
    /// caller's pipeline aborts retryably rather than resuming on a half-reconciled
    /// signature set.
    static func reconcileStoredSignatures(
        _ signatures: [KeystoneBundleSignatureInfo],
        storedSighash: (UInt32) async throws -> Data,
        clearSignature: (UInt32) async throws -> Void
    ) async throws -> [KeystoneBundleSignatureInfo] {
        let usable = await validatedStoredSignatures(signatures, storedSighash: storedSighash)
        for rejected in signatures
        where !usable.contains(where: { $0.bundleIndex == rejected.bundleIndex }) {
            LoggerProxy.warn(
                "Clearing stored Keystone signature for bundle \(rejected.bundleIndex): it no longer matches the bundle's delegation data"
            )
            try await clearSignature(rejected.bundleIndex)
        }
        return usable
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

    /// Some deployed `/tx` handlers opportunistically Base64-decode CometBFT
    /// event text. A non-ASCII value is recovered only when it re-encodes to
    /// the canonical decimal the server emits; all other values fail closed.
    static func delegationVanPosition(from confirmation: TxConfirmation) -> UInt32? {
        guard confirmation.code == 0,
            let leafValue = confirmation.event(ofType: "delegate_vote")?.attribute(forKey: "leaf_index")
        else {
            return nil
        }
        let normalizedLeafValue = leafValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let position = UInt32(normalizedLeafValue) {
            return position
        }
        guard normalizedLeafValue.unicodeScalars.contains(where: { $0.value > 0x7f }) else {
            return nil
        }
        // Check that the reencoding produces the same value, to verify the precondition
        // asserted in the method documentation, to ensure valuex from other
        // sources of corruption don't get interpreted as the encoding issue this
        // method is intended to protect against.
        let reencodedLeafValue = Data(normalizedLeafValue.utf8).base64EncodedString()
        guard let position = UInt32(reencodedLeafValue), String(position) == reencodedLeafValue else {
            return nil
        }
        return position
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
        if let confirmation = try? await votingAPI.fetchTxConfirmation(txHash, nil, nil),
            let vanPosition = delegationVanPosition(from: confirmation) {
            try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanPosition)
            return vanPosition
        }
        return nil
    }

    static func requireKeystoneDelegationVanPosition(
        txHash: String,
        preferredServerURL: String?,
        votingAPI: VotingAPIClient
    ) async throws -> UInt32 {
        let pollResult = try await VotingTxConfirmationPoller.wait(
            preferredServerURL: preferredServerURL,
            timeout: .seconds(90),
            clock: ContinuousClock()
        ) { preferredServer, remainingBudget in
            try await votingAPI.fetchTxConfirmation(txHash, preferredServer, remainingBudget)
        }
        guard let confirmation = pollResult.confirmation else {
            throw VotingFlowError.delegationTxFailed(code: 0, log: "")
        }
        guard confirmation.code == 0 else {
            throw VotingFlowError.delegationTxFailed(code: confirmation.code, log: confirmation.log)
        }
        guard let vanPosition = delegationVanPosition(from: confirmation) else {
            throw VotingFlowError.delegationTxFailed(code: 0, log: "missing or unrecoverable delegate_vote leaf_index")
        }
        return vanPosition
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
        // resume the batch now that authorization is done. The ticket is
        // consumed by `.authenticationSucceeded`'s entry guard, not here.
        if state.pendingBatchSubmission {
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
            // Finding #8 (CHP.md): mirror Task 8F's `getVotes` × `getShareDelegations`
            // pairing here, at every round hydration, so a submitted-but-shareless
            // proposal is visible to the CTA gates before the user ever taps Confirm —
            // not just to the in-loop recovery check 8F added.
            let shareDelegations = (try? await votingCrypto.getShareDelegations(roundId)) ?? []
            let undeliveredShareProposalIds = Self.undeliveredShareProposalIds(
                records: records,
                shareDelegations: shareDelegations
            )
            await send(.submittedVotesLoaded(
                roundId: roundId,
                votes: votes,
                undeliveredShareProposalIds: undeliveredShareProposalIds
            ))
        } catch: { error, _ in
            LoggerProxy.warn("Failed to load submitted voting choices: \(error)")
        }
    }

    /// Finding #8 (CHP.md): proposals with at least one `submitted` vote
    /// bundle that has no matching recorded share delegation. Same pairing
    /// as Task 8F's in-loop `bundlesWithRecordedShares` check
    /// (`VotingCoordFlowCoordinator`'s batch `.run` effect), generalized to
    /// every proposal in the round in one pass instead of one proposal at a
    /// time, so it can run ahead of the submission loop rather than inside it.
    static func undeliveredShareProposalIds(
        records: [VoteRecord],
        shareDelegations: [VotingShareDelegation]
    ) -> Set<UInt32> {
        var submittedBundlesByProposal: [UInt32: Set<UInt32>] = [:]
        for record in records where record.submitted {
            submittedBundlesByProposal[record.proposalId, default: []].insert(record.bundleIndex)
        }
        var sharedBundlesByProposal: [UInt32: Set<UInt32>] = [:]
        for delegation in shareDelegations {
            sharedBundlesByProposal[delegation.proposalId, default: []].insert(delegation.bundleIndex)
        }
        return submittedBundlesByProposal.reduce(into: Set<UInt32>()) { result, entry in
            let (proposalId, submittedBundles) = entry
            let sharedBundles = sharedBundlesByProposal[proposalId] ?? []
            if !submittedBundles.isSubset(of: sharedBundles) {
                result.insert(proposalId)
            }
        }
    }

    private func canStartSubmission(_ session: RoundSession) -> Bool {
        // Finding #8 (CHP.md): `draftVotes` alone misses a proposal that's
        // already on-chain but whose shares never got delegated — see
        // `RoundSession.hasPendingSubmissionWork`.
        guard session.hasPendingSubmissionWork else { return false }
        guard session.bundleCount > 0 else { return false }
        switch session.batchSubmissionStatus {
        case .idle, .authorizationFailed, .submissionFailed:
            return true
        case .requested, .authorizing, .submitting, .completed:
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

    /// Once bundle rows exist, the round may contain non-reproducible
    /// delegation material. Restart recovery must preserve the entire round.
    static func shouldResumePersistedRound(existingBundleCount: UInt32) -> Bool {
        existingBundleCount > 0
    }

    /// Distinguish an absent round from a failed database read. A read failure
    /// must propagate so the caller cannot mistake it for an empty round and
    /// authorize `prepareFreshRound` to clear persisted recovery material.
    static func loadExistingRoundSetup(
        roundId: String,
        votingCrypto: VotingCryptoClient
    ) async throws -> (state: RoundStateInfo?, bundleCount: UInt32) {
        let rounds = try await votingCrypto.listRounds()
        guard rounds.contains(where: { $0.roundId == roundId }) else {
            return (nil, 0)
        }

        let state = try await votingCrypto.getRoundState(roundId)
        let bundleCount = try await votingCrypto.getBundleCount(roundId)
        return (state, bundleCount)
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

    /// What a surviving `rounds` row means for this setup attempt.
    enum ExistingRoundRow: Equatable {
        /// No row: this is a genuine first setup, so insert one.
        case absent
        /// A row from a setup interrupted between `initRound` and
        /// `setupBundles`. Reuse it.
        case reusable
        /// A row that no longer describes the round the session reports.
        /// Reused anyway: a row only reaches this classification with no
        /// bundles yet, so there is nothing at stake to protect.
        case parametersChanged
    }

    /// Classifies a surviving round row.
    ///
    /// A row reaches `prepareFreshRound` only when the round carries no
    /// bundles, i.e. setup was interrupted between `initRound` and
    /// `setupBundles`.
    ///
    /// Only `snapshotHeight` is compared, because that is the only round
    /// parameter `RoundStateInfo` carries. A round whose `ea_pk`, `nc_root` or
    /// `nullifier_imt_root` changed under a stable id is NOT detected here;
    /// catching that needs those fields on `RoundStateInfo`, or the crate's
    /// `ensure_round` exposed through the FFI with its network-only comparison
    /// widened to the full parameter set.
    static func classifyExistingRoundRow(
        existingState: RoundStateInfo?,
        snapshotHeight: UInt64
    ) -> ExistingRoundRow {
        guard let existingState else { return .absent }
        return existingState.snapshotHeight == snapshotHeight ? .reusable : .parametersChanged
    }

    private static func prepareFreshRound(
        roundId: String,
        existingState: RoundStateInfo?,
        existingBundleCount: UInt32,
        session: VotingSession,
        snapshotHeight: UInt64,
        walletDbPath: String,
        networkId: UInt32,
        notes: [NoteInfo],
        votingCrypto: VotingCryptoClient,
        sdkSynchronizer: SDKSynchronizerClient,
        send: Send<Action>
    ) async throws -> Bool {
        let params = VotingRoundParams(
            voteRoundId: session.voteRoundId,
            snapshotHeight: snapshotHeight,
            eaPK: session.eaPK,
            ncRoot: session.ncRoot,
            nullifierIMTRoot: session.nullifierIMTRoot
        )

        switch classifyExistingRoundRow(existingState: existingState, snapshotHeight: snapshotHeight) {
        case .absent:
            try await votingCrypto.initRound(params, nil)
        case .reusable:
            break
        case .parametersChanged:
            // A round with bundle rows can reach this classification too (a
            // trimmed round abandoned before its first delegation broadcast
            // comes back as a fresh round); its rows are adopted rather than
            // rebuilt, and the delegation proof re-validates them against the
            // current notes, so there is nothing here to protect by
            // hard-failing.
            // Reuse the row rather than making the round permanently
            // unopenable: every value it feeds into a proof or submission is
            // re-verified independently downstream, so a stale row fails
            // loudly there instead of silently corrupting anything.
            LoggerProxy.warn(
                "Reusing round \(roundId) despite a snapshotHeight mismatch (no bundles exist yet to protect)"
            )
        }

        try await votingCrypto.clearRecoveryState(roundId)

        let setup = try await resolveFreshBundleSetup(
            roundId: roundId,
            notes: notes,
            existingBundleCount: existingBundleCount,
            votingCrypto: votingCrypto
        )
        let bundleCount = setup.keepCount
        let eligibleWeight = setup.keptWeight
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

        let allWitnesses = try await completeDeterministicRoundSetup(
            roundId: roundId,
            snapshotHeight: snapshotHeight,
            walletDbPath: walletDbPath,
            networkId: networkId,
            notes: notes,
            bundleCount: bundleCount,
            votingCrypto: votingCrypto,
            sdkSynchronizer: sdkSynchronizer
        )

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

    /// The bundle setup a fresh round starts from. Rows that already exist belong to a round that
    /// was set up, possibly trimmed, and then abandoned before its first delegation broadcast:
    /// re-running `setupBundles` over them would fail, because the crate insists that the planned
    /// and the stored bundle counts match, so the stored prefix is adopted as it is and the
    /// delegation proof re-validates it against the current notes before anything is proved.
    /// Without rows the bundles are created and the privacy trim runs. A result with no bundles
    /// or no weight means the wallet is not eligible.
    static func resolveFreshBundleSetup(
        roundId: String,
        notes: [NoteInfo],
        existingBundleCount: UInt32,
        votingCrypto: VotingCryptoClient
    ) async throws -> VotingBundleTrim {
        if existingBundleCount > 0 {
            return VotingBundleTrim(
                keepCount: existingBundleCount,
                keptWeight: votingWeight(for: notes, bundleCount: existingBundleCount),
                trimmedBundleCount: 0,
                trimmedWeight: 0
            )
        }
        let setupResult = try await votingCrypto.setupBundles(roundId, notes)
        guard setupResult.bundleCount > 0, setupResult.eligibleWeight > 0 else {
            return VotingBundleTrim(keepCount: 0, keptWeight: 0, trimmedBundleCount: 0, trimmedWeight: 0)
        }
        return try await applyBundleTrim(
            roundId: roundId,
            notes: notes,
            setupResult: setupResult,
            votingCrypto: votingCrypto
        )
    }

    /// Applies the privacy trim to a freshly built bundle setup: computes how many of the
    /// value-descending bundles to keep, deletes the tail rows through the crate's skipped-suffix
    /// path (the one the Keystone skip flow already uses, so the kept prefix keeps exactly the
    /// composition it was built with) and returns what the session should record. Nothing is
    /// trimmed when the app's bundling and the stored bundle count disagree: the raw weights would
    /// then describe a different layout than the rows.
    static func applyBundleTrim(
        roundId: String,
        notes: [NoteInfo],
        setupResult: BundleSetupResult,
        votingCrypto: VotingCryptoClient
    ) async throws -> VotingBundleTrim {
        let untrimmed = VotingBundleTrim(
            keepCount: setupResult.bundleCount,
            keptWeight: setupResult.eligibleWeight,
            trimmedBundleCount: 0,
            trimmedWeight: 0
        )
        let rawWeights = notes.smartBundles().bundles.map { bundle in
            bundle.reduce(UInt64(0)) { $0 + $1.value }
        }
        guard rawWeights.count == Int(setupResult.bundleCount) else {
            LoggerProxy.warn(
                """
                Voting round \(roundId): the app bundles these notes into \(rawWeights.count) bundles but \
                \(setupResult.bundleCount) rows are stored; skipping the privacy trim
                """
            )
            return untrimmed
        }
        let keepCount = VotingBundleTrimPolicy.keepCount(rawWeights: rawWeights)
        guard keepCount < rawWeights.count else {
            return untrimmed
        }

        let keptWeight = rawWeights.prefix(keepCount).reduce(UInt64(0)) { $0 + quantizeWeight($1) }
        let trimmedWeight = rawWeights.dropFirst(keepCount).reduce(UInt64(0)) { $0 + quantizeWeight($1) }
        LoggerProxy.info(
            """
            Trimming voting round \(roundId) from \(rawWeights.count) to \(keepCount) bundles \
            (\(trimmedWeight) zatoshi of voting weight dropped)
            """
        )
        try await votingCrypto.deleteSkippedBundles(roundId, UInt32(keepCount))
        return VotingBundleTrim(
            keepCount: UInt32(keepCount),
            keptWeight: keptWeight,
            trimmedBundleCount: UInt32(rawWeights.count - keepCount),
            trimmedWeight: trimmedWeight
        )
    }

    /// Completes only deterministic tree-state and witness work for a persisted
    /// round. This must not clear the round or rebuild delegation authorization.
    static func completeDeterministicRoundSetup(
        roundId: String,
        snapshotHeight: UInt64,
        walletDbPath: String,
        networkId: UInt32,
        notes: [NoteInfo],
        bundleCount: UInt32,
        votingCrypto: VotingCryptoClient,
        sdkSynchronizer: SDKSynchronizerClient
    ) async throws -> [WitnessData] {
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
                noteChunks[Int(bundleIndex)],
                networkId
            )
            allWitnesses.append(contentsOf: witnesses)
        }
        return allWitnesses
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

    /// Accept a successful broadcast directly. A spent-nullifier rejection is
    /// accepted only when its exact transaction hash resolves on-chain with code 0.
    static func isAcceptedVotingTransaction(
        _ result: TxResult,
        votingAPI: VotingAPIClient,
        maxRecoveryAttempts: Int = 3,
        retryDelay: Duration = .seconds(1)
    ) async throws -> Bool {
        let txHash = result.txHash.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.code == 0 {
            return !txHash.isEmpty
        }
        guard maxRecoveryAttempts > 0,
              !txHash.isEmpty,
              VotingErrorMapper.isNullifierAlreadySpent(result.log)
        else {
            return false
        }

        for attempt in 0..<maxRecoveryAttempts {
            if let confirmation = try await votingAPI.fetchTxConfirmation(txHash, nil, nil) {
                return confirmation.code == 0
            }
            if attempt + 1 < maxRecoveryAttempts {
                try await Task.sleep(for: retryDelay)
            }
        }
        return false
    }

    /// If we have a cached vote TX hash for `(roundId, bundleIndex, proposalId)`
    /// that confirmed on-chain, hand this bundle's tally shares to the delivery
    /// window without rebuilding the commitment. Returns the identity the
    /// delivery was enqueued under — the caller collects it so the proposal is
    /// reported submitted only once that delivery settles — or `nil` when
    /// nothing was recoverable.
    // swiftlint:disable:next function_body_length cyclomatic_complexity function_parameter_count
    static func tryRecoverInflightVote(
        roundId: String,
        bundleIndex: UInt32,
        proposalId: UInt32,
        choice: VoteChoice,
        submitAtDeadline: Double?,
        serverPool: VotingShareServerPool,
        deliveryWindow: VotingHelperDeliveryWindow<ShareDelegationResult>,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        send: Send<Action>,
        roundIdAction: () -> String,
        trace: VotingSubmissionTrace.Totals? = nil,
        timing: VotingSubmissionTimingClient = .liveValue
    ) async throws -> VotingShareDeliveryIdentity? {
        guard case let .present(cachedTxHash)? = try? await votingCrypto.getVoteTxHash(roundId, bundleIndex, proposalId) else {
            return nil
        }
        guard let confirmation = try? await votingAPI.fetchTxConfirmation(cachedTxHash, nil, nil),
              confirmation.code == 0 else {
            return nil
        }

        let eventsPayload: [[String: Any]] = confirmation.events.map { event in
            [
                "type": event.type,
                "attributes": event.attributes.map { attribute in
                    ["key": attribute.key, "value": attribute.value]
                }
            ]
        }
        guard let eventsData = try? JSONSerialization.data(withJSONObject: eventsPayload) else {
            return nil
        }
        let eventsJson = String(decoding: eventsData, as: UTF8.self)

        guard let voteConfirmation = try? await votingCrypto.confirmVoteSubmission(
            roundId, bundleIndex, proposalId, cachedTxHash, eventsJson
        ) else {
            return nil
        }

        guard let stored = try? await votingCrypto.getCommitmentBundleJson(roundId, bundleIndex, proposalId) else {
            LoggerProxy.error(
                """
                Recovered on-chain vote \(proposalId) for bundle \(bundleIndex), \
                but the saved commitment bundle is missing; cannot delegate tally shares.
                """
            )
            throw VotingFlowError.missingVoteCommitmentBundle
        }

        await send(.voteSubmissionStepUpdated(roundId: roundIdAction(), step: .sendingShares))

        // Finding #9 (CHP.md, 2026-08-12): the old guess of `singleShare ? 1 : numOptions`
        // under-delivered live (server accepted 16 built shares on a 2-option proposal; the
        // guess would have resubmitted 2). `recoverableShareIndices` reads the crate's own
        // `recover_payloads` slicing instead, so recovery resubmits exactly what it built.
        let shareIndices = try await votingCrypto.recoverableShareIndices(stored.bundleJson)

        // The on-chain vote really is confirmed at this point, so the bundle is marked submitted
        // before its shares are handed over rather than after: 8F proved the call idempotent to
        // re-mark on a later retry, and a bundle marked submitted whose shares never land is
        // exactly the state the caller's `getShareDelegations` check sends back through here.
        try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId, cachedTxHash)

        // Delivery — including the 8P rule that every accepted share is recorded locally before
        // any write failure is raised — happens inside the window, so this lane returns as soon
        // as the work is admitted. The identity is how the caller learns, at drain time, whether
        // this bundle's shares arrived.
        let identity = VotingShareDeliveryIdentity(
            roundId: roundId,
            bundleIndex: bundleIndex,
            proposalId: proposalId
        )
        try await enqueueDelivery(
            into: deliveryWindow,
            identity: identity,
            bundleJson: stored.bundleJson,
            shareIndices: shareIndices,
            voteCommitmentTreePosition: voteConfirmation.voteCommitmentTreePosition,
            submitAtDeadline: submitAtDeadline,
            serverPool: serverPool,
            votingCrypto: votingCrypto,
            votingAPI: votingAPI,
            trace: trace,
            timing: timing
        )
        return identity
    }

    // MARK: - Helper-share delivery (MOB-1928)

    /// One proposal whose on-chain votes are all in, waiting only on the tally-share deliveries
    /// its bundles enqueued. `batchVoteSubmitted` is deferred until those settle.
    struct AwaitingShareDelivery: Sendable {
        let proposalId: UInt32
        let choice: VoteChoice
        let identities: [VotingShareDeliveryIdentity]
        /// MOB-1930: `false` when one of this question's bundles was abandoned because the lanes
        /// stopped before reaching it. The deliveries the other bundles did enqueue still have to
        /// be attributed — an on-chain vote whose shares went nowhere is exactly what the voter has
        /// to be told — but the question was never fully cast, so it can never be reported submitted.
        let isFullyCast: Bool

        init(
            proposalId: UInt32,
            choice: VoteChoice,
            identities: [VotingShareDeliveryIdentity],
            isFullyCast: Bool = true
        ) {
            self.proposalId = proposalId
            self.choice = choice
            self.identities = identities
            self.isFullyCast = isFullyCast
        }
    }

    /// What the post-loop settlement added to the batch's tallies.
    struct ShareDeliverySettlement: Sendable {
        let successCount: Int
        let failCount: Int
    }

    /// Rebuild one bundle's helper-share payloads and hand them to the helper servers.
    ///
    /// Extracted from the batch loop so the same body serves the recovery lane and so it can run
    /// inside `VotingHelperDeliveryWindow` while the caller proves the next vote. The server set
    /// is read from `serverPool` when the delivery starts and pruned when it finishes, so a
    /// server that proved unreachable is not retried by a later delivery; a whole-set exhaustion
    /// empties the pool, which is what stops the batch.
    // swiftlint:disable:next function_parameter_count
    static func deliverShares(
        roundId: String,
        bundleIndex: UInt32,
        proposalId: UInt32,
        bundleJson: String,
        shareIndices: [UInt32],
        voteCommitmentTreePosition: UInt64,
        submitAtDeadline: Double?,
        serverPool: VotingShareServerPool,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient
    ) async throws -> ShareDelegationResult {
        let now = Date().timeIntervalSince1970
        var payloads: [SharePayload] = []
        var submitAtByShareIndex: [UInt32: UInt64] = [:]
        for shareIndex in shareIndices {
            let submitAt: UInt64
            if let deadline = submitAtDeadline, deadline > now {
                submitAt = UInt64(now + Double.random(in: 0..<(deadline - now)))
            } else {
                submitAt = 0
            }
            submitAtByShareIndex[shareIndex] = submitAt
            let wireJson = try await votingCrypto.recoverWireJson(
                bundleJson, proposalId, shareIndex,
                voteCommitmentTreePosition, submitAt
            )
            payloads.append(SharePayload(wireJson: wireJson, shareIndex: shareIndex))
        }

        let result: ShareDelegationResult
        do {
            result = try await Voting.delegateSharesWithFallback(
                payloads,
                proposalId: proposalId,
                votingAPI: votingAPI,
                serverURLs: await serverPool.current()
            )
        } catch let error as ShareDelegationError where error == .noReachableVoteServers {
            // Nothing reachable is left: empty the pool so the batch loop stops proving votes it
            // has nowhere to send, exactly as the old inline `shouldStopBatch` did.
            await serverPool.prune(to: [])
            throw error
        }
        await serverPool.prune(to: result.remainingServerURLs)

        // A share the servers already accepted must not be allowed to vanish from local
        // bookkeeping: record every delegation this loop can reach first (a write fault on one
        // share must not cost later shares their record), then throw once if any write failed,
        // so this bundle counts as failed instead of done. A silent success here would let
        // `reduceBatchSubmissionCompleted` write a completion record over shares invisible to
        // `getShareDelegations` (8O adversarial finding, CHP.md 2026-08-13) — the server still
        // holds the share, so the vote itself stays safe; only local resubmission bookkeeping
        // for that specific share is at risk.
        var shareRecordFailures: [Error] = []
        for info in result.delegatedShares {
            do {
                try await votingCrypto.recordShareDelegation(
                    roundId, bundleIndex, info.proposalId, info.shareIndex,
                    info.acceptedByServers, submitAtByShareIndex[info.shareIndex] ?? 0
                )
            } catch {
                LoggerProxy.warn("Batch: failed to record share delegation for share \(info.shareIndex): \(error)")
                shareRecordFailures.append(error)
            }
        }
        if let firstFailure = shareRecordFailures.first {
            throw firstFailure
        }
        return result
    }

    /// Admit one bundle's delivery into the window. Returns once it is admitted, which — when the
    /// window is already full — is when the oldest still-running delivery settles.
    // swiftlint:disable:next function_parameter_count
    static func enqueueDelivery(
        into deliveryWindow: VotingHelperDeliveryWindow<ShareDelegationResult>,
        identity: VotingShareDeliveryIdentity,
        bundleJson: String,
        shareIndices: [UInt32],
        voteCommitmentTreePosition: UInt64,
        submitAtDeadline: Double?,
        serverPool: VotingShareServerPool,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        trace: VotingSubmissionTrace.Totals? = nil,
        timing: VotingSubmissionTimingClient = .liveValue
    ) async throws {
        let traceContext = VotingSubmissionTrace.context(
            roundId: identity.roundId, bundleIndex: identity.bundleIndex, proposalId: identity.proposalId
        )
        try await deliveryWindow.enqueue(identity: identity) {
            try await VotingSubmissionTrace.measure("deliver", traceContext, totals: trace, sink: timing.sink, now: timing.now) {
                try await Self.deliverShares(
                    roundId: identity.roundId,
                    bundleIndex: identity.bundleIndex,
                    proposalId: identity.proposalId,
                    bundleJson: bundleJson,
                    shareIndices: shareIndices,
                    voteCommitmentTreePosition: voteCommitmentTreePosition,
                    submitAtDeadline: submitAtDeadline,
                    serverPool: serverPool,
                    votingCrypto: votingCrypto,
                    votingAPI: votingAPI
                )
            }
        }
    }

    /// Wait for every enqueued delivery and attribute the outcome back to its proposal: a
    /// proposal whose bundles all delivered is reported submitted here, one with any failed
    /// delivery is reported failed with that first failure's message. Returns what to add to
    /// the batch's success/fail tallies.
    ///
    /// The drain is unconditional. A proposal that threw *after* admitting one of its bundles'
    /// deliveries is already reported failed and never reaches `awaiting`, but its delivery is
    /// still ours to join: returning without draining would let it outlive the effect, writing
    /// share records beside a retry's. Nobody is left to attribute it to, which is the point —
    /// the proposal already carries its failure. The caller installs the cancellation handler
    /// that covers this wait, since it covers the walk that fed it too.
    static func settleDeliveries(
        roundId: String,
        awaiting: [AwaitingShareDelivery],
        deliveryWindow: VotingHelperDeliveryWindow<ShareDelegationResult>,
        send: Send<Action>
    ) async throws -> ShareDeliverySettlement {
        if !awaiting.isEmpty {
            await send(.voteSubmissionStepUpdated(roundId: roundId, step: .sendingShares))
        }

        var failures: [VotingShareDeliveryIdentity: Error] = [:]
        do {
            _ = try await deliveryWindow.drain()
        } catch let aggregate as VotingShareDeliveryAggregateError<ShareDelegationResult> {
            failures = aggregate.failures
        } catch {
            await deliveryWindow.cancelAndDrain()
            throw error
        }

        var successCount = 0
        var failCount = 0
        for proposal in awaiting {
            guard let firstFailure = proposal.identities.compactMap({ failures[$0] }).first else {
                // A question one of whose bundles was abandoned stays an outstanding draft: its
                // shares arrived, but it was never fully cast, so claiming it submitted would
                // record a vote the wallet did not finish casting.
                guard proposal.isFullyCast else { continue }
                successCount += 1
                await send(.batchVoteSubmitted(
                    roundId: roundId,
                    proposalId: proposal.proposalId,
                    choice: proposal.choice
                ))
                continue
            }
            failCount += 1
            LoggerProxy.error("Batch: share delivery failed for proposal \(proposal.proposalId): \(firstFailure)")
            await send(.batchVoteFailed(
                roundId: roundId,
                proposalId: proposal.proposalId,
                error: VotingErrorMapper.userFriendlyMessage(from: firstFailure)
            ))
        }
        return ShareDeliverySettlement(successCount: successCount, failCount: failCount)
    }

    // MARK: - Question-major vote submission (MOB-1930)

    /// How many vote lanes run at once (design D6).
    ///
    /// The proofs themselves still serialize behind the SDK's handle lock, so this does not buy
    /// parallel proving — it buys the overlap of one bundle's chain wait and share delivery with
    /// another bundle's proof. Raising it raises peak memory for no extra throughput.
    static let maxConcurrentVoteLanes = 2

    /// One question's work for one bundle.
    struct VoteBundleWork: Sendable {
        let proposalId: UInt32
        let choice: VoteChoice
        let numOptions: UInt32
    }

    /// One question of the ballot and how many bundle tasks it is waiting on. Zero means it needs
    /// no on-chain work at all — a synthetic abstain, or a question every bundle has already
    /// submitted with its shares recorded.
    struct VoteProposalPlan: Sendable {
        let proposalId: UInt32
        let choice: VoteChoice
        let bundleTaskCount: Int
    }

    /// The ballot, split the way the vote lanes consume it.
    struct VoteBundlePlan: Sendable {
        /// Per bundle, the questions that bundle still has to cast, in ballot order.
        let workByBundle: [UInt32: [VoteBundleWork]]
        /// Every question of the ballot, in ballot order.
        let proposals: [VoteProposalPlan]
    }

    /// Everything a vote lane needs that is the same for every task.
    struct VoteBatchContext: Sendable {
        let roundId: String
        let totalCount: Int
        let chainNodeUrl: String
        let hotkeySeed: [UInt8]
        let networkId: UInt32
        let singleShare: Bool
        let submitAtDeadline: Double?
        let serverPool: VotingShareServerPool
        let deliveryWindow: VotingHelperDeliveryWindow<ShareDelegationResult>
        let tracker: VotingProposalCompletionTracker
        /// Serializes each lane's vote-tree sync together with the witness it anchors. See
        /// `voteBundleWork`.
        let treeQueue: VotingSerialQueue
        /// Per-step totals across the vote lanes, for the summary line at the end of the batch.
        let trace: VotingSubmissionTrace.Totals
        let timing: VotingSubmissionTimingClient
        let votingCrypto: VotingCryptoClient
        let votingAPI: VotingAPIClient
    }

    /// Why a vote lane stopped.
    enum VoteLaneOutcome: Sendable {
        /// The scheduler had nothing left to hand out. Individual questions may still have failed.
        case finished
        /// No helper server is reachable any more, so it stopped rather than prove votes whose
        /// shares would have nowhere to go.
        case exhausted
        /// The batch effect was cancelled.
        case cancelled
    }

    /// What one task came to, for the lane loop.
    private enum VoteTaskOutcome: Sendable {
        case completed
        case cancelled
    }

    /// Turn the ballot into one work list per bundle.
    ///
    /// A bundle owes a question a vote unless it is both submitted AND has a recorded share
    /// delegation for it. A tally-share delegation failure can land *after* `markVoteSubmitted`
    /// runs (see Task 8E), leaving `submitted == true` with zero recorded share delegations — and
    /// no other lane ever retries an orphaned share — so anything less than both has to fall
    /// through to `tryRecoverInflightVote`, which re-confirms the cached tx and re-runs share
    /// delegation end to end.
    static func planVoteBundleWork(
        drafts: [(key: UInt32, value: VoteChoice)],
        proposals: [VotingProposal],
        bundleCount: UInt32,
        existingVotes: [VoteRecord],
        recordedShares: [VotingShareDelegation]
    ) -> VoteBundlePlan {
        var workByBundle: [UInt32: [VoteBundleWork]] = [:]
        var proposalPlans: [VoteProposalPlan] = []

        for draft in drafts {
            let proposalId = draft.key
            let choice = draft.value
            let proposal = proposals.first { $0.id == proposalId }

            // Synthetic abstain: nothing is cast on chain, so no bundle owes it anything.
            guard !Voting.isSyntheticAbstain(choice: choice, proposal: proposal) else {
                proposalPlans.append(VoteProposalPlan(proposalId: proposalId, choice: choice, bundleTaskCount: 0))
                continue
            }

            let submittedBundles = Set(
                existingVotes
                    .filter { $0.proposalId == proposalId && $0.submitted }
                    .map(\.bundleIndex)
            )
            let bundlesWithRecordedShares = Set(
                recordedShares
                    .filter { $0.proposalId == proposalId }
                    .map(\.bundleIndex)
            )
            let numOptions = UInt32(proposal?.options.count ?? 3)

            var pendingCount = 0
            for bundleIndex: UInt32 in 0..<bundleCount {
                if submittedBundles.contains(bundleIndex) && bundlesWithRecordedShares.contains(bundleIndex) {
                    LoggerProxy.debug("Batch: bundle \(bundleIndex + 1)/\(bundleCount) already submitted for proposal \(proposalId)")
                    continue
                }
                workByBundle[bundleIndex, default: []].append(VoteBundleWork(
                    proposalId: proposalId,
                    choice: choice,
                    numOptions: numOptions
                ))
                pendingCount += 1
            }
            proposalPlans.append(VoteProposalPlan(
                proposalId: proposalId,
                choice: choice,
                bundleTaskCount: pendingCount
            ))
        }

        return VoteBundlePlan(workByBundle: workByBundle, proposals: proposalPlans)
    }

    /// Run the vote lanes over the ballot, question-major.
    ///
    /// `orderedVoteTasks` lays the ballot out by question, then bundle, and the scheduler hands
    /// those tasks to `maxConcurrentVoteLanes` lanes, never two tasks of one bundle at once. With
    /// three or more bundles the lanes interleave bundles inside a question — so every question is
    /// fully cast roughly one bundle-count of tasks after it was started, and the progress the
    /// voter sees advances question by question — while a bundle's own votes stay in ballot order,
    /// which its authority-note chain requires. With one or two bundles each lane effectively owns
    /// a bundle, which is the walk this replaces.
    ///
    /// A lane never throws — it reports why it stopped — so one lane running out of helper
    /// servers, or the effect being cancelled, cannot tear the group down while another lane is
    /// sitting between an on-chain broadcast and its confirmation.
    static func runVoteLanes(
        _ plan: VoteBundlePlan,
        context: VoteBatchContext,
        send: Send<Action>
    ) async {
        let tasks = Self.orderedVoteTasks(from: plan)
        guard !tasks.isEmpty else { return }
        let scheduler = VotingVoteTaskScheduler(tasks: tasks)
        let laneCount = min(Self.maxConcurrentVoteLanes, plan.workByBundle.count)

        await withTaskGroup(of: VoteLaneOutcome.self) { group in
            for _ in 0..<laneCount {
                group.addTask {
                    await Self.runVoteLane(scheduler: scheduler, context: context, send: send)
                }
            }
            for await _ in group {}
        }
    }

    /// One lane's walk: take the next eligible task, cast it, free its bundle, repeat.
    ///
    /// The cancellation and helper-pool checks sit at the task boundary, outside the per-task
    /// `do`, on purpose. A cancelled batch must end the walk rather than mark a question failed
    /// and go on proving the next one — by the time it fires the flow is already gone
    /// (`.dismissFlow`, an account switch, or a retry's `cancelInFlight`), so another proof and
    /// another on-chain broadcast would be work for a screen the user has left. And an emptied
    /// pool must stop the whole ballot: the task just handed out is abandoned along with every
    /// task still queued, so the questions the lanes did cast can still be resolved.
    ///
    /// Both checks are taken again on the task the scheduler hands out, not only before the wait
    /// for one. A lane with nothing eligible parks inside `next()`, and it can be woken long after
    /// the flow was cancelled or the pool emptied: the scheduler releases a cancelled waiter from
    /// an unstructured task that races a sibling's `finish`, so a park can end with a real task in
    /// hand rather than `nil`. A check taken before the park would describe a world that is gone.
    /// A cancellation frees the task's bundle right away — `next()` marked it busy, and the
    /// scheduler's contract is one `finish` per task handed out. Exhaustion frees it only after
    /// draining the queue: freeing first could wake a parked sibling into `next()` before the
    /// drain removes what is left, handing it a task that is already doomed.
    static func runVoteLane(
        scheduler: VotingVoteTaskScheduler,
        context: VoteBatchContext,
        send: Send<Action>
    ) async -> VoteLaneOutcome {
        while true {
            if Task.isCancelled {
                return .cancelled
            }
            guard let task = await scheduler.next() else {
                return Task.isCancelled ? .cancelled : .finished
            }
            // A parked lane is normally released with `nil` when its task is cancelled, but that
            // release is an unstructured hop racing a sibling's `finish`, which wakes waiters
            // synchronously. So a lane can come out of `next()` holding a real task for a flow
            // the user has already left — `voteBundleWork` has no cancellation gate of its own,
            // and the vote it would prove and broadcast could land with its shares stranded.
            if Task.isCancelled {
                await scheduler.finish(bundleIndex: task.bundleIndex)
                return .cancelled
            }
            // Every helper server has proved unreachable — a delivery that ended in
            // `noReachableVoteServers` empties the pool — so there is nowhere left to send shares
            // and proving further votes would only strand them. The check runs on the task just
            // handed out rather than before the wait for it: a lane parked in `next()` can be
            // woken long after the pool emptied, and a check taken before the park would describe
            // a world that is gone.
            if await context.serverPool.isExhausted {
                let remaining = await scheduler.drainRemaining()
                await scheduler.finish(bundleIndex: task.bundleIndex)
                await Self.abandonRemainingWork([task] + remaining, context: context, send: send)
                return .exhausted
            }
            let outcome = await Self.runVoteTask(task, context: context, send: send)
            await scheduler.finish(bundleIndex: task.bundleIndex)
            if outcome == .cancelled {
                return .cancelled
            }
        }
    }

    /// One `(bundle, question)` task, reported to the tracker whatever happens to it.
    ///
    /// A question this bundle cannot cast fails that question — once, however many bundles hit
    /// it — and the lane carries on with the next eligible task, which is the per-proposal
    /// `continue` the serial loop had.
    private static func runVoteTask(
        _ task: VoteTask,
        context: VoteBatchContext,
        send: Send<Action>
    ) async -> VoteTaskOutcome {
        let item = task.work
        do {
            let identity = try await Self.voteBundleWork(
                bundleIndex: task.bundleIndex,
                work: item,
                context: context,
                send: send
            )
            let resolution = await context.tracker.finishBundleTask(
                proposalId: item.proposalId,
                identity: identity
            )
            await Self.announceProposalResolution(resolution, context: context, send: send)
        } catch is CancellationError {
            // Not a failed vote, and not this lane's to report: the walk just ends.
            return .cancelled
        } catch {
            LoggerProxy.error("Batch vote failed for proposal \(item.proposalId) in bundle \(task.bundleIndex): \(error)")
            if await context.tracker.markFailed(proposalId: item.proposalId) {
                await send(.batchVoteFailed(
                    roundId: context.roundId,
                    proposalId: item.proposalId,
                    error: VotingErrorMapper.userFriendlyMessage(from: error)
                ))
            }
            let resolution = await context.tracker.finishBundleTask(
                proposalId: item.proposalId,
                identity: nil
            )
            await Self.announceProposalResolution(resolution, context: context, send: send)
        }
        return .completed
    }

    /// One `(bundle, question)` vote, end to end: prove it, broadcast it, wait for the chain to
    /// confirm it, write it back, and hand this bundle's tally shares to the delivery window.
    ///
    /// Returns the identity the delivery was enqueued under, so the caller can report the question
    /// submitted only once those shares are accepted.
    static func voteBundleWork(
        bundleIndex: UInt32,
        work: VoteBundleWork,
        context: VoteBatchContext,
        send: Send<Action>
    ) async throws -> VotingShareDeliveryIdentity {
        let roundId = context.roundId
        let proposalId = work.proposalId
        let votingCrypto = context.votingCrypto
        let votingAPI = context.votingAPI
        let trace = context.trace
        let traceContext = VotingSubmissionTrace.context(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId)

        await send(.voteSubmissionBundleStarted(roundId: roundId, bundleIndex: bundleIndex))
        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .preparingProof))

        // Crash recovery: if this bundle's TX already landed on-chain,
        // skip to share delegation rather than re-proving.
        if let recoveredDelivery = try await Self.tryRecoverInflightVote(
            roundId: roundId,
            bundleIndex: bundleIndex,
            proposalId: proposalId,
            choice: work.choice,
            submitAtDeadline: context.submitAtDeadline,
            serverPool: context.serverPool,
            deliveryWindow: context.deliveryWindow,
            votingCrypto: votingCrypto,
            votingAPI: votingAPI,
            send: send,
            roundIdAction: { roundId },
            trace: trace,
            timing: context.timing
        ) {
            return recoveredDelivery
        }

        // MOB-1930: the tree sync and the witness it anchors are one unit. The SDK's lock
        // serializes each of those FFI calls on its own but not the pair, so with two lanes a
        // sibling's sync landing between this sync and this witness is not a rare interleaving but
        // the steady state — and nothing in the crate's contract says the witness is rooted at the
        // `anchorHeight` we passed rather than at whatever the tree holds when it runs. Rather than
        // rely on a guarantee nobody has stated, the pair goes through a queue every lane
        // shares. Plain actor isolation would not do it: an actor is reentrant at every `await`
        // inside the pair, which is exactly where the sibling would slip in. Both calls are cheap
        // next to proving and chain waits, so the design loses nothing.
        let vanWitness = try await context.treeQueue.run {
            let anchorHeight = try await VotingSubmissionTrace.measure("sync", traceContext, totals: trace) {
                try await Self.syncVoteTree(
                    roundId: roundId,
                    chainNodeUrl: context.chainNodeUrl,
                    hotkeyStoredSecret: Data(context.hotkeySeed),
                    networkId: context.networkId,
                    votingCrypto: votingCrypto
                )
            }
            return try await VotingSubmissionTrace.measure("witness", traceContext, totals: trace) {
                try await votingCrypto.generateVanWitness(roundId, bundleIndex, anchorHeight)
            }
        }

        // The serialized region ends at the witness on purpose. `commitVote` takes the witness by
        // value (the auth path, position and anchor height below) and the Rust shim rebuilds it
        // from those arguments alone: `zcashlc_voting_commit_vote` in `rust/src/voting/vote.rs`
        // calls `VanWitness::from_wire` and never reads `handle.tree_sync`. Only the sync and
        // witness entry points in `rust/src/voting/tree.rs` and the two session-reset entry points
        // touch the shared tree client, so a sibling's sync landing between this witness and this
        // commit cannot change what gets committed. Keeping the commit outside the queue lets the
        // sibling lane sync and take its own witness while this one signs.
        let (builtBundle, castVoteSig) = try await VotingSubmissionTrace.measure("prove", traceContext, totals: trace) {
            try await votingCrypto.commitVote(
                roundId, bundleIndex, context.hotkeySeed, proposalId, work.choice,
                work.numOptions, 0, vanWitness.authPath, vanWitness.position, vanWitness.anchorHeight,
                context.singleShare
            )
        }

        // The pool can only be seen empty at a question boundary, so this question's proof was
        // unavoidable once the walk was past that check — the broadcast is not. A vote confirmed on
        // chain whose tally shares have nowhere to go leaves the voter with stranded shares for the
        // recovery lane to find; a proof nobody broadcasts costs only the CPU already spent. The
        // per-question catch reports this question failed and the next boundary ends the walk.
        if await context.serverPool.isExhausted {
            throw ShareDelegationError.noReachableVoteServers
        }

        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .confirming))
        // The check above spares the `.confirming` step; this one is the real gate. The broadcast
        // takes the transaction guard, and the guard is a queue: it can wait behind a helper
        // delivery for seconds, and that delivery may be the one that empties the pool. The API
        // runs this closure inside the guard right before each POST attempt.
        let serverPool = context.serverPool
        let txResult = try await VotingSubmissionTrace.measure("broadcast", traceContext, totals: trace) {
            try await votingAPI.submitVoteCommitment(builtBundle, castVoteSig) {
                if await serverPool.isExhausted {
                    throw ShareDelegationError.noReachableVoteServers
                }
            }
        }
        guard try await Self.isAcceptedVotingTransaction(txResult, votingAPI: votingAPI) else {
            throw VotingFlowError.voteCommitmentTxFailed(code: txResult.code, log: txResult.log)
        }
        try await votingCrypto.storeVoteTxHash(roundId, bundleIndex, proposalId, txResult.txHash)

        let acceptingServer = txResult.code == 0 ? txResult.acceptedByServerURL : nil
        let confirmStarted = context.timing.now()
        let voteConfirmation: TxConfirmation
        do {
            let pollResult = try await VotingTxConfirmationPoller.wait(
                preferredServerURL: acceptingServer,
                timeout: .seconds(90),
                clock: ContinuousClock()
            ) { preferredServer, remainingBudget in
                try await votingAPI.fetchTxConfirmation(txResult.txHash, preferredServer, remainingBudget)
            }
            let candidate = pollResult.confirmation
            guard let candidate, candidate.code == 0 else {
                throw VotingFlowError.voteCommitmentTxFailed(code: candidate?.code ?? 0, log: candidate?.log ?? "")
            }
            voteConfirmation = candidate
            let confirmMs = VotingSubmissionTrace.milliseconds(since: confirmStarted, until: context.timing.now())
            context.timing.sink(VotingSubmissionTrace.endLine(
                step: "confirm", context: traceContext, milliseconds: confirmMs, detail: "attempts=\(pollResult.attempts)"
            ))
            await trace.add("confirm", confirmMs)
        } catch {
            let confirmMs = VotingSubmissionTrace.milliseconds(since: confirmStarted, until: context.timing.now())
            context.timing.sink(VotingSubmissionTrace.failedLine(step: "confirm", context: traceContext, milliseconds: confirmMs, error: error))
            await trace.add("confirm", confirmMs)
            throw error
        }

        try await VotingSubmissionTrace.measure("record", traceContext, totals: trace) {
            try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId, txResult.txHash)
        }

        let eventsPayload: [[String: Any]] = voteConfirmation.events.map { event in
            [
                "type": event.type,
                "attributes": event.attributes.map { attribute in
                    ["key": attribute.key, "value": attribute.value]
                }
            ]
        }
        let eventsData = try JSONSerialization.data(withJSONObject: eventsPayload)
        let eventsJson = String(decoding: eventsData, as: UTF8.self)

        let confirmation = try await VotingSubmissionTrace.measure("record", traceContext, totals: trace) {
            try await votingCrypto.confirmVoteSubmission(
                roundId, bundleIndex, proposalId, txResult.txHash, eventsJson
            )
        }

        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .sendingShares))
        guard let stored = try await votingCrypto.getCommitmentBundleJson(roundId, bundleIndex, proposalId) else {
            throw VotingFlowError.missingVoteCommitmentBundle
        }
        // `zcash_voting::share::recover_payloads` (rc.5 `share.rs:148-160`) slices its
        // own encrypted-share list to the first element when the bundle is single-share.
        // Mirror that here, position-based (not a computed `0..<N` range), so we only
        // ever ask `recoverWireJson` for a share the crate can actually serve.
        let sharesToDelegate = context.singleShare
            ? Array(builtBundle.encShares.prefix(1))
            : builtBundle.encShares
        let identity = VotingShareDeliveryIdentity(
            roundId: roundId,
            bundleIndex: bundleIndex,
            proposalId: proposalId
        )
        try await Self.enqueueDelivery(
            into: context.deliveryWindow,
            identity: identity,
            bundleJson: stored.bundleJson,
            shareIndices: sharesToDelegate.map(\.shareIndex),
            voteCommitmentTreePosition: confirmation.voteCommitmentTreePosition,
            submitAtDeadline: context.submitAtDeadline,
            serverPool: context.serverPool,
            votingCrypto: votingCrypto,
            votingAPI: votingAPI,
            trace: trace,
            timing: context.timing
        )
        return identity
    }

    /// Release the tasks the lanes will never run, so that the questions they *did* cast can
    /// still be resolved.
    ///
    /// A question left half-cast this way is deliberately not reported at all: it stays an
    /// outstanding draft, which is what makes a batch that stopped early end in
    /// `.submissionFailed` rather than claiming a ballot it never finished.
    private static func abandonRemainingWork(
        _ tasks: [VoteTask],
        context: VoteBatchContext,
        send: Send<Action>
    ) async {
        for task in tasks {
            let resolution = await context.tracker.abandonBundleTask(proposalId: task.work.proposalId)
            await Self.announceProposalResolution(resolution, context: context, send: send)
        }
    }

    /// Tell the store what a resolved question means.
    ///
    /// `batchVoteFailed` is deliberately not sent from here: a failure goes out at the moment the
    /// bundle hits it, so the voter sees it without waiting for the other bundles to finish the
    /// question.
    private static func announceProposalResolution(
        _ resolution: VotingProposalCompletionTracker.Resolution?,
        context: VoteBatchContext,
        send: Send<Action>
    ) async {
        guard let resolution else { return }
        switch resolution.outcome {
        case .abandoned:
            return
        case .submitted:
            await send(.batchVoteSubmitted(
                roundId: context.roundId,
                proposalId: resolution.proposalId,
                choice: resolution.choice
            ))
        case .failed, .awaitingDelivery:
            break
        }
        // `ConfirmSubmissionView` renders this as "question `currentIndex + 1` of `totalCount`", so
        // the count of questions the walk has finished is clamped to the last one rather than
        // stepping past the end of the ballot while the deliveries drain.
        await send(.batchSubmissionProgress(
            roundId: context.roundId,
            currentIndex: min(resolution.advancedCount, max(context.totalCount - 1, 0)),
            totalCount: context.totalCount,
            proposalId: resolution.proposalId
        ))
    }

    // MARK: - Delegation pipeline (Zashi inline)

    /// 3.0 bump (MOB-1678): `pir_layout.poly_len` is load-bearing — `zcash_voting` 3.0
    /// validates it locally (`poly_len ∈ {2048, 4096}`) and the PIR connect handshake
    /// re-checks it against the server. A dynamic config without the field predates the
    /// 3.0 service, so every delegation entry point fails closed *before any FFI call*
    /// rather than fabricating a value. Reuses the existing localized
    /// `coinVote.configError.decodeFailed` copy — no new strings in this wave.
    static let missingPolyLenConfigError = VotingConfigError.decodeFailed(
        "pir_layout.poly_len is required for delegation"
    )

    /// Mirrors `Voting.runDelegationPipeline` but sends back to
    /// `VotingCoordFlow.Action`. The legacy version targets `Voting.Action`,
    /// so cross-type dispatching is the only reason we duplicate this here.
    // swiftlint:disable:next function_body_length function_parameter_count
    static func runDelegationPipeline(
        roundId: String,
        cachedNotes: [NoteInfo],
        bundleCount: UInt32,
        senderSeed: [UInt8],
        hotkeySeed: [UInt8],
        networkId: UInt32,
        accountIndex: UInt32,
        roundName: String,
        pirEndpoints: [String],
        expectedSnapshotHeight: UInt64,
        pirDepth: UInt32,
        tier0Layers: UInt32,
        tier1Layers: UInt32,
        polyLen: UInt32,
        delegationPrepared: Bool = false,
        seedFingerprint: Data? = nil,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        send: Send<Action>,
        delegationConfirmationTimeout: TimeInterval = 90,
        delegationConfirmationRetryDelay: Duration = .milliseconds(750)
    ) async throws {
        let noteChunks = cachedNotes.smartBundles().bundles
        guard Int(bundleCount) <= noteChunks.count else {
            throw VotingFlowError.inconsistentBundleSetup(
                bundleCount: bundleCount,
                noteChunkCount: noteChunks.count
            )
        }
        var completedBundles = Set<UInt32>()
        let delegationStarted = ContinuousClock().now
        let trace = VotingSubmissionTrace.Totals()
        for idx: UInt32 in 0..<bundleCount {
            // Single probe (timeout 0): a cached hash that never propagated —
            // an earlier attempt died before confirmation — must fall through
            // to a fresh delegation immediately instead of holding this
            // bundle's full confirmation budget. The fresh submission below
            // keeps the full `delegationConfirmationTimeout` wait.
            if let vanPosition = try await recoverDelegationVanPosition(
                roundId: roundId,
                bundleIndex: idx,
                votingCrypto: votingCrypto,
                votingAPI: votingAPI,
                confirmationTimeout: 0,
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
            let traceContext = VotingSubmissionTrace.context(roundId: roundId, bundleIndex: bundleIndex)

            let registration: DelegationRegistration
            // The cache probe is now two calls: signing succeeds once the bundle's PCZT setup
            // is stored, and the submission only assembles once its proof is too. Either one
            // failing means this bundle is not finished yet, so fall through and build it.
            let cachedSignature = try? await votingCrypto.signDelegationRequest(
                roundId, bundleIndex, senderSeed, hotkeySeed, networkId, accountIndex, roundName
            )
            let cachedRegistration: DelegationRegistration?
            if let cachedSignature {
                cachedRegistration = try? await votingCrypto.getDelegationSubmission(
                    roundId, bundleIndex, cachedSignature.signature, cachedSignature.sighash
                )
            } else {
                cachedRegistration = nil
            }

            if let cachedRegistration {
                LoggerProxy.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) using cached submission")
                registration = cachedRegistration
                // The interactive prover would have driven the authorization progress here; a
                // reused proof has none to report, so count the bundle as authorized instead of
                // leaving the Confirm screen at zero through the chain confirmation below.
                await send(.delegationProofProgress(
                    roundId: roundId,
                    progress: Double(bundleIndex + 1) / Double(bundleCount)
                ))
            } else {
                // Finding #10 (CHP.md): `zcash_voting` stores `pczt_sighash` write-once per
                // (round, wallet, bundle) and every `buildVotingPczt` samples fresh randomness,
                // so re-building over persisted setup can never reproduce the stored sighash —
                // the crate refuses with "refusing to overwrite pczt_sighash" and the bundle
                // wedges permanently. A successful `cachedSignature` probe proves the persisted
                // setup (sighash + alpha, bound to this seed's fingerprint) already exists, so
                // skip the build and let `buildAndProveDelegation` resume deterministically
                // from the stored randomness instead.
                if delegationPrepared || cachedSignature != nil {
                    LoggerProxy.debug(
                        "Delegation bundle \(bundleIndex + 1)/\(bundleCount) resuming persisted PCZT setup (precomputed: \(delegationPrepared))"
                    )
                } else {
                    let orchardFvk = try seedFingerprint.map { _ in
                        try votingCrypto.extractOrchardFvkFromUfvk(bundleNotes[0].ufvkStr, networkId)
                    }
                    try await VotingSubmissionTrace.measure("pczt", traceContext, totals: trace) {
                        _ = try await votingCrypto.buildVotingPczt(
                            roundId, bundleIndex, bundleNotes,
                            senderSeed, hotkeySeed, networkId, accountIndex, roundName,
                            orchardFvk, seedFingerprint
                        )
                    }
                }

                try await VotingSubmissionTrace.measure("prove", traceContext, totals: trace) {
                    for try await event in votingCrypto.buildAndProveDelegation(
                        roundId,
                        bundleIndex,
                        bundleNotes,
                        senderSeed,
                        hotkeySeed,
                        networkId,
                        accountIndex,
                        roundName,
                        pirEndpoints,
                        expectedSnapshotHeight,
                        pirDepth,
                        tier0Layers,
                        tier1Layers,
                        polyLen
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
                }

                let signed = try await VotingSubmissionTrace.measure("sign", traceContext, totals: trace) {
                    try await votingCrypto.signDelegationRequest(
                        roundId, bundleIndex, senderSeed, hotkeySeed, networkId, accountIndex, roundName
                    )
                }
                registration = try await VotingSubmissionTrace.measure("assemble", traceContext, totals: trace) {
                    try await votingCrypto.getDelegationSubmission(
                        roundId, bundleIndex, signed.signature, signed.sighash
                    )
                }
            }
            let delegTxResult = try await VotingSubmissionTrace.measure("broadcast", traceContext, totals: trace) {
                try await votingAPI.submitDelegation(registration)
            }
            guard try await isAcceptedVotingTransaction(delegTxResult, votingAPI: votingAPI) else {
                throw VotingFlowError.delegationTxFailed(code: delegTxResult.code, log: delegTxResult.log)
            }
            LoggerProxy.info("Delegation TX \(bundleIndex) submitted: \(delegTxResult.txHash)")

            try await votingCrypto.storeDelegationTxHash(roundId, bundleIndex, delegTxResult.txHash)

            let vanPosition = try await VotingSubmissionTrace.measure("confirm", traceContext, totals: trace) {
                try await requireDelegationVanPosition(
                    txHash: delegTxResult.txHash,
                    preferredServerURL: delegTxResult.code == 0 ? delegTxResult.acceptedByServerURL : nil,
                    votingAPI: votingAPI,
                    confirmationTimeout: delegationConfirmationTimeout,
                    retryDelay: delegationConfirmationRetryDelay
                )
            }
            try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanPosition)
            LoggerProxy.debug("VAN position stored for bundle \(bundleIndex): \(vanPosition)")
        }

        let stepTotals = await trace.summary(["pczt", "prove", "sign", "assemble", "broadcast", "confirm"], suffix: "WorkMs")
        VotingSubmissionTrace.info(
            """
            Voting delegation work summary \(VotingSubmissionTrace.context(roundId: roundId)) scope=delegationPipeline \
            bundles=\(bundleCount) delegationWallMs=\(VotingSubmissionTrace.milliseconds(since: delegationStarted)) \
            \(stepTotals)
            """
        )
        await send(.delegationProofCompleted(roundId: roundId))
    }

    /// Three-valued probe over a bundle's on-chain delegation-registration state.
    ///
    /// `.unknown` covers every inconclusive path — no locally cached TX hash, a network
    /// failure while asking, or a chain answer that arrived but couldn't be parsed — so
    /// that callers gate destructive recovery decisions on `.registered` / `.notRegistered`
    /// alone and never mistake "we couldn't tell" for "it isn't registered".
    static func probeDelegationRegistration(
        roundId: String,
        bundleIndex: UInt32,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        confirmationTimeout: TimeInterval,
        retryDelay: Duration
    ) async -> DelegationRegistrationProbe {
        guard case let .present(txHash) = try? await votingCrypto.getDelegationTxHash(roundId, bundleIndex) else {
            return .unknown
        }

        do {
            switch try await delegationTxConfirmationStatus(
                txHash: txHash,
                votingAPI: votingAPI,
                confirmationTimeout: confirmationTimeout,
                retryDelay: retryDelay
            ) {
            case let .confirmed(vanPosition):
                do {
                    try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanPosition)
                    return .registered(vanPosition: vanPosition)
                } catch {
                    // Registered on-chain but the local write failed — same net effect as an
                    // inconclusive check, since neither outcome can be trusted as conclusive.
                    return .unknown
                }

            case let .failed(code, log) where code != 0:
                LoggerProxy.warn(
                    "Cached delegation TX \(txHash) for bundle \(bundleIndex) is not reusable: code=\(code) log=\(log)"
                )
                return .notRegistered

            case .failed:
                // code == 0 (e.g. "missing delegate_vote leaf_index"): the chain call
                // succeeded but the response was unusable — the TX may well have landed.
                LoggerProxy.debug(
                    "Cached delegation TX \(txHash) for bundle \(bundleIndex) confirmation is unusable: missing leaf index"
                )
                return .unknown

            case .notFound:
                LoggerProxy.debug("Cached delegation TX \(txHash) for bundle \(bundleIndex) is not confirmed yet")
                return .unknown
            }
        } catch {
            return .unknown
        }
    }

    /// Decides what an interrupted round's local delegation state is worth on resume.
    ///
    /// Rows (in order): a confirmed on-chain registration wins outright and names exactly
    /// the bundles that are reusable; failing that, any local material — a saved Keystone
    /// signature or a delegation TX this device already broadcast — keeps the round's rows
    /// alive; only when neither holds is the round genuinely disposable.
    ///
    /// `.unknown` probes deliberately count for nothing on either side: they are "we
    /// couldn't tell", never "it isn't registered", so they can never be the reason
    /// alpha/rk/sighash rows are destroyed under a registration that may already exist.
    static func roundResumeDecision(
        probes: [UInt32: DelegationRegistrationProbe],
        savedSignatureCount: Int,
        anyLocalDelegationTxHash: Bool
    ) -> RoundResumeDecision {
        var recoveredIndices: Set<UInt32> = []
        for (bundleIndex, probe) in probes {
            if case .registered = probe {
                recoveredIndices.insert(bundleIndex)
            }
        }

        if !recoveredIndices.isEmpty {
            return .reuseRecovered(recoveredIndices: recoveredIndices)
        }

        if savedSignatureCount > 0 || anyLocalDelegationTxHash {
            return .resumeInPlace
        }

        return .freshRound
    }

    private static func recoverDelegationVanPosition(
        roundId: String,
        bundleIndex: UInt32,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        confirmationTimeout: TimeInterval = 90,
        retryDelay: Duration = .seconds(2)
    ) async throws -> UInt32? {
        switch await probeDelegationRegistration(
            roundId: roundId,
            bundleIndex: bundleIndex,
            votingCrypto: votingCrypto,
            votingAPI: votingAPI,
            confirmationTimeout: confirmationTimeout,
            retryDelay: retryDelay
        ) {
        case let .registered(vanPosition):
            return vanPosition

        case .notRegistered, .unknown:
            return nil
        }
    }

    private static func requireDelegationVanPosition(
        txHash: String,
        preferredServerURL: String? = nil,
        votingAPI: VotingAPIClient,
        confirmationTimeout: TimeInterval = 90,
        retryDelay: Duration = .milliseconds(750)
    ) async throws -> UInt32 {
        switch try await delegationTxConfirmationStatus(
            txHash: txHash,
            preferredServerURL: preferredServerURL,
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
        preferredServerURL: String? = nil,
        votingAPI: VotingAPIClient,
        confirmationTimeout: TimeInterval = 90,
        retryDelay: Duration = .milliseconds(750)
    ) async throws -> DelegationTxConfirmationStatus {
        let confirmation: TxConfirmation?
        if confirmationTimeout <= 0 {
            do {
                confirmation = try await votingAPI.fetchTxConfirmation(txHash, preferredServerURL, nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                confirmation = nil
            }
        } else {
            let pollResult = try await VotingTxConfirmationPoller.wait(
                preferredServerURL: preferredServerURL,
                timeout: .seconds(confirmationTimeout),
                retryDelay: retryDelay,
                clock: ContinuousClock()
            ) { preferredServer, remainingBudget in
                try await votingAPI.fetchTxConfirmation(txHash, preferredServer, remainingBudget)
            }
            confirmation = pollResult.confirmation
        }

        guard let confirmation else {
            return .notFound
        }
        guard confirmation.code == 0 else {
            return .failed(code: confirmation.code, log: confirmation.log)
        }
        guard let vanPosition = delegationVanPosition(from: confirmation) else {
            return .failed(code: 0, log: "missing or unrecoverable delegate_vote leaf_index")
        }
        return .confirmed(vanPosition: vanPosition)
    }
}

// MARK: - Serial execution (MOB-1930)

/// Runs `async` operations strictly one after another, in the order `run` was called.
///
/// This exists because **actor isolation is not serialization**. An actor guarantees that only one
/// task touches its state at a time, but it is reentrant at every `await`: the moment an isolated
/// method suspends, another call gets in. So an actor cannot keep two `await`s of one caller
/// adjacent — which is exactly what a vote-tree sync and the witness anchored on it need.
///
/// Each `run` chains on the task the previous one left behind, so a second operation cannot start
/// before the first has finished, however many times either suspends. An operation that throws does
/// not break the chain: the link the next caller waits on absorbs the error, and only the caller
/// that submitted the failing operation sees it.
///
/// The wait is not cancellable. A caller cancelled while it is queued still waits for the
/// operations ahead of it and then for its own before it can notice the cancellation at its next
/// check, so with two lanes the extra wait is at most one sibling's sync and witness; raising
/// `maxConcurrentVoteLanes` raises it accordingly. That is also what keeps a queued operation
/// from outliving the batch effect: every caller awaits its own operation to completion, and the
/// effect awaits every lane.
actor VotingSerialQueue {
    private var last: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = last
        // `Task.init`, not `Task.detached`: the operation has to inherit the caller's task-local
        // values, because `syncVoteTree` resolves a `@Dependency` inside it and the tests rely on
        // their overrides reaching that lookup.
        let task = Task<T, Error> {
            _ = await previous?.value
            return try await operation()
        }
        last = Task { _ = try? await task.value }
        return try await task.value
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

// MARK: - Ballot completion tracking (MOB-1930)

/// Decides when a question of the ballot is done, now that its bundles are cast by concurrent
/// lanes rather than one after another.
///
/// Each question starts owing one task per bundle that still has to cast it. A lane reports
/// every task as it ends, and only the task that brings a question's count to zero resolves it:
///
/// - any bundle failed it → the question failed. The failure itself is reported the moment a
///   bundle hits it, by that lane, and only by the first one to do so;
/// - no delivery is outstanding → it is submitted right away (every bundle was already done, or
///   it was a synthetic abstain);
/// - otherwise it joins the list handed to `settleDeliveries`, which reports it once its shares
///   are accepted — the MOB-1928 rule, unchanged;
/// - a bundle abandoned it, because the lanes stopped before reaching it → nothing is reported. It stays
///   an outstanding draft, so a batch that stopped early ends in `.submissionFailed` rather than
///   claiming a ballot it never finished.
actor VotingProposalCompletionTracker {
    /// A question the walk has finished with.
    struct Resolution: Sendable {
        let proposalId: UInt32
        let choice: VoteChoice
        let outcome: Outcome
        /// How many questions the walk has resolved, this one included — the progress index.
        let advancedCount: Int

        enum Outcome: Sendable {
            case submitted
            case failed
            case awaitingDelivery
            case abandoned
        }
    }

    private struct Entry {
        let choice: VoteChoice
        var remaining: Int
        var hasFailed = false
        var wasAbandoned = false
        var identities: [VotingShareDeliveryIdentity] = []
    }

    private var entries: [UInt32: Entry] = [:]
    private let order: [UInt32]
    private var advancedCount = 0
    private var successCount = 0
    private var failCount = 0
    private var awaiting: [VotingCoordFlow.AwaitingShareDelivery] = []

    init(proposals: [VotingCoordFlow.VoteProposalPlan]) {
        var entries: [UInt32: Entry] = [:]
        for proposal in proposals {
            entries[proposal.proposalId] = Entry(
                choice: proposal.choice,
                remaining: proposal.bundleTaskCount
            )
        }
        self.entries = entries
        self.order = proposals.map(\.proposalId)
    }

    /// The questions that carried no bundle work at all, resolved in ballot order.
    func resolveProposalsWithoutWork() -> [Resolution] {
        let proposalIds = order
        return proposalIds.compactMap { proposalId in
            guard let remaining = entries[proposalId]?.remaining, remaining <= 0 else { return nil }
            return resolve(proposalId)
        }
    }

    /// Records that a bundle could not cast this question. Returns `true` only for the first
    /// bundle to fail it, so the voter is told once however many bundles hit the same question.
    func markFailed(proposalId: UInt32) -> Bool {
        guard var entry = entries[proposalId], !entry.hasFailed else { return false }
        entry.hasFailed = true
        entries[proposalId] = entry
        return true
    }

    /// One bundle task ended. `identity` is the delivery it handed to the window, or `nil` when
    /// the bundle failed the question.
    func finishBundleTask(proposalId: UInt32, identity: VotingShareDeliveryIdentity?) -> Resolution? {
        guard var entry = entries[proposalId] else { return nil }
        if let identity {
            entry.identities.append(identity)
        }
        entry.remaining -= 1
        entries[proposalId] = entry
        guard entry.remaining <= 0 else { return nil }
        return resolve(proposalId)
    }

    /// One bundle task will never run, because the lanes stopped before reaching it.
    func abandonBundleTask(proposalId: UInt32) -> Resolution? {
        guard var entry = entries[proposalId] else { return nil }
        entry.wasAbandoned = true
        entry.remaining -= 1
        entries[proposalId] = entry
        guard entry.remaining <= 0 else { return nil }
        return resolve(proposalId)
    }

    /// The questions every bundle has cast and whose tally shares are still travelling.
    func awaitingDeliveries() -> [VotingCoordFlow.AwaitingShareDelivery] {
        awaiting
    }

    /// What the walk itself decided, before `settleDeliveries` adds the deliveries' verdicts.
    func tallies() -> (successCount: Int, failCount: Int) {
        (successCount, failCount)
    }

    private func resolve(_ proposalId: UInt32) -> Resolution? {
        guard let entry = entries.removeValue(forKey: proposalId) else { return nil }

        // A failure outranks an abandonment: the voter was already told this question failed, so
        // it has to be counted, not quietly dropped.
        if entry.hasFailed {
            failCount += 1
            advancedCount += 1
            return Resolution(
                proposalId: proposalId,
                choice: entry.choice,
                outcome: .failed,
                advancedCount: advancedCount
            )
        }
        if entry.wasAbandoned {
            // Neither submitted nor failed — left in the drafts the batch could not get to. If
            // other bundles did cast it before the stop, their deliveries still go to
            // `settleDeliveries`: they carry on-chain votes whose shares may have gone nowhere,
            // and `isFullyCast: false` is what stops that settlement claiming the question was
            // submitted when they all arrive.
            if !entry.identities.isEmpty {
                awaiting.append(VotingCoordFlow.AwaitingShareDelivery(
                    proposalId: proposalId,
                    choice: entry.choice,
                    identities: entry.identities,
                    isFullyCast: false
                ))
            }
            return Resolution(
                proposalId: proposalId,
                choice: entry.choice,
                outcome: .abandoned,
                advancedCount: advancedCount
            )
        }

        advancedCount += 1
        guard !entry.identities.isEmpty else {
            successCount += 1
            return Resolution(
                proposalId: proposalId,
                choice: entry.choice,
                outcome: .submitted,
                advancedCount: advancedCount
            )
        }
        awaiting.append(VotingCoordFlow.AwaitingShareDelivery(
            proposalId: proposalId,
            choice: entry.choice,
            identities: entry.identities
        ))
        return Resolution(
            proposalId: proposalId,
            choice: entry.choice,
            outcome: .awaitingDelivery,
            advancedCount: advancedCount
        )
    }
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

// MARK: - Delegation registration probe

/// Outcome of `VotingCoordFlow.probeDelegationRegistration`. `.unknown` means the check
/// was inconclusive — no locally cached TX hash, a network failure, or an unusable chain
/// answer — and must never be treated as evidence that the bundle is not registered.
enum DelegationRegistrationProbe: Equatable, Sendable {
    case registered(vanPosition: UInt32)
    case notRegistered
    case unknown
}

// MARK: - Round resume decision

/// What an interrupted round's local delegation state is worth when the pipeline re-enters
/// it. `.freshRound` is reached only when no probe found a registration and nothing local
/// hints that one might exist; it clears the recovery state and adopts any bundle rows that
/// already exist instead of rebuilding them.
enum RoundResumeDecision: Equatable, Sendable {
    /// At least one bundle is confirmed registered on-chain — reuse exactly those.
    case reuseRecovered(recoveredIndices: Set<UInt32>)
    /// Nothing conclusive either way, but there is local material worth keeping: stay on
    /// the existing rows and clear only the per-session leftovers.
    case resumeInPlace
    /// Nothing recoverable — safe to rebuild the round from scratch.
    case freshRound
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
#endif

extension VotingCoordFlow {
    /// The message shown when the round pipeline fails.
    ///
    /// Everything except an incomplete delegation setup keeps the existing
    /// mapping. That one case gets `DelegationDiagnosis` instead, because it
    /// is the case where the old single message was not merely vague but
    /// wrong: it told the voter to leave the poll and enter it again, and
    /// re-entering is what used to call `clear_round`. Which of several
    /// states they are actually in decides whether that advice is safe, and
    /// only the round's own state separates them.
    ///
    /// `voteServiceAnswered: false` is literal here rather than pessimistic.
    /// This path fails on a local database read, so no check with the voting
    /// service has been made, and "not asked" and "asked and got nothing" are
    /// the same evidence: none. The diagnosis therefore never reports that
    /// rebuilding is safe from here, which is the intended direction to err.
    static func pipelineFailureMessage(
        error: Error,
        roundId: String,
        crypto: VotingCryptoClient
    ) async -> String {
        guard VotingErrorMapper.isIncompleteDelegationSetup(error.localizedDescription) else {
            return VotingErrorMapper.userFriendlyMessage(from: error)
        }

        // The only recovery-aware line in the message path, and the only one
        // that has to disappear with the recovery code. Without it the
        // diagnosis simply never reports `secretsRecovered`, which is the
        // truth once nothing is recovering anything.
        @Dependency(\.delegationRestore) var delegationRestore // VotingRecovery
        let escrowHoldsRecoveredSecrets = await delegationRestore.holdsRecoveredSecrets(roundId)

        let diagnosis = await DelegationDiagnosis.forRound(
            roundId,
            voteServiceAnswered: false,
            escrowHoldsRecoveredSecrets: escrowHoldsRecoveredSecrets,
            crypto: crypto
        )
        LoggerProxy.info("[poll-diagnosis] round=\(roundId) diagnosis=\(diagnosis.rawValue)")
        return diagnosis.message
    }
}

extension VotingCoordFlow {
    /// `syncVoteTree`, with one side effect on failure: when the chain
    /// refuses a leaf that a restore put back, the escrow candidate it came
    /// from is marked so the next restore tries the next-best one. The hotkey
    /// lets the same candidate the restore offered be found again.
    static func syncVoteTree(
        roundId: String,
        chainNodeUrl: String,
        hotkeyStoredSecret: Data,
        networkId: UInt32,
        votingCrypto: VotingCryptoClient
    ) async throws -> UInt32 {
        do {
            return try await votingCrypto.syncVoteTree(roundId, chainNodeUrl)
        } catch {
            @Dependency(\.delegationRestore) var delegationRestore // VotingRecovery
            _ = await delegationRestore.noteChainRefusal(roundId, error, hotkeyStoredSecret, networkId)
            throw error
        }
    }
}

extension VotingCoordFlow {
    /// VotingRecovery: exports the hotkey the restore recomputes commitments
    /// with, and hands the round to the module. Delete with the package.
    static func restoreRecoveredDelegation(
        roundId: String,
        session: VotingSession,
        networkId: UInt32,
        accountId: AccountUUID?,
        walletStorage: WalletStorageClient
    ) async -> DelegationRestore.Outcome {
        @Dependency(\.delegationRestore) var delegationRestore
        let hotkeySecret = accountId
            .flatMap { try? walletStorage.exportVotingHotkey($0) }?
            .storedSecret.value()
        return await delegationRestore.restoreIfNeeded(
            roundId,
            RoundParameters(
                voteRoundId: session.voteRoundId,
                snapshotHeight: session.snapshotHeight,
                eaPK: session.eaPK,
                ncRoot: session.ncRoot,
                nullifierIMTRoot: session.nullifierIMTRoot
            ),
            networkId,
            hotkeySecret
        )
    }
}
