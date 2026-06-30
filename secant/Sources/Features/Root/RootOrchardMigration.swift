//
//  RootOrchardMigration.swift
//  ZODL
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension Root {
    func orchardMigrationReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .observeOrchardMigration:
                return .publisher {
                    migrationProcessor.observe()
                        .map(Action.orchardMigrationStateChanged)
                }
                .cancellable(id: state.orchardMigrationCancelId, cancelInFlight: true)

            case .orchardMigrationStateChanged(let phase):
                state.orchardMigrationState.phase = phase

                switch phase {
                case .requiresAttention(.invalidTransfer):
                    // Surface a non-blocking alert; user can still dismiss and use the app.
                    state.alert = AlertState.orchardMigrationInvalidTransfer()

                case .requiresAttention(.transferExpired):
                    state.alert = AlertState.orchardMigrationTransferExpired()

                case .requiresAttention(.syncRequired):
                    // Sync gate: do not surface an alert — the sync flow handles this.
                    break

                case .failed(let error):
                    state.alert = AlertState.orchardMigrationFailed(error)

                default:
                    break
                }

                return .none

            // Keystone path: migration produced a PCZT — route through existing signing flow.
            case .orchardMigrationKeystoneProposalReady(let proposal):
                state.signWithKeystoneCoordFlowState = .initial
                state.signWithKeystoneCoordFlowState.sendConfirmationState.proposal = proposal
                state.signWithKeystoneCoordFlowState.sendConfirmationState.isMigration = true
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(0.8))
                    await send(.signWithKeystoneRequested)
                }

            default:
                return .none
            }
        }
    }
}

// MARK: - Alert states

extension AlertState where Action == Root.Action {
    static func orchardMigrationInvalidTransfer() -> Self {
        AlertState {
            TextState("Transfer already sent")
        } actions: {
            ButtonState(role: .cancel) { TextState("OK") }
        } message: {
            TextState("This transfer was already sent, possibly from another device. The migration will continue from the current on-chain state.")
        }
    }

    static func orchardMigrationTransferExpired() -> Self {
        AlertState {
            TextState("Transfer expired")
        } actions: {
            ButtonState(role: .cancel) { TextState("OK") }
        } message: {
            TextState("A scheduled transfer expired before it was sent. ZODL will prepare a new one when you tap retry.")
        }
    }

    static func orchardMigrationFailed(_ error: ZcashError) -> Self {
        AlertState {
            TextState("Migration error")
        } actions: {
            ButtonState(role: .cancel) { TextState("OK") }
        } message: {
            TextState(error.detailedMessage)
        }
    }
}
