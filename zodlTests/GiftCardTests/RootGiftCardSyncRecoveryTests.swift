import Combine
import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(3))) @MainActor struct RootGiftCardSyncRecoveryTests {
    private final class Engine: @unchecked Sendable {
        let starts = LockIsolated(0)
        let stops = LockIsolated(0)
        let advances = LockIsolated<[MigrationOpenPhase]>([])
        let subscriptions = LockIsolated(0)
        let blocked = LockIsolated(false)
        let entered = GiftCardTestGate()
        let release = GiftCardTestGate()
        let preparationEntered = GiftCardTestGate()
        let preparationRelease = GiftCardTestGate()
        var holdPreparation = false
        var visit: MigrationVisit = .sync
        var cancelled = false
        var failures = 1
        var migrationFailure = false
        var suspended = false

        func start() async throws {
            let attempt = starts.withValue {
                $0 += 1
                return $0
            }
            if suspended {
                await entered.open()
                await release.wait()
            }
            if cancelled { throw CancellationError() }
            if attempt <= failures {
                if migrationFailure { throw ZcashError.migrationSyncBlocked }
                throw ZcashError.synchronizerDisconnected
            }
        }
    }

    private func makeStore(
        _ engine: Engine, clock: TestClock<Swift.Duration>, pending: Bool = true, cardPresented: Bool = false
    ) -> TestStore<Root.State, Root.Action> {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.destinationState.destination = .home
            state.splashAppeared = true
            state.giftCardSyncResumePending = pending
            if cardPresented {
                state.path = .giftCardCoordFlow
                state.giftCardCoordFlowState = GiftCardCoordFlow.State(link: "https://gift.zodl.com/#fixture".redacted)
            }
            state.giftCardSyncIsPaused = pending
            state.$featureFlags.withLock { $0 = FeatureFlags(appLaunchBiometric: false) }
            let store = TestStore(initialState: state) { Root() } withDependencies: {
                $0.giftCard = .mock()
                $0.mainQueue = .immediate
                $0.continuousClock = clock
                $0.migrationTickInterval = .zero
                $0.exchangeRate = .noOp
                $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
                $0.migrationManager.visitKind = {
                    if engine.holdPreparation {
                        await engine.preparationEntered.open()
                        await engine.preparationRelease.wait()
                    }
                    return engine.visit
                }
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.autoServerSelection.findBestServer = { nil }
                $0.migrationManager.advance = { phase in
                    engine.advances.withValue { $0.append(phase) }
                    return .broadcast(id: 1)
                }
                $0.sdkSynchronizer = .mocked(
                    stateStream: {
                        engine.subscriptions.withValue { $0 += 1 }
                        return Empty().eraseToAnyPublisher()
                    },
                    latestState: {
                        var state = SynchronizerState.zero
                        state.syncStatus = .stopped
                        return state
                    },
                    start: { _ in try await engine.start() },
                    stopAndWait: { engine.stops.withValue { $0 += 1 } },
                    isMigrationSyncBlocked: { engine.blocked.value }
                )
            }
            store.exhaustivity = .off
            return store
        }
    }

    private func drain(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    // Swallowing the first failure strands sync; immediately reconciling pending demand spins.
    @Test(arguments: [1, 2]) func failedStartKeepsDemandAndRetriesOnlyOnceAfterFifteenSeconds(failures: Int) async {
        let engine = Engine()
        engine.failures = failures
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive({
            if case .giftCardSyncStartFinished(_, .transientFailure(.synchronizerDisconnected)) = $0 { return true }
            return false
        }, timeout: .seconds(2))
        #expect(store.state.giftCardSyncResumePending)
        #expect(store.state.didScheduleStartFailureRetry)
        await clock.advance(by: .seconds(14))
        #expect(engine.starts.value == 1)
        await clock.advance(by: .seconds(1))
        await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        #expect(engine.starts.value == 2)
        #expect(store.state.giftCardSyncResumePending == (failures == 2))
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 2)
        await drain(store)
    }

    @Test(arguments: [0, 1, 2]) func delayedRetryCannotOutliveBackgroundAcceptedVisitOrRootReset(boundary: Int) async throws {
        let engine = Engine()
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        let retiredGeneration = store.state.giftCardSyncGeneration
        await store.send(.giftCardResumeSync(retiredGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(store.state.giftCardSyncResumePending)
        if boundary == 0 {
            await store.send(.initialization(.appDelegate(.didEnterBackground)))
        } else if boundary == 1 {
            await store.send(.home(.redeemGiftCardTapped))
            await store.send(.giftCardCoordFlow(.scan(.foundGiftCard("https://gift.zodl.com/#fixture".redacted))))
            let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
            await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        } else {
            await store.send(.deeplinkWarning(.rescanInZashi))
        }
        await store.send(.giftCardRetrySync(retiredGeneration))
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 1)
        await drain(store)
    }

    // The real Root migration policy must discharge beforeSync, restore feeds, and hold demand.
    @Test func migrationRefusalRestoresObservationAndWaitsForClearance() async {
        let engine = Engine()
        engine.migrationFailure = true
        engine.blocked.setValue(true)
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(store.state.syncDeferredByMigrationGate)
        #expect(store.state.giftCardSyncResumePending)
        #expect(engine.advances.value.filter { $0 == .beforeSync }.count == 2)
        #expect(engine.subscriptions.value > 0)
        engine.blocked.setValue(false)
        await store.send(.migrationSyncGateChanged(false))
        await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        #expect(engine.starts.value == 2)
        #expect(!store.state.giftCardSyncResumePending)
        await drain(store)
    }

    @Test func ordinaryRetryCannotOverlapAnOwnedNativeStart() async {
        let engine = Engine()
        engine.failures = 0
        engine.suspended = true
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.entered.wait()
        await store.send(.initialization(.retryStart))
        await engine.release.open()
        await store.receive(\.giftCardSyncStartFinished)
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 1)
        await drain(store)
    }

    @Test func backgroundDuringGiftPreparationDoesNotStartTheEngine() async {
        let engine = Engine()
        engine.failures = 0
        engine.holdPreparation = true
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.preparationEntered.wait()
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        await engine.preparationRelease.open()
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 0)
        #expect(store.state.giftCardSyncStartId == nil)
        await drain(store)
    }

    @Test func successfulRecoveryRestoresForegroundSubscriptions() async {
        let engine = Engine()
        engine.failures = 0
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive(\.giftCardSyncObserve, timeout: .seconds(2))
        #expect(engine.subscriptions.value > 0)
        await drain(store)
    }

    @Test func cancelledStartKeepsDemandWithoutAutomaticRetry() async {
        let engine = Engine()
        engine.cancelled = true
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished) { state in
            #expect(state.giftCardSyncResumePending)
        }
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 1)
        #expect(!store.state.didScheduleStartFailureRetry)
        await drain(store)
    }

    @Test func acceptedVisitDuringSuspendedStartWaitsForCompletionBeforeStopping() async throws {
        let engine = Engine()
        engine.failures = 0
        engine.suspended = true
        let store = makeStore(engine, clock: TestClock(), cardPresented: true)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.entered.wait()
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        await store.send(.initialization(.retryStart))
        #expect(engine.stops.value == 0)
        await engine.release.open()
        await store.receive(\.giftCardSyncStopped)
        #expect(engine.starts.value == 1)
        #expect(engine.stops.value == 1)
        #expect(store.state.giftCardSyncPauseOwner == visit)
        await drain(store)
    }

    @Test func persistentMigrationRefusalPermitsOnlyOneFalseSeedRecheck() async {
        let engine = Engine()
        engine.migrationFailure = true
        engine.failures = 100
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive(\.giftCardSyncStartFinished)
        for _ in 0..<3 { await store.send(.migrationSyncGateChanged(false)) }
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 2)
        #expect(store.state.giftCardSyncResumePending)
        await drain(store)
    }

    @Test func gateClearanceDuringOwnedStartCannotAdmitAnotherStart() async {
        let engine = Engine()
        engine.failures = 0
        engine.suspended = true
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.entered.wait()
        await store.send(.migrationGateDeferredSyncStart)
        await store.send(.migrationSyncGateChanged(true))
        await store.send(.migrationSyncGateChanged(false))
        await engine.release.open()
        await store.receive(\.giftCardSyncStartFinished)
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 1)
        await drain(store)
    }

    @Test func cancelledOrdinaryPreparationReleasesItsCompletionFence() async {
        let engine = Engine()
        engine.holdPreparation = true
        let store = makeStore(engine, clock: TestClock(), pending: false)
        await store.send(.initialization(.retryStart))
        await engine.preparationEntered.wait()
        #expect(store.state.ordinarySyncOperations.count == 1)
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        await engine.preparationRelease.open()
        await store.receive(\.ordinarySyncFinished)
        #expect(engine.starts.value == 0)
        #expect(store.state.ordinarySyncOperations.isEmpty)
        await drain(store)
    }

    @Test func ordinaryCompletionSurvivesRootResetAndBackground() async throws {
        let engine = Engine()
        engine.failures = 0
        engine.suspended = true
        let store = makeStore(engine, clock: TestClock(), pending: false, cardPresented: true)
        await store.send(.initialization(.retryStart))
        await engine.entered.wait()
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        let operation = try #require(store.state.ordinarySyncOperations.first)
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        await store.send(.deeplinkWarning(.rescanInZashi))
        #expect(store.state.ordinarySyncOperations.contains(operation))
        #expect(engine.stops.value == 0)
        await engine.release.open()
        await store.receive(\.ordinarySyncFinished)
        await store.receive(\.giftCardSyncStopped)
        #expect(store.state.ordinarySyncOperations.isEmpty)
        #expect(engine.starts.value == 1)
        #expect(engine.stops.value == 1)
        await drain(store)
    }


    @Test func ordinaryFailureAndGiftFailureShareOneForegroundRetryBudget() async throws {
        let engine = Engine()
        engine.failures = 2
        let clock = TestClock()
        let store = makeStore(engine, clock: clock, pending: false, cardPresented: true)
        await store.send(.initialization(.retryStart))
        await store.receive(\.ordinarySyncFinished)
        #expect(store.state.didScheduleStartFailureRetry)
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        await store.receive(\.giftCardSyncStopped)
        await store.send(.giftCardCoordFlow(.redeem(.delegate(.dismiss))))
        await store.receive(\.giftCardSyncStartFinished)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 2)
        #expect(store.state.giftCardSyncResumePending)
        await drain(store)
    }

    @Test func broadcastVisitDefersWithoutCallingNativeStartOrSpinningOnFalseSeeds() async {
        let engine = Engine()
        engine.visit = .send
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive(\.giftCardSyncStartFinished)
        for _ in 0..<3 { await store.send(.migrationSyncGateChanged(false)) }
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 0)
        #expect(engine.advances.value == [.beforeSync, .beforeSync])
        #expect(store.state.syncDeferredByMigrationGate)
        await drain(store)
    }

    @Test func immediateOrdinaryCompletionAlwaysReleasesTheAdmissionFence() async {
        let engine = Engine()
        engine.failures = 0
        let store = makeStore(engine, clock: TestClock(), pending: false)
        await store.send(.initialization(.retryStart))
        await store.receive(\.ordinarySyncFinished)
        #expect(engine.starts.value == 1)
        #expect(store.state.ordinarySyncOperations.isEmpty)
        await drain(store)
    }


    @Test func gateClearanceBeforeObservationRestorationGetsOneFreshRecheck() async {
        let engine = Engine()
        engine.migrationFailure = true
        // The native refusal observed a blocked gate, but by the first restored feed it is clear.
        engine.blocked.setValue(false)
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        #expect(engine.starts.value == 2)
        #expect(!store.state.giftCardSyncResumePending)
        await drain(store)
    }


    @Test func migrationClearanceInBackgroundWaitsForForeground() async {
        let engine = Engine()
        engine.migrationFailure = true
        engine.blocked.setValue(true)
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        engine.blocked.setValue(false)
        await store.send(.migrationSyncGateChanged(false))
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 1)
        await store.send(.initialization(.appDelegate(.willEnterForeground)))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 2)
        await drain(store)
    }


    @Test(arguments: [false, true])
    func foregroundRefreshesTheMigrationGateThatWasUnobservedInBackground(gateClears: Bool) async {
        let engine = Engine()
        engine.migrationFailure = true
        engine.blocked.setValue(true)
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive({
            if case .migrationSyncGateChanged(true) = $0 { return true }
            return false
        }, timeout: .seconds(2))
        #expect(store.state.lastMigrationSyncGateBlocked)
        let subscriptionsBeforeBackground = engine.subscriptions.value
        let retiredGeneration = store.state.giftCardSyncGeneration
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        // No reducer gate action: the actual SDK gate changes while its observations are cancelled.
        engine.blocked.setValue(!gateClears)
        await store.send(.giftCardSyncObserve(retiredGeneration))
        #expect(engine.subscriptions.value == subscriptionsBeforeBackground)
        await store.send(.initialization(.appDelegate(.willEnterForeground)))
        await store.receive(\.giftCardSyncObserve, timeout: .seconds(2))
        await store.receive({
            if case .migrationSyncGateChanged(let blocked) = $0 { return blocked == !gateClears }
            return false
        }, timeout: .seconds(2))
        #expect(engine.subscriptions.value > subscriptionsBeforeBackground)
        if gateClears {
            await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        }
        await store.skipReceivedActions(strict: false)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == (gateClears ? 2 : 1))
        #expect(store.state.giftCardSyncResumePending == !gateClears)
        #expect(store.state.lastMigrationSyncGateBlocked == !gateClears)
        await drain(store)
    }

}
