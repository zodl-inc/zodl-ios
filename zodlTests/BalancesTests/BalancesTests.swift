//
//  BalancesTests.swift
//  zodlTests
//
//  Batch 3 — balances. Covers Balances reducer computed flags + updateBalance spendability
//  (Features/BalanceBreakdown/BalancesStore.swift), including the non-nil AccountBalance
//  aggregation path across all shielded pools (Sapling + Orchard + Ironwood).
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

    @MainActor @Test func updateBalanceAggregatesAllShieldedPoolsIncludingIronwood() async {
        // sapling: 1 / 2 / 4   orchard: 8 / 16 / 32   ironwood: 64 / 128 / 256
        let accountBalance = AccountBalance(
            saplingBalance: PoolBalance(spendableValue: Zatoshi(1), changePendingConfirmation: Zatoshi(2), valuePendingSpendability: Zatoshi(4)),
            orchardBalance: PoolBalance(spendableValue: Zatoshi(8), changePendingConfirmation: Zatoshi(16), valuePendingSpendability: Zatoshi(32)),
            ironwoodBalance: PoolBalance(spendableValue: Zatoshi(64), changePendingConfirmation: Zatoshi(128), valuePendingSpendability: Zatoshi(256)),
            unshielded: .zero
        )
        let store = TestStore(initialState: state(autoShieldingThreshold: Zatoshi(1_000_000))) {
            Balances()
        } withDependencies: {
            $0.zcashSDKEnvironment.shieldingThreshold = { Zatoshi(1_000_000) }
        }
        store.exhaustivity = .off
        await store.send(.updateBalance(accountBalance))
        #expect(store.state.shieldedBalance == Zatoshi(1 + 8 + 64))
        #expect(store.state.changePending == Zatoshi(2 + 16 + 128))
        #expect(store.state.pendingTransactions == Zatoshi(4 + 32 + 256))
        #expect(store.state.shieldedWithPendingBalance == Zatoshi((1 + 2 + 4) + (8 + 16 + 32) + (64 + 128 + 256)))
        #expect(store.state.ironwoodBalance == Zatoshi(64 + 128 + 256))
        #expect(store.state.totalBalance == Zatoshi((1 + 2 + 4) + (8 + 16 + 32) + (64 + 128 + 256)))
        #expect(store.state.hasIronwoodBalance)
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
