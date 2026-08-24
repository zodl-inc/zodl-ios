//
//  MigrationResidualStore.swift
//  zodl
//
//  MOB-1749 "Remaining Orchard Funds" (Figma 6855:24967 / locking 6855:25169 / locked 6855:25254):
//  the decision screen for a wallet that holds Ironwood funds plus a SPENDABLE Orchard balance
//  strictly between 0.0001 and 0.01 ZEC without a migration run behind it — restored after
//  migrating elsewhere, or self-migrated. Reached only as a re-entry root: `MigrationDerivations
//  .reentryRoute` answers `.residual(_)` where it used to answer `.entry`, and
//  `MigrationCoordFlowCoordinator.reentryPathState` hydrates `State` straight from the figures that
//  route carries — the one balances read the decision was made on, never a second one that could
//  disagree with it.
//
//  The lock half is not this reducer's: `MigrationLockDecision` owns the whole machine — the lock
//  itself (`.offered` → `.locking` → `.locked`, back to `.offered` on failure), the explainer
//  sheet, and the single-flight "Migrate anyway" — and both this screen and Migration Complete
//  `Scope` the identical child (review fix: they used to carry byte-identical rename-copies of it,
//  so audit 2026-08-03 #11's re-arm fix had to be made twice). What stays here is this screen's own
//  glue: the failure ALERT the child's `.lockFailed` delegate asks for, the `.migrateAnyway`
//  delegate re-surfaced at screen level so the coordinator keeps listening to the SCREEN (it rides
//  the same immediate-review leg Complete uses, minus the unlock), and `gotItTapped` — reachable
//  only from `.locked`, delegating `.done`, since there is no run to acknowledge. The explainer
//  sheet's own dismiss is deliberately distinct from `gotItTapped`: it closes only the sheet.
//
//  No "nothing to decide" state: the screen exists only while there is something to decide, which
//  is why the child's vocabulary has no such case either. What fires the banner and the route is a
//  SPENDABLE Orchard balance in range (review fix 2026-08-24: spendable, not "total minus locked" —
//  the SDK reports a locked-but-unconfirmed note as pending rather than locked, so the old basis
//  made a successful lock look like it had done nothing), and a fully locked residual has none — so
//  a wallet that locked everything it had does not come back here. A lock is per-note, though: a
//  later spendable arrival (0.005 locked, 0.004 received afterwards) puts an in-range spendable
//  balance back on the account and re-enters at `.offered`, with the card naming the SPENDABLE
//  figure alone — the locked notes are not part of what is offered again, and are reported
//  separately by `lockedOrchardBalance`'s own row.
//
//  Within a single visit the card is a HYDRATION snapshot, not a live balance, by design: locking
//  flips `lock.resolution` to `.locked` but never rewrites `orchardBalance` or
//  `lockedOrchardBalance`, so the rows keep reading as of arrival while the locked callout narrates
//  the same frozen `orchardBalance` figure as the amount that just got locked — the same
//  static-card semantics Migration Complete ships, and the same thing the Figma locked frame
//  (6855:25254) draws. The next re-entry re-hydrates fresh from the route's own balances, folding
//  the lock into this row.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationResidual {
    @ObservableState
    struct State: Equatable {
        @Presents var alert: AlertState<Action>?
        /// The SPENDABLE Orchard residual the screen is about. A lock does not change it — the
        /// same number is then the LOCKED amount the locked callout names.
        var orchardBalance: Zatoshi
        /// The account's LOCKED Orchard balance at hydration — the conditional "Locked in Orchard"
        /// row. A residual the user locked on an earlier visit is still part of the pool; hiding it
        /// made this screen disagree with the Balances breakdown.
        ///
        /// This row freezes at its hydration figure for the rest of the current visit, by design:
        /// an in-session lock only flips `lock.resolution` to `.locked`, it never rewrites this
        /// balance (or `orchardBalance`). The locked callout that then renders instead names the
        /// just-locked amount from that same static `orchardBalance` — the same static-card
        /// semantics Migration Complete ships and the Figma locked frame (6855:25254) draws. The
        /// next re-entry re-hydrates from the route's fresh balances, folding the lock into this row.
        var lockedOrchardBalance: Zatoshi
        /// The account's Ironwood pool total — the "In Ironwood" row.
        var ironwoodBalance: Zatoshi
        /// The shared lock machine. Everything the decision half of this screen reads and writes
        /// lives in here, so there is exactly one copy of it across both adopting screens.
        var lock: MigrationLockDecision.State

        init(
            orchardBalance: Zatoshi,
            lockedOrchardBalance: Zatoshi = .zero,
            ironwoodBalance: Zatoshi,
            resolution: MigrationLockResolution = .offered
        ) {
            self.orchardBalance = orchardBalance
            self.lockedOrchardBalance = lockedOrchardBalance
            self.ironwoodBalance = ironwoodBalance
            self.lock = MigrationLockDecision.State(resolution: resolution)
        }
    }

    enum Action: Equatable {
        case alert(PresentationAction<Action>)
        case delegate(Delegate)
        case gotItTapped
        case lock(MigrationLockDecision.Action)

        enum Delegate: Equatable {
            case done
            case migrateAnyway
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Scope(state: \.lock, action: \.lock) {
            MigrationLockDecision()
        }

        Reduce { state, action in
            switch action {
            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .delegate:
                return .none

            case .gotItTapped:
                return .send(.delegate(.done))

            case .lock(.delegate(.lockFailed)):
                state.alert = AlertState.migrationLockFailed()
                return .none

            case .lock(.delegate(.migrateAnyway)):
                // Re-surfaced at screen level: the coordinator listens for the SCREEN's delegate,
                // so both adopters keep their own coordinator wiring unchanged.
                return .send(.delegate(.migrateAnyway))

            case .lock:
                return .none
            }
        }
    }
}
