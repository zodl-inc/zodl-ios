//
//  RootGiftCards.swift
//  Zodl
//
//  Created by Zodl on 2026-10-03.
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

/// Routing for the "Redeem gift card" flow: Home's entry point, gift card links found by the
/// scanners of the Scan, Send, Swap/Pay and Settings flows, and gift card links the app was opened with.
///
/// Only a card scanned (or pasted) inside the app is ever redeemed. A link handed to the app from
/// outside (a universal link, another app) could have been altered on its way in, so it is
/// discarded and the user is asked to scan the card with the app instead, as for ZIP 321 links
/// (see `DeeplinkWarning`).
extension Root {
    enum GiftCardSyncStartOutcome: Equatable {
        case success
        case cancelled
        case transientFailure(ZcashError)
        case migrationDeferred
    }

    enum GiftCardSyncRecovery: Equatable {
        case none
        case delayedRetry
        case migrationDeferred
        case waitingForExternalTrigger
    }

    func giftCardsReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .initialization(.appDelegate(.didFinishLaunching)):
                // A card wallet holds the card's keys and the claim's recipient. One left behind
                // by a run that was killed or crashed mid-flow is deleted now, before any card can
                // be opened; the SDK spares a card that is open.
                return .run { _ in giftCard.removeLeftoverWallets() }

            case .home(.redeemGiftCardTapped):
                return openGiftCardFlow(.initial, state: &state)

            case .scanCoordFlow(.scan(.foundGiftCard(let link))),
                    .scanCoordFlow(.path(.element(id: _, action: .scan(.foundGiftCard(let link))))),
                    .sendCoordFlow(.path(.element(id: _, action: .scan(.foundGiftCard(let link))))),
                    .swapAndPayCoordFlow(.path(.element(id: _, action: .scan(.foundGiftCard(let link))))),
                    .settings(.path(.element(id: _, action: .scan(.foundGiftCard(let link))))):
                // The user scanned a gift card where they expected an address: take them to the
                // redeem flow instead. Nothing has been sent from these flows at scan time.
                return openGiftCardFlow(GiftCardCoordFlow.State(link: link), state: &state)

            case .giftCardCoordFlow(.scan(.cancelTapped)),
                    .giftCardCoordFlow(.redeem(.delegate(.dismiss))):
                state.path = nil
                return .none

            case .giftCardCoordFlow(.redeem(.delegate(.redeemed))):
                return .send(.fetchTransactionsForTheSelectedAccount)

            default:
                return .none
            }
        }
    }

    /// Handles a gift card link the app was opened with. The link itself is never read: it opens
    /// the scanner asking the user to scan the card with the app, now if nothing on screen stands
    /// in the way, otherwise as soon as it can (`canOpenGiftCardFlow`).
    func receiveExternalGiftCardLink(state: inout Root.State) -> Effect<Root.Action> {
        LoggerProxy.event("[GiftCard] external link received, asking for an in-app scan")
        guard state.canOpenGiftCardFlow else {
            state.isGiftCardRescanPending = true
            return .none
        }
        return openGiftCardFlow(.rescanRequested, state: &state)
    }

    /// Presents a fresh gift card flow. The outer lifecycle boundary retires the previous visit.
    func openGiftCardFlow(_ flowState: GiftCardCoordFlow.State, state: inout Root.State) -> Effect<Root.Action> {
        state.isGiftCardRescanPending = false
        state.giftCardCoordFlowState = flowState
        state.path = .giftCardCoordFlow
        exchangeRate.refreshExchangeRateUSD()
        return .none
    }

    /// Outermost boundary: parent navigation and onChange routing may both replace child state.
    /// Reject responses before optional scopes, and snapshot resources before any reducer resets them.
    func giftCardLifecycle(_ content: some Reducer<State, Action>) -> Reduce<State, Action> {
        Reduce { state, action in
            if case let .giftCardCoordFlow(.redeem(.response(visit, response))) = action {
                guard state.path == .giftCardCoordFlow, state.giftCardCoordFlowState.redeemState?.cancelId == visit else {
                    if case .opened(let handle) = response {
                        return .run { _ in await giftCard.cleanup(handle) }
                    }
                    return .none
                }
                if case .opened = response {
                    state.giftCardSyncGeneration = UUID()
                    state.giftCardSyncResumePending = false
                    state.giftCardSyncRecovery = .none
                    state.giftCardSyncDidRecheckMigrationSeed = false
                    state.giftCardSyncPauseOwner = visit
                }
            }
            if case .giftCardRetrySync(let generation) = action {
                guard state.giftCardSyncGeneration == generation,
                      state.giftCardSyncRecovery == .delayedRetry else { return .none }
                state.giftCardSyncRecovery = .none
                return reconcileGiftCardSync(state: &state)
            }
            if case .ordinarySyncFinished(let operation) = action {
                guard state.ordinarySyncOperations.remove(operation) != nil else { return .none }
                if state.ownsGiftCardSyncLifecycle { state.giftCardSyncIsPaused = false }
                return reconcileGiftCardSync(state: &state)
            }
            if case .initialization(.retryStart) = action, state.ownsGiftCardSyncLifecycle {
                // Normal timers and gate wake-ups must use the same native admission fence.
                if state.giftCardSyncRecovery == .waitingForExternalTrigger
                    || (state.giftCardSyncRecovery == .migrationDeferred && !state.lastMigrationSyncGateBlocked) {
                    state.giftCardSyncRecovery = .none
                    state.giftCardSyncDidRecheckMigrationSeed = false
                }
                return reconcileGiftCardSync(state: &state)
            }
            if case .giftCardResumeSync(let generation) = action {
                guard state.giftCardSyncGeneration == generation, state.canResumeGiftCardSync,
                      state.giftCardSyncResumePending, !state.lastMigrationSyncGateBlocked,
                      state.giftCardSyncRecovery == .none,
                      state.giftCardSyncStopId == nil, state.giftCardSyncStartId == nil,
                      state.ordinarySyncOperations.isEmpty else { return .none }
                let startId = UUID()
                state.giftCardSyncStartId = startId
                state.giftCardSyncStartGeneration = generation
                state.giftCardSyncGateClearedDuringStart = false
                state.syncDeferredByMigrationGate = false
                @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast = false
                $migrationStoppedSyncForBroadcast.withLock { $0 = false }
                state.giftCardSyncIsPaused = false
                return .run { send in
                    await send(.giftCardSyncVisitReady(startId, await migrationManager.visitKind()))
                }
            }
            if case .giftCardSyncObserve(let generation) = action {
                guard generation == state.giftCardSyncGeneration, state.canResumeGiftCardSync else { return .none }
                state.giftCardSyncObservationGeneration = generation
                return .merge(
                    initializationReduce()._reduce(into: &state, action: .initialization(.registerForSynchronizersUpdate(generation: nil))),
                    .send(.observeTransactions)
                )
            }
            if case .giftCardSyncVisitReady(let startId, let visit) = action {
                guard state.canContinueGiftCardSyncStart(startId) else {
                    return .send(.giftCardSyncStartFinished(startId, .cancelled))
                }
                if visit == .send { state.syncDeferredByMigrationGate = true }
                return .run { send in
                    _ = await migrationManager.advance(.beforeSync)
                    if visit == .send {
                        await send(.giftCardSyncStartFinished(startId, .migrationDeferred))
                    } else {
                        await send(.giftCardSyncStartReady(startId))
                    }
                }
            }
            if case .giftCardSyncMigrationRefused(let startId) = action {
                guard state.canContinueGiftCardSyncStart(startId) else {
                    return .send(.giftCardSyncStartFinished(startId, .cancelled))
                }
                state.syncDeferredByMigrationGate = true
                return .run { send in
                    _ = await migrationManager.advance(.beforeSync)
                    await send(.giftCardSyncStartFinished(startId, .migrationDeferred))
                }
            }
            if case .giftCardSyncStartReady(let startId) = action {
                guard state.canContinueGiftCardSyncStart(startId) else {
                    return .send(.giftCardSyncStartFinished(startId, .cancelled))
                }
                if state.lastMigrationSyncGateBlocked {
                    return .send(.giftCardSyncStartFinished(startId, .migrationDeferred))
                }
                // Re-check admission after both asynchronous preparation boundaries. From here
                // through completion this native operation retains its identity even in background.
                return .run { send in
                    do {
                        try await sdkSynchronizer.start(true)
                        await send(.giftCardSyncStartFinished(startId, .success))
                    } catch is CancellationError {
                        await send(.giftCardSyncStartFinished(startId, .cancelled))
                    } catch ZcashError.migrationSyncBlocked {
                        await send(.giftCardSyncMigrationRefused(startId))
                    } catch {
                        await send(.giftCardSyncStartFinished(startId, .transientFailure(error.toZcashError())))
                    }
                }
            }
            if case .giftCardSyncStartFinished(let startId, let outcome) = action {
                let isOwned = state.giftCardSyncStartId == startId
                let isCurrent = isOwned && state.giftCardSyncStartGeneration == state.giftCardSyncGeneration
                if isOwned {
                    state.giftCardSyncStartId = nil
                    state.giftCardSyncStartGeneration = nil
                }
                // Stale successes still changed the engine. Stale failures cannot recover a new visit.
                if outcome == .success {
                    if isCurrent {
                        state.giftCardSyncResumePending = false
                        state.giftCardSyncRecovery = .none
                        state.syncDeferredByMigrationGate = false
                        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast = false
                        $migrationStoppedSyncForBroadcast.withLock { $0 = false }
                    }
                    if !state.canResumeGiftCardSync {
                        state.giftCardSyncIsPaused = false
                        state.giftCardSyncResumePending = state.giftCardSyncPauseOwner == nil
                        return stopGiftCardSync(state: &state)
                    }
                    return .merge(
                        reconcileGiftCardSync(state: &state),
                        isCurrent ? .send(.giftCardSyncObserve(state.giftCardSyncGeneration)) : .none
                    )
                }
                guard isCurrent else { return reconcileGiftCardSync(state: &state) }
                state.giftCardSyncResumePending = true
                switch outcome {
                case .success:
                    break
                case .cancelled:
                    state.giftCardSyncRecovery = .waitingForExternalTrigger
                case .migrationDeferred:
                    state.syncDeferredByMigrationGate = true
                    state.giftCardSyncRecovery = state.giftCardSyncGateClearedDuringStart ? .none : .migrationDeferred
                case .transientFailure:
                    state.giftCardSyncRecovery = state.didScheduleStartFailureRetry ? .waitingForExternalTrigger : .delayedRetry
                }
                var effects: [Effect<Action>] = []
                if state.canResumeGiftCardSync {
                    // Restore the same state and migration feeds the ordinary failure path restores.
                    // A migration hold admits only one seed recheck until a genuine edge or
                    // external trigger. Re-registering these feeds cannot replenish that allowance.
                    effects.append(.send(.giftCardSyncObserve(state.giftCardSyncGeneration)))
                    if state.giftCardSyncRecovery == .delayedRetry {
                        state.didScheduleStartFailureRetry = true
                        let generation = state.giftCardSyncGeneration
                        effects.append(.run { send in
                            try await continuousClock.sleep(for: .seconds(15))
                            await send(.giftCardRetrySync(generation))
                        }.cancellable(id: state.startFailureRetryCancelId, cancelInFlight: true))
                    }
                }
                effects.append(reconcileGiftCardSync(state: &state))
                return .merge(effects)
            }
            if case .giftCardSyncStopped(let stopId) = action {
                guard state.giftCardSyncStopId == stopId else { return .none }
                state.giftCardSyncStopId = nil
                state.giftCardSyncIsPaused = true
                return reconcileGiftCardSync(state: &state)
            }

            if case .initialization(.appDelegate(.didEnterBackground)) = action, state.ownsGiftCardSyncLifecycle {
                // A foreground retry can start the SDK before its throttled running state arrives.
                // Background must request an owned stop even when the last observed pause completed.
                state.giftCardSyncIsPaused = false
                state.giftCardSyncGeneration = UUID()
                state.giftCardSyncRecovery = .waitingForExternalTrigger
            }
            if case .initialization(.appDelegate(.willEnterForeground)) = action {
                state.giftCardSyncGeneration = UUID()
                state.giftCardSyncRecovery = .none
                state.giftCardSyncDidRecheckMigrationSeed = false
            }
            if case .migrationSyncGateChanged(false) = action, state.ownsGiftCardSyncLifecycle {
                let genuineClearance = state.lastMigrationSyncGateBlocked
                let deferred = state.syncDeferredByMigrationGate || state.giftCardSyncRecovery == .migrationDeferred
                if genuineClearance || (deferred && !state.giftCardSyncDidRecheckMigrationSeed) {
                    // A true clearing edge begins a new epoch. A nonblocking seed bridges the
                    // missed-edge window once, but repeated refusals cannot create a seed loop.
                    state.giftCardSyncDidRecheckMigrationSeed = !genuineClearance
                    if state.giftCardSyncStartId != nil { state.giftCardSyncGateClearedDuringStart = true }
                    if state.giftCardSyncRecovery == .migrationDeferred { state.giftCardSyncRecovery = .none }
                }
            }
            let previous = state.giftCardCoordFlowState.redeemState
            let previousPath = state.path
            let previousPauseOwner = state.giftCardSyncPauseOwner
            let previousStopId = state.giftCardSyncStopId
            let previousStartId = state.giftCardSyncStartId
            let previousStartGeneration = state.giftCardSyncStartGeneration
            let previousOrdinaryOperations = state.ordinarySyncOperations
            let previousGeneration = state.giftCardSyncGeneration
            let previousRecovery = state.giftCardSyncRecovery
            let previousRetryBudget = state.didScheduleStartFailureRetry
            let wasPaused = state.giftCardSyncIsPaused
            let resumeWasPending = state.giftCardSyncResumePending
            let previousAppStartState = state.appStartState
            let previousScanId = state.giftCardCoordFlowState.scanState.cancelId
            let effect = content._reduce(into: &state, action: action)
            // Parent reducers can replace Root.State wholesale. Work already handed to the SDK
            // must retain its identity until actual completion, independently of child state.
            state.giftCardSyncPauseOwner = previousPauseOwner
            state.giftCardSyncStopId = previousStopId
            state.giftCardSyncStartId = previousStartId
            state.giftCardSyncStartGeneration = previousStartGeneration
            state.ordinarySyncOperations.formUnion(previousOrdinaryOperations)
            if state.giftCardSyncGeneration != previousGeneration {
                // A wholesale reset retires timer work but preserves already-admitted native work.
                state.giftCardSyncRecovery = previousRecovery == .none ? .none : .waitingForExternalTrigger
                state.didScheduleStartFailureRetry = previousRetryBudget
            }
            state.giftCardSyncIsPaused = wasPaused
            state.giftCardSyncResumePending = resumeWasPending
            if state.appStartState == .unknown,
               previousAppStartState == .didEnterBackground || previousAppStartState == .backgroundTask {
                state.appStartState = previousAppStartState
            }
            let exited = previousPath == .giftCardCoordFlow && state.path != .giftCardCoordFlow
            let replaced = previous?.cancelId != state.giftCardCoordFlowState.redeemState?.cancelId
            var effects: [Effect<Action>] = [effect]
            if exited || previousScanId != state.giftCardCoordFlowState.scanState.cancelId {
                effects.append(.cancel(id: previousScanId))
            }
            if (exited || replaced), let previous {
                state.giftCardSyncGeneration = UUID()
                state.giftCardSyncRecovery = .none
                state.giftCardSyncDidRecheckMigrationSeed = false
                effects.append(.cancel(id: state.startFailureRetryCancelId))
                if exited {
                    state.giftCardCoordFlowState = GiftCardCoordFlow.State()
                }
                state.giftCardSyncResumePending = state.giftCardSyncResumePending
                    || previousPauseOwner == previous.cancelId || previous.handle != nil
                if previousPauseOwner == previous.cancelId { state.giftCardSyncPauseOwner = nil }
                effects.append(.cancel(id: previous.cancelId))
                effects.append(.cancel(id: previous.autoRetryCancelId))
                // The coordinator handles an explicit cleanUp when it is tested or hosted alone.
                switch action {
                case .giftCardCoordFlow(.cleanUp), .giftCardCoordFlow(.scan(.foundGiftCard)):
                    break // Internal replacement is closed by the coordinator.
                default:
                    if let handle = previous.handle {
                        effects.append(.run { _ in await giftCard.cleanup(handle) })
                    }
                }
            }
            if case .synchronizerStateChanged(let snapshot) = action, state.giftCardSyncPauseOwner != nil {
                switch snapshot.data.syncStatus {
                case .syncing, .upToDate:
                    // Other app lifecycle code can also start the SDK. Reconcile its observed
                    // running state while this visit owns a pause; stream ticks are not stop acknowledgments.
                    state.giftCardSyncIsPaused = false
                case .stopped, .unprepared, .error:
                    break
                }
            }
            effects.append(reconcileGiftCardSync(state: &state))
            return .merge(effects)
        }
    }

    private func reconcileGiftCardSync(state: inout State) -> Effect<Action> {
        guard state.giftCardSyncStopId == nil, state.giftCardSyncStartId == nil, state.ordinarySyncOperations.isEmpty else { return .none }
        if state.ownsGiftCardSyncLifecycle, !state.canResumeGiftCardSync, !state.giftCardSyncIsPaused {
            return stopGiftCardSync(state: &state)
        }
        if state.giftCardSyncResumePending, state.canResumeGiftCardSync, state.giftCardSyncRecovery == .none {
            if state.lastMigrationSyncGateBlocked {
                // Background cancels the gate feeds. Refresh once in this recovery generation
                // before trusting a cached block that may have cleared while nobody observed it.
                guard state.giftCardSyncObservationGeneration != state.giftCardSyncGeneration else { return .none }
                state.giftCardSyncObservationGeneration = state.giftCardSyncGeneration
                return .send(.giftCardSyncObserve(state.giftCardSyncGeneration))
            }
            return .send(.giftCardResumeSync(state.giftCardSyncGeneration))
        }
        return .none
    }

    private func stopGiftCardSync(state: inout State) -> Effect<Action> {
        guard state.giftCardSyncStopId == nil, state.giftCardSyncStartId == nil, state.ordinarySyncOperations.isEmpty else { return .none }
        let stopId = UUID()
        state.giftCardSyncStopId = stopId
        // This effect belongs to Root, not the exiting visit or its foreground subscriptions.
        // Awaiting the native operation also handles idle engines that emit no stopped event.
        return .run { send in
            await sdkSynchronizer.stopAndWait()
            await send(.giftCardSyncStopped(stopId))
        }
    }
}

extension Root.State {
    func canContinueGiftCardSyncStart(_ startId: UUID) -> Bool {
        giftCardSyncStartId == startId && giftCardSyncStartGeneration == giftCardSyncGeneration && canResumeGiftCardSync
    }

    var ownsGiftCardSyncLifecycle: Bool {
        giftCardSyncPauseOwner != nil || giftCardSyncStopId != nil
            || giftCardSyncStartId != nil || giftCardSyncResumePending
    }

    var canResumeGiftCardSync: Bool {
        giftCardSyncPauseOwner == nil
            && destinationState.destination == .home && splashAppeared && bgTask == nil
            && appStartState != .didEnterBackground && appStartState != .backgroundTask
    }
}
