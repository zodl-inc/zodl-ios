//
//  HomeTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 02.06.2022.
//

@preconcurrency import Combine
import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite struct HomeTests {
    @MainActor @Test func synchronizerErrorBringsUpAlert() async {
        let testError = ZcashError.synchronizerNotPrepared

        var state = SynchronizerState.zero
        state.syncStatus = .error(testError)

        let store = TestStore(
            initialState: .initial
        ) {
            Home()
        }

        await store.send(.synchronizerStateChanged(state.redacted))

        await store.receive(.showSynchronizerErrorAlert(testError))

        await store.finish()
    }

    @MainActor @Test func balanceTappedPresentsPoolBalancesSheet() async {
        let store = TestStore(
            initialState: .initial
        ) {
            Home()
        }

        await store.send(.walletBalances(.balanceTapped)) {
            $0.poolBalancesRequest = true
        }

        await store.finish()
    }

    @MainActor @Test func poolBalancesDismissTappedHidesPoolBalancesSheet() async {
        var initialState = Home.State.initial
        initialState.poolBalancesRequest = true

        let store = TestStore(
            initialState: initialState
        ) {
            Home()
        }

        await store.send(.poolBalancesDismissTapped) {
            $0.poolBalancesRequest = false
        }

        await store.finish()
    }
}
