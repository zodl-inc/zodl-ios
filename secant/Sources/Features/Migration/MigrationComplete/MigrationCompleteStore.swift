//
//  MigrationCompleteStore.swift
//  zodl
//
//  "Migration Complete" screen (MOB-1464, Figma S12 · 2696:7267). Display-only summary fields are
//  injected by the coordinator (MOB-1466). This screen has no back control at all
//  (`.navigationBarBackButtonHidden()`); `isFlowRoot` is carried in State for coordinator-injection
//  consistency with the other re-entry roots even though there's no back-control behavior to gate
//  here. The `gotItTapped` delegate is consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1487 (round 2, Figma offered 3836:8394 / locking 3836:8488 / locked 3836:8643): dust
//  resolution replaces the old take-it-or-leave-it dust callout. `dustResolution` derives from
//  `dust` at init (`.offered` when > `.zero`, else `.none`) unless a caller passes it explicitly —
//  the coordinator's `completeState(isFlowRoot:)` still constructs `State` without naming it, so
//  that derivation is the only thing driving it in the shipped app; tests can pin an explicit
//  value. `lockBalanceTapped` (valid only from `.offered`) runs `migrationManager.lockMigrationDust()`:
//  `.locking` while in flight, `.locked` on success, back to `.offered` plus a failure alert
//  otherwise. `migrateAnywayTapped` emits `.delegate(.migrateAnyway)` for the coordinator to wire up
//  later (delegate wiring is a separate serialized stream) — see MOB-1458 below for the one local
//  state change it does make now. `gotItTapped` is unchanged and reachable from `.none`/`.locked`.
//
//  MOB-1487 (round 3, Figma 3925:24209): adds the "Lock balance" explainer sheet's presentation
//  state — `isLockExplainerPresented`, toggled by an explicit present/dismiss action pair
//  (`lockExplainerHelpTapped` sets it true, `lockExplainerDismissed` sets it false) rather than
//  `BindableAction`/`BindingReducer`. This mirrors `MigrationCoordFlow`'s Tor-sheet (a manual
//  `Binding(get:set:)` in the view), not `SwapAndPayCoordFlow`'s bindable-store pattern, because
//  there's exactly one sheet and no cross-screen state to round-trip — consistent with this
//  reducer's existing plain (non-bindable) `Action` enum. Neither action is gated on
//  `dustResolution`; the trailing help button that sends `lockExplainerHelpTapped` is only ever
//  shown by the view when `dustResolution != .none`, so the reducer doesn't need its own guard
//  (unlike `lockBalanceTapped`'s `.offered`-only guard, which protects a real SDK side effect).
//  `lockExplainerDismissed` is intentionally distinct from `gotItTapped` — it closes only the
//  sheet, never the screen.
//
//  MOB-1458 (code review — F4): `migrateAnywayTapped` gains a single-flight guard
//  (`State.isMigratingAnyway`) — two fast taps could otherwise both emit
//  `.delegate(.migrateAnyway)` and each run its own unlock/propose leg. (Audit 2026-08-03, C10 —
//  truth over intention: the coordinator device-authentication gate and the
//  `.migrateAnywayAuthenticated`/`.migrateAnywayAuthenticationCancelled` cases this doc once
//  named were never built; the coordinator goes straight from the delegate to
//  `unlockMigrationResidual`. The flag clears on `.migrateAnywayFailed` and re-arms on every
//  `.onAppear`.)
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationComplete {
    @ObservableState
    struct State: Equatable {
        enum DustResolution: Equatable {
            case none
            case offered
            case locking
            case locked
        }

        @Presents var alert: AlertState<Action>?
        /// The total value transferred across the whole run. `nil` when not derivable — a W1
        /// fallback re-entry with no persisted schedule (MOB-1513) — never a placeholder
        /// `Zatoshi.zero`; the view renders an em-dash in its place (see `MigrationCompleteView
        /// .summaryCard`).
        var totalTransferred: Zatoshi?
        var dust = Zatoshi.zero
        var dustResolution: DustResolution
        var transfersSent = 0
        var transfersTotal = 0
        /// Same "nil, never a placeholder `0`" W1-fallback convention as `totalTransferred` above.
        var durationHours: Int?
        /// Carried for consistency with the other re-entry-root screens; this screen has no back
        /// control to gate (`.navigationBarBackButtonHidden()`, no custom leading toolbar item).
        var isFlowRoot = false
        /// MOB-1487 (round 3): presentation flag for the "Lock balance" explainer sheet. Toggled by
        /// `lockExplainerHelpTapped` (nav-bar help button) / `lockExplainerDismissed` (the sheet's
        /// own "Got it" button and swipe-to-dismiss both route through it). Deliberately not part of
        /// the memberwise `init` below — like `alert`, it's presentation-only state that tests
        /// mutate directly on a case that needs to start with the sheet already up.
        var isLockExplainerPresented = false
        /// MOB-1458 (code review — F4): single-flight for "Migrate anyway" — true from the tap that
        /// starts the coordinator's device-authentication gate until that gate's continuation lands
        /// (a refusal, a post-gate unlock/propose failure, or — implicitly, since the flow then
        /// closes — a success). SET here, locally, by `migrateAnywayTapped` itself, unlike
        /// `MigrationRecovery.State.isRecovering`/`MigrationStatus.State.isRescheduling`, which the
        /// COORDINATOR sets on their path elements — those flags guard coordinator-owned async work
        /// that starts asynchronously from the coordinator's own handler, while this tap's own
        /// reducer runs synchronously and can set its own guard before ever delegating out. CLEARED
        /// by the coordinator via `.migrateAnywayFailed` (audit 2026-08-03, C10: the
        /// `.migrateAnywayAuthenticationCancelled` case this doc once named was never built — no
        /// authentication gate exists on this leg) and re-armed by `.onAppear` on every arrival.
        /// Deliberately not part of the memberwise `init` below, matching
        /// `isLockExplainerPresented`'s own precedent just above.
        var isMigratingAnyway = false

        var hasDust: Bool {
            dust.amount > 0
        }

        init(
            totalTransferred: Zatoshi? = nil,
            dust: Zatoshi = .zero,
            transfersSent: Int = 0,
            transfersTotal: Int = 0,
            durationHours: Int? = nil,
            isFlowRoot: Bool = false,
            dustResolution: DustResolution? = nil
        ) {
            self.totalTransferred = totalTransferred
            self.dust = dust
            self.dustResolution = dustResolution ?? (dust.amount > 0 ? .offered : .none)
            self.transfersSent = transfersSent
            self.transfersTotal = transfersTotal
            self.durationHours = durationHours
            self.isFlowRoot = isFlowRoot
        }
    }

    enum Action: Equatable {
        case alert(PresentationAction<Action>)
        case delegate(Delegate)
        case gotItTapped
        case lockBalanceTapped
        case lockDustFailed(ZcashError)
        case lockDustSucceeded
        case lockExplainerDismissed
        /// The sheet's presentation BINDING (`$store...sending`) — SwiftUI writes `false` here on
        /// drag-dismiss. Distinct from `lockExplainerDismissed` (the sheet's own button) only in
        /// who sends it; both land on the same flag.
        case lockExplainerPresentedChanged(Bool)
        case lockExplainerHelpTapped
        case migrateAnywayTapped
        /// Audit 2026-08-03 (#11): re-arms "Migrate anyway" on every arrival — the flag used to be
        /// cleared only on FAILURE, so unlock-success → push → back landed here with the button
        /// permanently disabled and "Got it" (which wipes the run) as the only live control, with
        /// the residual already unlocked on chain. Mirrors `MigrationRecovery`'s own `.onAppear`
        /// reset of its twin flag.
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
                guard state.dustResolution == .offered else { return .none }
                state.dustResolution = .locking
                return .run { send in
                    do {
                        // MOB-1509: nil resolves the selected account — the Complete screen only
                        // ever shows for the selected account's own migration.
                        try await migrationManager.lockMigrationDust(nil)
                        await send(.lockDustSucceeded)
                    } catch {
                        await send(.lockDustFailed(error.toZcashError()))
                    }
                }

            case .lockDustFailed:
                state.dustResolution = .offered
                state.alert = AlertState.lockFailed()
                return .none

            case .lockDustSucceeded:
                state.dustResolution = .locked
                return .none

            case .lockExplainerDismissed:
                state.isLockExplainerPresented = false
                return .none

            case .lockExplainerPresentedChanged(let presented):
                state.isLockExplainerPresented = presented
                return .none

            case .lockExplainerHelpTapped:
                state.isLockExplainerPresented = true
                return .none

            case .migrateAnywayTapped:
                // MOB-1458 (F4): single-flight — see `State.isMigratingAnyway`'s doc. A second tap
                // that arrives before the coordinator's gate/unlock/propose leg resolves is a no-op;
                // the view's `.disabled` mirrors this so the common double-tap never reaches here at
                // all, but this guard is the backstop for a tap that lands anyway (e.g. queued just
                // ahead of the disable taking visual effect).
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

// MARK: - Alerts

extension AlertState where Action == MigrationComplete.Action {
    /// Generic failure copy — `lockMigrationDust` throws a bare error with no user-facing detail to
    /// surface. Reuses `MigrationNoteSplit`'s failure-sheet copy (same Migration domain, no
    /// interpolated argument, and "tap below to try again" matches this screen's shape exactly:
    /// dismissing lands back on `.offered` with "Lock balance" visible again).
    static func lockFailed() -> AlertState {
        AlertState {
            TextState(String(localizable: .migrationNoteSplitFailedTitle))
        } message: {
            TextState(String(localizable: .migrationNoteSplitFailedBody))
        }
    }
}
