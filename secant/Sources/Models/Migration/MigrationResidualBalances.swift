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

import ZcashLightClientKit

struct MigrationResidualBalances: Equatable, Sendable {
    /// The account's spendable (and not locked) Orchard balance — the figure the residual lane
    /// names, locks, and sweeps.
    let residualOrchard: Zatoshi
    /// The account's locked Orchard balance — the "Locked in Orchard" row on the residual screen.
    let lockedOrchard: Zatoshi
    /// The account's Ironwood pool TOTAL — the "In Ironwood" row.
    let ironwood: Zatoshi

    /// The residual predicate shared by the banner and the re-entry route: a spendable Orchard
    /// balance strictly between the residual floor and the offer floor, on a wallet that already
    /// holds Ironwood funds. The Ironwood gate is deliberate: the screen's "You've moved to
    /// Ironwood" framing presumes them, so a wallet with nothing in Ironwood is not told about
    /// Orchard dust at all.
    var isResidualCandidate: Bool {
        ironwood > Zatoshi.zero
            && residualOrchard > MigrationDerivations.minimumResidualOrchardBalance
            && residualOrchard < MigrationDerivations.minimumOfferableOrchardBalance
    }

    init(residualOrchard: Zatoshi, lockedOrchard: Zatoshi, ironwood: Zatoshi) {
        self.residualOrchard = residualOrchard
        self.lockedOrchard = lockedOrchard
        self.ironwood = ironwood
    }

    init(accountBalance: AccountBalance) {
        self.residualOrchard = accountBalance.orchardBalance.spendableValue
        self.lockedOrchard = accountBalance.orchardBalance.lockedValue
        self.ironwood = accountBalance.ironwoodBalance.total()
    }
}
