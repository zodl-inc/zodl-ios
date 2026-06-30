//
//  BalancesTests.swift
//  zodlTests
//
//  Batch 3 — balances. Covers Balances reducer computed flags, updateBalance(nil)/non-nil
//  spendability + sapling/orchard/transparent aggregation, shielding-processor state, and
//  shieldFunds (Features/BalanceBreakdown/BalancesStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct BalancesTests {
    @Test func pendingFlags() {
        let pending = state(changePending: Zatoshi(5), pendingTransactions: Zatoshi(7))
        #expect(pending.isPendingChange)
        #expect(pending.isPendingInProcess)

        let idle = state()
        #expect(!idle.isPendingChange)
        #expect(!idle.isPendingInProcess)
    }

    @Test func shieldabilityFlags() {
        let shieldable = state(transparentBalance: Zatoshi(2_000_000))
        #expect(shieldable.isShieldableBalanceAvailable)
        #expect(!shieldable.isShieldingButtonDisabled)

        let belowThreshold = state(transparentBalance: Zatoshi(500))
        #expect(!belowThreshold.isShieldableBalanceAvailable)
        #expect(belowThreshold.isShieldingButtonDisabled)

        let shielding = state(isShielding: true, transparentBalance: Zatoshi(2_000_000))
        #expect(shielding.isShieldingButtonDisabled) // disabled while shielding even if available
    }

    @Test func isProcessingZeroAvailableBalance() {
        var processing = state(shieldedBalance: .zero, transparentBalance: Zatoshi(10))
        processing.autoShieldingThreshold = Zatoshi(50)
        processing.totalBalance = Zatoshi(10)
        #expect(processing.isProcessingZeroAvailableBalance)

        var hasTransparentAboveThreshold = state(shieldedBalance: .zero, transparentBalance: Zatoshi(100))
        hasTransparentAboveThreshold.autoShieldingThreshold = Zatoshi(50)
        #expect(!hasTransparentAboveThreshold.isProcessingZeroAvailableBalance)
    }

    @Test func isPendingTransactionReflectsSharedTransactions() {
        var state = state()
        state.$transactions.withLock { $0 = [] }
        #expect(!state.isPendingTransaction)
        state.$transactions.withLock { $0 = [TransactionState(pendingSendId: "p", zecAmount: Zatoshi(1))] }
        #expect(state.isPendingTransaction)
    }

    @MainActor @Test func updateBalanceWithNilZerosAndEmitsEverythingSpendable() async {
        let store = TestStore(initialState: state(autoShieldingThreshold: Zatoshi(1_000_000))) {
            Balances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
        }
        store.exhaustivity = .off
        await store.send(.updateBalance(nil))
        await store.receive(\.everythingSpendable)
        #expect(store.state.shieldedBalance == .zero)
        #expect(store.state.totalBalance == .zero)
        #expect(store.state.spendability == .everything)
    }

    @MainActor @Test func updateBalanceAggregatesSaplingOrchardAndTransparent() async {
        let store = TestStore(initialState: state(autoShieldingThreshold: Zatoshi(1_000_000))) {
            Balances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
        }
        store.exhaustivity = .off

        let balance = AccountBalance(
            saplingBalance: PoolBalance(spendableValue: Zatoshi(100), changePendingConfirmation: Zatoshi(10), valuePendingSpendability: Zatoshi(20)),
            orchardBalance: PoolBalance(spendableValue: Zatoshi(200), changePendingConfirmation: Zatoshi(30), valuePendingSpendability: Zatoshi(40)),
            unshielded: Zatoshi(5),
            awaitingResolution: Zatoshi(1)
        )

        await store.send(.updateBalance(balance))

        #expect(store.state.changePending == Zatoshi(40))             // 10 + 30
        #expect(store.state.pendingTransactions == Zatoshi(60))       // 20 + 40
        #expect(store.state.shieldedBalance == Zatoshi(300))          // 100 + 200
        #expect(store.state.transparentBalance == Zatoshi(5))         // unshielded
        #expect(store.state.shieldedWithPendingBalance == Zatoshi(400)) // 130 + 270 totals
        #expect(store.state.totalBalance == Zatoshi(406))            // 400 + 5 + 1 awaiting
        #expect(store.state.spendability == .something)
    }

    @MainActor @Test func shieldingProcessorRequestedMarksShielding() async {
        let store = TestStore(initialState: state()) { Balances() }

        await store.send(.shieldingProcessorStateChanged(.requested)) {
            $0.isShielding = true
        }
    }

    @MainActor @Test func shieldingProcessorSucceededClearsShieldingAndRefreshes() async {
        let store = TestStore(initialState: state(isShielding: true)) { Balances() }
        store.exhaustivity = .off

        await store.send(.shieldingProcessorStateChanged(.succeeded)) {
            $0.isShielding = false
        }
        // No selected account, so the refresh request is a no-op effect.
        await store.receive(\.updateBalancesOnAppear)
    }

    @MainActor @Test func shieldFundsTappedInvokesProcessor() async {
        let shieldCalled = LockIsolated(false)
        let store = TestStore(initialState: state()) {
            Balances()
        } withDependencies: {
            $0.shieldingProcessor.shieldFunds = { shieldCalled.setValue(true) }
        }

        await store.send(.shieldFundsTapped)

        #expect(shieldCalled.value)
    }

    private func state(
        autoShieldingThreshold: Zatoshi = Zatoshi(1_000_000),
        changePending: Zatoshi = .zero,
        isShielding: Bool = false,
        pendingTransactions: Zatoshi = .zero,
        shieldedBalance: Zatoshi = .zero,
        transparentBalance: Zatoshi = .zero
    ) -> Balances.State {
        Balances.State(
            autoShieldingThreshold: autoShieldingThreshold,
            changePending: changePending,
            isShielding: isShielding,
            pendingTransactions: pendingTransactions,
            shieldedBalance: shieldedBalance,
            transparentBalance: transparentBalance
        )
    }
}
