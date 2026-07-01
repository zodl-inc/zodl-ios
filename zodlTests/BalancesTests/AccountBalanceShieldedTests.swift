//
//  AccountBalanceShieldedTests.swift
//  zodlTests
//
//  Covers the shielded-pool aggregation helper on AccountBalance
//  (Utils/AccountBalance+Shielded.swift): each helper must sum Sapling + Orchard + Ironwood.
//
//  Pools use distinct power-of-two values per field so a dropped or duplicated term fails loudly.
//

import Testing
import Foundation
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite struct AccountBalanceShieldedTests {
    // sapling: 1 / 2 / 4   orchard: 8 / 16 / 32   ironwood: 64 / 128 / 256
    private func balance(
        ironwood: PoolBalance = PoolBalance(
            spendableValue: Zatoshi(64),
            changePendingConfirmation: Zatoshi(128),
            valuePendingSpendability: Zatoshi(256)
        )
    ) -> AccountBalance {
        AccountBalance(
            saplingBalance: PoolBalance(
                spendableValue: Zatoshi(1),
                changePendingConfirmation: Zatoshi(2),
                valuePendingSpendability: Zatoshi(4)
            ),
            orchardBalance: PoolBalance(
                spendableValue: Zatoshi(8),
                changePendingConfirmation: Zatoshi(16),
                valuePendingSpendability: Zatoshi(32)
            ),
            ironwoodBalance: ironwood,
            unshielded: Zatoshi(1_000)
        )
    }

    @Test func shieldedSpendableValueSumsAllThreePools() {
        #expect(balance().shieldedSpendableValue == Zatoshi(1 + 8 + 64))
    }

    @Test func shieldedTotalIncludingPendingSumsAllThreePools() {
        // per-pool total = spendable + changePending + pendingSpendability
        #expect(balance().shieldedTotalIncludingPending == Zatoshi((1 + 2 + 4) + (8 + 16 + 32) + (64 + 128 + 256)))
    }

    @Test func shieldedChangePendingSumsAllThreePools() {
        #expect(balance().shieldedChangePending == Zatoshi(2 + 16 + 128))
    }

    @Test func shieldedValuePendingSpendabilitySumsAllThreePools() {
        #expect(balance().shieldedValuePendingSpendability == Zatoshi(4 + 32 + 256))
    }

    @Test func ironwoodContributesToShieldedTotals() {
        let withIronwood = balance()
        let withoutIronwood = balance(ironwood: .zero)

        #expect(withIronwood.shieldedSpendableValue.amount - withoutIronwood.shieldedSpendableValue.amount == 64)
        #expect(withIronwood.shieldedChangePending.amount - withoutIronwood.shieldedChangePending.amount == 128)
        #expect(withIronwood.shieldedValuePendingSpendability.amount - withoutIronwood.shieldedValuePendingSpendability.amount == 256)
        #expect(withIronwood.shieldedTotalIncludingPending.amount - withoutIronwood.shieldedTotalIncludingPending.amount == 64 + 128 + 256)
    }
}
