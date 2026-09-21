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
                // Read before the cache that names the tracked rounds is
                // emptied: a pass nothing cancels keeps a session of the
                // previous source alive.
                let stopShareTracking = cancelAllShareTracking(state)
                state.allRounds = []
                state.roundCache.removeAll()
                state.voteRecords.removeAll()
                state.zodlEndorsedRoundIds = []
                state.pendingPipelineRoundId = nil
                state.serviceConfig = nil
                state.pollsLoadError = false
                state.rootScreen = .loading
                state.pollClosedSheet = nil
                // The sessions the previous source opened are bound to its
                // endpoints and to rounds this flow has just forgotten, so they
                // go the same way as the cache that named them.
                let fenceSessions = fenceOpenRoundSessions(&state)
                return .merge(
                    .cancel(id: cancelPipelineId),
                    .cancel(id: cancelDelegationPrecomputeId),
                    .cancel(id: cancelRunRetryId),
                    .cancel(id: cancelStatusPollingId),
                    .cancel(id: cancelNewRoundPollingId),
                    stopShareTracking,
                    .cancel(id: cancelRouteObservationId),
                    fenceSessions,
                    .send(.initialize)
                )

            case .path:
                return .none

                // MARK: - Lifecycle

            case .onAppear:
                // Entering the flow is one of the moments share delivery is
                // picked back up: a helper that was unreachable when the voter
                // left has had time to come back, and this is where the round
                // asks again. (The other one the spec names -- the app coming
                // back to the foreground -- has no action to hang off in this
                // flow, so there is nothing here to hook it to yet.)
                let resumeShareTracking = shareTrackingForOpenRounds(state)

                // Re-entry from a nested screen pop = no-op. The user just
                // navigated back to the polls list root; we already have
                // rounds + service config loaded, so don't flip rootScreen
                // back to `.loading` and re-fetch.
                //
                // Without this guard, NavigationStack's pop fires `.onAppear`
                // again on the root content, which would briefly show the
                // loading screen before the polls list re-renders.
                if state.serviceConfig != nil {
                    return resumeShareTracking
                }

                // First-time entry: show the intro before initializing the
                // round-loading pipeline. The intro's continue button drives
                // `.howToVoteContinueTapped` which re-enters `.onAppear` with
                // the flag set.
                guard state.hasSeenHowToVoteForCurrentWallet else {
                    state.rootScreen = .howToVote
                    return resumeShareTracking
                }
                state.rootScreen = .loading
                return .merge(resumeShareTracking, .send(.initialize))

            case .warmProvingCaches:
                // Sent from `.serviceConfigLoaded`, once the proving policy has
                // been fixed. Warming is what starts the crate's pool, and a
                // pool started on the crate's default policy keeps it: warming
                // from the view's `onAppear` instead would race the configure
                // and win often enough to make the policy a coin toss.
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

            case let .swapAPIAccessChanged(access):
                return reduceSwapAPIAccessChanged(&state, access: access)

            case .votingTeardownBegan:
                return reduceVotingTeardownBegan(&state)

            case .provingPolicyNotApplied:
                // Nothing asked the crate for a policy, so the next config load
                // must be allowed to.
                state.hasConfiguredProving = false
                // The config was recorded before the effect ran, and the effect
                // then stopped short of opening the database -- refused by a
                // teardown, or failed before the ask. A config held with the
                // sidecar closed is the one state `.onAppear` reads as "already
                // initialized", so it goes too and the next appearance starts
                // the load over.
                state.serviceConfig = nil
                state.hasResumedPendingShareRounds = false
                return .none

            case let .roundEntryAbandoned(roundId):
                if state.pendingPipelineRoundId == roundId {
                    state.pendingPipelineRoundId = nil
                }
                if state.checkingEligibilityRoundId == roundId {
                    state.checkingEligibilityRoundId = nil
                }
                return .none

            case .initialize:
                // Sweep legacy plaintext keys from a prior internal-build
                // persistence shape. Idempotent and cheap; safe to keep.
                Voting.sweepLegacyUserDefaultsVotingKeys()

                // A fresh initialize is a fresh sidecar and a fresh rounds
                // list, so the rounds that still owe helper work are read again
                // once the two have landed.
                state.hasResumedPendingShareRounds = false

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

                // Watched for the flow's whole life, not just while a session is
                // open: a reset can begin at any point after the sidecar was
                // opened, and the effect that opened it is the one that has to be
                // stopped. The refusals in `VotingTeardown` are what protect an
                // effect this never reaches; this is what stops the rest.
                let observeTeardown: Effect<Action> = .publisher { [votingCrypto] in
                    votingCrypto.teardownBegan().map { _ in VotingCoordFlow.Action.votingTeardownBegan }
                }
                .cancellable(id: cancelTeardownObservationId, cancelInFlight: true)

                return .merge(observeTeardown, .run { [votingAPI] send in
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
                })

            case .serviceConfigLoaded(let config):
                // This effect is the one that recreates `voting.sqlite3`, so it is
                // the one a wallet reset or heal has to stop. Refused outright
                // while a teardown is under way; the generation captured here is
                // what refuses it if one begins while it is in flight.
                guard let teardownGeneration = votingCrypto.teardownGenerationIfIdle() else {
                    LoggerProxy.info("Voting: a wallet teardown is under way; the voting database stays closed")
                    return .none
                }
                state.serviceConfig = config
                let walletId = state.walletId
                let network = zcashSDKEnvironment.network()
                let networkId: UInt32 = network.networkType.votingRustNetworkId
                // Once per process: the crate refuses a second policy, and that
                // refusal is only correct to ignore because the first ask won.
                // Recorded before the effect rather than after it succeeds, so two
                // config loads in flight at once (a chain switch re-initializing
                // over a load already running) cannot both ask.
                let shouldConfigureProving = !state.hasConfiguredProving
                state.hasConfiguredProving = true
                // Resolved here rather than from `FileManager` inside the
                // effect: the sidecar lives beside the wallet's own databases,
                // and going through the same dependency is what lets a test
                // give one suite a sidecar of its own instead of racing the
                // rest of the suite for the real `Documents` copy.
                let dbPath = databaseFiles.documentsDirectory()
                    .appendingPathComponent(Self.votingSidecarFileName).path
                return .run { [votingAPI, votingCrypto, networkId, shouldConfigureProving, teardownGeneration] send in
                    // 1. Configure API client URLs from the loaded config.
                    await votingAPI.configureURLs(config)

                    // 2. Push the refreshed helper fleet and vote-tree nodes into
                    //    every round session already open, so a session opened
                    //    before this load and one opened after cannot disagree
                    //    about where to reach them. Independent of the teardown
                    //    gate below -- a session already open has nothing to do
                    //    with whether a *fresh* database open is allowed -- and
                    //    safe with nothing open: the registry's loop is then
                    //    empty. Round timing is per round, not per service, so it
                    //    is never pushed here. A config this build cannot open a
                    //    session on (no vote servers, no PIR endpoints or layout)
                    //    has nothing valid to push, so it is skipped rather than
                    //    blanking a session's existing configuration.
                    if let transport = VotingSessionTransport(serviceConfig: config) {
                        let hostURLs = Self.sessionHostURLs(transport: transport)
                        await votingCrypto.updateHostConfiguration(
                            VotingHostOverrides(helperUrls: hostURLs.helperUrls, voteTreeNodeUrls: hostURLs.voteTreeNodeUrls)
                        )
                    }

                    // 3. Open the voting DB and scope it to this wallet.
                    // Asked again here rather than only at the top, because the
                    // config fetch above suspends for as long as the network takes
                    // and a reset can begin in that time. Last possible moment
                    // before the call that would recreate the file a reset is
                    // deleting.
                    guard votingCrypto.teardownAllowsOpen(teardownGeneration) else {
                        LoggerProxy.info("Voting: a wallet teardown began while the config loaded; the sidecar stays closed")
                        await send(.provingPolicyNotApplied)
                        return
                    }
                    try await votingCrypto.openDatabase(dbPath, networkId)
                    try await votingCrypto.setWalletId(walletId)

                    // 4. Fix the proving policy, then warm the caches -- in that
                    //    order, and never the other way round. One heavy job at a
                    //    time is what keeps a phone from being killed for memory
                    //    mid-proof; `cpuWorkerCount: nil` leaves the worker count
                    //    to the crate's own `available_parallelism`.
                    //
                    //    A policy the crate refuses is logged and survived inside
                    //    the client: the voter's flow is not worth failing over a
                    //    pool that is already running.
                    if shouldConfigureProving {
                        do {
                            try await votingCrypto.configureProving(
                                VotingProvingPolicy(cpuWorkerCount: nil, maxActiveHeavyJobs: 1)
                            )
                        } catch {
                            LoggerProxy.warn("Voting proving policy could not be applied: \(error)")
                        }
                    }
                    await send(.warmProvingCaches)

                    // 5. Fetch rounds. Network failures surface as a
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
                    // Only the database calls above the policy ask can throw here --
                    // the ask survives its own failure and the rounds fetch has its
                    // own catch -- so a load that fails never applied a policy.
                    await send(.provingPolicyNotApplied)
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
                // The first rounds list of this initialize is the earliest point
                // a pending round can be matched against a round the
                // authenticator vouched for, and the sidecar it is read from
                // was opened by the same effect that fetched the list.
                let resumePendingShares: Effect<Action>
                if state.hasResumedPendingShareRounds {
                    resumePendingShares = .none
                } else {
                    state.hasResumedPendingShareRounds = true
                    resumePendingShares = .run { [votingCrypto] send in
                        await send(.pendingShareRoundsLoaded(try await votingCrypto.pendingShareRounds()))
                    } catch: { error, _ in
                        LoggerProxy.warn("Reading the rounds that still owe helper shares failed: \(error)")
                    }
                }

                guard let finalizedRoundFromPath else {
                    return .merge(endorsements, resumePendingShares)
                }
                return .merge(
                    endorsements,
                    resumePendingShares,
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
                // On custom config the decision was already made at
                // `.allRoundsLoaded`, so this is a no-op there.
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
                let stopShareTracking = cancelAllShareTracking(state)
                state.roundCache.removeAll()
                state.path.removeAll()
                state.pendingPipelineRoundId = nil
                state.pendingBatchSubmission = false
                state.pollClosedSheet = nil
                state.ineligibleSheet = nil
                state.legacyRoundSheetRoundId = nil
                state.checkingEligibilityRoundId = nil
                state.walletSyncingSheetRoundId = nil
                state.skippedQuestionsSheet = nil
                state.openRoundSessionIds.removeAll()
                state.sessionRouteAccess = nil
                state.hasResumedPendingShareRounds = false
                return .merge(
                    .cancel(id: cancelPipelineId),
                    .cancel(id: cancelSubmissionId),
                    .cancel(id: cancelDelegationProofId),
                    .cancel(id: cancelDelegationPrecomputeId),
                    .cancel(id: cancelRunRetryId),
                    .cancel(id: cancelStatusPollingId),
                    .cancel(id: cancelNewRoundPollingId),
                    stopShareTracking,
                    // Nothing is left to invalidate once the sessions are gone.
                    .cancel(id: cancelRouteObservationId),
                    .cancel(id: cancelTeardownObservationId),
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
                            .cancel(id: cancelNewRoundPollingId),
                            .send(.startRoundStatusPolling(roundId: roundId)),
                            loadSubmittedVotesFromPlan(state, roundId: roundId)
                        )
                    }
                    // Cache hit (hotkey + bundles ready): eligibility is
                    // already proven for this session, push the proposal
                    // list immediately — no spinner needed.
                    //
                    // The open session is part of the hit, not a detail of it.
                    // A fence — an account switch, a route change, a wallet
                    // teardown — closes the sessions and deliberately keeps the
                    // cache, so without this the round still looks warm while
                    // nothing can act on it: the voter would reach the ballot
                    // and Confirm would answer `notOpen`. Re-tapping the round
                    // is the one recovery path the voter has, so it has to open
                    // a session rather than skip past the open.
                    //
                    // A round latched `isLegacyInFlight` is excluded from the hit even
                    // when the other three conditions hold — some other path
                    // (share-tracking resume, say) can reopen its session without
                    // going through `reduceRoundSessionOpened`, and that gate must
                    // hold here too. Falling through re-drives the round through the
                    // full pipeline below, which reaches the gate.
                    if let cached = state.roundCache[roundId],
                       cached.hotkeyAddress != nil,
                       cached.bundleCount > 0,
                       !cached.isLegacyInFlight,
                       state.openRoundSessionIds.contains(roundId) {
                        state.path.append(.proposalList(ProposalList.State(roundId: roundId)))
                        return .merge(
                            startHealthSweep,
                            .cancel(id: cancelNewRoundPollingId),
                            .send(.startRoundStatusPolling(roundId: roundId)),
                            loadSubmittedVotesFromPlan(state, roundId: roundId)
                        )
                    }
                    // No cache: keep the user on the polls list with an
                    // in-button spinner on this row while the session opens
                    // and answers with the round's plan. The push to
                    // `.proposalList` happens in `.earlyEligibilityConfirmed`,
                    // which the session sends as soon as the round has bundles;
                    // ineligibility opens the sheet via `.ineligibleForRound`.
                    state.checkingEligibilityRoundId = roundId
                    return .merge(
                        startHealthSweep,
                        .cancel(id: cancelNewRoundPollingId),
                        .send(.startRoundStatusPolling(roundId: roundId)),
                        .send(.startActiveRoundPipeline(roundId: roundId)),
                        loadSubmittedVotesFromPlan(state, roundId: roundId)
                    )
                case .tallying:
                    state.path.append(.tallying(Tallying.State(roundId: roundId)))
                    return .none
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

            case let .ballotIntentsRecorded(roundId, plan):
                // The plan the session is left in once the ballot is recorded.
                // Kept so the gates that ask what the round still owes read the
                // answer for the ballot the run is about to cast.
                mutateSession(&state, roundId: roundId) { $0.roundPlan = plan }
                return .none

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

            case let .bundleLayoutRestored(roundId, layout):
                // Only what the round is worth. The open effect that asked for
                // this layout goes on to send `.roundSessionOpened` itself, so
                // re-planning here would open the round twice.
                applyBundleLayout(&state, roundId: roundId, layout: layout)
                return .none

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

            case let .keystoneSigningPrepared(roundId, request):
                return reduceKeystoneSigningPrepared(&state, roundId: roundId, request: request)

            case let .keystoneSigningFailed(roundId, error):
                mutateSession(&state, roundId: roundId) {
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

            case let .keystoneBundleSignatureStored(roundId, bundleIndex):
                return reduceKeystoneBundleSignatureStored(&state, roundId: roundId, bundleIndex: bundleIndex)

            case let .keystoneAllBundlesSigned(roundId):
                return reduceKeystoneAllBundlesSigned(&state, roundId: roundId)

            case let .keystoneSignaturesRestored(roundId, bundleIndices):
                return reduceKeystoneSignaturesRestored(&state, roundId: roundId, bundleIndices: bundleIndices)

            case let .keystoneSignatureRejected(roundId, message):
                // The bundle stays the one on screen: nothing was stored, so the
                // device still owes this round a signature for it.
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
                // and submitted votes are preserved, and so are the signatures
                // the crate has already stored: they are what a resumed loop
                // starts from.
                mutateSession(&state, roundId: roundId) { roundSession in
                    resetKeystoneSigningLoop(&roundSession)
                    switch roundSession.batchSubmissionStatus {
                    case .authorizing, .submitting:
                        // The run that set this has already stopped to ask for
                        // signatures; nothing is driving the round any more.
                        if !roundSession.isSubmittingVote {
                            roundSession.batchSubmissionStatus = .idle
                        }
                    default:
                        break
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

            case let .submittedVotesLoaded(roundId, votes):
                guard !votes.isEmpty else { return .none }
                let account = state.selectedWalletAccount?.account
                var session = state.roundCache[roundId] ?? RoundSession(roundId: roundId)
                session.votes.merge(votes) { current, _ in current }
                let mergedVotes = session.votes
                let filteredDrafts = session.draftVotes
                    .filter { mergedVotes[$0.key] == nil }
                session.draftVotes = filteredDrafts
                // Cast votes no longer imply helper work: the session's plan is
                // what says whether any share is still unconfirmed, and the
                // triggers that act on it are entering the flow, initializing,
                // and a run that ended asking for tracking.
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
                return .none

            case let .ineligibleForRound(roundId, reason):
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
                    reason: reason,
                    snapshotHeight: snapshotHeight,
                    minimumZatoshi: ballotDivisor
                )
                return .cancel(id: cancelPipelineId)

            case let .legacyInFlightRound(roundId):
                // An older build dispatched a delegation or vote for this round
                // and never saw it confirmed. The SDK does not adopt it and
                // upstream does not support resuming it, so the round is shown
                // and never driven: no bundle setup, no precompute, no run. With
                // the deferred-navigation flow we typically never pushed the
                // proposal list -- but pop defensively, the same as
                // `.ineligibleForRound`, in case the pipeline landed here from
                // the wallet-sync resume path which does push proactively.
                //
                // The session opened only to read this plan is given back, and
                // the round leaves `openRoundSessionIds` in the same stroke --
                // the registry's own close cancels and removes the session, so
                // leaving the round's id on this list would have every
                // share-tracking path (`shareTrackingForOpenRounds`,
                // `reducePollShareStatus`) read a session that no longer
                // exists and fail. Removing it here is what lets a pending-share
                // sweep (`reducePendingShareRoundsLoaded`, which never asks for
                // a plan and so never reaches this gate) open a fresh
                // tracking-only session for the round: share tracking is
                // separate from this gate and stays working, just not on the
                // session this handler is closing.
                //
                // And the sweep is asked for right here, once the close has
                // returned. The entry that reached this gate replaced the
                // round's tracking-only session and cancelled its re-arm timer
                // before the plan came back, so without this nothing would
                // reopen one until the voter left the flow and came back --
                // and every re-tap of the round would do it again. The
                // reopened session reads no plan, so it cannot return through
                // this gate: the voter sees one sheet, not a loop.
                state.checkingEligibilityRoundId = nil
                state.pendingPipelineRoundId = nil
                if case .proposalList = state.path.last {
                    _ = state.path.popLast()
                }
                state.legacyRoundSheetRoundId = roundId
                state.openRoundSessionIds.removeAll { $0 == roundId }
                return .merge(
                    .cancel(id: cancelPipelineId),
                    .run { [votingCrypto] send in
                        await votingCrypto.closeRoundSession(roundId)
                        // This round only. The sidecar answers for every round
                        // that still owes helper work, and the rest of them are
                        // none of this tap's business: one whose session an
                        // earlier route change closed would be reopened here
                        // for tracking only, with no hotkey bound, and the next
                        // tap on it would take the cache-hit path and drive a
                        // round on a session that cannot sign.
                        let pending = try await votingCrypto.pendingShareRounds()
                        await send(.pendingShareRoundsLoaded(pending.filter { $0.roundId == roundId }))
                    } catch: { error, _ in
                        LoggerProxy.warn("Reading the rounds that still owe helper shares failed: \(error)")
                    }
                )

            case .dismissLegacyRoundSheet:
                state.legacyRoundSheetRoundId = nil
                return .none

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
                    guard isCurrentRound else { return .none }
                    // The vote is over, so there is nothing left for a helper
                    // to confirm: the round's tracking stops here rather than
                    // waiting to be told `voteEndReached`.
                    let stopTracking = endShareTracking(&state, roundId: roundId)
                    return .merge(.cancel(id: cancelStatusPollingId), stopTracking)

                case .finalized:
                    let isCurrentRound = topPathRoundId(state) == roundId
                    if activeVotingFlowRoundId(state) == roundId, !hasVoted {
                        state.pollClosedSheet = State.PollClosedSheet(roundId: roundId, status: status)
                    } else if isCurrentRound {
                        replacePathWithStatusScreen(&state, roundId: roundId, status: status)
                    }
                    guard isCurrentRound else { return .none }
                    let stopTracking = endShareTracking(&state, roundId: roundId)
                    return .merge(
                        .cancel(id: cancelStatusPollingId),
                        stopTracking,
                        .send(.fetchTallyResults(roundId: roundId)),
                        .send(.startNewRoundPolling)
                    )

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

            case let .pendingShareRoundsLoaded(rounds):
                return reducePendingShareRoundsLoaded(&state, rounds: rounds)

            case let .pollShareStatus(roundId):
                return reducePollShareStatus(&state, roundId: roundId)

            case let .shareTrackingEvent(roundId, epoch, event):
                return reduceShareTrackingEvent(&state, roundId: roundId, epoch: epoch, event: event)

            case let .shareTrackingFinished(roundId, epoch, report):
                return reduceShareTrackingFinished(&state, roundId: roundId, epoch: epoch, report: report)

            case let .shareTrackingFailed(roundId, epoch, error):
                return reduceShareTrackingFailed(&state, roundId: roundId, epoch: epoch, error: error)

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
        // Before the flow forgets which rounds it had open: the fence needs the
        // list of sessions, and `resetAccountScopedVotingState` clears the cache
        // that would otherwise be the only record of them. The tracking passes
        // are read off the same list, for the same reason.
        let stopShareTracking = cancelAllShareTracking(state)
        let fenceSessions = fenceOpenRoundSessions(&state)
        resetAccountScopedVotingState(&state)
        votingMetadata.reset()

        let cancellation: Effect<Action> = .merge(
            .cancel(id: cancelPipelineId),
            .cancel(id: cancelSubmissionId),
            .cancel(id: cancelDelegationProofId),
            .cancel(id: cancelDelegationPrecomputeId),
            .cancel(id: cancelRunRetryId),
            .cancel(id: cancelStatusPollingId),
            .cancel(id: cancelNewRoundPollingId),
            stopShareTracking,
            .cancel(id: cancelRouteObservationId),
            // Not cancellable, and deliberately: this is the work that stops the
            // previous wallet's rounds, so cancelling it along with the effects
            // it is cleaning up after would leave them driving.
            fenceSessions
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
        state.legacyRoundSheetRoundId = nil
        state.checkingEligibilityRoundId = nil
        state.walletSyncingSheetRoundId = nil
        state.skippedQuestionsSheet = nil
    }

    /// `.swapAPIAccessChanged` handler. A session's transport is fixed when the
    /// session is opened, so a wallet that changes its mind about Tor cannot be
    /// served by the sessions it already has.
    ///
    /// Closing them is the whole remedy: the next entry into a round opens a
    /// session on the route the wallet asks for now.
    func reduceSwapAPIAccessChanged(
        _ state: inout State,
        access: WalletStorage.SwapAPIAccess
    ) -> Effect<Action> {
        // The shared value replays what it already holds to a new subscriber, and
        // the wallet re-announces the route it already had on its own, so only a
        // route the open sessions were not opened on is a reason to close them.
        guard let openedOn = state.sessionRouteAccess, openedOn != access else { return .none }

        LoggerProxy.info("Voting: the wallet's transport changed; closing every open round session")
        // An entry that is still opening was opened on the route being left, and
        // the spinner it put on the polls list belongs to it.
        state.pendingPipelineRoundId = nil
        state.checkingEligibilityRoundId = nil
        let stopShareTracking = cancelAllShareTracking(state)
        let fenceSessions = fenceOpenRoundSessions(&state)
        return .merge(
            .cancel(id: cancelPipelineId),
            .cancel(id: cancelSubmissionId),
            .cancel(id: cancelDelegationProofId),
            .cancel(id: cancelDelegationPrecomputeId),
            .cancel(id: cancelRunRetryId),
            stopShareTracking,
            fenceSessions
        )
    }

    /// `.votingTeardownBegan` handler. A wallet reset or heal is about to close
    /// the sidecar and delete it.
    ///
    /// ``VotingTeardown`` refuses the opens this flow has not started yet, and
    /// refuses the ones already in flight when they reach their own check. This is
    /// the other half, for a flow that is still alive to act on: stop the effects
    /// that are waiting on the network or the crate, and give back the sessions
    /// the flow is holding rather than making the reset's own close wait for them.
    func reduceVotingTeardownBegan(_ state: inout State) -> Effect<Action> {
        guard !state.openRoundSessionIds.isEmpty || state.pendingPipelineRoundId != nil else {
            return .none
        }

        LoggerProxy.info("Voting: a wallet teardown began; closing every open round session")
        state.pendingPipelineRoundId = nil
        state.checkingEligibilityRoundId = nil
        let stopShareTracking = cancelAllShareTracking(state)
        let fenceSessions = fenceOpenRoundSessions(&state)
        return .merge(
            .cancel(id: cancelPipelineId),
            .cancel(id: cancelSubmissionId),
            .cancel(id: cancelDelegationProofId),
            .cancel(id: cancelDelegationPrecomputeId),
            .cancel(id: cancelRunRetryId),
            .cancel(id: cancelStatusPollingId),
            .cancel(id: cancelNewRoundPollingId),
            stopShareTracking,
            fenceSessions
        )
    }

    /// Fence and close every session the flow has open, answering with the work
    /// that does it.
    ///
    /// The per-round order is the only one that stops a run that is still driving
    /// without losing what it has already done: the epoch moves first, so a pass
    /// that captured the old one can no longer submit anything; the cancel then
    /// stops the round's bounded passes; and only then does the close wait on what
    /// is still in flight. Cancelling a session is permanent, which is exactly
    /// what is wanted here -- a round whose wallet or route has changed is
    /// reopened rather than resumed.
    ///
    /// The flow's own generation moves with it and every cached round is stamped
    /// with the new one, so an event still on its way from a session that has just
    /// been closed is recognised as stale instead of written back.
    private func fenceOpenRoundSessions(_ state: inout State) -> Effect<Action> {
        state.votingSessionEpoch += 1
        let epoch = state.votingSessionEpoch
        state.roundCache = state.roundCache.mapValues { session in
            var stamped = session
            stamped.sessionEpoch = epoch
            return stamped
        }
        let openRoundIds = state.openRoundSessionIds
        state.openRoundSessionIds.removeAll()
        state.sessionRouteAccess = nil
        guard !openRoundIds.isEmpty else { return .none }

        return .run { [votingCrypto] _ in
            for roundId in openRoundIds {
                await votingCrypto.setOperationEpoch(roundId, epoch)
                await votingCrypto.cancelRoundSession(roundId)
                await votingCrypto.closeRoundSession(roundId)
            }
        }
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

    /// How long the flow waits before driving a round again after a run refused
    /// to start for a reason the crate itself called retryable. Short, because
    /// such a refusal is a contention -- a session another pass is holding, a
    /// store that was busy -- rather than something a long wait makes likelier
    /// to clear.
    static let runFailureRetrySeconds: Double = 2

    /// The crate takes at most this many chain endpoints and vote-tree nodes.
    static let maxSessionChainEndpoints = 8

    /// The voting sidecar database, beside the wallet's own databases.
    static let votingSidecarFileName = "voting.sqlite3"

    /// Whether this round's bundle rows do not exist yet, so laying them out is
    /// the next thing that has to happen.
    ///
    /// `needsBundleSetup` on its own does not answer this. The SDK raises that
    /// flag only for a round that already holds a ballot choice and has no rows
    /// to cast it into -- the one ordering a host can resolve, by laying the
    /// bundles out. A round nobody has decided on yet reports it as `false`
    /// and owes a draft instead, and that is every round on a first entry, so
    /// reading the flag alone treats a round the wallet has never laid out as
    /// one whose layout is merely being re-read.
    ///
    /// What does answer it is the delegation statuses: the crate reports one
    /// per bundle row, in bundle order, independently of any ballot, so an
    /// empty list is a round with no bundles.
    static func needsFirstBundleSetup(_ plan: VotingRoundPlan) -> Bool {
        plan.needsBundleSetup || plan.delegationStatuses.isEmpty
    }

    /// A directory of preserved copies of the voting database, written in
    /// Documents by builds 3.10.2 to 3.14.1.
    static let preservedVotingDatabaseDirectoryName = "voting_recovery"

    /// A file of delegation blinding factors and transaction hashes, written
    /// in Documents beside the sidecar by builds 3.12.0 to 3.14.1.
    static let preservedDelegationSecretsFileName = "voting-delegation-escrow.json"

    /// Removes what those builds preserved.
    ///
    /// They kept a copy of the voting database and the delegation secrets that
    /// open a submission left in flight, so a wiped round could be recovered.
    /// Nothing writes either any more, but what was written is still on disk,
    /// and it is a wallet's own database contents and secrets: a reset that
    /// left it behind would hand the next wallet on the device the previous
    /// one's. Deliberately only on a reset -- until then those bytes are the
    /// one remaining record of a submission an older build never saw
    /// confirmed. The whole directory goes, because the write-ahead log and
    /// shared-memory sidecars and the capture marker live inside it. A wallet
    /// that never ran one of those builds has neither, which is not an error.
    static func removePreservedVotingRecoveryFiles(inDocuments documents: URL) {
        let preservedDatabases = documents.appendingPathComponent(
            preservedVotingDatabaseDirectoryName,
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: preservedDatabases)
        let preservedSecrets = documents.appendingPathComponent(preservedDelegationSecretsFileName)
        try? FileManager.default.removeItem(at: preservedSecrets)
    }

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
        // A wallet being reset or healed has no round to enter, and the session
        // this would open holds the sidecar the reset is about to delete.
        guard let teardownGeneration = votingCrypto.teardownGenerationIfIdle() else {
            LoggerProxy.info("Voting: a wallet teardown is under way; no round session is opened")
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
        // Tor for everything this session touches whenever the wallet asked
        // for it -- the vote chain, the helper servers, the private lookups
        // and the vote tree all ride the one route -- and it fails closed: a
        // voter who chose Tor is never silently announced over a plain
        // connection.
        let route = state.swapAPIAccess == .protected
            ? VotingTransportRoute.tor
            : VotingTransportRoute.direct

        state.votingSessionEpoch += 1
        let epoch = state.votingSessionEpoch
        var roundSession = state.roundCache[roundId] ?? RoundSession(roundId: roundId)
        roundSession.sessionEpoch = epoch
        roundSession.didAttemptBundleSetup = false
        roundSession.runRetryCount = 0
        // A fresh session is a fresh start for its shares too: the pass the
        // previous session was running ends with it, and its backoff ladder
        // belongs to a session that no longer exists.
        roundSession.isTrackingShares = false
        roundSession.shareTrackingAttempt = 0
        roundSession.lastRunFailureSummary = nil
        roundSession.progress = VotingRoundProgressSnapshot()
        roundSession.delegationProofStatus = ProofStatus.notStarted
        roundSession.precomputeStatus.removeAll()
        roundSession.delegationPrecomputeStatus = .notStarted
        roundSession.isDelegationPrecomputeInFlight = false
        state.roundCache[roundId] = roundSession
        state.pendingPipelineRoundId = roundId
        state.ineligibleSheet = nil
        state.legacyRoundSheetRoundId = nil
        state.walletSyncingSheetRoundId = nil
        // The round counts as open from here, and a refused open does not take it
        // off again: the list is what a fence closes, and closing a round the
        // registry has no session for is three no-ops, where missing one that it
        // does have is a session left driving a wallet or a route that is gone.
        // Re-entering a round moves it to the end, which is where the session it
        // is about to have belongs.
        state.openRoundSessionIds.removeAll { $0 == roundId }
        state.openRoundSessionIds.append(roundId)
        state.sessionRouteAccess = state.swapAPIAccess

        // Watching the shared value rather than re-reading it on each entry: the
        // route is fixed for a session's whole life, so the change has to reach a
        // round that is already open, not just the next one to be opened. This is
        // the same `.publisher` on a `@Shared` the rest of the app uses to follow
        // shared state (`TransactionList`, `TransactionDetails`). It replays the
        // current value to this new subscriber, which `.swapAPIAccessChanged`
        // recognises as the route the sessions were just opened on and ignores.
        let observeRoute: Effect<Action> = .publisher { [sharedAccess = state.$swapAPIAccess] in
            sharedAccess.publisher
                .map { VotingCoordFlow.Action.swapAPIAccessChanged($0) }
        }
        .cancellable(id: cancelRouteObservationId, cancelInFlight: true)

        let open: Effect<Action> = .run { [sdkSynchronizer, votingCrypto, walletStorage, teardownGeneration] send in
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
            // Asked again after the sync gate, the keychain and the tree-state
            // read have all suspended: a session opened now would hold the
            // sidecar a reset is deleting, and would register behind the close
            // that was meant to be the last one.
            guard votingCrypto.teardownAllowsOpen(teardownGeneration) else {
                LoggerProxy.info("Voting: a wallet teardown began while \(roundId) was opening; no session is opened")
                await send(.roundEntryAbandoned(roundId: roundId))
                return
            }
            try await votingCrypto.openRoundSession(
                inputs,
                VotingSessionBinding(roster: roster, hotkeySecret: hotkeySecret),
                route,
                epoch
            )

            let plan = try await votingCrypto.sessionPlan(roundId)
            if !Self.needsFirstBundleSetup(plan) {
                // The bundles already exist, so no first setup will answer with
                // their weight -- that one belongs to `reduceRoundSessionOpened`
                // and runs only when the rows are missing. Setting them up again
                // is how the weight is asked for here: on a round whose rows are
                // persisted the crate validates the stored prefix and hands back
                // the same layout it built them from, including what its privacy
                // trim dropped and what a skip deleted. Nothing on this side can
                // reconstruct those -- the read-only report names no
                // dropped-bundle count, and the count is persisted -- so without
                // this an entry that found the round's cache evicted (leaving the
                // flow, saving a config source, switching accounts, restarting
                // the app) would show no "not included" row and finish with a
                // record saying the whole wallet voted.
                var didRestoreLayout = false
                // Never for a round an older build left mid-submission: that
                // round is display-only and this call writes. Its weight comes
                // from the read-only report, as it always did.
                if !plan.hasLegacyInFlightSubmission {
                    do {
                        let layout = try await votingCrypto.setupBundles(roundId)
                        await send(.bundleLayoutRestored(roundId: roundId, layout: layout))
                        didRestoreLayout = true
                    } catch {
                        LoggerProxy.warn("Restoring the bundle layout of \(roundId) failed: \(error)")
                    }
                }
                // The fallback, and the only path a flagged round takes: worth
                // less than the layout -- it cannot name what was left out --
                // but better than showing the voter a round worth nothing.
                if !didRestoreLayout, let report = try? await votingCrypto.eligibility(roundId) {
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
            await send(.roundSessionOpenFailed(
                roundId: roundId,
                error: Self.sessionOpenError(from: error, route: route)
            ))
        }
        .cancellable(id: cancelPipelineId, cancelInFlight: true)

        // A previous entry's warm-up belongs to the session this open replaces,
        // and it holds the crate's proof lock for as long as it runs. The
        // round's scheduled tracking pass goes the same way -- it would wake up
        // against a session that has been replaced -- but the pass that may be
        // in flight is left to end on its own, because cancelling one finishes
        // the session under it and this open closes that session anyway.
        return .merge(
            .cancel(id: cancelDelegationPrecomputeId),
            .cancel(id: cancelShareTrackingReArmId(roundId)),
            observeRoute,
            open
        )
    }

    /// What a refused open tells the voter.
    ///
    /// A `.tor` session the SDK cannot give a Tor client is the one refusal that
    /// must not read as "the voting service is unavailable": the voter asked to be
    /// announced over Tor, this flow will not announce them any other way, and the
    /// thing that changes the outcome is the wallet's own Tor setting. There is no
    /// retry on `.direct` to offer -- a session opened on a route the voter did not
    /// choose is the failure, not the fix.
    static func sessionOpenError(from error: Error, route: VotingTransportRoute) -> VotingError {
        guard route == VotingTransportRoute.tor, Self.isTorUnavailable(error) else {
            return Self.votingError(from: error)
        }
        return VotingError(
            kind: VotingErrorKind.other,
            message: String(localizable: .migrationFailureTorFirstRunBody)
        )
    }

    /// Whether the SDK refused because it has no Tor client to give -- either it
    /// holds none at all, or Tor is off in the SDK while the wallet still asks for
    /// it.
    static func isTorUnavailable(_ error: Error) -> Bool {
        guard let zcashError = error as? ZcashError else { return false }
        switch zcashError {
        case .torClientUnavailable, .torNotEnabled:
            return true
        default:
            return false
        }
    }

    /// The helper fleet and vote-tree node URLs a round session's drivers
    /// read, derived once from the session's transport so a fresh open
    /// (``sessionInputs(votingSession:transport:accountUUID:walletDbPath:anchorTreeState:)``)
    /// and a live host-configuration refresh
    /// (`.serviceConfigLoaded`) cannot derive them differently.
    ///
    /// Chain and vote-tree traffic go to the first few configured servers
    /// because the crate polls each of them; helper traffic goes to all of
    /// them, since a share may be delivered anywhere.
    static func sessionHostURLs(transport: VotingSessionTransport) -> (helperUrls: [String], voteTreeNodeUrls: [String]) {
        let voteTreeNodeUrls = Array(transport.voteServerURLs.prefix(Self.maxSessionChainEndpoints))
        return (helperUrls: transport.voteServerURLs, voteTreeNodeUrls: voteTreeNodeUrls)
    }

    /// The inputs a round session lives on.
    static func sessionInputs(
        votingSession: VotingSession,
        transport: VotingSessionTransport,
        accountUUID: String,
        walletDbPath: String,
        anchorTreeState: Data
    ) -> VotingSessionInputs {
        let hostURLs = Self.sessionHostURLs(transport: transport)
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
            chainEndpoints: hostURLs.voteTreeNodeUrls,
            voteTreeNodeUrls: hostURLs.voteTreeNodeUrls,
            helperUrls: hostURLs.helperUrls,
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
        // A session that finished opening after its round was fenced -- the open
        // was already inside the SDK call when the wallet, the route or the
        // database went away -- is one nothing is tracking any more. Give it back
        // here rather than let it hold the sidecar until the flow is dismissed.
        guard state.openRoundSessionIds.contains(roundId) else {
            LoggerProxy.info("Round \(roundId) opened after it was fenced; closing the session it registered")
            return .run { [votingCrypto] _ in
                await votingCrypto.cancelRoundSession(roundId)
                await votingCrypto.closeRoundSession(roundId)
            }
        }

        // An older build dispatched a delegation or vote for this round and
        // never saw it confirmed. The 5.x chain lifecycle owns only
        // submissions it reserved itself, and upstream does not support
        // resuming this one: running the round would re-dispatch the same
        // transaction with no promised outcome. Checked before anything else
        // acts on the plan -- no bundle setup, no precompute, no run -- and
        // ahead of the second call this function gets after bundle setup, so
        // neither entry point can act on a legacy-in-flight plan. Latched on
        // the cached session (never cleared) rather than left to a re-read of
        // this plan, so the guards elsewhere (`startRoundRun`,
        // `reduceMaybeStartDelegationPrecompute`, `reduceSubmitAllDraftsTapped`,
        // and the Polls List cache-hit re-entry) hold even once `roundPlan` is
        // later overwritten by a plan embedded in a drive event or a run
        // report -- the SDK never stamps either with this flag. `roundCache`
        // should already hold an entry here (`reduceStartActiveRoundPipeline`
        // creates one before every open), but `mutateSession` is a no-op on a
        // miss, so one is created first regardless.
        if plan.hasLegacyInFlightSubmission {
            if state.roundCache[roundId] == nil {
                state.roundCache[roundId] = RoundSession(roundId: roundId)
            }
            mutateSession(&state, roundId: roundId) {
                $0.roundPlan = plan
                $0.isLegacyInFlight = true
            }
            return .send(.legacyInFlightRound(roundId: roundId))
        }

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

        if Self.needsFirstBundleSetup(plan) {
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
            restoreKeystoneSignaturesEffect(isKeystoneUser: state.isKeystoneUser, roundId: roundId),
            .send(.maybeStartDelegationPrecompute(roundId: roundId))
        )
    }

    /// What the crate already holds for a Keystone round, read as its session
    /// opens so a signing loop resumes where the voter left it instead of
    /// starting over. A software wallet stores no signatures, so nothing to do.
    private func restoreKeystoneSignaturesEffect(isKeystoneUser: Bool, roundId: String) -> Effect<Action> {
        guard isKeystoneUser else { return .none }
        return .run { [votingCrypto] send in
            let stored = try await votingCrypto.keystoneSignatures(roundId)
            await send(.keystoneSignaturesRestored(
                roundId: roundId,
                bundleIndices: stored.map(\.bundleIndex)
            ))
        } catch: { error, _ in
            // Only the screen's progress is at stake: a run names whatever is
            // still unsigned whatever this read answered.
            LoggerProxy.warn("Reading the stored Keystone signatures for \(roundId) failed: \(error)")
        }
        .cancellable(id: cancelPipelineId)
    }

    /// `.bundlesSetUp` handler. The layout is the round's voting power; the
    /// refreshed plan is what it owes now that the rows exist.
    func reduceBundlesSetUp(_ state: inout State, roundId: String, layout: VotingBundleLayout) -> Effect<Action> {
        if layout.privacyTrimDroppedBundles > 0 {
            let bundles = layout.privacyTrimDroppedBundles
            let notes = layout.privacyTrimDroppedNotes
            LoggerProxy.info("Round \(roundId): privacy trim dropped \(bundles) bundles, \(notes) notes")
        }
        applyBundleLayout(&state, roundId: roundId, layout: layout)
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
    ///
    /// The two ineligible kinds are kept apart rather than merged: the crate
    /// hands back no balance with either, and the sheet used to quote a zero as
    /// the wallet's holding for both -- which for `insufficientEligibility`,
    /// where the wallet does hold notes, is a false statement about the voter's
    /// own money. Each kind now says only what is known about it.
    func reduceBundleSetupFailed(_ state: inout State, roundId: String, error: VotingError) -> Effect<Action> {
        switch error.kind {
        case .noSpendableNotes:
            return .send(.ineligibleForRound(roundId: roundId, reason: IneligibleReason.noSpendableNotes))
        case .insufficientEligibility:
            return .send(.ineligibleForRound(roundId: roundId, reason: IneligibleReason.belowMinimum))
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
        let failed: () -> Effect<Action> = {
            .send(.batchAuthorizationFailed(
                roundId: roundId,
                error: VotingErrorMapper.userFriendlyMessage(from: error)
            ))
        }
        // The crate's own answer rather than an inference from the kind: a
        // refusal it calls retryable is a contention the next run can win, and
        // it takes the same bounded ladder a run that stopped short takes.
        // Everything else fails the same way however often it is asked, so the
        // voter is told instead of watching a wait they cannot see.
        guard error.retryable else { return failed() }
        return scheduleRunRetry(
            &state,
            roundId: roundId,
            seconds: Self.runFailureRetrySeconds,
            exhausted: failed
        )
    }

    /// Schedules another run of the round after `seconds`, or answers with what
    /// `exhausted` says when the round has had its re-runs.
    ///
    /// Bounded, because a backoff the voter cannot see is indistinguishable from
    /// the app doing nothing.
    ///
    /// The retry is the automatic continuation of a Confirm the voter has
    /// already authenticated, so it carries `pendingBatchSubmission` the way
    /// `.runBundleSetupThenRerun` does: without it the run goes back through
    /// `.submitAllDraftsTapped`, which would raise a biometric sheet seconds
    /// after a contention the voter never saw and did nothing to cause. An
    /// unexplained Face ID prompt in a wallet reads as an attack. Nothing of
    /// the first run is carried into the retry either way — the seed was never
    /// retained, and the run effect reads it again for its own single call.
    private func scheduleRunRetry(
        _ state: inout State,
        roundId: String,
        seconds: Double,
        exhausted: () -> Effect<Action>
    ) -> Effect<Action> {
        guard let session = state.roundCache[roundId], session.runRetryCount < Self.maxRunRetries else {
            return exhausted()
        }
        state.roundCache[roundId]?.runRetryCount += 1
        state.pendingBatchSubmission = true
        return .run { [continuousClock] send in
            try await continuousClock.sleep(for: .seconds(seconds))
            await send(.retryBatchSubmission(roundId: roundId))
        }
        .cancellable(id: cancelRunRetryId, cancelInFlight: true)
    }

    /// `.roundRunDecision` handler. One branch per thing a stopped run can
    /// leave the host owing.
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
            drainDecidedDrafts(&state, roundId: roundId)
            return finishedRunEffect(
                roundId: roundId,
                session: state.roundCache[roundId] ?? session,
                alsoTrackShares: false
            )

        case .startShareTracking:
            // Only helper-share confirmation is left, and it is not blocking:
            // the ballot is cast, so the flow closes and the tracking timer
            // finishes the delivery.
            state.roundCache[roundId]?.runRetryCount = 0
            drainDecidedDrafts(&state, roundId: roundId)
            return finishedRunEffect(
                roundId: roundId,
                session: state.roundCache[roundId] ?? session,
                alsoTrackShares: true
            )

        case .runBundleSetupThenRerun:
            // The re-run is the automatic continuation of the Confirm the voter
            // has already authenticated, so the ticket deliberately skips a
            // second biometric prompt. Nothing of the first run is carried into
            // it: the seed was never retained, and the new run effect reads it
            // from wallet storage again for its own single call.
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
            return reduceCollectSignatures(&state, roundId: roundId, bundles: bundles)

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
            return scheduleRunRetry(&state, roundId: roundId, seconds: seconds) {
                LoggerProxy.error("Round \(roundId) still had work after \(Self.maxRunRetries) re-runs")
                return .send(.batchSubmissionFailed(
                    roundId: roundId,
                    error: String(localizable: .coinVoteSubmissionGenericBatchFailure),
                    submittedCount: completedCount,
                    totalCount: totalCount
                ))
            }

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

    /// `.collectSignatures` decision. The bundles the run named are the signing
    /// loop's work list, and the Keystone screen walks them one at a time.
    ///
    /// Two ways this is not a signing loop at all: a software wallet asked for a
    /// signature has already given the only one it has, and a device asked again
    /// for bundles whose signatures are already stored signed something other
    /// than what the round wanted. Both are failures to show, not another pass.
    private func reduceCollectSignatures(
        _ state: inout State,
        roundId: String,
        bundles: [UInt32]
    ) -> Effect<Action> {
        guard state.isKeystoneUser else {
            LoggerProxy.error("Round \(roundId) asked a software wallet for signatures on bundles \(bundles)")
            return .send(.batchAuthorizationFailed(
                roundId: roundId,
                error: String(localizable: .coinVoteSubmissionGenericBatchFailure)
            ))
        }
        let signed = state.roundCache[roundId]?.keystoneSignedBundles ?? []
        guard bundles.contains(where: { !signed.contains($0) }) else {
            LoggerProxy.error(
                "Round \(roundId) asked again for signatures on bundles \(bundles) this device has already stored"
            )
            return .send(.batchAuthorizationFailed(
                roundId: roundId,
                error: String(localizable: .coinVoteSubmissionGenericBatchFailure)
            ))
        }
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.keystoneBundlesToSign = bundles
            roundSession.keystoneSigningStatus = .idle
            // The driver has stopped to ask for signatures, so nothing is
            // driving the round while the voter is on the signing screen.
            // Whatever the run's own narration last wrote here -- `.submitting`,
            // once it had reported a positive tally -- no longer describes a
            // run in progress, and leaving it would freeze Confirm's bar behind
            // this screen.
            roundSession.batchSubmissionStatus = .authorizing
        }
        if !hasKeystoneSigningRound(state: state, roundId: roundId) {
            state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
        }
        return .send(.startDelegationProof(roundId: roundId))
    }

    /// Moves every draft this run decided into the round's cast votes.
    ///
    /// The intents the host wrote are the authoritative list of what the run
    /// was asked to decide. The plan's completed display is not that list: a
    /// proposal the voter skipped appears in it with no choice at all, so
    /// `submittedVotes(from:)` drops it and a drain taken from there would
    /// leave the skip as a draft — outliving the round and turning a completed
    /// run into a submission failure. Draining from the intents is what covers
    /// it.
    ///
    /// A skipped proposal is recorded with the choice the voter drafted — the
    /// synthetic Abstain included, exactly as the per-proposal loop recorded it
    /// before — because that is what the review screens read.
    private func drainDecidedDrafts(_ state: inout State, roundId: String) {
        guard var session = state.roundCache[roundId] else { return }
        let decided = Set(session.castBallotIntents.map(\.proposalId))
        guard !decided.isEmpty else { return }

        var votes = session.votes
        var drafts = session.draftVotes
        for proposalId in decided {
            guard let draft = drafts.removeValue(forKey: proposalId) else { continue }
            if votes[proposalId] == nil {
                votes[proposalId] = draft
            }
        }
        guard votes != session.votes || drafts != session.draftVotes else { return }

        session.votes = votes
        session.draftVotes = drafts
        do {
            try Voting.persistRoundChoices(
                drafts: drafts,
                submittedVotes: votes,
                roundId: roundId,
                account: state.selectedWalletAccount?.account
            )
        } catch {
            // The chain has the vote either way, so the in-memory round keeps
            // it; only the on-disk copy is behind, and the voter is told.
            LoggerProxy.error("Failed to persist decided voting choices: \(error)")
            state.submissionAlert = .votingMetadataPersistenceFailed(error)
        }
        state.roundCache[roundId] = session
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
        // Counted, not rationed: a skipped bundle costs the round that bundle's
        // voting power across every proposal, so quoting it against the ballot's
        // proposal count would read as a ballot that was partly cast.
        //
        // Two keys rather than one with a count, matching the singular/plural
        // pair the continued-processing copy already uses -- the count reaches
        // the voter through the catalogue either way, never as an English
        // fragment built here.
        guard skipped > 1 else {
            return String(localizable: .coinVoteSubmissionPartialFailureBundlesSkippedSingle(detail))
        }
        return String(
            localizable: .coinVoteSubmissionPartialFailureBundlesSkippedMultiple(detail, String(skipped))
        )
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
            // A round that lost its unsigned tail keeps only the signatures and
            // weights of the bundles it still has.
            roundSession.keystoneSignedBundles = roundSession.keystoneSignedBundles.filter { $0 < bundleCount }
            roundSession.keystoneBundleWeights = roundSession.keystoneBundleWeights.filter { $0.key < bundleCount }
        }
    }

    /// Writes a round's bundle layout onto its cached session: the live pair
    /// from the bundles the round delegates, the eligible pair from everything
    /// the wallet brought to it.
    ///
    /// One helper for both the entry that creates the rows (`.bundlesSetUp`)
    /// and the one that finds them already there (`.bundleLayoutRestored`), so
    /// a round cannot be worth one thing on first entry and another on the
    /// next. Two things can sit outside the delegation: the bundles the
    /// crate's privacy trim dropped, and the trailing ones "use signed bundles
    /// only" deleted. The eligible pair carries both, because it is what the
    /// Confirm screen's "not included" row and the completed-round record
    /// compare the live pair against -- overriding the kept-only default
    /// `applyBundleTotals` fills in. The two dropped values are the raw value
    /// of those notes, not their bundle-quantized voting weight; they are
    /// summed with `eligibleWeight` as the crate reports all three,
    /// unconverted. A layout with neither writes no eligible pair of its own,
    /// so the round keeps whatever it already had -- for a session that has
    /// never carried one, the kept-only default, which is what says nothing
    /// was left out.
    func applyBundleLayout(_ state: inout State, roundId: String, layout: VotingBundleLayout) {
        applyBundleTotals(&state, roundId: roundId, weight: layout.eligibleWeight, bundleCount: layout.bundleCount)
        guard layout.privacyTrimDroppedBundles > 0 || layout.skippedSuffixBundles > 0 else { return }
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.eligibleBundleCount =
                layout.bundleCount + layout.privacyTrimDroppedBundles + layout.skippedSuffixBundles
            roundSession.eligibleVotingWeight =
                layout.eligibleWeight + layout.privacyTrimDroppedValueZatoshi + layout.skippedSuffixValueZatoshi
        }
    }

    /// Keeps the confirmation screen's own progress shape in step with the
    /// run's, so a voter watching it sees the round move rather than a spinner
    /// that never changes.
    ///
    /// `delegationProofStatus` is one of those shapes rather than state of its
    /// own: the Confirm screen reserves the bar's first 30 % for the delegation
    /// proof, which is the longest thing a software wallet waits on, and the
    /// only live account of it is the run's progress. Derived here rather than
    /// written by the proof itself, so the two cannot disagree.
    private static func applySubmissionProgress(_ session: inout RoundSession) {
        session.currentVoteBundleIndex = session.progress.activeBundleIndex
        switch session.progress.stage {
        case .idle:
            break
        case .proving:
            session.voteSubmissionStep = .preparingProof
            if let fraction = session.progress.proofFraction {
                session.delegationProofStatus = ProofStatus.generating(progress: fraction)
            } else if session.delegationProofStatus == ProofStatus.notStarted {
                // A proving step the crate reports no fraction for — the vote
                // commitment's own proof, which follows the delegation. Showing
                // it as started is honest; dropping the bar back to nothing
                // would not be.
                session.delegationProofStatus = ProofStatus.generating(progress: 0)
            }
        case .submitting:
            session.voteSubmissionStep = .preparingProof
            session.delegationProofStatus = ProofStatus.complete
        case .confirming:
            session.voteSubmissionStep = .confirming
            session.delegationProofStatus = ProofStatus.complete
        case .deliveringShares:
            session.voteSubmissionStep = .sendingShares
            session.delegationProofStatus = ProofStatus.complete
        case .done:
            session.voteSubmissionStep = nil
            session.delegationProofStatus = ProofStatus.complete
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
    ///
    /// The SDK wrapper's own refusals are the exception, because they carry the
    /// one answer this flow branches on. Run/track contention is
    /// `VotingRustBackendError.sessionBusy` — a different type from the crate's
    /// `VotingError` — and flattening it into `.other` would leave it
    /// `retryable == false`, so the very contention `reduceRoundRunFailed`'s
    /// bounded ladder exists for would never take it. A closed session is the
    /// opposite: that session is finished for good, so repeating the call
    /// answers the same way however long the flow waits.
    static func votingError(from error: Error) -> VotingError {
        if let votingError = error as? VotingError {
            return votingError
        }
        if let backendError = error as? VotingRustBackendError {
            switch backendError {
            case .sessionBusy:
                return VotingError(
                    kind: VotingErrorKind.busy,
                    retryable: true,
                    message: backendError.localizedDescription
                )
            case .sessionClosed, .databaseNotOpen, .databaseAlreadyOpen:
                return VotingError(
                    kind: VotingErrorKind.internal,
                    retryable: false,
                    message: backendError.localizedDescription
                )
            }
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
        // The round-entry gate (`reduceRoundSessionOpened`) already keeps a
        // legacy-in-flight round off the path that reaches Confirm, but this is
        // the one starter that writes to the database (`setBallotIntents`) and
        // the one whose CTA would otherwise be left stuck mid-spinner with no
        // error if the proposal list were ever reached for such a round. Route
        // back through the same sheet the gate shows rather than write a ballot
        // or ask for authentication.
        guard !session.isLegacyInFlight else {
            return .send(.legacyInFlightRound(roundId: roundId))
        }
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
        // What this run was asked to decide. Kept because the plan's completed
        // display carries only proposals with a choice, so a deliberate skip
        // appears nowhere in it and its draft would outlive the round.
        mutateSession(&state, roundId: roundId) { $0.castBallotIntents = intents }

        return .run { [votingCrypto, localAuthentication] send in
            let plan = try await votingCrypto.setBallotIntents(roundId, intents)
            await send(.ballotIntentsRecorded(roundId: roundId, plan: plan))
            // The planner empties `openProposals` the moment every rostered
            // proposal has an intent, and lists an intent it cannot cast under
            // `unrosteredIntents`. Those two say whether this ballot can be
            // cast. `allDecided` cannot: it turns true only once the chosen
            // votes are confirmed, so a fresh ballot never has it.
            guard plan.openProposals.isEmpty, plan.unrosteredIntents.isEmpty else {
                LoggerProxy.error(
                    "Round \(roundId) refused to cast: open \(plan.openProposals), unrostered \(plan.unrosteredIntents)"
                )
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

    /// `.authenticationSucceeded` handler. Starts the run the voter's Confirm
    /// asked for.
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
        return startRoundRun(&state, roundId: roundId)
    }

    /// Puts the round into "a run is driving it" and starts one.
    ///
    /// Both wallets come through here, including a Keystone round resuming after
    /// its signing loop: the round the voter authorised is driven the same way
    /// either way, and only the signer differs.
    private func startRoundRun(_ state: inout State, roundId: String) -> Effect<Action> {
        guard let session = state.roundCache[roundId] else { return .none }
        // An older build's unconfirmed submission makes this round display-only;
        // see `reduceRoundSessionOpened`. Belt-and-suspenders: the round's own
        // gate already keeps a legacy-in-flight round off every path that could
        // reach here, but a run never starts on one regardless of how it did.
        guard !session.isLegacyInFlight else { return .none }
        let epoch = session.sessionEpoch
        let pendingCount = max(session.draftVotes.count, 1)
        let keystoneStored = state.isKeystoneUser
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.batchSubmissionStatus = .authorizing
            roundSession.voteSubmissionStep = .authorizingVote
            roundSession.batchVoteErrors = [:]
            roundSession.isSubmittingVote = true
            roundSession.lastRunFailureSummary = nil
            // The bar's delegation share is folded out of the progress
            // snapshot, so it starts over with it rather than carrying the
            // previous run's answer into a run that has not proved anything yet.
            roundSession.progress = VotingRoundProgressSnapshot()
            roundSession.delegationProofStatus = ProofStatus.notStarted
        }

        return .merge(
            // The precompute holds the crate's proof lock, and the run waits
            // for a proof already running and then reuses it — so stopping the
            // warm-up costs nothing. Cancel the effect, never the session:
            // cancelling a session is permanent, and this round is about to
            // drive.
            .cancel(id: cancelDelegationPrecomputeId),
            .cancel(id: cancelRunRetryId),
            // A run and a tracking pass are exclusive on one session, so the
            // pass this round has scheduled is stood down rather than left to
            // wake up into the run. The timer holds nothing of the session, so
            // stopping it costs the round nothing.
            .cancel(id: cancelShareTrackingReArmId(roundId)),
            roundRunEffect(
                roundId: roundId,
                epoch: epoch,
                pendingCount: pendingCount,
                keystoneStored: keystoneStored
            )
        )
    }

    /// One run of the round, on the only signer this wallet can offer.
    ///
    /// A Keystone round carries no key material at all: its signatures are
    /// already in the crate's rows and the run reads them from there. A software
    /// wallet's seed is read inside the effect for the one call the SDK carries
    /// it into.
    private func roundRunEffect(
        roundId: String,
        epoch: UInt64,
        pendingCount: Int,
        keystoneStored: Bool
    ) -> Effect<Action> {
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

            let signer: VotingDelegationSigner
            if keystoneStored {
                signer = VotingDelegationSigner.keystoneStored
            } else {
                // The seed exists for exactly one run: the SDK carries it into
                // the Rust signer and zeroizes it there, and nothing on this
                // side keeps it past the call.
                let seed = try mnemonic.toSeed(walletStorage.exportWallet().seedPhrase.value())
                signer = VotingDelegationSigner.software(seed: seed)
            }

            for try await event in votingCrypto.runRound(roundId, signer, VotingRoundDrivePolicy.default) {
                await send(.roundRunEvent(roundId: roundId, epoch: epoch, event: event))
            }
        } catch: { error, send in
            LoggerProxy.error("Round run for \(roundId) failed to start: \(error)")
            await send(.roundRunFailed(roundId: roundId, epoch: epoch, error: Self.votingError(from: error)))
        }
        .cancellable(id: cancelSubmissionId, cancelInFlight: true)
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
        // An older build's unconfirmed submission makes this round display-only;
        // see `reduceRoundSessionOpened`. Belt-and-suspenders, the same as
        // `startRoundRun`: precompute never warms a proof for a legacy-in-flight
        // round regardless of how this got called.
        guard !session.isLegacyInFlight else { return .none }
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

    /// The first backoff between two tracking passes, in seconds, and the
    /// ceiling it doubles towards.
    static let shareTrackingBaseBackoffSeconds = 15
    static let shareTrackingMaxBackoffSeconds = 300

    /// How long to wait before the `attempt`-th re-arm: the base delay doubled
    /// once per attempt so far, and never more than the ceiling.
    ///
    /// Bounded on both ends. The shift is clamped because a round that keeps
    /// failing for a day would otherwise overflow it, and the answer past the
    /// ceiling is the ceiling anyway.
    static func shareTrackingBackoffSeconds(attempt: Int) -> Int {
        let exponent = min(max(attempt, 0), 16)
        return min(shareTrackingBaseBackoffSeconds << exponent, shareTrackingMaxBackoffSeconds)
    }

    /// How many passes one foreground tracking run gets before it hands the
    /// round back.
    static let shareTrackingForegroundPasses: UInt32 = 8

    /// The policy every pass this flow starts runs under.
    ///
    /// A pass budget, deliberately, where the SDK's default has none. A run and
    /// a tracking pass are exclusive on one session, and a pass in flight is
    /// never cancelled to make room for a run — cancelling one ends the session
    /// under it, permanently. So an unbudgeted pass, which stops only on
    /// confirmation, the vote ending, a cancel, or 240 consecutive failures at
    /// 15 s each, would hold the round for about an hour and refuse every run
    /// the voter asked for in that window with `sessionBusy`.
    ///
    /// With a budget the driver quiesces `passBudgetExhausted` instead, which
    /// is a re-arm on this flow's own 15 s→300 s ladder: the round is picked up
    /// again a moment later, on a session nothing else is holding, and the
    /// ladder stops on its own at the vote's end.
    static let shareTrackingPolicy = VotingShareTrackingPolicy(maxPasses: shareTrackingForegroundPasses)

    /// `.pollShareStatus` handler. Runs one pass of the session's share-tracking
    /// driver over the round's unconfirmed helper shares.
    ///
    /// Four things stop a pass before it starts, and each of them is a
    /// contention the SDK would otherwise answer with `sessionBusy`: a round
    /// with no open session has nothing to drive, a round whose session is being
    /// opened has nothing to drive *yet*, a pass already in flight is the one
    /// that will report, and a run holds the session for itself.
    ///
    /// `cancelInFlight` is deliberately off. `isTrackingShares` is already the
    /// serializer, and it is reset out from under a live pass on round entry --
    /// so a second send that got past the guard would, with `cancelInFlight`,
    /// cancel the live consumer, whose termination hook cancels the round's
    /// session. That is the one cancel path that could reach a session nobody
    /// is closing, and after a reopen it would be the *new* session. A genuine
    /// second pass is answered `alreadyDriving` or `sessionBusy` instead, which
    /// costs nothing.
    ///
    /// The pass runs on ``shareTrackingPolicy`` rather than the SDK's default,
    /// and the budget in it is the point: a pass is never cancelled to let a
    /// run through, so the only thing that stands one down in time for the next
    /// Confirm is the driver running out of passes and this flow re-arming it.
    func reducePollShareStatus(_ state: inout State, roundId: String) -> Effect<Action> {
        guard state.openRoundSessionIds.contains(roundId) else { return .none }
        // An entry into the round is about to replace its session, and it clears
        // `isTrackingShares` for the session it is opening -- so without this, a
        // poll landing in that window gets past the flag and starts a second
        // pass beside the one the entry deliberately left running. The entry's
        // own plan is what says whether the round still owes share work.
        guard state.pendingPipelineRoundId != roundId else { return .none }
        guard let session = state.roundCache[roundId] else { return .none }
        guard !session.isTrackingShares else { return .none }
        guard !isBatchSubmitting(session), !session.isSubmittingVote else { return .none }

        let epoch = session.sessionEpoch
        state.roundCache[roundId]?.isTrackingShares = true
        return .run { [votingCrypto] send in
            for try await element in votingCrypto.trackShares(roundId, Self.shareTrackingPolicy) {
                switch element {
                case let .event(event):
                    await send(.shareTrackingEvent(roundId: roundId, epoch: epoch, event: event))
                case let .finished(report):
                    await send(.shareTrackingFinished(roundId: roundId, epoch: epoch, report: report))
                }
            }
        } catch: { error, send in
            await send(.shareTrackingFailed(roundId: roundId, epoch: epoch, error: Self.votingError(from: error)))
        }
        .cancellable(id: cancelShareTrackingId(roundId))
    }

    /// `.shareTrackingEvent` handler. The driver narrating its own passes.
    func reduceShareTrackingEvent(
        _ state: inout State,
        roundId: String,
        epoch: UInt64,
        event: VotingShareTrackingEvent
    ) -> Effect<Action> {
        // An observation from a session that has since been replaced describes
        // a pass that no longer exists, the same way a run's events do.
        guard state.roundCache[roundId]?.sessionEpoch == epoch else { return .none }

        switch event.kind {
        case .passStarted, .passFinished:
            guard let pass = event.pass else { return .none }
            mutateSession(&state, roundId: roundId) { $0.shareTrackingStatus = .tracking(pass: pass) }
        case .passFailed:
            LoggerProxy.warn("Share tracking pass for \(roundId) failed: \(event.message ?? "")")
        case .awaitingNextPass, .unknown:
            break
        }
        return .none
    }

    /// `.shareTrackingFinished` handler. The report a pass stopped with, which
    /// is the authoritative account of it.
    ///
    /// A pass that stopped short is re-armed rather than abandoned, on a
    /// doubling backoff that never schedules a wake-up past the vote's end --
    /// after which no helper can confirm anything and the wait would be for
    /// nothing.
    func reduceShareTrackingFinished(
        _ state: inout State,
        roundId: String,
        epoch: UInt64,
        report: VotingShareTrackingRunReport
    ) -> Effect<Action> {
        // A report from a replaced session says nothing about the round as it
        // is now, and the in-flight flag it would clear belongs to whatever the
        // reopen started.
        guard state.roundCache[roundId]?.sessionEpoch == epoch else { return .none }
        state.roundCache[roundId]?.isTrackingShares = false

        switch report.quiescence.kind {
        case .allConfirmed, .nothingToTrack:
            mutateSession(&state, roundId: roundId) { roundSession in
                roundSession.shareTrackingStatus = .confirmed
                roundSession.shareTrackingAttempt = 0
            }
            return .none

        case .voteEndReached:
            mutateSession(&state, roundId: roundId) { $0.shareTrackingStatus = .ended }
            return .none

        case .cancelled, .alreadyDriving:
            // Nothing this round did: the pass was stopped, or another one
            // holds the round and is the one that will report. Saying anything
            // about the shares from here would be inventing it.
            return .none

        case .unknown:
            // A quiescence this build cannot name. Neither confirmed nor a
            // failure to back off from, so it is logged and left alone rather
            // than guessed at in either direction.
            LoggerProxy.warn("Share tracking for \(roundId) stopped with a quiescence this build does not know")
            return .none

        case .failing, .passBudgetExhausted:
            return reArmShareTracking(&state, roundId: roundId, failures: report.failures)
        }
    }

    /// `.shareTrackingFailed` handler. The tracking call itself refused.
    ///
    /// Not re-armed: a throw here is the session going away under the pass or a
    /// run holding it, not a helper the driver could not reach -- the driver
    /// reports those through its own quiescence. The next trigger picks the
    /// round back up, on whatever session it has by then.
    func reduceShareTrackingFailed(
        _ state: inout State,
        roundId: String,
        epoch: UInt64,
        error: VotingError
    ) -> Effect<Action> {
        guard state.roundCache[roundId]?.sessionEpoch == epoch else { return .none }
        LoggerProxy.warn("Share tracking for \(roundId) could not run: \(error.message)")
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.isTrackingShares = false
            if roundSession.shareTrackingStatus != .confirmed, roundSession.shareTrackingStatus != .ended {
                roundSession.shareTrackingStatus = .retrying
            }
        }
        return .none
    }

    /// Schedules the round's next tracking pass, unless the vote ends first.
    private func reArmShareTracking(
        _ state: inout State,
        roundId: String,
        failures: [String]
    ) -> Effect<Action> {
        guard let session = state.roundCache[roundId] else { return .none }
        let attempt = session.shareTrackingAttempt
        let delaySeconds = Self.shareTrackingBackoffSeconds(attempt: attempt)
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.shareTrackingStatus = .retrying
            roundSession.shareTrackingAttempt = attempt + 1
        }
        if let first = failures.first {
            LoggerProxy.warn("Share tracking for \(roundId) stopped short: \(first)")
        }

        guard let voteEndTime = activeSession(in: state, roundId: roundId)?.voteEndTime else { return .none }
        guard Date().addingTimeInterval(TimeInterval(delaySeconds)) < voteEndTime else {
            // Nothing will be scheduled, so `.retrying` would be a wait that
            // never comes. The vote closes with these shares unconfirmed, which
            // is what `.ended` says.
            LoggerProxy.info("Share tracking for \(roundId) is not re-armed: the vote ends first")
            mutateSession(&state, roundId: roundId) { $0.shareTrackingStatus = .ended }
            return .none
        }

        return .run { [continuousClock] send in
            try await continuousClock.sleep(for: .seconds(delaySeconds))
            await send(.pollShareStatus(roundId: roundId))
        }
        .cancellable(id: cancelShareTrackingReArmId(roundId), cancelInFlight: true)
    }

    /// `.pendingShareRoundsLoaded` handler. The sidecar's own list of rounds
    /// that still owe helper work, turned into sessions and tracking passes.
    ///
    /// Three filters, and each one drops a round this flow has no business
    /// opening: another wallet's, one the authenticated config no longer
    /// carries, and one whose vote has already ended. A round the flow already
    /// holds a session for is not reopened -- that would replace the session a
    /// pass may be running on -- it is simply asked to track.
    func reducePendingShareRoundsLoaded(
        _ state: inout State,
        rounds: [VotingPendingShareRound]
    ) -> Effect<Action> {
        guard !rounds.isEmpty else { return .none }
        guard let serviceConfig = state.serviceConfig,
              let account = state.selectedWalletAccount
        else { return .none }
        guard let transport = VotingSessionTransport(serviceConfig: serviceConfig) else { return .none }
        // A wallet being reset or healed has no round to resume, and the
        // sessions this would open hold the sidecar the reset is about to
        // delete.
        guard let teardownGeneration = votingCrypto.teardownGenerationIfIdle() else {
            LoggerProxy.info("Voting: a wallet teardown is under way; no pending share round is resumed")
            return .none
        }

        let walletId = state.walletId
        let now = Date()
        let network = zcashSDKEnvironment.network()
        let walletDbPath = databaseFiles.dataDbURLFor(network).path
        let accountId = account.id
        let route = state.swapAPIAccess == .protected
            ? VotingTransportRoute.tor
            : VotingTransportRoute.direct
        var effects: [Effect<Action>] = []
        var didOpen = false

        for pending in rounds where pending.walletId == walletId {
            let roundId = pending.roundId
            guard serviceConfig.rounds[roundId] != nil,
                  let item = state.allRounds.first(where: { $0.id == roundId }),
                  item.session.voteEndTime > now
            else { continue }
            guard !state.openRoundSessionIds.contains(roundId) else {
                effects.append(.send(.pollShareStatus(roundId: roundId)))
                continue
            }

            let votingSession = item.session
            let roster = votingSession.proposals.map { proposal in
                VotingProposalRosterEntry(proposalId: proposal.id, numOptions: UInt32(proposal.options.count))
            }
            state.votingSessionEpoch += 1
            let epoch = state.votingSessionEpoch
            var roundSession = state.roundCache[roundId] ?? RoundSession(roundId: roundId)
            roundSession.sessionEpoch = epoch
            // A cancelled pass never delivers a terminal action, so a round
            // reaching the resume path can still be carrying the flag and the
            // ladder of a pass that ended with a session this is replacing.
            roundSession.isTrackingShares = false
            roundSession.shareTrackingAttempt = 0
            state.roundCache[roundId] = roundSession
            state.openRoundSessionIds.append(roundId)
            state.sessionRouteAccess = state.swapAPIAccess
            didOpen = true

            effects.append(.run { [sdkSynchronizer, votingCrypto, teardownGeneration] send in
                // No hotkey: confirming a share reads the round's own rows and
                // signs nothing, so the binding the voting path needs is not
                // one this open has to build.
                let inputs = Self.sessionInputs(
                    votingSession: votingSession,
                    transport: transport,
                    accountUUID: accountId.votingUUIDString,
                    walletDbPath: walletDbPath,
                    anchorTreeState: try await sdkSynchronizer.getTreeState(votingSession.snapshotHeight)
                )
                // Asked again after the tree-state read has suspended, the same
                // way the round-entry open asks: a session opened now would hold
                // the sidecar a reset is deleting.
                guard votingCrypto.teardownAllowsOpen(teardownGeneration) else {
                    LoggerProxy.info("Voting: a wallet teardown began while \(roundId) was resuming; no session is opened")
                    await send(.roundEntryAbandoned(roundId: roundId))
                    return
                }
                try await votingCrypto.openRoundSession(
                    inputs,
                    VotingSessionBinding(roster: roster),
                    route,
                    epoch
                )
                await send(.pollShareStatus(roundId: roundId))
            } catch: { error, _ in
                LoggerProxy.warn("Resuming share tracking for \(roundId) failed to open a session: \(error)")
            }
            .cancellable(id: cancelShareTrackingResumeId(roundId), cancelInFlight: true))
        }

        guard !effects.isEmpty else { return .none }
        guard didOpen else { return .merge(effects) }
        // The sessions this just opened are bound to the route the wallet asks
        // for now, and a wallet that changes its mind has to reach them -- the
        // same subscription a round entry starts.
        let observeRoute: Effect<Action> = .publisher { [sharedAccess = state.$swapAPIAccess] in
            sharedAccess.publisher
                .map { VotingCoordFlow.Action.swapAPIAccessChanged($0) }
        }
        .cancellable(id: cancelRouteObservationId, cancelInFlight: true)
        return .merge(effects + [observeRoute])
    }

    /// Every open round whose plan still says a share is unconfirmed, asked to
    /// track. What entering the flow acts on.
    ///
    /// A round a pass has already settled is left alone: the plan is only as
    /// new as the last thing that refreshed it, and the driver's own answer is
    /// newer than that.
    private func shareTrackingForOpenRounds(_ state: State) -> Effect<Action> {
        let roundIds = state.openRoundSessionIds.filter { roundId in
            guard let session = state.roundCache[roundId] else { return false }
            guard session.roundPlan?.hasUnconfirmedShares == true else { return false }
            switch session.shareTrackingStatus {
            case .confirmed, .ended:
                return false
            case .idle, .tracking, .retrying:
                return true
            }
        }
        guard !roundIds.isEmpty else { return .none }
        return .merge(roundIds.map { Effect.send(.pollShareStatus(roundId: $0)) })
    }

    /// Stops one round's tracking: the pass in flight and the one it has
    /// scheduled.
    ///
    /// Cancelling a pass finishes the session it runs on, permanently, so this
    /// belongs only where the session is going anyway.
    private func cancelShareTracking(for roundId: String) -> Effect<Action> {
        .merge(
            .cancel(id: cancelShareTrackingId(roundId)),
            .cancel(id: cancelShareTrackingReArmId(roundId)),
            .cancel(id: cancelShareTrackingResumeId(roundId))
        )
    }

    /// Stops one round's tracking for good, gives the round's session back, and
    /// forgets the pass that was running it.
    ///
    /// Cancelling an effect delivers no terminal action, so the flags a live
    /// pass set stay exactly as it left them: the round would go on saying a
    /// pass holds it, and show a delivery that is never going to finish. The
    /// reset mirrors the one the resume path does, for the same reason.
    ///
    /// Cancelling the pass also reaches the SDK session — the consumer's
    /// termination hook cancels it, and the SDK's cancellation is permanent —
    /// so the session is finished whatever this does next. Leaving it
    /// registered would only keep the sidecar, and on Tor its isolated client,
    /// held by a round the vote has closed. So it is closed here and the round
    /// leaves the open list: the vote is over, and nothing reopens a round to
    /// track shares no helper can confirm any more.
    private func endShareTracking(_ state: inout State, roundId: String) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.isTrackingShares = false
            roundSession.shareTrackingAttempt = 0
            // A round whose shares were confirmed before the vote closed keeps
            // that answer. Every other round gets the terminal one: the vote is
            // over, so no later pass can change what it is holding.
            if roundSession.shareTrackingStatus != .confirmed {
                roundSession.shareTrackingStatus = .ended
            }
        }
        let wasOpen = state.openRoundSessionIds.contains(roundId)
        state.openRoundSessionIds.removeAll { $0 == roundId }
        guard wasOpen else { return cancelShareTracking(for: roundId) }
        return .merge(
            cancelShareTracking(for: roundId),
            .run { [votingCrypto] _ in
                await votingCrypto.closeRoundSession(roundId)
            }
        )
    }

    /// Stops tracking for every round this flow could still be driving one for.
    ///
    /// Read before the caller empties the cache or the open-session list: those
    /// two are the only record of which rounds have a pass to stop.
    private func cancelAllShareTracking(_ state: State) -> Effect<Action> {
        let roundIds = Set(state.roundCache.keys).union(state.openRoundSessionIds)
        guard !roundIds.isEmpty else { return .none }
        return .merge(roundIds.map { cancelShareTracking(for: $0) })
    }

    // MARK: - Share delegation recovery (legacy, retired with the fan-out)

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
        // Helper-share tracking is not started from here: a completed ballot
        // does not by itself mean a share is outstanding. The run's own
        // `.startShareTracking` decision is what says so, and it asks directly.
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

    // MARK: - Keystone signing loop

    /// `.startDelegationProof` handler. Asks the crate for the next bundle's
    /// redacted PCZT, which the signing screen shows the device as a QR.
    ///
    /// Keystone only: a software wallet's delegation happens inside the run,
    /// with no step for the host to take.
    func reduceStartDelegationProof(_ state: inout State, roundId: String) -> Effect<Action> {
        guard state.isKeystoneUser else { return .none }
        guard let session = state.roundCache[roundId] else { return .none }
        guard let bundleIndex = session.nextKeystoneBundleToSign else {
            // Every bundle the run asked for is stored, so there is nothing left
            // to put in front of the device: run the round on those signatures.
            return .send(.keystoneAllBundlesSigned(roundId: roundId))
        }
        // One request at a time, and only between bundles: a second dispatch
        // while a request is being built — or while its QR is on screen — would
        // replace the code the voter is part-way through scanning.
        guard case .idle = session.keystoneSigningStatus else { return .none }

        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.currentKeystoneBundleIndex = bundleIndex
            roundSession.keystoneSigningStatus = .preparingRequest
        }

        return .run { [backgroundTask, votingCrypto] send in
            let bgTaskId = await backgroundTask.beginTask("Keystone signing request")
            do {
                LoggerProxy.info("Keystone: requesting the signing payload for bundle \(bundleIndex)")
                let requests = try await votingCrypto.keystoneSigningRequests(roundId, [bundleIndex])
                guard let request = requests.first(where: { $0.bundleIndex == bundleIndex }) else {
                    throw VotingError(
                        kind: VotingErrorKind.invalidInput,
                        message: VotingFlowError.missingPendingUnsignedPczt.localizedDescription
                    )
                }
                await backgroundTask.endTask(bgTaskId)
                await send(.keystoneSigningPrepared(roundId: roundId, request: request))
            } catch {
                await backgroundTask.endTask(bgTaskId)
                throw error
            }
        } catch: { error, send in
            LoggerProxy.error("Keystone signing request for \(roundId) failed: \(error)")
            await send(.keystoneSigningFailed(roundId: roundId, error: error.localizedDescription))
        }
        .cancellable(id: cancelDelegationProofId, cancelInFlight: true)
    }

    /// `.keystoneSigningPrepared` handler. The redacted PCZT the crate built is
    /// what the screen shows and what the device signs; the round's totals come
    /// from the same request rather than from a bundling repeated on this side.
    func reduceKeystoneSigningPrepared(
        _ state: inout State,
        roundId: String,
        request: VotingKeystoneSigningRequest
    ) -> Effect<Action> {
        // A request that finished building after the loop moved on — a skip the
        // voter confirmed while it was in flight — is not put on screen.
        guard state.roundCache[roundId]?.keystoneSigningStatus == .preparingRequest else { return .none }
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.pendingKeystoneRequest = request
            roundSession.currentKeystoneBundleIndex = request.bundleIndex
            roundSession.keystoneBundleWeights[request.bundleIndex] = request.delegatedWeightZatoshi
            if request.bundleCount > 0 {
                roundSession.bundleCount = request.bundleCount
            }
            if roundSession.eligibleVotingWeight == 0 {
                roundSession.eligibleVotingWeight = request.eligibleWeightZatoshi
            }
            roundSession.keystoneSigningStatus = .awaitingSignature
        }
        return .none
    }

    /// The signed PCZT scanned back from the device, handed to the crate as it
    /// came: the crate lifts the signature off it, checks it against the bundle
    /// it belongs to and stores it. Nothing here reads the signature material.
    func reduceKeystoneScanFound(_ state: inout State, signedPczt: Pczt) -> Effect<Action> {
        // The scan sheet is presented from the delegation signing screen, which
        // exists for one round at a time: the round in the loop.
        state.keystoneScan = nil
        guard case let .delegationSigning(signingState) = state.path.last else { return .none }
        let roundId = signingState.roundId
        guard let request = state.roundCache[roundId]?.pendingKeystoneRequest else { return .none }
        mutateSession(&state, roundId: roundId) {
            $0.keystoneSigningStatus = .parsingSignature
        }
        let bundleIndex = request.bundleIndex

        // Deliberately no cancel id and no epoch: cancelling this mid-write
        // would lose a signature the device has already produced, and the voter
        // would have to sign the same bundle again to get it back.
        return .run { [votingCrypto] send in
            let signed = VotingKeystoneSignedBundle(bundleIndex: bundleIndex, signedPczt: signedPczt)
            let result = try await votingCrypto.storeKeystoneSignatures(roundId, [signed])
            LoggerProxy.info(
                "Keystone: bundle \(bundleIndex) stored (inserted \(result.inserted), kept \(result.alreadyPresent))"
            )
            await send(.keystoneBundleSignatureStored(roundId: roundId, bundleIndex: bundleIndex))
        } catch: { error, send in
            let failure = Self.votingError(from: error)
            switch failure.kind {
            case .keystoneSignatureConflict, .invalidInput:
                // The device signed something other than the bundle on screen,
                // or signed it differently than the round already has it. The
                // scan is refused with the crate's own reason for refusing it.
                LoggerProxy.error("Keystone signature for bundle \(bundleIndex) refused: \(failure.message)")
                await send(.keystoneSignatureRejected(
                    roundId: roundId,
                    message: VotingErrorMapper.userFriendlyMessage(from: failure)
                ))
            default:
                await send(.keystoneSigningFailed(roundId: roundId, error: failure.message))
            }
        }
    }

    /// `.keystoneBundleSignatureStored` handler. One bundle down: the loop moves
    /// to the next one the run asked for, or hands the round back to a run once
    /// there is none.
    func reduceKeystoneBundleSignatureStored(
        _ state: inout State,
        roundId: String,
        bundleIndex: UInt32
    ) -> Effect<Action> {
        guard state.roundCache[roundId] != nil else { return .none }
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.keystoneSignedBundles.insert(bundleIndex)
            roundSession.pendingKeystoneRequest = nil
            roundSession.keystoneSigningStatus = .idle
        }
        // A signature stored after the voter left the signing screen is kept —
        // the crate holds it either way — but it does not restart the loop.
        guard hasKeystoneSigningRound(state: state, roundId: roundId) else { return .none }

        if state.roundCache[roundId]?.nextKeystoneBundleToSign != nil {
            return .send(.startDelegationProof(roundId: roundId))
        }
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.keystoneSigningStatus = .finalizingAuthorization
        }
        // Back to Confirm Submission while the run these signatures unblock
        // drives the round.
        if case .delegationSigning = state.path.last {
            _ = state.path.popLast()
        }
        return .send(.keystoneAllBundlesSigned(roundId: roundId))
    }

    /// `.keystoneAllBundlesSigned` handler. Every bundle the run asked for is
    /// stored, so the round is driven again — this time reading those rows.
    ///
    /// Three sends reach here, all only once nothing is left to sign:
    /// `reduceStartDelegationProof` and `reduceKeystoneBundleSignatureStored`
    /// both check that on `keystoneBundlesToSign`/`keystoneSignedBundles`
    /// before sending it, and `reduceSkipRemainingKeystoneBundles` sends it
    /// after deleting the bundles it gave up on. None of the three touches
    /// `batchSubmissionStatus` or `isSubmittingVote`, so all three still find
    /// the handoff exactly as `reduceCollectSignatures` left it. A delivery
    /// that does not -- stale, or arriving after the voter backed out and
    /// `.delegationRejected` rolled the status back -- is not the live
    /// continuation of that handoff, so it drives nothing.
    func reduceKeystoneAllBundlesSigned(_ state: inout State, roundId: String) -> Effect<Action> {
        guard let session = state.roundCache[roundId] else { return .none }
        guard isOpenKeystoneHandoff(session) else {
            LoggerProxy.info("Round \(roundId): ignoring a stale or duplicate all-bundles-signed")
            return .none
        }
        guard activeSession(in: state, roundId: roundId) != nil else {
            return .send(.batchAuthorizationFailed(
                roundId: roundId,
                error: VotingFlowError.missingActiveSession.localizedDescription
            ))
        }
        mutateSession(&state, roundId: roundId) { roundSession in
            roundSession.keystoneSigningStatus = .finalizingAuthorization
            roundSession.pendingKeystoneRequest = nil
            // The next run names the bundles it still wants signed; keeping this
            // one's list would have the loop re-ask for bundles already stored.
            roundSession.keystoneBundlesToSign = []
        }
        return .merge(
            .cancel(id: cancelDelegationProofId),
            startRoundRun(&state, roundId: roundId)
        )
    }

    /// `.keystoneSignaturesRestored` handler. What the crate already holds for
    /// this round, so a re-entered loop resumes where the voter left it instead
    /// of asking the device for bundles it has already signed.
    func reduceKeystoneSignaturesRestored(
        _ state: inout State,
        roundId: String,
        bundleIndices: [UInt32]
    ) -> Effect<Action> {
        mutateSession(&state, roundId: roundId) { roundSession in
            // Added to, never replaced: this is what the crate held when the
            // session opened, and a bundle signed since then — the read is an
            // effect, and the loop does not wait for it — is not in it.
            roundSession.keystoneSignedBundles.formUnion(bundleIndices)
            // A read that lands after a run has named the bundles it wants
            // signed leaves that list alone: the run's list is the newer answer,
            // and the loop may already be walking it.
            guard roundSession.keystoneBundlesToSign.isEmpty else { return }
            // Otherwise the plan's own list of what still needs signing, less
            // what is stored — what the signing screen counts until a run names
            // the same bundles itself.
            let signed = roundSession.keystoneSignedBundles
            let needingSigning = roundSession.roundPlan?.delegationBundlesNeedingSigning ?? []
            roundSession.keystoneBundlesToSign = needingSigning.filter { !signed.contains($0) }
            roundSession.currentKeystoneBundleIndex = roundSession.nextKeystoneBundleToSign ?? 0
        }
        return .none
    }

    /// "Use signed bundles only": the round keeps the bundles the device has
    /// signed and gives up the rest.
    ///
    /// A prefix, never a subset — the crate keeps the first `keepCount` bundles
    /// and deletes the others, so a gap in the signed set cannot be skipped over
    /// and `resolvedKeystonePrefixCount` is the only count this can act on.
    func reduceSkipRemainingKeystoneBundles(_ state: inout State, roundId: String) -> Effect<Action> {
        guard let session = state.roundCache[roundId] else { return .none }
        let keepCount = session.resolvedKeystonePrefixCount
        guard keepCount > 0 else { return .none }
        // The kept bundles' own weights, when this entry into the round built a
        // signing request for each of them. When it did not — a loop resumed
        // after the app was closed — the round's total stands rather than a
        // figure made up from the bundles it can see.
        let keptWeight = session.keystoneWeight(ofFirst: keepCount)
        if keptWeight == nil {
            LoggerProxy.warn(
                "Round \(roundId) keeps \(keepCount) bundle(s) this entry never priced; its voting power is left as it was"
            )
        }

        mutateSession(&state, roundId: roundId) { roundSession in
            if roundSession.eligibleBundleCount == 0 {
                roundSession.eligibleBundleCount = session.bundleCount
            }
            if roundSession.eligibleVotingWeight == 0 {
                roundSession.eligibleVotingWeight = session.votingWeight
            }
            roundSession.bundleCount = keepCount
            if let keptWeight {
                roundSession.votingWeight = keptWeight
            }
            roundSession.keystoneSignedBundles = roundSession.keystoneSignedBundles.filter { $0 < keepCount }
            roundSession.keystoneBundleWeights = roundSession.keystoneBundleWeights.filter { $0.key < keepCount }
            roundSession.keystoneBundlesToSign = []
            roundSession.pendingKeystoneRequest = nil
            roundSession.keystoneSigningStatus = .finalizingAuthorization
        }
        if case .delegationSigning = state.path.last {
            _ = state.path.popLast()
        }

        return .merge(
            // A request for a bundle about to be deleted has nothing to sign.
            .cancel(id: cancelDelegationProofId),
            // Deliberately no cancel id and no epoch: this deletion is what the
            // voter confirmed, and a round left with the tail still in it would
            // ask them to sign bundles they have just given up.
            .run { [votingCrypto] send in
                try await votingCrypto.deleteSkippedBundles(roundId, keepCount)
                await send(.keystoneAllBundlesSigned(roundId: roundId))
            } catch: { error, send in
                LoggerProxy.error("Deleting the skipped bundles of \(roundId) failed: \(error)")
                await send(.batchAuthorizationFailed(
                    roundId: roundId,
                    error: VotingErrorMapper.userFriendlyMessage(from: error)
                ))
            }
        )
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

    /// Whether `.keystoneAllBundlesSigned` is the live continuation of the
    /// signing handoff `reduceCollectSignatures` opened, rather than a stale
    /// or duplicate delivery.
    ///
    /// The handoff leaves `batchSubmissionStatus` at `.authorizing` and
    /// nothing on the signing loop's own path touches it again until either a
    /// run claims it (`startRoundRun` sets `.authorizing` once more, this
    /// time with `isSubmittingVote` true) or the voter backs out
    /// (`.delegationRejected` rolls it back to `.idle`). So a delivery is
    /// live only while the status still reads that way and no run has
    /// already claimed it -- read from state alone, deliberately not from
    /// whether the signing screen is still on the navigation stack:
    /// `reduceKeystoneBundleSignatureStored` and
    /// `reduceSkipRemainingKeystoneBundles` both pop it before their own send
    /// of this action reaches here, so the screen being gone is normal for a
    /// live delivery too.
    private func isOpenKeystoneHandoff(_ session: RoundSession) -> Bool {
        guard !session.isSubmittingVote else { return false }
        switch session.batchSubmissionStatus {
        case .authorizing:
            return true
        default:
            return false
        }
    }

    /// Stands the signing loop down without touching what the crate has stored:
    /// those signatures are exactly what a resumed loop starts from.
    private func resetKeystoneSigningLoop(_ session: inout RoundSession) {
        session.keystoneBundlesToSign = []
        session.pendingKeystoneRequest = nil
        session.currentKeystoneBundleIndex = session.resolvedKeystonePrefixCount
        session.keystoneSigningStatus = .idle
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
        String(format: "%.3f", Double(Self.keystoneWeightSplit(session).signed) / 100_000_000.0)
    }

    private func skippedBundlesZECString(_ session: RoundSession) -> String {
        String(format: "%.3f", Double(Self.keystoneWeightSplit(session).pending) / 100_000_000.0)
    }

    /// How a round's voting power divides between the bundles the device has
    /// signed and the ones it has not.
    ///
    /// The crate quantizes the bundles and names each one's weight on its
    /// signing request, so those are the figures; a bundle this entry into the
    /// round never requested has no figure, and its weight stays on the pending
    /// side rather than being counted as locked in. Erring that way keeps the
    /// skip alert from telling a voter they are giving up less than they are.
    ///
    /// The total is the live pair -- what this round actually delegates -- and
    /// not the eligible one. On a trimmed round the eligible weight also
    /// carries the value the crate's privacy trim left out of the delegation,
    /// and no bundle the device can sign ever held it, so counting it would
    /// quote the voter a forfeit the round never asked of them.
    /// `eligibleVotingWeight` is the fallback for the entry that reaches here
    /// before a layout has named the live weight.
    static func keystoneWeightSplit(_ session: RoundSession) -> (signed: UInt64, pending: UInt64) {
        let total = session.votingWeight > 0 ? session.votingWeight : session.eligibleVotingWeight
        let signed = session.keystoneWeight(ofFirst: session.resolvedKeystonePrefixCount) ?? 0
        return (signed, total > signed ? total - signed : 0)
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

    // MARK: - Dynamic config

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

    static func clearRecoveryState(_ roundId: String) async throws {
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
