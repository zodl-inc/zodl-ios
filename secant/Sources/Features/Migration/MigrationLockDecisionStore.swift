//
//  MigrationLockDecisionStore.swift
//  zodl
//
//  MOB-1749 review fix: the ONE lock-decision state machine. Migration Complete's lock half and
//  the Remaining Orchard Funds screen carried byte-identical rename-copies of this reducer —
//  lock → locking → locked with a failure return, the explainer-sheet trio, and the single-flight
//  "Migrate anyway" with its `.onAppear` re-arm (audit 2026-08-03 #11's fix, which must never
//  need re-fixing twice). Both screens `Scope` this child; each keeps its own exit ("Got it") and
//  its own alert (`AlertState.migrationLockFailed()`), driven by this reducer's delegates.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

/// The three states a leftover Orchard balance can be in on a decision screen. "No dust at all"
/// is deliberately NOT a case — a screen with nothing to decide never renders the decision pieces
/// (Migration Complete gates them on its own `hasDust`), so the vocabulary cannot express the
/// state the old `DustResolution.none → .offered` view adapter had to lie about.
enum MigrationLockResolution: Equatable {
    case offered
    case locking
    case locked
}

@Reducer
struct MigrationLockDecision {
    @ObservableState
    struct State: Equatable {
        var resolution: MigrationLockResolution
        /// Presentation flag for the "What does locking do?" sheet — an explicit present/dismiss
        /// pair plus the sheet binding's own writes, never `BindingReducer`.
        var isLockExplainerPresented = false
        /// Single-flight for "Migrate anyway": set by the tap, cleared by the coordinator on
        /// failure and by `.onAppear` on every arrival (a back-swipe off the review screen must
        /// not land on a permanently disabled button).
        var isMigratingAnyway = false

        init(resolution: MigrationLockResolution = .offered) {
            self.resolution = resolution
        }
    }

    enum Action: Equatable {
        case delegate(Delegate)
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
            /// The lock failed (state is already back on `.offered`); the enclosing screen
            /// presents its failure alert.
            case lockFailed
            case migrateAnyway
        }
    }

    @Dependency(\.migrationManager) var migrationManager

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .delegate:
                return .none

            case .lockBalanceTapped:
                guard state.resolution == .offered else { return .none }
                state.resolution = .locking
                return .run { send in
                    do {
                        // nil resolves the selected account — both adopting screens only ever
                        // show for the selected account's own balance.
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
                return .send(.delegate(.lockFailed))

            case .lockSucceeded:
                state.resolution = .locked
                return .none

            case .migrateAnywayTapped:
                // The view hides this button once `.locked`, but a queued tap must never reach
                // the coordinator's leg — on Complete that leg still runs the blanket unlock.
                guard state.resolution != .locked else { return .none }
                // Backstop for a tap queued ahead of the view's `.disabled` taking effect; the
                // coordinator's propose leg must never start twice.
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
