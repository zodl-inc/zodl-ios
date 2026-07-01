//
//  AccountBalance+Shielded.swift
//  Zashi
//
//  Aggregates the shielded pools (Sapling + Orchard + Ironwood) of an `AccountBalance`.
//
//  Ironwood is Orchard note-version V3 (NU6.3), received at the account's existing Orchard
//  receiver. It is `.zero` for every wallet until NU6.3 activates and a lightwalletd serves
//  Ironwood compact blocks, so folding it in here is additive and dormant until then.
//
//  Centralizing the pool set means the next pool addition is a one-line change in this file
//  rather than a sweep across every call site that sums shielded balances.
//

import ZcashLightClientKit

extension AccountBalance {
    /// Spendable balance across all shielded pools (Sapling + Orchard + Ironwood).
    var shieldedSpendableValue: Zatoshi {
        saplingBalance.spendableValue + orchardBalance.spendableValue + ironwoodBalance.spendableValue
    }

    /// Total shielded balance including pending, across all shielded pools.
    var shieldedTotalIncludingPending: Zatoshi {
        saplingBalance.total() + orchardBalance.total() + ironwoodBalance.total()
    }

    /// Change awaiting confirmation, across all shielded pools.
    var shieldedChangePending: Zatoshi {
        saplingBalance.changePendingConfirmation
            + orchardBalance.changePendingConfirmation
            + ironwoodBalance.changePendingConfirmation
    }

    /// Value pending spendability, across all shielded pools.
    var shieldedValuePendingSpendability: Zatoshi {
        saplingBalance.valuePendingSpendability
            + orchardBalance.valuePendingSpendability
            + ironwoodBalance.valuePendingSpendability
    }
}
