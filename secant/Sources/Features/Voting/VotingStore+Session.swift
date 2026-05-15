import Combine
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import os

// MARK: - Session (Initialization, Rounds, Polling, Tally, DB State, Governance Tab)

extension Voting {
    func reduceSession(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {

        // MARK: - Rounds List

        case .roundsLoadFailed:
            state.pollsLoadError = true
            // Land the user on the polls list so the sheet has the right
            // backdrop. Any previously loaded allRounds stay visible behind
            // the sheet; an empty list just shows blank chrome underneath.
            if state.currentScreen != .pollsList {
                state.screenStack = [.pollsList]
            }
            return .none

        case .retryLoadRounds:
            state.pollsLoadError = false
            return .run { [votingAPI] send in
                let allRounds = try await votingAPI.fetchAllRounds()
                await send(.allRoundsLoaded(allRounds))
            } catch: { error, send in
                votingLogger.error("Retry rounds fetch failed: \(error)")
                await send(.roundsLoadFailed)
            }

        case .allRoundsLoaded(let sessions):
            state.pollsLoadError = false

            // Sort by created_at_height ascending for reliable creation order
            let sorted = sessions.sorted { $0.createdAtHeight < $1.createdAtHeight }
            state.allRounds = sorted.enumerated().map { index, session in
                State.RoundListItem(roundNumber: index + 1, session: session)
            }

            // Populate voteRecords from persisted UserDefaults so the polls
            // list can render the Voted pill for rounds the user has fully
            // submitted. Per-round, sync read, fast even for tens of rounds.
            let walletId = state.walletId
            var loadedRecords: [String: VoteRecord] = [:]
            for item in state.allRounds {
                if let record = Self.loadCompletedVoteRecord(walletId: walletId, roundId: item.id) {
                    loadedRecords[item.id] = record
                }
            }
            state.voteRecords = loadedRecords

            // Always land on the polls list when there are any rounds, so the
            // user explicitly chooses which one to enter — even if there's only
            // one. Empty case shows the no-polls sheet over the list backdrop. Guards
            // against onAppear re-firing while the user is mid-vote.
            if state.allRounds.isEmpty {
                state.screenStack = [.noRounds]
                return .none
            } else if state.activeSession == nil {
                state.screenStack = [.pollsList]
            }
            return .send(.fetchZodlEndorsements)

        case .roundTapped(let roundId):
            guard let item = state.allRounds.first(where: { $0.id == roundId }) else { return .none }
            if shouldShowUnverifiedPollSheet(state, roundId: roundId) {
                state.screenStack = [.pollsList]
                state.showUnverifiedPollWarning = true
                state.pendingUnverifiedRoundTapId = roundId
                return .none
            }
            return openRound(&state, item: item)

        case .unverifiedPollWarningProceedTapped:
            state.showUnverifiedPollWarning = false
            return .none

        case .openPendingUnverifiedRound:
            guard let roundId = state.pendingUnverifiedRoundTapId else { return .none }
            return .run { send in
                try await Task.sleep(for: .milliseconds(220))
                await send(.openPendingUnverifiedRoundNow(roundId))
            } catch: { _, _ in }

        case .openPendingUnverifiedRoundNow(let roundId):
            guard state.pendingUnverifiedRoundTapId == roundId,
                  let item = state.allRounds.first(where: { $0.id == roundId })
            else {
                state.pendingUnverifiedRoundTapId = nil
                return .none
            }
            state.pendingUnverifiedRoundTapId = nil
            return openRound(&state, item: item)

        case .unverifiedPollWarningGoBackTapped:
            state.showUnverifiedPollWarning = false
            state.pendingUnverifiedRoundTapId = nil
            return .none

        // MARK: - Initialization

        case .warmProvingCaches:
            guard !state.hasStartedProvingCacheWarmup else { return .none }
            state.hasStartedProvingCacheWarmup = true
            return .run { [votingCrypto] _ in
                try await votingCrypto.warmProvingCaches()
                votingLogger.info("Voting proving caches warmed")
            } catch: { error, _ in
                votingLogger.error("Voting proving cache warm-up failed: \(error)")
            }

        case .initialize:
            // Re-fetch service discovery whenever the governance flow is opened.
            // This keeps vote/PIR endpoints fresh while proposal data stays sourced
            // from the chain round queries below.
            guard state.currentScreen != .howToVote else { return .none }
            guard !state.isSubmittingVote else { return .none }
            state.prepareForServiceConfigRefresh()
            // Read straight from UserDefaults rather than `state.votingConfigOverrideURL`
            // so this picks up the value `VotingConfigSettings` just wrote, even when
            // its `@Shared(.appStorage(.votingConfigOverrideURL))` change has not yet
            // propagated to the parent state at dismiss time. Otherwise the first save
            // after a chain switch refetches with the previous override.
            let overrideURLString = UserDefaults.standard
                .string(forKey: .votingConfigOverrideURL) ?? ""
            return .run { [votingAPI, overrideURLString] send in
                // 1. Fetch service config (local override -> CDN). Decode or version failures
                //    surface as VotingConfigError and block the voting feature entirely;
                //    the wallet must be updated before the user can proceed.
                let override: PinnedConfigSource?
                if overrideURLString.isEmpty {
                    override = nil
                } else {
                    override = try? PinnedConfigSource.parse(overrideURLString)
                }
                let config = try await votingAPI.fetchServiceConfig(override)
                await send(.serviceConfigLoaded(config))
            } catch: { error, send in
                votingLogger.error("Service config unavailable: \(error)")
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await send(.configUnsupported(message))
            }

        case .configUnsupported(let message):
            state.clearLoadedVotingConfigState()
            state.screenStack = [.configError(message)]
            return .none

        case .serviceConfigLoaded(let config):
            state.serviceConfig = config
            let walletId = state.walletId
            return .run { [votingAPI, votingCrypto] send in
                // 2. Configure API client URLs
                await votingAPI.configureURLs(config)

                // 3. Open voting database and scope to current wallet
                let dbPath = FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("voting.sqlite3").path
                try await votingCrypto.openDatabase(dbPath)
                try await votingCrypto.setWalletId(walletId)

                // 4. Fetch all rounds and populate the list. Kept in its own
                //    do/catch so transient network failures surface as the
                //    recoverable "Couldn't load polls" sheet on top of the
                //    polls list, rather than bricking init with the generic
                //    error screen (which belongs to DB/wallet/config failures).
                do {
                    let allRounds = try await votingAPI.fetchAllRounds()
                    votingLogger.info("Fetched \(allRounds.count) rounds")
                    for round in allRounds {
                        votingLogger.debug(
                            "round=\(round.voteRoundId.hexString.prefix(16))... status=\(round.status.rawValue) snapshot=\(round.snapshotHeight)"
                        )
                    }
                    await send(.allRoundsLoaded(allRounds))
                } catch {
                    votingLogger.error("Failed to fetch rounds: \(error)")
                    await send(.roundsLoadFailed)
                }
            } catch: { error, send in
                votingLogger.error("Initialization failed: \(error)")
                await send(.initializeFailed(error.localizedDescription))
            }

        case .startActiveRoundPipeline:
            guard let session = state.activeSession, session.status == .active else { return .none }
            let network = zcashSDKEnvironment.network
            let walletDbPath = databaseFiles.dataDbURLFor(network).path
            let networkId: UInt32 = network.networkType.votingRustNetworkId
            let snapshotHeight = session.snapshotHeight
            let roundId = session.voteRoundId.hexString
            let accountUUID: [UInt8] = state.selectedWalletAccount?.id.id ?? []
            return .run { [votingCrypto, mnemonic, walletStorage, sdkSynchronizer] send in
                // Gate on the contiguous-from-birthday scan progress, not the chain tip.
                // Spend-before-Sync scans head-first and birthday-first in parallel, so
                // a height past the snapshot from the head side doesn't imply the
                // snapshot itself has been scanned — getWalletNotes would return
                // incomplete state and downstream voting would silently fail.
                // The SDK synchronizer may report height 0 briefly on a fresh app
                // launch before it hydrates its persisted state — retry a few times.
                var walletScannedHeight = UInt64(sdkSynchronizer.latestState().fullyScannedHeight)
                if walletScannedHeight == 0 {
                    for _ in 0..<5 {
                        try await Task.sleep(for: .seconds(1))
                        walletScannedHeight = UInt64(sdkSynchronizer.latestState().fullyScannedHeight)
                        if walletScannedHeight > 0 { break }
                    }
                }
                if walletScannedHeight < snapshotHeight {
                    votingLogger.info("Wallet scanned to \(walletScannedHeight), snapshot at \(snapshotHeight) — not synced yet")
                    await send(.walletNotSynced(scannedHeight: walletScannedHeight, snapshotHeight: snapshotHeight))
                    return
                }

                let notes = try await votingCrypto.getWalletNotes(
                    walletDbPath,
                    snapshotHeight,
                    networkId,
                    accountUUID
                )
                let totalWeight = notes.reduce(UInt64(0)) { $0 + $1.value }
                votingLogger.info("Loaded \(notes.count) notes at height \(snapshotHeight), total weight: \(totalWeight)")
                await send(.votingWeightLoaded(totalWeight, notes))

                // Load or generate voting hotkey mnemonic, derive address for UI
                do {
                    let phrase: String
                    if let stored = try? walletStorage.exportVotingHotkey("") {
                        phrase = stored.seedPhrase.value()
                    } else {
                        phrase = try mnemonic.randomMnemonic()
                        try walletStorage.importVotingHotkey(phrase, "")
                    }
                    let seed = try mnemonic.toSeed(phrase)
                    let hotkey = try await votingCrypto.generateHotkey(roundId, seed)
                    votingLogger.debug("Hotkey address: \(hotkey.address)")
                    await send(.hotkeyLoaded(hotkey.address))
                } catch {
                    votingLogger.error("Failed to generate hotkey: \(error)")
                }
            } catch: { error, send in
                votingLogger.error("Active round pipeline failed: \(error)")
                await send(.initializeFailed(error.localizedDescription))
            }
            .cancellable(id: cancelPipelineId, cancelInFlight: true)

        case .activeSessionLoaded(let session):
            state.activeSession = session
            state.roundId = session.voteRoundId.hexString
            state.votingRound = sessionBackedRound(from: session, title: state.votingRound.title, fallback: state.votingRound)
            reconcileProposalState(&state)
            let roundPrefix = session.voteRoundId.hexString.prefix(16)
            votingLogger.info("activeSessionLoaded: status=\(session.status.rawValue) round=\(roundPrefix)... proposals=\(session.proposals.count)")
            return .none

        case .noActiveRound:
            state.activeSession = nil
            state.screenStack = [.noRounds]
            return .none

        case let .votingWeightLoaded(weight, notes):
            state.walletNotes = notes
            if notes.isEmpty {
                state.votingWeight = 0
                state.ineligibilityReason = .noNotes
                state.screenStack = [.ineligible]
                return .none
            }
            // Use smart bundling to determine eligible weight (excluding dust bundles)
            let bundleResult = notes.smartBundles()
            let eligibleWeight = bundleResult.eligibleWeight
            state.votingWeight = eligibleWeight
            if bundleResult.droppedCount > 0 {
                let dropped = bundleResult.droppedCount
                votingLogger.info("Smart bundling: dropped \(dropped) notes in sub-threshold bundles (eligible: \(eligibleWeight) of \(weight) total)")
            }
            if eligibleWeight < ballotDivisor {
                state.ineligibilityReason = .balanceTooLow
                state.screenStack = [.ineligible]
                return .none
            }
            // Show proposals immediately while witnesses load in the background.
            // For Keystone users that haven't authorized yet, go straight to the
            // delegation signing screen to avoid a brief flash of the proposal list.
            // Don't set delegationProofStatus here — verifyWitnesses will set it
            // only for fresh rounds, avoiding a brief flash for cached rounds.
            // Restore persisted draft votes (survives app termination)
            let restored = Self.loadDrafts(walletId: state.walletId, roundId: state.roundId)
            // Only keep drafts for proposals that haven't been submitted yet
            state.draftVotes = restored.filter { state.votes[$0.key] == nil }
            if !state.draftVotes.isEmpty {
                let draftCount = state.draftVotes.count
                votingLogger.info("Restored \(draftCount) persisted draft votes")
            }

            state.screenStack = [.pollsList, .proposalList]
            return .merge(
                .publisher {
                    votingCrypto.stateStream()
                        .receive(on: DispatchQueue.main)
                        .map(Action.votingDbStateChanged)
                }
                .cancellable(id: cancelStateStreamId, cancelInFlight: true),
                .send(.verifyWitnesses)
            )

        case .initializeFailed(let error):
            votingLogger.error("Initialization error: \(error)")
            state.screenStack = [.error(VotingErrorMapper.userFriendlyMessage(from: error))]
            return .none

        case let .walletNotSynced(scannedHeight, snapshotHeight):
            state.walletScannedHeight = scannedHeight
            state.screenStack = [.walletSyncing]
            // Poll sync progress and auto-retry the pipeline once caught up
            return .run { [sdkSynchronizer] send in
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let height = UInt64(sdkSynchronizer.latestState().fullyScannedHeight)
                    await send(.walletSyncProgressUpdated(height))
                    if height >= snapshotHeight {
                        await send(.startActiveRoundPipeline)
                        return
                    }
                }
            } catch: { _, _ in }
            .cancellable(id: cancelPipelineId, cancelInFlight: true)

        case .walletSyncProgressUpdated(let height):
            state.walletScannedHeight = height
            return .none

        case .hotkeyLoaded(let address):
            state.hotkeyAddress = address
            return .send(.maybeStartDelegationPrecompute)

        // MARK: - Round Status Polling

        case .startRoundStatusPolling:
            guard let session = state.activeSession else { return .none }
            let roundIdHex = session.voteRoundId.hexString
            return .run { [votingAPI] send in
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5))
                    let updated = try await votingAPI.fetchRoundById(roundIdHex)
                    await send(.roundStatusUpdated(roundId: updated.voteRoundId, updated.status))
                }
            } catch: { error, _ in
                votingLogger.error("Status polling error: \(error)")
            }
            .cancellable(id: cancelStatusPollingId, cancelInFlight: true)

        case let .roundStatusUpdated(polledRoundId, newStatus):
            guard let session = state.activeSession else { return .none }

            // Guard against stale poll responses from a previously viewed
            // round arriving after the user navigated to a different round.
            // TCA effect cancellation is cooperative, so a queued action
            // from the old poll can slip through.
            guard polledRoundId == session.voteRoundId else {
                let polledPrefix = polledRoundId.hexString.prefix(16)
                let activePrefix = session.voteRoundId.hexString.prefix(16)
                votingLogger.debug("roundStatusUpdated: ignoring stale poll for \(polledPrefix)..., active round is \(activePrefix)...")
                return .none
            }

            // Only react to actual transitions
            votingLogger.info("roundStatusUpdated: old=\(session.status.rawValue) new=\(newStatus.rawValue)")
            guard newStatus != session.status else { return .none }

            // Update session status
            let updatedSession = VotingSession(
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
                status: newStatus,
                createdAtHeight: session.createdAtHeight,
                title: session.title
            )
            state.activeSession = updatedSession

            // Also update the corresponding entry in allRounds so the list stays consistent
            if let idx = state.allRounds.firstIndex(where: { $0.session.voteRoundId == session.voteRoundId }) {
                state.allRounds[idx] = State.RoundListItem(
                    roundNumber: state.allRounds[idx].roundNumber,
                    session: updatedSession
                )
            }

            switch newStatus {
            case .tallying:
                if state.isInActiveVotingFlow {
                    // Don't yank the user out of voting/review/confirm — show
                    // the Poll Closed sheet and let them choose Close or View
                    // results. Status polling stops either way; it's work done.
                    state.showPollClosedSheet = true
                    return .cancel(id: cancelStatusPollingId)
                }
                state.screenStack = [.tallying]
                return .none
            case .finalized:
                // Fetch tally results + start new-round polling regardless of
                // where the user is, so the data is ready whether they get
                // routed to Results immediately or via the Poll Closed sheet.
                let sideEffects: Effect<Action> = .merge(
                    .cancel(id: cancelStatusPollingId),
                    .send(.fetchTallyResults),
                    .send(.fetchZodlEndorsements),
                    .send(.startNewRoundPolling)
                )
                if state.isInActiveVotingFlow {
                    state.showPollClosedSheet = true
                    return sideEffects
                }
                state.screenStack = [.results]
                return sideEffects
            default:
                return .none
            }

        // MARK: - Poll Closed Sheet

        case .dismissPollClosedSheet:
            state.showPollClosedSheet = false
            return .send(.backToRoundsList)

        case .viewPollClosedResults:
            state.showPollClosedSheet = false
            guard let session = state.activeSession else {
                return .send(.backToRoundsList)
            }
            let roundIdHex = session.voteRoundId.hexString
            if shouldShowUnverifiedPollSheet(state, roundId: roundIdHex),
               state.allRounds.contains(where: { $0.id == roundIdHex })
            {
                state.screenStack = [.pollsList]
                state.showUnverifiedPollWarning = true
                state.pendingUnverifiedRoundTapId = roundIdHex
                return .none
            }
            switch session.status {
            case .finalized:
                state.screenStack = [.results]
            case .tallying:
                state.screenStack = [.tallying]
            default:
                return .send(.backToRoundsList)
            }
            return .none

        // MARK: - New Round Polling (after finalization)

        case .startNewRoundPolling:
            return .run { [votingAPI] send in
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(30))
                    let allRounds = try await votingAPI.fetchAllRounds()
                    let hasActive = allRounds.contains { $0.status == .active || $0.status == .tallying }
                    if hasActive {
                        await send(.allRoundsLoaded(allRounds))
                    }
                }
            } catch: { _, _ in }
            .cancellable(id: cancelNewRoundPollingId, cancelInFlight: true)

        // MARK: - Tally Results

        case .fetchTallyResults:
            guard let session = state.activeSession else { return .none }
            state.isLoadingTallyResults = true
            state.resultsLoadError = false
            let roundIdHex = session.voteRoundId.hexString
            return .run { [votingAPI] send in
                let results = try await votingAPI.fetchTallyResults(roundIdHex)
                await send(.tallyResultsLoaded(results))
            } catch: { error, send in
                votingLogger.error("Failed to fetch tally results: \(error)")
                await send(.tallyResultsLoadFailed)
            }

        case .tallyResultsLoaded(let results):
            state.tallyResults = results
            state.isLoadingTallyResults = false
            state.resultsLoadError = false
            return .none

        case .tallyResultsLoadFailed:
            state.isLoadingTallyResults = false
            state.resultsLoadError = true
            return .none

        case .retryLoadTallyResults:
            state.resultsLoadError = false
            return .send(.fetchTallyResults)

        // MARK: - Zodl Endorsements

        case .fetchZodlEndorsements:
            return .run { [votingAPI] send in
                let ids = try await votingAPI.fetchZodlEndorsedRoundIds()
                await send(.zodlEndorsementsLoaded(ids))
            } catch: { error, send in
                votingLogger.error("Failed to fetch zodl endorsements: \(error)")
                // Non-fatal decoration: no icon is shown when endorsements are unavailable.
                await send(.zodlEndorsementsLoaded([]))
            }

        case .zodlEndorsementsLoaded(let ids):
            state.zodlEndorsedRoundIds = ids
            return .none

        // MARK: - DB State Stream

        case .votingDbStateChanged(let dbState):
            // Votes: DB is source of truth, but preserve optimistic vote during submission
            var mergedVotes = dbState.votesByProposal
            if state.isSubmittingVote {
                for (proposalId, choice) in state.votes where mergedVotes[proposalId] == nil {
                    mergedVotes[proposalId] = choice
                }
            }
            state.votes = mergedVotes
            // Proof status: if DB says proof succeeded and we're not actively generating, sync it
            if dbState.roundState.proofGenerated && state.delegationProofStatus != .complete {
                state.delegationProofStatus = .complete
            }
            // Sync hotkey address from DB if available
            if let addr = dbState.roundState.hotkeyAddress {
                state.hotkeyAddress = addr
            }
            votingLogger.debug("DB state: phase=\(String(describing: dbState.roundState.phase)), \(dbState.votes.count) votes")

            // If votes arrived and share tracking hasn't started yet, kick it off.
            // This handles cold start where governanceTabAppeared fires before votes are loaded.
            // Don't start while a vote is actively being submitted — the share delegation
            // rows are written at the end of submission, so polling mid-submission shows
            // a flickering empty/partial bar.
            if !state.votes.isEmpty && state.shareTrackingStatus == .idle
                && !state.isSubmittingVote {
                state.shareTrackingStatus = .loading
                return .send(.loadShareDelegations)
            }
            // Don't re-trigger if already tracking — the poll loop handles refresh.
            return .none

        // MARK: - Governance Tab Lifecycle

        case .governanceTabAppeared:
            guard state.activeSession != nil else { return .none }
            guard !state.isSubmittingVote else { return .none }
            guard !state.votes.isEmpty else { return .none }

            state.shareTrackingStatus = .loading
            return .send(.loadShareDelegations)

        case .governanceTabDisappeared:
            state.shareTrackingStatus = .idle
            return .cancel(id: cancelShareTrackingId)

        default:
            return .none
        }
    }

    /// Gate before entering a poll or viewing results whenever a custom chain URL is selected.
    /// Endorsement from the chain applies only to Default config (and the list hides unendorsed rounds there).
    fileprivate func shouldShowUnverifiedPollSheet(_ state: State, roundId _: String) -> Bool {
        !state.isOnDefaultConfig
    }

    fileprivate func openRound(_ state: inout State, item: State.RoundListItem) -> Effect<Action> {
        let session = item.session
        let isSwitchingRounds = state.roundId != session.voteRoundId.hexString
        state.activeSession = session
        state.roundId = session.voteRoundId.hexString
        if isSwitchingRounds {
            state.delegationProofStatus = .notStarted
            state.isDelegationProofInFlight = false
            state.delegationPrecomputeStatus = .notStarted
            state.isDelegationPrecomputeInFlight = false
            state.pendingBatchSubmission = false
            state.currentKeystoneBundleIndex = 0
            state.keystoneBundleSignatures = []
            state.pendingVotingPczt = nil
            state.pendingUnsignedDelegationPczt = nil
            state.keystoneSigningStatus = .idle
        }
        state.votingRound = sessionBackedRound(from: session, title: item.title, fallback: state.votingRound)
        state.voteRecord = Self.loadCompletedVoteRecord(walletId: state.walletId, roundId: state.roundId)
        reconcileProposalState(&state)
        let cancelStaleDelegation: Effect<Action> = isSwitchingRounds
            ? .cancel(id: cancelDelegationProofId)
            : .none
        let cancelStalePrecompute: Effect<Action> = isSwitchingRounds
            ? .cancel(id: cancelDelegationPrecomputeId)
            : .none

        switch session.status {
        case .active:
            state.screenStack = [.pollsList, .proposalList]
            return .merge(
                cancelStaleDelegation,
                cancelStalePrecompute,
                .cancel(id: cancelNewRoundPollingId),
                .send(.startRoundStatusPolling),
                .run { send in await send(.startActiveRoundPipeline) }
            )
        case .tallying:
            state.screenStack = [.tallying]
            return .merge(cancelStaleDelegation, cancelStalePrecompute, .send(.startRoundStatusPolling))
        case .finalized:
            state.screenStack = [.results]
            return .merge(
                cancelStaleDelegation,
                cancelStalePrecompute,
                .send(.fetchTallyResults),
                .send(.fetchZodlEndorsements),
                .send(.startNewRoundPolling)
            )
        case .unspecified:
            return .none
        }
    }
}

extension Voting.State {
    mutating func prepareForServiceConfigRefresh() {
        clearLoadedVotingConfigState()
        screenStack = [.loading]
    }

    mutating func clearLoadedVotingConfigState() {
        serviceConfig = nil
        activeSession = nil
        allRounds = []
        voteRecords = [:]
        zodlEndorsedRoundIds = []
        voteRecord = nil
        roundId = ""
        votingRound = VotingRound(
            id: "",
            title: "",
            description: "",
            snapshotHeight: 0,
            snapshotDate: Date(timeIntervalSince1970: 0),
            votingStart: Date(timeIntervalSince1970: 0),
            votingEnd: Date(timeIntervalSince1970: 0),
            proposals: []
        )
        votes = [:]
        votingWeight = 0
        walletNotes = []
        bundleCount = 0
        hotkeyAddress = nil
        tallyResults = [:]
        isLoadingTallyResults = false
        pollsLoadError = false
        resultsLoadError = false
        showPollClosedSheet = false
        showUnverifiedPollWarning = false
        pendingUnverifiedRoundTapId = nil
        shareTrackingStatus = .idle
        shareDelegations = []
        showShareInfoSheet = false
        shareInfoProposalId = nil
        noteWitnessResults = []
        witnessStatus = .notStarted
        cachedWitnesses = []
        witnessTiming = nil
        delegationProofStatus = .notStarted
        isDelegationProofInFlight = false
        pendingBatchSubmission = false
        currentKeystoneBundleIndex = 0
        keystoneBundleSignatures = []
        pendingVotingPczt = nil
        pendingUnsignedDelegationPczt = nil
        keystoneSigningStatus = .idle
        isSubmittingVote = false
        voteSubmissionStep = nil
        currentVoteBundleIndex = nil
        submittingProposalId = nil
        selectedProposalId = nil
        editingFromReview = nil
        batchSubmissionStatus = .idle
        batchVoteErrors = [:]
    }
}
