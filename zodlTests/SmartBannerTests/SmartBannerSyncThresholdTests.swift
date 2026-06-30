//
//  SmartBannerSyncThresholdTests.swift
//  zodlTests
//

import Foundation
import Testing
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SmartBannerSyncThresholdTests {
    private func makeStore(
        blocksRemaining: BlockHeight,
        walletStatus: WalletStatus = .none
    ) -> TestStore<SmartBanner.State, SmartBanner.Action> {
        let initialState = SmartBanner.State()
        initialState.$walletStatus.withLock { $0 = walletStatus }
        var mutableState = initialState
        mutableState.lastKnownBlocksRemaining = blocksRemaining

        let store = TestStore(initialState: mutableState) {
            SmartBanner()
        }
        store.exhaustivity = .off
        store.dependencies.mainQueue = .immediate
        return store
    }

    @Test func blocksRemainingAboveThresholdTriggersSyncBanner() async {
        let store = makeStore(blocksRemaining: 5000)
        await store.send(.evaluatePriority4)
        await store.receive(\.triggerPriority)
    }

    @Test func blocksRemainingAtThresholdTriggersSyncBanner() async {
        let store = makeStore(blocksRemaining: 3456)
        await store.send(.evaluatePriority4)
        await store.receive(\.triggerPriority)
    }

    @Test func blocksRemainingBelowThresholdDoesNotTriggerSyncBanner() async {
        let store = makeStore(blocksRemaining: 100)
        await store.send(.evaluatePriority4)
        await store.receive(\.evaluatePriority45)
    }

    @Test func blocksRemainingZeroDoesNotTriggerSyncBanner() async {
        let store = makeStore(blocksRemaining: 0)
        await store.send(.evaluatePriority4)
        await store.receive(\.evaluatePriority45)
    }

    @Test func sentinelMinusOneDoesNotTriggerSyncBanner() async {
        let store = makeStore(blocksRemaining: -1)
        await store.send(.evaluatePriority4)
        await store.receive(\.evaluatePriority45)
    }

    @Test func restoringStateNeverTriggersSyncBanner() async {
        let store = makeStore(blocksRemaining: 100_000, walletStatus: .restoring)
        await store.send(.evaluatePriority4)
        await store.receive(\.evaluatePriority45)
    }
}
