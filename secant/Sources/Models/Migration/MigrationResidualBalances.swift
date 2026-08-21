//
//  MigrationResidualBalances.swift
//  zodl
//
//  MOB-1749: the two figures the Remaining Orchard Funds lane reads, from ONE balances read.
//

import ZcashLightClientKit

struct MigrationResidualBalances: Equatable, Sendable {
    /// The account's Orchard balance minus any explicit lock — `PoolBalance.unlockedForMigration`,
    /// the same number `MigrationManagerClient.orchardBalanceToMigrate` answers.
    let unlockedOrchard: Zatoshi
    /// The account's Ironwood pool TOTAL — the figure the migration snapshot shows as `ironwoodHeld`.
    let ironwood: Zatoshi

    static let zero = MigrationResidualBalances(unlockedOrchard: .zero, ironwood: .zero)
}
