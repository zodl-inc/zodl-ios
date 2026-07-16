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
//  value. `lockBalanceTapped` (valid only from `.offered`) runs `sdkSynchronizer.lockMigrationDust()`:
//  `.locking` while in flight, `.locked` on success, back to `.offered` plus a failure alert
//  otherwise. `migrateAnywayTapped` just emits `.delegate(.migrateAnyway)` for the coordinator to
//  wire up later (delegate wiring is a separate serialized stream) — no local state change.
//  `gotItTapped` is unchanged and reachable from `.none`/`.locked`.
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
        var totalTransferred = Zatoshi.zero
        var dust = Zatoshi.zero
        var dustResolution: DustResolution
        var transfersSent = 0
        var transfersTotal = 0
        var durationHours = 0
        /// Carried for consistency with the other re-entry-root screens; this screen has no back
        /// control to gate (`.navigationBarBackButtonHidden()`, no custom leading toolbar item).
        var isFlowRoot = false

        var hasDust: Bool {
            dust.amount > 0
        }

        init(
            totalTransferred: Zatoshi = .zero,
            dust: Zatoshi = .zero,
            transfersSent: Int = 0,
            transfersTotal: Int = 0,
            durationHours: Int = 0,
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
        case migrateAnywayTapped

        enum Delegate: Equatable {
            case done
            case migrateAnyway
        }
    }

    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

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
                        try await sdkSynchronizer.lockMigrationDust()
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

            case .migrateAnywayTapped:
                return .send(.delegate(.migrateAnyway))
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
