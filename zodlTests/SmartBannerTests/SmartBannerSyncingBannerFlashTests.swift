//
//  SmartBannerSyncingBannerFlashTests.swift
//  zodlTests
//
//  MOB-1912 — the syncing banner (priority 4) opens from `latestBlockHeight − fullyScannedHeight`
//  reaching `smartBannerSyncingBlocksThreshold`. The states the SDK publishes before a pass —
//  `start()`'s `.syncing(progress)` and `stop()`'s `.stopped` — carry no `fullyScannedHeight`, so it
//  defaults to 0 and the subtraction says the whole chain is left. The app stops the synchronizer on
//  every background and restarts it on foreground, so every foreground flashed "Syncing 100 %" in
//  and out, and a new wallet's first start flashed "Syncing 0 %", each closing one throttle window
//  later when the first in-pass state or `.upToDate` arrived.
//
//  Pinned here: a fully-scanned height of 0 is "unknown", not "nothing scanned" — it neither opens
//  the banner nor overwrites the last real blocks-remaining figure; the foreground sequence never
//  opens the banner; a real gap at the threshold still does.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SmartBannerSyncingBannerFlashTests {
    private static let chainTip: BlockHeight = 3_000_000

    private static func synchronizerState(
        _ status: SyncStatus,
        fullyScannedHeight: BlockHeight,
        latestBlockHeight: BlockHeight = chainTip
    ) -> RedactableSynchronizerState {
        var state = SynchronizerState.zero
        state.syncStatus = status
        state.latestBlockHeight = latestBlockHeight
        state.fullyScannedHeight = fullyScannedHeight
        return state.redacted
    }

    private func makeStore(_ state: SmartBanner.State = SmartBanner.State()) -> TestStore<SmartBanner.State, SmartBanner.Action> {
        let store = TestStore(initialState: state) {
            SmartBanner()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationManager = .noOp
            $0.sdkSynchronizer = .mocked(latestState: { .zero })
        }
        store.exhaustivity = .off
        return store
    }

    @Test func aPrePassStateWithoutAScannedHeightDoesNotOpenTheSyncingBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.synchronizerStateChanged(Self.synchronizerState(.syncing(0, false), fullyScannedHeight: 0)))
            await store.finish()

            #expect(store.state.priorityContent == nil)
            #expect(store.state.lastKnownBlocksRemaining == -1)
        }
    }

    @Test func theForegroundSequenceNeverOpensTheSyncingBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initial = SmartBanner.State()
            initial.synchronizerStatusSnapshot = .snapshotFor(state: .upToDate)
            let store = makeStore(initial)

            await store.send(.synchronizerStateChanged(Self.synchronizerState(.stopped, fullyScannedHeight: 0)))
            await store.send(.synchronizerStateChanged(Self.synchronizerState(.syncing(0, false), fullyScannedHeight: 0)))
            await store.finish()
            #expect(store.state.priorityContent == nil, "the pre-pass state opened the banner")

            await store.send(
                .synchronizerStateChanged(Self.synchronizerState(.syncing(1.0, true), fullyScannedHeight: Self.chainTip - 10))
            )
            await store.send(.synchronizerStateChanged(Self.synchronizerState(.upToDate, fullyScannedHeight: Self.chainTip)))
            await store.finish()
            #expect(store.state.priorityContent == nil)
        }
    }

    @Test func aRealGapAtTheThresholdStillOpensTheSyncingBanner() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()
            let gap = SmartBanner.Constants.smartBannerSyncingBlocksThreshold

            await store.send(
                .synchronizerStateChanged(Self.synchronizerState(.syncing(0.2, false), fullyScannedHeight: Self.chainTip - gap))
            )
            await store.receive(\.triggerPriority)
            await store.receive(\.openBannerRequest)
            await store.finish()

            #expect(store.state.priorityContent == .priority4)
            #expect(store.state.lastKnownBlocksRemaining == gap)
        }
    }

    @Test func anUnknownScannedHeightKeepsTheLastRealBlocksRemaining() async {
        // A long sync interrupted by backgrounding: the pre-pass state on foreground must not erase
        // the gap the previous pass reported, or the ladder could not re-seat the banner for it.
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initial = SmartBanner.State()
            initial.synchronizerStatusSnapshot = .snapshotFor(state: .stopped)
            initial.lastKnownBlocksRemaining = 50_000
            let store = makeStore(initial)

            await store.send(.synchronizerStateChanged(Self.synchronizerState(.syncing(0, false), fullyScannedHeight: 0)))
            await store.finish()

            #expect(store.state.lastKnownBlocksRemaining == 50_000)
        }
    }
}
