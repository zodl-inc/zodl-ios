import Combine
import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootGiftCardForegroundSyncTests {
    @Test(arguments: [false, true])
    func backgroundStopsAForegroundRetryWithoutReceivingItsRunningState(backgroundWhileStarting: Bool) async throws {
        let engine = LockIsolated(SynchronizerState.zero)
        let awaitedStops = LockIsolated(0)
        let legacyStops = LockIsolated(0)
        let starts = LockIsolated(0)
        let startEntered = GiftCardTestGate()
        let startRelease = GiftCardTestGate()
        let undoEntered = GiftCardTestGate()
        let undoRelease = GiftCardTestGate()
        let undoCompleted = GiftCardTestGate()
        let store = withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.destinationState.destination = .home
            state.splashAppeared = true
            state.$featureFlags.withLock { $0 = FeatureFlags(appLaunchBiometric: false) }
            state.path = .giftCardCoordFlow
            state.giftCardCoordFlowState = GiftCardCoordFlow.State(link: "https://gift.zodl.com/#fixture".redacted)
            engine.withValue { $0.syncStatus = .upToDate }
            let store = TestStore(initialState: state) { Root() } withDependencies: {
                $0.giftCard = .mock()
                $0.mainQueue = .immediate
                $0.continuousClock = TestClock()
                $0.migrationTickInterval = .zero
                $0.exchangeRate = .noOp
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.autoServerSelection.findBestServer = { nil }
                $0.sdkSynchronizer = .mocked(
                    // Simulate a running-state delivery still held by the normal stream throttle.
                    stateStream: { Empty().eraseToAnyPublisher() },
                    latestState: { engine.value },
                    start: { _ in
                        if backgroundWhileStarting {
                            await startEntered.open()
                            await startRelease.wait()
                        }
                        starts.withValue { $0 += 1 }
                        engine.withValue { $0.syncStatus = .syncing(0.5, false) }
                    },
                    stop: {
                        legacyStops.withValue { $0 += 1 }
                        // Preserve the live boundary: legacy stop returns before its work completes.
                        Task {
                            await undoEntered.open()
                            await undoRelease.wait()
                            engine.withValue { $0.syncStatus = .stopped }
                            await undoCompleted.open()
                        }
                    },
                    stopAndWait: {
                        awaitedStops.withValue { $0 += 1 }
                        engine.withValue { $0.syncStatus = .stopped }
                    }
                )
            }
            store.exhaustivity = .off
            return store
        }
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        await store.receive(\.giftCardSyncStopped)
        #expect(awaitedStops.value == 1)
        await store.send(.initialization(.appDelegate(.willEnterForeground)))
        if backgroundWhileStarting {
            await store.receive { action in
                if case .initialization(.retryStart) = action { return true }
                return false
            }
            await startEntered.wait()
        } else {
            await store.receive { action in
                if case .initialization(.retryStartFinished) = action { return true }
                return false
            }
            // After SDK start and its cancellation check, with no running state delivered.
            #expect(starts.value == 1)
            #expect(engine.value.syncStatus == .syncing(0.5, false))
        }
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        if backgroundWhileStarting {
            await store.receive(\.giftCardSyncStopped)
            await startRelease.open()
            await undoEntered.wait()
            // The existing canceled retry still performs its undo after the SDK start returns.
            await undoRelease.open()
            await undoCompleted.wait()
        }
        await store.finish()
        #expect(awaitedStops.value == 2)
        #expect(legacyStops.value == (backgroundWhileStarting ? 1 : 0))
        #expect(engine.value.syncStatus == .stopped)
    }
}
