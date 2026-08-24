//
//  MigrationResidualBalances.swift
//  zodl
//
//  MOB-1749: the figures the Remaining Orchard Funds lane reads, from ONE balances read.
//
//  Review fix (2026-08-24): the lane keys off the SPENDABLE Orchard balance — the set
//  `lockMigrationResidual` visibly moves to `lockedValue`, and the set the immediate sweep's
//  send-max actually spends. The pending buckets (`changePendingConfirmation` +
//  `valuePendingSpendability`) are deliberately excluded: the SDK reports a locked-but-unconfirmed
//  note as still PENDING, not locked, so a pending-based figure made a successful lock look like
//  it did nothing (the banner came straight back). Locked value is carried separately for the
//  screen's "Locked in Orchard" row.
//
//  Two bases, therefore, and both are carried: the residual lane acts on SPENDABLE, while the
//  OFFER lane it must never compete with is sized from `unlockedForMigration`. Deriving the
//  predicate's upper bound from the offer's own basis is what keeps the banner and the re-entry
//  route from answering differently about the same wallet.
//

import ZcashLightClientKit

struct MigrationResidualBalances: Equatable, Sendable {
    /// The account's spendable (and not locked) Orchard balance — the figure the residual lane
    /// names, locks, and sweeps.
    let residualOrchard: Zatoshi
    /// The OFFER lane's basis — `PoolBalance.unlockedForMigration`, spendable plus both pending
    /// buckets. Carried so the residual predicate can stand down whenever the offer lane would
    /// fire.
    let unlockedOrchard: Zatoshi
    /// The account's locked Orchard balance — the "Locked in Orchard" row on the residual screen.
    let lockedOrchard: Zatoshi
    /// The account's Ironwood pool TOTAL — the "In Ironwood" row.
    let ironwood: Zatoshi

    /// The residual predicate shared by the banner and the re-entry route: an Orchard balance
    /// between the residual floor and the offer floor, on a wallet that already holds Ironwood
    /// funds. The Ironwood gate is deliberate: the screen's "You've moved to Ironwood" framing
    /// presumes them, so a wallet with nothing in Ironwood is not told about Orchard dust at all.
    ///
    /// The two bounds ride DIFFERENT bases on purpose. The UPPER bound rides the offer basis
    /// (`unlockedOrchard`), so the residual lane can never compete with the offer: `bannerVariant`
    /// gates the offer on that same figure, and a wallet whose spendable balance is dust but whose
    /// pending balance clears the offer floor must be offered the migration by BOTH surfaces
    /// rather than banner-offered and route-residualed. The LOWER bound and the named amount ride
    /// the spendable basis — that is what the lock and the sweep actually act on.
    ///
    /// No separate `residualOrchard < minimumOfferableOrchardBalance` clause is needed: spendable
    /// is a component of unlocked, so `unlockedOrchard` below the floor puts `residualOrchard`
    /// below it too.
    var isResidualCandidate: Bool {
        ironwood > Zatoshi.zero
            && residualOrchard > MigrationDerivations.minimumResidualOrchardBalance
            && unlockedOrchard < MigrationDerivations.minimumOfferableOrchardBalance
    }

    init(residualOrchard: Zatoshi, unlockedOrchard: Zatoshi, lockedOrchard: Zatoshi, ironwood: Zatoshi) {
        self.residualOrchard = residualOrchard
        self.unlockedOrchard = unlockedOrchard
        self.lockedOrchard = lockedOrchard
        self.ironwood = ironwood
    }

    init(accountBalance: AccountBalance) {
        self.residualOrchard = accountBalance.orchardBalance.spendableValue
        self.unlockedOrchard = accountBalance.orchardBalance.unlockedForMigration
        self.lockedOrchard = accountBalance.orchardBalance.lockedValue
        self.ironwood = accountBalance.ironwoodBalance.total()
    }
}
