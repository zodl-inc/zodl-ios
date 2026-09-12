#if VOTING_ENABLED
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
                state.pendingPipelineRoundId = nil
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
                    .cancel(id: cancelRunRetryId),
                    .cancel(id: cancelStatusPollingId),
                    .cancel(id: cancelNewRoundPollingId),
                    .cancel(id: cancelShareTrackingId),
                    // A round session holds a database handle and, on the Tor
                    // route, its own isolated client. Leaving the flow is where
                    // those go back.
                    .run { [votingCrypto] _ in await votingCrypto.closeAllRoundSessions() }
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
                            loadSubmittedVotesFromPlan(state, roundId: roundId)
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
                            loadSubmittedVotesFromPlan(state, roundId: roundId)
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
                        loadSubmittedVotesFromPlan(state, roundId: roundId)
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
                        loadSubmittedVotesFromPlan(state, roundId: roundId)
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
                    loadSubmittedVotesFromPlan(state, roundId: roundId)
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

            case let .delegationPrecomputeCompleted(roundId):
                // Every bundle the plan named has answered, or has failed and
                // been recorded. Either way the warm-up is over; Confirm never
                // waits on it, so there is nothing to resume here.
                mutateSession(&state, roundId: roundId) { roundSession in
                    roundSession.delegationPrecomputeStatus = .ready
                    roundSession.isDelegationPrecomputeInFlight = false
                }
                return .none

            case let .delegationPrecomputeFailed(roundId, error):
                let message = VotingErrorMapper.userFriendlyMessage(from: error)
                mutateSession(&state, roundId: roundId) { roundSession in
                    roundSession.delegationPrecomputeStatus = .failed(message)
                    roundSession.isDelegationPrecomputeInFlight = false
                }
                return .none

            case let .roundSessionOpened(roundId, plan):
                return reduceRoundSessionOpened(&state, roundId: roundId, plan: plan)

            case let .roundSessionOpenFailed(roundId, error):
                LoggerProxy.error("Opening the round session for \(roundId) failed: \(error.message)")
                return .send(.pipelineFailed(
                    roundId: roundId,
                    message: VotingErrorMapper.userFriendlyMessage(from: error)
                ))

            case let .bundlesSetUp(roundId, layout):
                return reduceBundlesSetUp(&state, roundId: roundId, layout: layout)

            case let .bundleSetupFailed(roundId, error):
                return reduceBundleSetupFailed(&state, roundId: roundId, error: error)

            case let .precomputeProofEvent(roundId, bundleIndex, event):
                return reducePrecomputeProofEvent(
                    &state,
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    event: event
                )

            case let .precomputeProofFailed(roundId, bundleIndex, error):
                // A warm-up that failed costs that bundle a cold start and
                // nothing else: the run proves it again itself.
                LoggerProxy.warn("Delegation precompute for bundle \(bundleIndex) failed: \(error.message)")
                mutateSession(&state, roundId: roundId) { roundSession in
                    roundSession.progress.lastMessage = VotingErrorMapper.userFriendlyMessage(from: error)
                }
                return .none

            case let .roundRunEvent(roundId, epoch, event):
                return reduceRoundRunEvent(&state, roundId: roundId, epoch: epoch, event: event)

            case let .roundRunFailed(roundId, epoch, error):
                return reduceRoundRunFailed(&state, roundId: roundId, epoch: epoch, error: error)

            case let .roundRunDecision(roundId, decision):
                return reduceRoundRunDecision(&state, roundId: roundId, decision: decision)

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
                return reduceStartActiveRoundPipeline(&state, roundId: roundId)

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

            case let .votingWeightLoaded(roundId, weight, bundleCount):
                applyBundleTotals(&state, roundId: roundId, weight: weight, bundleCount: bundleCount)
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
                state.pendingPipelineRoundId = nil
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
                return .run { send in
                    let delegations = try await VotingLegacy.getShareDelegations(roundId)
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

    // MARK: - Round session

    /// How many times a round's run is re-scheduled after stopping with work
    /// still to do. A backoff the voter cannot see is indistinguishable from
    /// the app doing nothing, so it is bounded and then reported.
    static let maxRunRetries = 3

    /// The crate takes at most this many chain endpoints and vote-tree nodes.
    static let maxSessionChainEndpoints = 8

    /// `.startActiveRoundPipeline` handler. Opens the round's session and asks
    /// it what the round owes.
    ///
    /// Always a fresh open, never a reuse: the route and the session epoch are
    /// fixed when a session is opened, and the registry closes the round's
    /// previous session first, so re-entering a round is how the two are
    /// allowed to change.
    func reduceStartActiveRoundPipeline(_ state: inout State, roundId: String) -> Effect<Action> {
        guard let item = state.allRounds.first(where: { $0.id == roundId }),
              item.session.status == .active
        else { return .none }
        // One open at a time per round. Two concurrent opens carry two epochs,
        // which is the one thing the registry's single-flight cannot join, so a
        // second tap while the first is still opening is ignored rather than
        // raced.
        guard state.pendingPipelineRoundId != roundId else { return .none }
        guard let serviceConfig = state.serviceConfig,
              let account = state.selectedWalletAccount
        else {
            LoggerProxy.error("Voting config or selected account missing; cannot open a round session")
            return .none
        }
        // Fail closed before the FFI on a config the session cannot be opened
        // on: no endpoints to reach, or a PIR geometry this build predates.
        guard let transport = VotingSessionTransport(serviceConfig: serviceConfig) else {
            LoggerProxy.error("Round session refused: the config names no endpoints or no pir_layout.poly_len")
            return .send(.pipelineFailed(
                roundId: roundId,
                message: String(localizable: .coinVoteStoreUserErrorPirEndpointsMissing)
            ))
        }

        let votingSession = item.session
        let snapshotHeight = votingSession.snapshotHeight
        let network = zcashSDKEnvironment.network()
        let networkId: UInt32 = network.networkType.votingRustNetworkId
        let walletDbPath = databaseFiles.dataDbURLFor(network).path
        let accountId = account.id
        let roster = votingSession.proposals.map { proposal in
            VotingProposalRosterEntry(proposalId: proposal.id, numOptions: UInt32(proposal.options.count))
        }
        // Tor for the session's chain and helper traffic whenever the wallet
        // asked for it, and it fails closed: a voter who chose Tor is never
        // silently announced over a plain connection.
        let route = state.swapAPIAccess == .protected
            ? VotingTransportRoute.tor
            : VotingTransportRoute.direct

        state.votingSessionEpoch += 1
        let epoch = state.votingSessionEpoch
        var roundSession = state.roundCache[roundId] ?? RoundSession(roundId: roundId)
        roundSession.sessionEpoch = epoch
        roundSession.didAttemptBundleSetup = false
        roundSession.runRetryCount = 0
        roundSession.lastRunFailureSummary = nil
        roundSession.progress = VotingRoundProgressSnapshot()
        roundSession.precomputeStatus.removeAll()
        roundSession.delegationPrecomputeStatus = .notStarted
        roundSession.isDelegationPrecomputeInFlight = false
        state.roundCache[roundId] = roundSession
        state.pendingPipelineRoundId = roundId
        state.ineligibleSheet = nil
        state.walletSyncingSheetRoundId = nil

        return .run { [sdkSynchronizer, votingCrypto, walletStorage] send in
            // 1. Wallet sync gate.
            //
            // Spend-before-Sync scans head-first and birthday-first in
            // parallel, so a `latestScannedHeight` past the snapshot does not
            // mean the snapshot itself was scanned. Only the contiguous
            // `fullyScannedHeight` says that. The synchronizer may report 0
            // briefly on cold start before it hydrates state — retry a few
            // times.
            var walletScannedHeight = UInt64(sdkSynchronizer.latestState().fullyScannedHeight)
            if walletScannedHeight == 0 {
                for _ in 0..<5 {
                    try await Task.sleep(for: .seconds(1))
                    walletScannedHeight = UInt64(sdkSynchronizer.latestState().fullyScannedHeight)
                    if walletScannedHeight > 0 {
                        break
                    }
                }
            }
            if walletScannedHeight < snapshotHeight {
                await send(.walletNotSynced(
                    roundId: roundId,
                    scannedHeight: walletScannedHeight,
                    snapshotHeight: snapshotHeight
                ))
                return
            }

            // 2. The voting hotkey. App-owned random material, not a seed
            // derivation: it is generated once per account and persisted,
            // because it cannot be recovered from the wallet seed.
            let hotkeySecret: Data
            if let stored = try? walletStorage.exportVotingHotkey(accountId) {
                hotkeySecret = stored.storedSecret.value()
            } else {
                let hotkey = try await votingCrypto.generateHotkey(networkId)
                hotkeySecret = Data(hotkey.storedSecret)
                try walletStorage.importVotingHotkey(hotkeySecret, accountId)
            }

            // 3. Open the session on the round's own parameters and the anchor
            // the wallet's notes are proved against.
            let inputs = Self.sessionInputs(
                votingSession: votingSession,
                transport: transport,
                accountUUID: accountId.votingUUIDString,
                walletDbPath: walletDbPath,
                anchorTreeState: try await sdkSynchronizer.getTreeState(snapshotHeight)
            )
            try await votingCrypto.openRoundSession(
                inputs,
                VotingSessionBinding(roster: roster, hotkeySecret: hotkeySecret),
                route,
                epoch
            )

            let plan = try await votingCrypto.sessionPlan(roundId)
            if !plan.needsBundleSetup {
                // The bundles already exist, so no layout will answer with
                // their weight. Ask for it directly rather than showing the
                // voter a round worth nothing.
                if let report = try? await votingCrypto.eligibility(roundId) {
                    await send(.votingWeightLoaded(
                        roundId: roundId,
                        weight: report.eligibleWeight,
                        bundleCount: UInt32(plan.delegationStatuses.count)
                    ))
                }
            }
            await send(.roundSessionOpened(roundId: roundId, plan: plan))
        } catch: { error, send in
            LoggerProxy.error("Opening the round session failed: \(error)")
            await send(.roundSessionOpenFailed(roundId: roundId, error: Self.votingError(from: error)))
        }
        .cancellable(id: cancelPipelineId, cancelInFlight: true)
    }

    /// The inputs a round session lives on.
    ///
    /// Chain and vote-tree traffic go to the first few configured servers
    /// because the crate polls each of them; helper traffic goes to all of
    /// them, since a share may be delivered anywhere.
    static func sessionInputs(
        votingSession: VotingSession,
        transport: VotingSessionTransport,
        accountUUID: String,
        walletDbPath: String,
        anchorTreeState: Data
    ) -> VotingSessionInputs {
        let chainEndpoints = Array(transport.voteServerURLs.prefix(Self.maxSessionChainEndpoints))
        return VotingSessionInputs(
            accountUUID: accountUUID,
            walletDbPath: walletDbPath,
            roundParams: VotingRoundParameters(
                voteRoundId: votingSession.voteRoundId.hexString,
                snapshotHeight: votingSession.snapshotHeight,
                eaPk: votingSession.eaPK,
                ncRoot: votingSession.ncRoot,
                nullifierImtRoot: votingSession.nullifierIMTRoot
            ),
            roundName: votingSession.title,
            anchorTreeState: anchorTreeState,
            chainEndpoints: chainEndpoints,
            voteTreeNodeUrls: chainEndpoints,
            helperUrls: transport.voteServerURLs,
            pirEndpoints: transport.pirEndpointURLs,
            pirLayout: transport.pirLayout,
            ceremonyStartSeconds: Self.authenticatedSeconds(votingSession.ceremonyStart),
            voteEndTimeSeconds: Self.authenticatedSeconds(votingSession.voteEndTime)
        )
    }

    /// Round timing the session can rely on, or nothing.
    ///
    /// A round the authenticator could not vouch for carries the epoch-0
    /// default here, and passing that on as a real time would tell the crate
    /// the vote ended in 1970.
    static func authenticatedSeconds(_ date: Date) -> UInt64? {
        let seconds = date.timeIntervalSince1970
        guard seconds > 0 else { return nil }
        return UInt64(seconds)
    }

    /// `.roundSessionOpened` handler. Stores the plan and either persists the
    /// round's bundle rows or moves on to the ballot.
    func reduceRoundSessionOpened(_ state: inout State, roundId: String, plan: VotingRoundPlan) -> Effect<Action> {
        if state.pendingPipelineRoundId == roundId {
            state.pendingPipelineRoundId = nil
        }
        var session = state.roundCache[roundId] ?? RoundSession(roundId: roundId)
        session.roundPlan = plan
        // The session binds the hotkey as it opens, so reaching here is the
        // proof this round has one. The address itself is not read back from
        // the keychain, so it stays empty — as it did before the session.
        if session.hotkeyAddress == nil {
            session.hotkeyAddress = ""
        }
        if !plan.delegationStatuses.isEmpty {
            session.bundleCount = UInt32(plan.delegationStatuses.count)
            if session.eligibleBundleCount == 0 {
                session.eligibleBundleCount = session.bundleCount
            }
        }
        state.roundCache[roundId] = session

        if plan.needsBundleSetup {
            guard !session.didAttemptBundleSetup else {
                // A plan that still wants bundle rows after one setup answered
                // is a disagreement with the sidecar, not a step to repeat.
                LoggerProxy.error("Round \(roundId) still needs bundle setup after one was persisted")
                return .send(.pipelineFailed(
                    roundId: roundId,
                    message: String(localizable: .coinVoteSubmissionGenericBatchFailure)
                ))
            }
            state.roundCache[roundId]?.didAttemptBundleSetup = true
            return .run { [votingCrypto] send in
                let layout = try await votingCrypto.setupBundles(roundId)
                await send(.bundlesSetUp(roundId: roundId, layout: layout))
            } catch: { error, send in
                await send(.bundleSetupFailed(roundId: roundId, error: Self.votingError(from: error)))
            }
            .cancellable(id: cancelPipelineId)
        }

        return .merge(
            .send(.earlyEligibilityConfirmed(roundId: roundId)),
            submittedVotesEffect(plan: plan, roundId: roundId),
            .send(.maybeStartDelegationPrecompute(roundId: roundId))
        )
    }

    /// `.bundlesSetUp` handler. The layout is the round's voting power; the
    /// refreshed plan is what it owes now that the rows exist.
    func reduceBundlesSetUp(_ state: inout State, roundId: String, layout: VotingBundleLayout) -> Effect<Action> {
        applyBundleTotals(&state, roundId: roundId, weight: layout.eligibleWeight, bundleCount: layout.bundleCount)
        if layout.privacyTrimDroppedBundles > 0 {
            let bundles = layout.privacyTrimDroppedBundles
            let notes = layout.privacyTrimDroppedNotes
            LoggerProxy.info("Round \(roundId): privacy trim dropped \(bundles) bundles, \(notes) notes")
        }
        return .merge(
            // Eligibility is proven the moment bundles exist, so hand
            // navigation off now rather than holding the polls list.
            .send(.earlyEligibilityConfirmed(roundId: roundId)),
            .run { [votingCrypto] send in
                let plan = try await votingCrypto.sessionPlan(roundId)
                await send(.roundSessionOpened(roundId: roundId, plan: plan))
            } catch: { error, send in
                await send(.roundSessionOpenFailed(roundId: roundId, error: Self.votingError(from: error)))
            }
            .cancellable(id: cancelPipelineId)
        )
    }

    /// `.bundleSetupFailed` handler. A wallet the crate will not bundle for is
    /// not an error screen: it is the polls list with the sheet that explains
    /// why this round is closed to it.
    func reduceBundleSetupFailed(_ state: inout State, roundId: String, error: VotingError) -> Effect<Action> {
        switch error.kind {
        case .noSpendableNotes, .insufficientEligibility:
            return .send(.ineligibleForRound(roundId: roundId, heldZatoshi: 0))
        default:
            LoggerProxy.error("Bundle setup for \(roundId) failed: \(error.message)")
            return .send(.pipelineFailed(
                roundId: roundId,
                message: VotingErrorMapper.userFriendlyMessage(from: error)
            ))
        }
    }

    /// `.precomputeProofEvent` handler. Progress is narration; the status is
    /// the answer, and it is what keeps a second precompute off this bundle.
    func reducePrecomputeProofEvent(
        _ state: inout State,
        roundId: String,
        bundleIndex: UInt32,
        event: VotingDelegationProofEvent
    ) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { roundSession in
            switch event {
            case .progress(let progress):
                roundSession.progress.apply(progress)
            case .finished(let status):
                roundSession.precomputeStatus[bundleIndex] = status
            }
        }
        return .none
    }

    /// `.roundRunEvent` handler. Folds one element of a run's stream into the
    /// round, and hands the report to the host decision when the run stops.
    func reduceRoundRunEvent(
        _ state: inout State,
        roundId: String,
        epoch: UInt64,
        event: VotingRoundRunEvent
    ) -> Effect<Action> {
        // An element from a session that has since been replaced describes a
        // round state that no longer exists; writing it back would undo newer
        // state rather than add to it.
        guard let session = state.roundCache[roundId], session.sessionEpoch == epoch else { return .none }

        switch event {
        case .event(let driveEvent):
            mutateSession(&state, roundId: roundId) { roundSession in
                roundSession.progress.apply(driveEvent)
                if let plan = driveEvent.plan {
                    roundSession.roundPlan = plan
                }
                // A run overlaps bundles, so an event that names no proposal
                // leaves the last named one on screen rather than blanking it.
                if let proposalId = driveEvent.progress?.proposalId ?? driveEvent.step?.proposalId {
                    roundSession.submittingProposalId = proposalId
                }
                Self.applySubmissionProgress(&roundSession)
            }
            return .none

        case .finished(let report):
            var updated = session
            updated.isSubmittingVote = false
            // The report is authoritative where the stream is a best-effort
            // narration the SDK may drop, so the run's own tally replaces
            // whatever the stream managed to deliver.
            updated.progress.completedProposals = report.tally.completedProposals
            updated.progress.totalProposals = report.tally.totalProposals
            updated.progress.stage = .done
            updated.progress.proofFraction = nil
            if let plan = report.plan {
                updated.roundPlan = plan
                if !plan.delegationStatuses.isEmpty {
                    updated.bundleCount = UInt32(plan.delegationStatuses.count)
                }
            }
            updated.lastRunFailureSummary = Self.partialFailureSummary(report)
            state.roundCache[roundId] = updated

            let decision = VotingRoundHostDecision.decide(report)
            let votes = report.plan.map(Self.submittedVotes(from:)) ?? [:]
            guard !votes.isEmpty else {
                return .send(.roundRunDecision(roundId: roundId, decision: decision))
            }
            // Sequenced, not merged: the decision counts what the round has
            // cast, so the cast votes have to land first.
            return .concatenate(
                .send(.submittedVotesLoaded(roundId: roundId, votes: votes)),
                .send(.roundRunDecision(roundId: roundId, decision: decision))
            )
        }
    }

    /// `.roundRunFailed` handler. The driver itself does not fail — a throw is
    /// the call around it: a session that is closed or already driving, or a
    /// signer this host could not build.
    func reduceRoundRunFailed(
        _ state: inout State,
        roundId: String,
        epoch: UInt64,
        error: VotingError
    ) -> Effect<Action> {
        guard state.roundCache[roundId]?.sessionEpoch == epoch else { return .none }
        LoggerProxy.error("Round run for \(roundId) failed: \(error.message)")
        return .send(.batchAuthorizationFailed(
            roundId: roundId,
            error: VotingErrorMapper.userFriendlyMessage(from: error)
        ))
    }

    /// `.roundRunDecision` handler. One branch per thing a stopped run can
    /// leave the host owing.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func reduceRoundRunDecision(
        _ state: inout State,
        roundId: String,
        decision: VotingRoundHostDecision
    ) -> Effect<Action> {
        guard let session = state.roundCache[roundId] else { return .none }
        let completedCount = Int(session.progress.completedProposals)
        let totalCount = Int(max(session.progress.totalProposals, session.progress.completedProposals))

        switch decision {
        case .completed:
            state.roundCache[roundId]?.runRetryCount = 0
            return finishedRunEffect(roundId: roundId, session: session, alsoTrackShares: false)

        case .startShareTracking:
            // Only helper-share confirmation is left, and it is not blocking:
            // the ballot is cast, so the flow closes and the tracking timer
            // finishes the delivery.
            state.roundCache[roundId]?.runRetryCount = 0
            return finishedRunEffect(roundId: roundId, session: session, alsoTrackShares: true)

        case .runBundleSetupThenRerun:
            // The seed is never kept past one run, so the re-run is a fresh
            // Confirm. The ticket is what lets it skip a second auth prompt.
            state.pendingBatchSubmission = true
            mutateSession(&state, roundId: roundId) { $0.batchSubmissionStatus = .idle }
            return .run { [votingCrypto] send in
                let layout = try await votingCrypto.setupBundles(roundId)
                await send(.bundlesSetUp(roundId: roundId, layout: layout))
                await send(.submitAllDraftsTapped(roundId: roundId))
            } catch: { error, send in
                await send(.bundleSetupFailed(roundId: roundId, error: Self.votingError(from: error)))
            }

        case .collectSignatures(let bundles):
            mutateSession(&state, roundId: roundId) { $0.keystoneBundlesToSign = bundles }
            // The Keystone loop is Task A4's; a software wallet asked for a
            // signature has already given the only one it has.
            guard !state.isKeystoneUser else { return .none }
            LoggerProxy.error("Round \(roundId) asked a software wallet for signatures on bundles \(bundles)")
            return .send(.batchAuthorizationFailed(
                roundId: roundId,
                error: String(localizable: .coinVoteSubmissionGenericBatchFailure)
            ))

        case let .waitForBallot(openProposals, unrosteredIntents):
            LoggerProxy.error(
                "Round \(roundId) still wants a ballot: open \(openProposals), unrostered \(unrosteredIntents)"
            )
            return .send(.batchSubmissionFailed(
                roundId: roundId,
                error: String(localizable: .coinVoteSubmissionGenericBatchFailure),
                submittedCount: completedCount,
                totalCount: totalCount
            ))

        case .chainTerminal(let message):
            return .send(.batchSubmissionFailed(
                roundId: roundId,
                error: VotingErrorMapper.userFriendlyMessage(from: message),
                submittedCount: completedCount,
                totalCount: totalCount
            ))

        case .retryLater(let seconds):
            guard session.runRetryCount < Self.maxRunRetries else {
                LoggerProxy.error("Round \(roundId) still had work after \(Self.maxRunRetries) re-runs")
                return .send(.batchSubmissionFailed(
                    roundId: roundId,
                    error: String(localizable: .coinVoteSubmissionGenericBatchFailure),
                    submittedCount: completedCount,
                    totalCount: totalCount
                ))
            }
            state.roundCache[roundId]?.runRetryCount += 1
            return .run { [continuousClock] send in
                try await continuousClock.sleep(for: .seconds(seconds))
                await send(.retryBatchSubmission(roundId: roundId))
            }
            .cancellable(id: cancelRunRetryId, cancelInFlight: true)

        case let .failed(message, retryable):
            LoggerProxy.error("Round \(roundId) run failed (retryable: \(retryable)): \(message)")
            return .send(.batchSubmissionFailed(
                roundId: roundId,
                error: VotingErrorMapper.userFriendlyMessage(from: message),
                submittedCount: completedCount,
                totalCount: totalCount
            ))

        case .cancelled:
            // A cancelled run is one the flow itself stopped; the screen it
            // stopped on is still the right one.
            return .none
        }
    }

    /// What a run that reached the end of its work leaves on screen.
    ///
    /// A run can isolate one bundle and finish the rest, so a clean quiescence
    /// is not a clean run: a partial result is shown as one, with the counts,
    /// rather than as a completed ballot.
    private func finishedRunEffect(
        roundId: String,
        session: RoundSession,
        alsoTrackShares: Bool
    ) -> Effect<Action> {
        let completedCount = Int(session.progress.completedProposals)
        let totalCount = Int(max(session.progress.totalProposals, session.progress.completedProposals))
        let result: Effect<Action>
        if let summary = session.lastRunFailureSummary {
            result = .send(.batchSubmissionFailed(
                roundId: roundId,
                error: summary,
                submittedCount: completedCount,
                totalCount: totalCount
            ))
        } else {
            result = .send(.batchSubmissionCompleted(
                roundId: roundId,
                successCount: completedCount,
                failCount: 0
            ))
        }
        guard alsoTrackShares else { return result }
        return .merge(result, .send(.pollShareStatus(roundId: roundId)))
    }

    /// What a finished run could not do, when it finished anyway.
    ///
    /// A failure list does not imply a failure quiescence: the driver isolates
    /// a failing bundle and drives the rest, so telling the voter everything
    /// landed would hide voting power that never voted.
    static func partialFailureSummary(_ report: VotingRoundRunReport) -> String? {
        guard !report.failures.isEmpty || !report.skippedBundles.isEmpty else { return nil }
        let detail = report.failures.first.map { VotingErrorMapper.userFriendlyMessage(from: $0.failure.message) }
            ?? String(localizable: .coinVoteSubmissionGenericBatchFailure)
        let skipped = report.skippedBundles.count
        guard skipped > 0 else { return detail }
        return "\(detail) (\(skipped)/\(max(Int(report.tally.totalProposals), skipped)))"
    }

    /// The choices a round's plan says are cast, as the flow's own vote map. A
    /// proposal the voter deliberately skipped carries no choice and stays out.
    static func submittedVotes(from plan: VotingRoundPlan) -> [UInt32: VoteChoice] {
        guard let display = plan.completedVoteDisplay else { return [:] }
        var votes: [UInt32: VoteChoice] = [:]
        for entry in display.choices {
            guard let choice = entry.choice else { continue }
            votes[entry.proposalId] = VoteChoice.option(choice)
        }
        return votes
    }

    private func submittedVotesEffect(plan: VotingRoundPlan, roundId: String) -> Effect<Action> {
        let votes = Self.submittedVotes(from: plan)
        guard !votes.isEmpty else { return .none }
        return .send(.submittedVotesLoaded(roundId: roundId, votes: votes))
    }

    /// Hydrates a round's cast votes from the sidecar's own plan.
    ///
    /// Deliberately the store-scoped plan rather than a session's: opening a
    /// session binds a hotkey and fixes a route, and reading what was already
    /// voted is worth neither.
    private func loadSubmittedVotesFromPlan(_ state: State, roundId: String) -> Effect<Action> {
        let proposalIds = activeSession(in: state, roundId: roundId)?.proposals.map(\.id) ?? []
        return .run { [votingCrypto] send in
            let plan = try await votingCrypto.roundPlan(roundId, proposalIds)
            let votes = Self.submittedVotes(from: plan)
            guard !votes.isEmpty else { return }
            await send(.submittedVotesLoaded(roundId: roundId, votes: votes))
        } catch: { error, _ in
            LoggerProxy.warn("Failed to load submitted voting choices: \(error)")
        }
    }

    /// The round's bundle totals, from whichever call answered with them.
    private func applyBundleTotals(
        _ state: inout State,
        roundId: String,
        weight: UInt64,
        bundleCount: UInt32
    ) {
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.votingWeight = weight
            roundSession.bundleCount = bundleCount
            if roundSession.eligibleVotingWeight == 0 {
                roundSession.eligibleVotingWeight = weight
            }
            if roundSession.eligibleBundleCount == 0 {
                roundSession.eligibleBundleCount = bundleCount
            }
            roundSession.completedKeystoneDelegationBundleIndices =
                roundSession.completedKeystoneDelegationBundleIndices.filter { $0 < bundleCount }
        }
    }

    /// Keeps the confirmation screen's own progress shape in step with the
    /// run's, so a voter watching it sees the round move rather than a spinner
    /// that never changes.
    private static func applySubmissionProgress(_ session: inout RoundSession) {
        session.currentVoteBundleIndex = session.progress.activeBundleIndex
        switch session.progress.stage {
        case .idle:
            break
        case .proving:
            session.voteSubmissionStep = .preparingProof
        case .submitting:
            session.voteSubmissionStep = .preparingProof
        case .confirming:
            session.voteSubmissionStep = .confirming
        case .deliveringShares:
            session.voteSubmissionStep = .sendingShares
        case .done:
            session.voteSubmissionStep = nil
        }
        guard session.progress.totalProposals > 0 else { return }
        session.batchSubmissionStatus = .submitting(
            currentIndex: Int(session.progress.completedProposals),
            totalCount: Int(session.progress.totalProposals),
            currentProposalId: session.submittingProposalId ?? 0
        )
    }

    /// The voting failure an arbitrary error describes.
    ///
    /// Most of these already are one; the rest come from the app's own
    /// dependencies — the keychain, the synchronizer — and keep their text
    /// rather than being flattened into something the mapper cannot read.
    static func votingError(from error: Error) -> VotingError {
        if let votingError = error as? VotingError {
            return votingError
        }
        return VotingError(kind: VotingErrorKind.other, message: error.localizedDescription)
    }

    // MARK: - Entry point

    /// `.submitAllDraftsTapped` handler. Records the ballot with the round's
    /// session, then asks for the voter's local authentication.
    ///
    /// The intents are written before the auth prompt on purpose: a ballot the
    /// crate refuses is a refusal the voter should see instead of a Face ID
    /// sheet followed by a failure.
    func reduceSubmitAllDraftsTapped(_ state: inout State, roundId: String) -> Effect<Action> {
        guard let session = state.roundCache[roundId] else { return .none }
        guard canStartSubmission(session) else { return .none }
        guard let activeSession = activeSession(in: state, roundId: roundId) else { return .none }

        // Flip the CTA into its disabled/spinner state before the round-trip so
        // the tap registers instantly; `.requested` also makes re-taps no-ops
        // (`canStartSubmission`), so only one of these can ever be in flight.
        mutateSession(&state, roundId: roundId) {
            $0.batchSubmissionStatus = .requested
        }

        let intents = Self.ballotIntents(
            proposals: activeSession.proposals,
            drafts: session.draftVotes,
            alreadyCast: Set(session.votes.keys)
        )
        let needsAuthentication = !state.isKeystoneUser && !state.pendingBatchSubmission
        let totalCount = max(intents.count, session.draftVotes.count)

        return .run { [votingCrypto, localAuthentication] send in
            let plan = try await votingCrypto.setBallotIntents(roundId, intents)
            guard plan.allDecided else {
                // Every rostered proposal was just given a decision, so the
                // planner disagreeing means the roster is not the one the
                // session was bound to. Nothing here can cast a ballot for it.
                LoggerProxy.error("Round \(roundId) refused to cast: the ballot is incomplete after recording intents")
                await send(.batchSubmissionFailed(
                    roundId: roundId,
                    error: String(localizable: .coinVoteSubmissionGenericBatchFailure),
                    submittedCount: 0,
                    totalCount: totalCount
                ))
                return
            }
            if needsAuthentication {
                guard await localAuthentication.authenticate() else {
                    await send(.batchAuthenticationDeclined(roundId: roundId))
                    return
                }
            }
            await send(.authenticationSucceeded(roundId: roundId))
        } catch: { error, send in
            LoggerProxy.error("Recording the ballot for \(roundId) failed: \(error)")
            await send(.batchSubmissionFailed(
                roundId: roundId,
                error: VotingErrorMapper.userFriendlyMessage(from: error),
                submittedCount: 0,
                totalCount: totalCount
            ))
        }
    }

    /// One ballot intent per rostered proposal the round has not already cast.
    ///
    /// A proposal the voter left blank, and the synthetic Abstain the ballot UI
    /// offers where a proposal has no abstain option of its own, are both
    /// recorded as skipped rather than left out: the planner needs a terminal
    /// decision for every rostered proposal before it will plan a cast, so an
    /// omission would stall the round instead of submitting a partial ballot.
    static func ballotIntents(
        proposals: [VotingProposal],
        drafts: [UInt32: VoteChoice],
        alreadyCast: Set<UInt32>
    ) -> [VotingBallotIntent] {
        proposals
            .filter { !alreadyCast.contains($0.id) }
            .map { proposal in
                guard
                    let choice = drafts[proposal.id],
                    !Voting.isSyntheticAbstain(choice: choice, proposal: proposal)
                else {
                    return VotingBallotIntent(proposalId: proposal.id, decision: VotingBallotDecision.skipped)
                }
                return VotingBallotIntent(
                    proposalId: proposal.id,
                    decision: VotingBallotDecision.choice(choice.index)
                )
            }
    }

    /// `.authenticationSucceeded` handler. Branches on Keystone vs. software,
    /// and for a software wallet starts the round run the seed signs.
    func reduceAuthenticationSucceeded(_ state: inout State, roundId: String) -> Effect<Action> {
        guard let session = state.roundCache[roundId] else { return .none }
        // Idempotent entry: a fresh `.requested` tap (or a retryable status)
        // may start the run, and an in-flight status may only be re-entered by
        // a resume holding the `pendingBatchSubmission` ticket. A stray
        // duplicate — a stale auth effect, a double dispatch — falls through to
        // `.none` instead of restarting (and thereby cancelling) the run.
        let isResume = state.pendingBatchSubmission
        guard session.batchSubmissionStatus == .requested
            || canStartSubmission(session)
            || (isResume && isBatchSubmitting(session))
        else { return .none }
        state.pendingBatchSubmission = false
        guard activeSession(in: state, roundId: roundId) != nil else { return .none }

        // Keystone: route into the per-bundle QR signing screen first. The run
        // resumes via `pendingBatchSubmission` once every bundle is signed.
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

        let epoch = session.sessionEpoch
        let pendingCount = max(session.draftVotes.count, 1)
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.batchSubmissionStatus = .authorizing
            roundSession.voteSubmissionStep = .authorizingVote
            roundSession.batchVoteErrors = [:]
            roundSession.isSubmittingVote = true
            roundSession.lastRunFailureSummary = nil
            roundSession.progress = VotingRoundProgressSnapshot()
        }

        return .merge(
            // The precompute holds the crate's proof lock, and the run waits
            // for a proof already running and then reuses it — so stopping the
            // warm-up costs nothing. Cancel the effect, never the session:
            // cancelling a session is permanent, and this round is about to
            // drive.
            .cancel(id: cancelDelegationPrecomputeId),
            .cancel(id: cancelRunRetryId),
            .run { [backgroundTask, mnemonic, votingAPI, votingCrypto, walletStorage] send in
                // MOB-1810: refresh operator health in the background so the
                // share walk's ordering reflects the present rather than poll
                // entry. Fire-and-forget; nothing here awaits its results.
                await votingAPI.startHealthProbeSweep()
                let bgTaskId = await backgroundTask.beginTask("Voting round run")
                _ = await backgroundTask.beginContinuedProcessing(
                    "co.zodl.voting.*",
                    String(localizable: .coinVoteSubmissionContinuedProcessingTitle),
                    pendingCount == 1
                        ? String(localizable: .coinVoteSubmissionContinuedProcessingMessageSingle(String(pendingCount)))
                        : String(localizable: .coinVoteSubmissionContinuedProcessingMessageMultiple(String(pendingCount)))
                )
                defer {
                    Task {
                        await backgroundTask.endContinuedProcessing()
                        await backgroundTask.endTask(bgTaskId)
                    }
                }

                // The seed exists for exactly one run: the SDK carries it into
                // the Rust signer and zeroizes it there, and nothing on this
                // side keeps it past the call.
                let seed = try mnemonic.toSeed(walletStorage.exportWallet().seedPhrase.value())
                for try await event in votingCrypto.runRound(
                    roundId,
                    VotingDelegationSigner.software(seed: seed),
                    VotingRoundDrivePolicy.default
                ) {
                    await send(.roundRunEvent(roundId: roundId, epoch: epoch, event: event))
                }
            } catch: { error, send in
                LoggerProxy.error("Round run for \(roundId) failed to start: \(error)")
                await send(.roundRunFailed(roundId: roundId, epoch: epoch, error: Self.votingError(from: error)))
            }
            .cancellable(id: cancelSubmissionId, cancelInFlight: true)
        )
    }

    // MARK: - Delegation precompute

    /// `.maybeStartDelegationPrecompute` handler. Warms each bundle's
    /// delegation proof while the voter is still reading the ballot, so Confirm
    /// does not start from cold.
    func reduceMaybeStartDelegationPrecompute(_ state: inout State, roundId: String) -> Effect<Action> {
        // Keystone signs on the device, one bundle at a time; there is no proof
        // to warm ahead of that.
        guard !state.isKeystoneUser else { return .none }
        guard let session = state.roundCache[roundId], let plan = session.roundPlan else { return .none }
        guard session.delegationPrecomputeStatus == .notStarted else { return .none }
        guard !session.isDelegationPrecomputeInFlight, !isBatchSubmitting(session) else { return .none }
        guard activeSession(in: state, roundId: roundId)?.status == .active else { return .none }
        // The planner's own list rather than a walk over every bundle: it
        // computes the list from an exhaustive match, so a bundle whose
        // delegation is already done is not proved again for nothing.
        let bundles = plan.delegationBundlesNeedingWork.filter { session.precomputeStatus[$0] == nil }
        guard !bundles.isEmpty else { return .none }

        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.delegationPrecomputeStatus = .inProgress
            roundSession.isDelegationPrecomputeInFlight = true
        }

        return .run { [votingCrypto] send in
            // Sequentially: two Orchard proofs at once is the memory-pressure
            // kill a phone does not recover from.
            for bundleIndex in bundles {
                try Task.checkCancellation()
                do {
                    for try await event in votingCrypto.precomputeDelegationProof(roundId, bundleIndex) {
                        await send(.precomputeProofEvent(
                            roundId: roundId,
                            bundleIndex: bundleIndex,
                            event: event
                        ))
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        throw CancellationError()
                    }
                    await send(.precomputeProofFailed(
                        roundId: roundId,
                        bundleIndex: bundleIndex,
                        error: Self.votingError(from: error)
                    ))
                }
            }
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

        return .run { [votingAPI] send in
            let freshDelegations = (try? await VotingLegacy.getShareDelegations(roundId)) ?? []
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
                    try await VotingLegacy.markShareConfirmed(
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
                guard let stored = try? await VotingLegacy.getCommitmentBundleJson(roundId, bundleIndex, proposalId) else {
                    continue
                }

                do {
                    for share in shares {
                        let wireJson = try await VotingLegacy.recoverWireJson(
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
                            try await VotingLegacy.addSentServers(
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

            let updatedDelegations = (try? await VotingLegacy.getShareDelegations(roundId))
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
                let govPczt = try await VotingLegacy.buildVotingPczt(
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
        return .run { send in
            let scannedSighash = try VotingLegacy.extractPcztSighash(signedPczt)
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

            let spendAuthSig = try VotingLegacy.extractSpendAuthSignatureFromSignedPczt(
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
        let persistEffect: Effect<Action> = .run { _ in
            try await VotingLegacy.storeKeystoneBundleSignature(roundId, sigInfo)
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
            let pirLayout = state.serviceConfig?.pirLayout,
            let accountId = state.selectedWalletAccount?.id
        else {
            LoggerProxy.error("serviceConfig/selectedAccount unexpectedly nil during Keystone delegation proof")
            return .none
        }
        // Fail closed before any FFI call when the dynamic config predates
        // `pir_layout.poly_len` (see `missingPolyLenConfigError`).
        guard let polyLen = pirLayout.polyLen else {
            LoggerProxy.error("Keystone delegation proof refused: dynamic config lacks pir_layout.poly_len")
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
            return .send(.delegationProofFailed(
                roundId: roundId,
                error: "Keystone signature state is inconsistent."
            ))
        }

        return .run { [backgroundTask, votingCrypto, votingAPI, mnemonic, walletStorage, pirLayout] send in
            let bgTaskId = await backgroundTask.beginTask("Keystone delegation proof")
            do {
                let senderPhrase = try walletStorage.exportWallet().seedPhrase.value()
                let senderSeed = try mnemonic.toSeed(senderPhrase)
                let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())
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

                    for try await event in VotingLegacy.buildAndProveDelegation(
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

                    let registration = try await VotingLegacy.getDelegationSubmission(
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
                    try await VotingLegacy.storeDelegationTxHash(roundId, bundleIdx, delegTxResult.txHash)
                    let vanPosition = try await Self.requireKeystoneDelegationVanPosition(
                        txHash: delegTxResult.txHash,
                        votingAPI: votingAPI
                    )
                    try await VotingLegacy.storeVanPosition(roundId, bundleIdx, vanPosition)
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
        guard case let .present(txHash) = try? await VotingLegacy.getDelegationTxHash(roundId, bundleIndex) else {
            return nil
        }
        if let confirmation = try? await votingAPI.fetchTxConfirmation(txHash),
            let vanPosition = delegationVanPosition(from: confirmation) {
            try await VotingLegacy.storeVanPosition(roundId, bundleIndex, vanPosition)
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
                guard let vanPosition = delegationVanPosition(from: confirmation) else {
                    throw VotingFlowError.delegationTxFailed(code: 0, log: "missing or unrecoverable delegate_vote leaf_index")
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

    private func canStartSubmission(_ session: RoundSession) -> Bool {
        // Drafts alone miss a round that has cast every choice and still owes
        // work — a delivery a run stopped part-way through, say. The plan is
        // the driver's own answer to "is there anything left", so a round with
        // no drafts is still submittable while it says yes.
        let hasWork = session.hasPendingSubmissionWork
            || session.roundPlan?.hasRecoverableVoteOrShareWork == true
        guard hasWork else { return false }
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
            if let confirmation = try await votingAPI.fetchTxConfirmation(txHash) {
                return confirmation.code == 0
            }
            if attempt + 1 < maxRecoveryAttempts {
                try await Task.sleep(for: retryDelay)
            }
        }
        return false
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
}

// MARK: - Round session transport

/// Where a round session's traffic goes, validated once from the service config.
///
/// A config that names no vote servers or no PIR endpoints cannot host a
/// session, and one that predates `pir_layout.poly_len` names a PIR geometry
/// the crate refuses — `zcash_voting` validates the layout locally and the PIR
/// handshake re-checks it against the server, so failing here costs nothing and
/// fabricating a value would be worse than stopping.
struct VotingSessionTransport: Equatable, Sendable {
    let voteServerURLs: [String]
    let pirEndpointURLs: [String]
    let pirLayout: VotingPirLayout

    init?(serviceConfig: VotingServiceConfig) {
        let voteServerURLs = serviceConfig.voteServers.map(\.url)
        let pirEndpointURLs = serviceConfig.pirEndpoints.map(\.url)
        guard
            !voteServerURLs.isEmpty,
            !pirEndpointURLs.isEmpty,
            let polyLen = serviceConfig.pirLayout.polyLen
        else { return nil }
        self.voteServerURLs = voteServerURLs
        self.pirEndpointURLs = pirEndpointURLs
        self.pirLayout = VotingPirLayout(
            pirDepth: serviceConfig.pirLayout.pirDepth,
            tier0Layers: serviceConfig.pirLayout.tier0Layers,
            tier1Layers: serviceConfig.pirLayout.tier1Layers,
            polyLen: polyLen
        )
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

// MARK: - Delegation registration probe

// MARK: - Round resume decision

// MARK: - Delegation TX confirmation status

extension VotingCoordFlow {
    /// The message shown when the round pipeline fails.
    static func pipelineFailureMessage(
        error: Error,
        roundId: String,
        crypto: VotingCryptoClient
    ) async -> String {
        VotingErrorMapper.userFriendlyMessage(from: error)
    }
}

// MARK: - The 3.0-era pipeline's calls

/// A lookup that distinguishes "no row" from a read failure.
enum VotingTxHashLookup: Equatable, Sendable {
    case notFound
    case present(String)
}

/// Positions a mined cast-vote transaction confirmed.
struct VoteConfirmationInfo: Equatable, Sendable {
    let txHash: String
    let vanLeafPosition: UInt32
    let voteCommitmentTreePosition: UInt64
}

/// The per-step voting calls `zcash_voting` no longer offers.
///
/// 4.0 drives a round through one session: the crate selects notes, proves,
/// signs, submits, delivers shares and polls for confirmation itself, and the
/// three dozen calls the pipeline below is written against have no counterpart
/// on the new surface. Rewriting that pipeline is its own change; until it
/// lands, every one of those calls arrives here and throws.
///
/// Deliberately a throw rather than a stub answer. The pipeline's control flow
/// is left exactly as it was so the rewrite has the same shape to work
/// against, and a path that still reaches one of these must fail where it is
/// rather than carry on with a plausible-looking lie about the round's state.
private enum VotingLegacy {
    static func removed<T>() throws -> T {
        throw VotingLegacyAPIRemoved()
    }

    static func removedStream<Element>() -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { $0.finish(throwing: VotingLegacyAPIRemoved()) }
    }

    static func getWalletNotes(
        _ walletDbPath: String,
        _ snapshotHeight: UInt64,
        _ networkId: UInt32,
        _ accountUUID: [UInt8]
    ) async throws -> [NoteInfo] {
        try removed()
    }

    static func getRoundState(_ roundId: String) async throws -> RoundStateInfo {
        try removed()
    }

    static func getVotes(_ roundId: String) async throws -> [VoteRecord] {
        try removed()
    }

    static func getBundleCount(_ roundId: String) async throws -> UInt32 {
        try removed()
    }

    static func initRound(_ params: VotingRoundParams, _ sessionJson: String?) async throws {
        throw VotingLegacyAPIRemoved()
    }

    static func setupBundles(_ roundId: String, _ notes: [NoteInfo]) async throws -> BundleSetupResult {
        try removed()
    }

    static func storeTreeState(_ roundId: String, _ treeState: Data) async throws {
        throw VotingLegacyAPIRemoved()
    }

    static func generateNoteWitnesses(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ walletDbPath: String,
        _ notes: [NoteInfo],
        _ networkId: UInt32
    ) async throws -> [WitnessData] {
        try removed()
    }

    // swiftlint:disable:next function_parameter_count
    static func buildVotingPczt(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ notes: [NoteInfo],
        _ senderSeed: [UInt8],
        _ hotkeySeed: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String,
        _ orchardFvkOverride: Data?,
        _ keystoneSeedFingerprintOverride: Data?
    ) async throws -> VotingPcztResult {
        try removed()
    }

    static func extractPcztSighash(_ pcztBytes: Data) throws -> Data {
        try removed()
    }

    static func extractSpendAuthSignatureFromSignedPczt(
        _ signedPczt: Data,
        _ actionIndex: UInt32
    ) throws -> Data {
        try removed()
    }

    // swiftlint:disable:next function_parameter_count
    static func precomputeDelegationPir(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64,
        _ networkId: UInt32,
        _ pirDepth: UInt32,
        _ tier0Layers: UInt32,
        _ tier1Layers: UInt32,
        _ polyLen: UInt32
    ) async throws -> DelegationPirPrecomputeResult {
        try removed()
    }

    // swiftlint:disable:next function_parameter_count
    static func buildAndProveDelegation(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ senderSeed: [UInt8],
        _ hotkeyStoredSecret: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String,
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64,
        _ pirDepth: UInt32,
        _ tier0Layers: UInt32,
        _ tier1Layers: UInt32,
        _ polyLen: UInt32
    ) -> AsyncThrowingStream<ProofEvent, Error> {
        removedStream()
    }

    // swiftlint:disable:next function_parameter_count
    static func commitVote(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ hotkeyStoredSecret: [UInt8],
        _ proposalId: UInt32,
        _ choice: VoteChoice,
        _ numOptions: UInt32,
        _ voteCommitmentTreePosition: UInt64,
        _ vanAuthPath: [Data],
        _ vanPosition: UInt32,
        _ vanAnchorHeight: UInt32,
        _ singleShare: Bool
    ) async throws -> (bundle: VoteCommitmentBundle, signature: CastVoteSignature) {
        try removed()
    }

    // swiftlint:disable:next function_parameter_count
    static func signDelegationRequest(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ senderSeed: [UInt8],
        _ hotkeyStoredSecret: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String
    ) async throws -> (signature: Data, sighash: Data) {
        try removed()
    }

    static func getDelegationSubmission(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ signature: Data,
        _ sighash: Data
    ) async throws -> DelegationRegistration {
        try removed()
    }

    static func storeVanPosition(_ roundId: String, _ bundleIndex: UInt32, _ position: UInt32) async throws {
        throw VotingLegacyAPIRemoved()
    }

    static func generateVanWitness(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ anchorHeight: UInt32
    ) async throws -> VanWitness {
        try removed()
    }

    static func markVoteSubmitted(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32,
        _ txHash: String
    ) async throws {
        throw VotingLegacyAPIRemoved()
    }

    static func storeDelegationTxHash(_ roundId: String, _ bundleIndex: UInt32, _ txHash: String) async throws {
        throw VotingLegacyAPIRemoved()
    }

    static func getDelegationTxHash(_ roundId: String, _ bundleIndex: UInt32) async throws -> VotingTxHashLookup {
        try removed()
    }

    static func storeVoteTxHash(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32,
        _ txHash: String
    ) async throws {
        throw VotingLegacyAPIRemoved()
    }

    static func getVoteTxHash(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32
    ) async throws -> VotingTxHashLookup {
        try removed()
    }

    static func confirmVoteSubmission(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32,
        _ txHash: String,
        _ eventsJson: String
    ) async throws -> VoteConfirmationInfo {
        try removed()
    }

    static func getCommitmentBundleJson(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32
    ) async throws -> (bundleJson: String, vcTreePosition: UInt64)? {
        try removed()
    }

    static func recoverWireJson(
        _ commitmentBundleJson: String,
        _ proposalId: UInt32,
        _ shareIndex: UInt32,
        _ voteCommitmentTreePosition: UInt64,
        _ submitAt: UInt64
    ) async throws -> String {
        try removed()
    }

    static func recoverableShareIndices(_ commitmentBundleJson: String) async throws -> [UInt32] {
        try removed()
    }

    static func storeKeystoneBundleSignature(_ roundId: String, _ info: KeystoneBundleSignatureInfo) async throws {
        throw VotingLegacyAPIRemoved()
    }

    static func loadKeystoneBundleSignatures(_ roundId: String) async throws -> [KeystoneBundleSignatureInfo] {
        try removed()
    }

    static func clearRecoveryState(_ roundId: String) async throws {
        throw VotingLegacyAPIRemoved()
    }

    static func getStoredDelegationSighash(_ roundId: String, _ bundleIndex: UInt32) async throws -> Data {
        try removed()
    }

    static func clearKeystoneSignature(_ roundId: String, _ bundleIndex: UInt32) async throws {
        throw VotingLegacyAPIRemoved()
    }

    // swiftlint:disable:next function_parameter_count
    static func recordShareDelegation(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32,
        _ shareIndex: UInt32,
        _ sentToURLs: [String],
        _ submitAt: UInt64
    ) async throws {
        throw VotingLegacyAPIRemoved()
    }

    static func getShareDelegations(_ roundId: String) async throws -> [VotingShareDelegation] {
        try removed()
    }

    static func markShareConfirmed(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32,
        _ shareIndex: UInt32
    ) async throws {
        throw VotingLegacyAPIRemoved()
    }

    static func addSentServers(
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32,
        _ shareIndex: UInt32,
        _ newURLs: [String]
    ) async throws {
        throw VotingLegacyAPIRemoved()
    }
}
#endif
