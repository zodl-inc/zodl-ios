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
//  The lock half is Migration Complete's (MOB-1487 rounds 2/3, MOB-1458 F4) without the run
//  summary: `lockBalanceTapped` (valid only from `.offered`) runs `migrationManager
//  .lockMigrationDust(nil)` — `.locking` while in flight, `.locked` on success, back to `.offered`
//  plus the failure alert otherwise. `migrateAnywayTapped` is single-flight (`isMigratingAnyway`,
//  re-armed by `.onAppear` on every arrival, cleared by the coordinator's `.migrateAnywayFailed`)
//  and delegates out — the coordinator rides the identical unlock → immediate-review leg Complete
//  uses. `gotItTapped` (reachable only from `.locked`) delegates `.done`; there is no run to
//  acknowledge, so the coordinator simply finishes the flow. The explainer sheet's own dismiss is
//  deliberately distinct from `gotItTapped` — it closes only the sheet.
//
//  No `.none` state: the screen exists only while there is something to decide. What fires the
//  banner and the route is a SPENDABLE Orchard balance in range (review fix 2026-08-24: spendable,
//  not "total minus locked" — the SDK reports a locked-but-unconfirmed note as pending rather than
//  locked, so the old basis made a successful lock look like it had done nothing), and a fully
//  locked residual has none — so a wallet that locked everything it had does not come back here. A
//  lock is per-note, though: a later spendable arrival (0.005 locked, 0.004 received afterwards)
//  puts an in-range spendable balance back on the account and re-enters at `.offered`, with the
//  card naming the SPENDABLE figure alone — the locked notes are not part of what is offered
//  again, and are reported separately by `lockedOrchardBalance`'s own row.
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
        var lockedOrchardBalance: Zatoshi
        /// The account's Ironwood pool total — the "In Ironwood" row.
        var ironwoodBalance: Zatoshi
        var resolution: MigrationLockResolution
        /// Presentation flag for the "What does locking do?" sheet — toggled by an explicit
        /// present/dismiss pair plus the sheet binding's own writes, never by `BindingReducer`.
        var isLockExplainerPresented = false
        /// Single-flight for "Migrate anyway": set by the tap, cleared by the coordinator on
        /// failure and by `.onAppear` on every arrival (a back-swipe off the review screen must
        /// not land on a permanently disabled button).
        var isMigratingAnyway = false

        init(
            orchardBalance: Zatoshi,
            lockedOrchardBalance: Zatoshi = .zero,
            ironwoodBalance: Zatoshi,
            resolution: MigrationLockResolution = .offered
        ) {
            self.orchardBalance = orchardBalance
            self.lockedOrchardBalance = lockedOrchardBalance
            self.ironwoodBalance = ironwoodBalance
            self.resolution = resolution
        }
    }

    enum Action: Equatable {
        case alert(PresentationAction<Action>)
        case delegate(Delegate)
        case gotItTapped
        case lockBalanceTapped
        case lockExplainerDismissed
        case lockExplainerHelpTapped
        /// The sheet's presentation BINDING (`$store...sending`) — SwiftUI writes `false` here on
        /// drag-dismiss. Same flag as `lockExplainerDismissed`; only the sender differs.
        case lockExplainerPresentedChanged(Bool)
        case lockFailed(ZcashError)
        case lockSucceeded
        case migrateAnywayTapped
        case onAppear

        enum Delegate: Equatable {
            case done
            case migrateAnyway
        }
    }

    @Dependency(\.migrationManager) var migrationManager

    init() { }

    var body: some Reducer<State, Action> {
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

            case .lockBalanceTapped:
                guard state.resolution == .offered else { return .none }
                state.resolution = .locking
                return .run { send in
                    do {
                        // nil resolves the selected account — this screen only ever shows for the
                        // selected account's own balance.
                        try await migrationManager.lockMigrationDust(nil)
                        await send(.lockSucceeded)
                    } catch {
                        await send(.lockFailed(error.toZcashError()))
                    }
                }

            case .lockExplainerDismissed:
                state.isLockExplainerPresented = false
                return .none

            case .lockExplainerHelpTapped:
                state.isLockExplainerPresented = true
                return .none

            case .lockExplainerPresentedChanged(let presented):
                state.isLockExplainerPresented = presented
                return .none

            case .lockFailed:
                state.resolution = .offered
                state.alert = AlertState.migrationLockFailed()
                return .none

            case .lockSucceeded:
                state.resolution = .locked
                return .none

            case .migrateAnywayTapped:
                // Backstop for a tap queued ahead of the view's `.disabled` taking effect; the
                // coordinator's unlock/propose leg must never start twice.
                guard !state.isMigratingAnyway else { return .none }
                state.isMigratingAnyway = true
                return .send(.delegate(.migrateAnyway))

            case .onAppear:
                state.isMigratingAnyway = false
                return .none
            }
        }
    }
}
