import Combine
import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

/// Models the SDK boundary: stop returns before the observable stopped state is published.
private final class GiftCardSyncFixture: @unchecked Sendable {
    let states: CurrentValueSubject<SynchronizerState, Never>
    let starts = LockIsolated(0)
    let stops = LockIsolated(0)
    let stopEntered = GiftCardTestGate()
    let stopRelease = GiftCardTestGate()
    let stopTasks = LockIsolated<[Task<Void, Never>]>([])
    let delayedStop: Bool
    let emitsStopped: Bool
    let delayedStart: Bool
    let startEntered = GiftCardTestGate()
    let startRelease = GiftCardTestGate()

    init(delayedStop: Bool = false, emitsStopped: Bool = true, delayedStart: Bool = false, status: SyncStatus = .syncing(0.5, false)) {
        self.delayedStop = delayedStop
        self.emitsStopped = emitsStopped
        self.delayedStart = delayedStart
        var state = SynchronizerState.zero
        state.syncStatus = status
        states = CurrentValueSubject(state)
    }

    func publish(_ status: SyncStatus) {
        var state = states.value
        state.syncStatus = status
        states.send(state)
    }

    func start() async {
        if delayedStart {
            await startEntered.open()
            await startRelease.wait()
        }
        starts.withValue { $0 += 1 }
        publish(.syncing(0.5, false))
    }

    func stop() {
        stops.withValue { $0 += 1 }
        if !delayedStop {
            if emitsStopped { publish(.stopped) }
            return
        }
        let task = Task {
            await stopEntered.open()
            await stopRelease.wait()
            if emitsStopped { publish(.stopped) }
        }
        stopTasks.withValue { $0.append(task) }
    }

    func stopAndWait() async {
        stop()
        if let task = stopTasks.value.last { await task.value }
    }

    func finishStops() async {
        await stopRelease.open()
        for task in stopTasks.value { await task.value }
    }
}

@Suite(.serialized) @MainActor struct RootGiftCardSyncOwnershipTests {
    private func makeStore(sync: GiftCardSyncFixture, appStartState: AppStartState = .unknown) -> StoreOf<Root> {
        var state = Root.State.initial
        state.destinationState.destination = .home
        state.splashAppeared = true
        state.appStartState = appStartState
        state.$selectedWalletAccount.withLock { $0 = nil }
        state.path = .giftCardCoordFlow
        state.giftCardCoordFlowState = GiftCardCoordFlow.State(link: "https://gift.zodl.com/#fixture".redacted)
        return Store(initialState: state) { Root() } withDependencies: {
            $0.giftCard = .mock()
            $0.sdkSynchronizer = .mocked(
                stateStream: { Empty().eraseToAnyPublisher() },
                latestState: { sync.states.value },
                start: { _ in await sync.start() },
                stop: { sync.stop() },
                stopAndWait: { await sync.stopAndWait() }
            )
            $0.exchangeRate = .noOp
            $0.walletStorage = .noOp
            $0.migrationManager.migrationSyncGateFeed = { AsyncStream { $0.finish() } }
            $0.mainQueue = .immediate
            $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
            $0.date.now = { Date(timeIntervalSince1970: 1_000_000) }
        }
    }

    @Test(arguments: [false, true]) func losingTheHandleDoesNotLoseTheAcceptedVisitsPause(replace: Bool) async throws {
        let sync = GiftCardSyncFixture()
        let store = makeStore(sync: sync)
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle()))))).finish()
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .checkFailed(.unknownHandle))))).finish()
        #expect(store.state.giftCardCoordFlowState.redeemState?.handle == nil)
        if replace {
            await store.send(.home(.redeemGiftCardTapped)).finish()
        } else {
            await store.send(.giftCardCoordFlow(.redeem(.delegate(.dismiss)))).finish()
        }
        #expect(sync.starts.value == 1)
        #expect(sync.states.value.syncStatus == .syncing(0.5, false))
    }

    @Test func aResumeCompletionCannotUnpauseAnAcceptedVisitWhoseHandleWasLost() async throws {
        let sync = GiftCardSyncFixture()
        let store = makeStore(sync: sync)
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle()))))).finish()
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .checkFailed(.unknownHandle))))).finish()
        sync.publish(.syncing(0.5, false))
        await store.send(.giftCardSyncStartFinished(UUID(), .success)).finish()
        #expect(sync.states.value.syncStatus == .stopped)
    }

    @Test(arguments: [0, 1, 2, 3, 4]) func stopOperationCompletionDoesNotRequireANewStoppedState(statusIndex: Int) async throws {
        let statuses: [SyncStatus] = [
            .stopped, .unprepared, .upToDate,
            .error(ZcashError.synchronizerDisconnected), .error(ZcashError.synchronizerNotPrepared)
        ]
        let status = statuses[statusIndex]
        let sync = GiftCardSyncFixture(delayedStop: true, emitsStopped: false, status: status)
        let store = makeStore(sync: sync)
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        let opening = store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        await sync.stopEntered.wait()
        await store.send(.giftCardCoordFlow(.redeem(.delegate(.dismiss)))).finish()
        #expect(sync.starts.value == 0)
        await sync.finishStops()
        await opening.finish()
        #expect(sync.starts.value == 1)
        #expect(sync.stops.value == 1)
    }

    @Test func backgroundDuringSuspendedResumeUsesTheOwnedAwaitableStop() async throws {
        let sync = GiftCardSyncFixture(delayedStart: true)
        let store = makeStore(sync: sync)
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle()))))).finish()
        let exiting = store.send(.giftCardCoordFlow(.redeem(.delegate(.dismiss))))
        await sync.startEntered.wait()
        await store.send(.initialization(.appDelegate(.didEnterBackground))).finish()
        await sync.startRelease.open()
        await exiting.finish()
        #expect(sync.starts.value == 1)
        #expect(sync.states.value.syncStatus == .stopped)
        // The initial pause plus the post-start correction. Background must not enqueue an
        // additional unowned fire-and-forget stop that could outlive the next foreground.
        #expect(sync.stops.value == 2)
    }

    @Test(arguments: [false, true]) func rescanResetRetainsBackgroundEligibilityUntilThePendingStopCompletes(backgroundTask: Bool) async throws {
        let background: AppStartState = backgroundTask ? .backgroundTask : .didEnterBackground
        let sync = GiftCardSyncFixture(delayedStop: true)
        let store = makeStore(sync: sync, appStartState: background)
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        let opening = store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        await sync.stopEntered.wait()
        await store.send(.deeplinkWarning(.rescanInZashi)).finish()
        #expect(store.state.appStartState == background)
        #expect(store.state.destinationState.destination == .home)
        #expect(store.state.splashAppeared)
        #expect(store.state.bgTask == nil)
        #expect(sync.starts.value == 0)
        await sync.finishStops()
        await opening.finish()
        #expect(sync.starts.value == 0)
        #expect(sync.states.value.syncStatus == .stopped)
        #expect(store.state.giftCardSyncResumePending)
    }

    @Test(arguments: [false, true]) func deferredStopIsObservedAcrossExitAndBackground(background: Bool) async throws {
        let sync = GiftCardSyncFixture(delayedStop: true)
        let store = makeStore(sync: sync)
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        let opening = store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        await sync.stopEntered.wait()
        if background {
            await store.send(.initialization(.appDelegate(.didEnterBackground))).finish()
        }
        await store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: nil, isTorFailure: false)))).finish()
        // No new resume may race the deferred stop or restart a backgrounded wallet.
        #expect(sync.starts.value == 0)
        await sync.finishStops()
        await opening.finish()
        await store.send(.synchronizerStateChanged(sync.states.value.redacted)).finish()
        #expect(sync.starts.value == (background ? 0 : 1))
        #expect(sync.states.value.syncStatus == (background ? .stopped : .syncing(0.5, false)))
    }
}
