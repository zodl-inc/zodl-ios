//
//  RootGiftCards.swift
//  Zodl
//
//  Created by Zodl on 2026-10-03.
//

import ComposableArchitecture
import Foundation

/// Routing for the "Redeem gift card" flow: Home's entry point, gift card links found by the
/// scanners of the Scan and Send flows, and gift card links the app was opened with.
///
/// Only a card scanned (or pasted) inside the app is ever redeemed. A link handed to the app from
/// outside (a universal link, another app) could have been altered on its way in, so it is
/// discarded and the user is asked to scan the card with the app instead, as for ZIP 321 links
/// (see `DeeplinkWarning`).
extension Root {
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
                    .sendCoordFlow(.path(.element(id: _, action: .scan(.foundGiftCard(let link))))):
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
                    state.giftCardSyncPauseOwner = visit
                }
            }
            if case .giftCardResumeSync(let generation) = action {
                guard state.giftCardSyncGeneration == generation, state.canResumeGiftCardSync,
                      state.giftCardSyncStopId == nil, state.giftCardSyncStartId == nil else { return .none }
                let startId = UUID()
                state.giftCardSyncStartId = startId
                state.giftCardSyncResumePending = false
                state.giftCardSyncIsPaused = false
                return .run { send in
                    try? await sdkSynchronizer.start(true)
                    await send(.giftCardSyncResumed(startId))
                }
            }
            if case .giftCardSyncResumed(let startId) = action {
                if state.giftCardSyncStartId == startId { state.giftCardSyncStartId = nil }
                // A start may finish after a new visit or backgrounding. Retain its completion
                // and correct current desired state; cancelling its effect would hide that race.
                if !state.canResumeGiftCardSync {
                    state.giftCardSyncIsPaused = false
                    state.giftCardSyncResumePending = state.giftCardSyncPauseOwner == nil
                    return stopGiftCardSync(state: &state)
                }
                return reconcileGiftCardSync(state: &state)
            }
            if case .giftCardSyncStopped(let stopId) = action {
                guard state.giftCardSyncStopId == stopId else { return .none }
                state.giftCardSyncStopId = nil
                state.giftCardSyncIsPaused = true
                return reconcileGiftCardSync(state: &state)
            }

            let previous = state.giftCardCoordFlowState.redeemState
            let previousPath = state.path
            let previousPauseOwner = state.giftCardSyncPauseOwner
            let previousStopId = state.giftCardSyncStopId
            let previousStartId = state.giftCardSyncStartId
            let wasPaused = state.giftCardSyncIsPaused
            let resumeWasPending = state.giftCardSyncResumePending
            let wasBackgrounded = state.appStartState == .didEnterBackground
            let previousScanId = state.giftCardCoordFlowState.scanState.cancelId
            let effect = content._reduce(into: &state, action: action)
            // Parent reducers can replace Root.State wholesale. Work already handed to the SDK
            // must retain its identity until actual completion, independently of child state.
            state.giftCardSyncPauseOwner = previousPauseOwner
            state.giftCardSyncStopId = previousStopId
            state.giftCardSyncStartId = previousStartId
            state.giftCardSyncIsPaused = wasPaused
            state.giftCardSyncResumePending = resumeWasPending
            if wasBackgrounded, state.appStartState == .unknown { state.appStartState = .didEnterBackground }
            let exited = previousPath == .giftCardCoordFlow && state.path != .giftCardCoordFlow
            let replaced = previous?.cancelId != state.giftCardCoordFlowState.redeemState?.cancelId
            var effects: [Effect<Action>] = [effect]
            if exited || previousScanId != state.giftCardCoordFlowState.scanState.cancelId {
                effects.append(.cancel(id: previousScanId))
            }
            if (exited || replaced), let previous {
                state.giftCardSyncGeneration = UUID()
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
        guard state.giftCardSyncStopId == nil, state.giftCardSyncStartId == nil else { return .none }
        if state.ownsGiftCardSyncLifecycle, !state.canResumeGiftCardSync, !state.giftCardSyncIsPaused {
            return stopGiftCardSync(state: &state)
        }
        if state.giftCardSyncResumePending, state.canResumeGiftCardSync {
            return .send(.giftCardResumeSync(state.giftCardSyncGeneration))
        }
        return .none
    }

    private func stopGiftCardSync(state: inout State) -> Effect<Action> {
        guard state.giftCardSyncStopId == nil, state.giftCardSyncStartId == nil else { return .none }
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
