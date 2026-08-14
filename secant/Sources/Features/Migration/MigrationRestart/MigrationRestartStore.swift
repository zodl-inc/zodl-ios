//
//  MigrationRestartStore.swift
//  zodl
//
//  "Restart Migration" — the Advanced Settings escape hatch for a run the user believes is stuck
//  (Figma: Advanced Settings → Migration Settings → Bottom Sheet).
//
//  WHAT THE ENGINE CALL ACTUALLY DOES. `restartCurrentMigrationStep(accountUUID:)` is one call with
//  three effects, per `ZcashRustBackendWelding`: it CANCELS the stored run (its pre-signed
//  transactions are abandoned — already-broadcast ones are untouched on-chain and stay migrated),
//  CLEARS the invalid marks, and returns a fresh PREVIEW schedule derived against the live balance.
//
//  THE PREVIEW IS DELIBERATELY DISCARDED HERE. The returned schedule is not a committed plan: it
//  only becomes one if something signs and stores it (`signAndStoreMigrationSchedule`, or the PCZT
//  ceremony for Keystone). Committing it from a settings screen would mean a biometric prompt — and
//  for a Keystone account a whole QR ceremony — behind a button whose sheet promises neither. So v1
//  cancels and lands the user back in Advanced Settings; the migration banner then re-offers the run
//  from `.required`, and the user re-enters the normal flow for the remaining balance. This is the
//  same discard-the-preview shape `Root.cancelAbandonedKeystoneMigrationRun` already uses, with the
//  same recorded semantics: "the user re-runs from a fresh preview."
//
//  Whether the confirm should instead auto-commit the returned schedule is a product/engine call
//  (Lukas ↔ nuttycom, 2026-08-07) — the seam is exactly one line in `confirmRestartTapped`.
//
//  NUMBERS COME FROM THE SNAPSHOT, never a second read: `doneTransfers`/`totalTransfers` and
//  `orchardRemaining` are the same values the banner, the timeline and the pool header render, so
//  this screen cannot disagree with them (R13's one-derivation rule).
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationRestart {
    @ObservableState
    struct State: Equatable {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        /// The run's progress, as the timeline shows it — wallet-confirmed done transfers out of
        /// the plan's total.
        var doneTransfers = 0
        var totalTransfers = 0
        /// Orchard value still in the source pool — what a fresh plan would cover.
        var remainingBalance = Zatoshi.zero

        /// The confirmation sheet.
        var isConfirmationPresented = false
        /// TRUE from the moment Confirm restart is tapped until the engine answers. Drives the
        /// spinner AND disables every control in the flow — see `MigrationRestartView`.
        var isRestarting = false

        /// The whole flow is inert without an account to act on: no engine call can be addressed,
        /// so the CTA must not pretend otherwise.
        var isRestartPossible: Bool {
            selectedWalletAccount?.id != nil
        }

        init() { }
    }

    enum Action: Equatable {
        case onAppear
        /// The snapshot's numbers, read once on appear.
        case snapshotLoaded(done: Int, total: Int, remaining: Zatoshi)
        case nextTapped
        case confirmationPresentedChanged(Bool)
        case cancelTapped
        case confirmRestartTapped
        /// The engine answered. `true` = the run was cancelled; the coordinator pops on this.
        case restartFinished(Bool)
        case delegate(Delegate)

        enum Delegate: Equatable {
            /// The run is cancelled — leave this screen. The coordinator owns where to.
            case restarted
        }
    }

    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    let snapshot = await migrationManager.migrationViewSnapshot(accountUUID)
                    await send(
                        .snapshotLoaded(
                            done: snapshot.doneTransfers,
                            total: snapshot.totalTransfers,
                            remaining: snapshot.orchardRemaining
                        )
                    )
                }

            case let .snapshotLoaded(done, total, remaining):
                state.doneTransfers = done
                state.totalTransfers = total
                state.remainingBalance = remaining
                return .none

            case .nextTapped:
                state.isConfirmationPresented = true
                return .none

            case let .confirmationPresentedChanged(isPresented):
                // A swipe-down while the engine call is in flight would leave the spinner running
                // behind a dismissed sheet and the user free to tap Next again. The sheet is
                // modal for the duration; only the finish re-opens the gate.
                guard !state.isRestarting else { return .none }
                state.isConfirmationPresented = isPresented
                return .none

            case .cancelTapped:
                guard !state.isRestarting else { return .none }
                state.isConfirmationPresented = false
                return .none

            case .confirmRestartTapped:
                // Re-entrancy: the button is disabled while restarting, but a queued tap that
                // landed in the same frame must not start a second engine call.
                guard !state.isRestarting, let accountUUID = state.selectedWalletAccount?.id else {
                    return .none
                }
                state.isRestarting = true
                return .run { send in
                    do {
                        // The fresh preview is discarded on purpose — see this file's header.
                        _ = try await sdkSynchronizer.restartCurrentMigrationStep(accountUUID)
                        // MOB-1466 (Lukas, 2026-08-07): THE ONLY PLACE THIS IS EVER SET. The engine
                        // has no field for "the user asked to start over" — it folds a cancelled run
                        // into the same terminal step as every other one — so without this the state
                        // derivation reads the cancelled run as terminated-UNFINISHED and the banner
                        // offers "Update migration plan" instead of "Migration required".
                        //
                        // AFTER the engine's cancel returns, never before: a throw above must leave
                        // no marker behind for a run that still exists.
                        await migrationManager.markRunCancelledByUser(accountUUID)
                        // The cancel changed engine state that every migration surface reads;
                        // without this the banner keeps showing the run that no longer exists.
                        await migrationManager.reconcile()
                        await send(.restartFinished(true))
                    } catch {
                        LoggerProxy.event(
                            "\(MigrationManagerImpl.logTag) restart migration failed — \(error.toZcashError())"
                        )
                        await send(.restartFinished(false))
                    }
                }

            case let .restartFinished(didRestart):
                state.isRestarting = false
                guard didRestart else {
                    // NO designed failure state exists (the Figma has three frames, none of them an
                    // error). Rather than invent copy, the sheet stays open with its controls live
                    // so the user can retry or cancel, and the failure is logged. Flagged to
                    // product 2026-08-07.
                    return .none
                }
                state.isConfirmationPresented = false
                return .send(.delegate(.restarted))

            case .delegate:
                return .none
            }
        }
    }
}
