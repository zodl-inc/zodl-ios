//
//  ShieldingEligibilityTests.swift
//  zodlTests
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct ShieldingEligibilityTests {
    /// The SDK's `proposeShielding` returns nil only when the balance "is zero or below
    /// `shieldingThreshold`", so eligibility is inclusive: exactly-at-threshold shields.
    @Test func thresholdBoundaryIsInclusive() {
        #expect(ShieldingProcessorClient.isShieldable(balance: Zatoshi(100_000), threshold: Zatoshi(100_000)))
        #expect(ShieldingProcessorClient.isShieldable(balance: Zatoshi(100_001), threshold: Zatoshi(100_000)))
        #expect(!ShieldingProcessorClient.isShieldable(balance: Zatoshi(99_999), threshold: Zatoshi(100_000)))
        #expect(!ShieldingProcessorClient.isShieldable(balance: .zero, threshold: Zatoshi(100_000)))
    }

    @Test func pendingShieldingDetectionMatchesOnlyInFlightShields() {
        let pendingShield = TransactionState(
            fee: Zatoshi(10_000),
            id: "pending-shield",
            status: .shielding,
            zecAmount: Zatoshi(1_000_000),
            isShieldingTransaction: true
        )
        let doneShield = TransactionState(
            fee: Zatoshi(10_000),
            id: "done-shield",
            status: .shielded,
            zecAmount: Zatoshi(1_000_000),
            isShieldingTransaction: true
        )
        let pendingSend = TransactionState(
            fee: Zatoshi(10_000),
            id: "pending-send",
            status: .sending,
            zecAmount: Zatoshi(1_000_000)
        )

        var transactions: IdentifiedArrayOf<TransactionState> = [doneShield, pendingSend]
        #expect(!transactions.isAnyShieldingPending())

        transactions.append(pendingShield)
        #expect(transactions.isAnyShieldingPending())
    }
}

// `WalletBalances.State` carries `@Shared(.inMemory(...))` properties (`currencyConversion`,
// `selectedWalletAccount`), so constructing it touches process-global in-memory storage — the same
// reason `WalletBalancesTests` (WalletBalancesTests.swift) is `.serialized` rather than living in
// the plain `ShieldingEligibilityTests` suite above. A dedicated `.serialized` suite with pinned
// storage keeps this test isolated from concurrently running suites that also touch that storage.
@Suite(.serialized) struct WalletBalancesEligibilityTests {
    /// WalletBalances and Balances compute "processing with zero available" from the same wallet
    /// and must agree at exactly the shielding threshold (the SDK's rule is inclusive).
    @Test func walletBalancesProcessingRuleIsInclusiveAtTheThreshold() {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = WalletBalances.State()
            state.shieldedBalance = .zero
            state.totalBalance = Zatoshi(100_000)
            state.transparentBalance = Zatoshi(100_000)
            state.autoShieldingThreshold = Zatoshi(100_000)

            #expect(!state.isProcessingZeroAvailableBalance)
        }
    }
}
