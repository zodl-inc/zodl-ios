//
//  MigrationNoteSplitStore.swift
//  zodl
//
//  Phase 1 — the note-split send-to-self that breaks the balance into transfer-sized notes. The user
//  first sees an explainer (Figma "Notes Splitting_Explainer_A") and must Confirm; the send-to-self is
//  submitted only then. After that the user waits ~15s for the simulated on-chain confirmation before
//  continuing (Figma B3a → B3b).
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationNoteSplit {
    @ObservableState
    struct State: Equatable {
        enum Step: Equatable {
            /// Pre-split explainer — the user confirms before the send-to-self is broadcast.
            case explainer
            /// Send-to-self broadcast, waiting for confirmation.
            case splitting
            /// Confirmed — ready to continue to the schedule.
            case confirmed
        }

        var step: Step = .explainer
        var totalAmount: Zatoshi = .zero
        var fee: Zatoshi = .zero
        var txId = ""
        var proposal: NoteSplitProposal?

        init() { }
    }

    enum Action {
        enum Delegate: Equatable {
            case continued
        }

        case onAppear
        case proposalLoaded(NoteSplitProposal)
        case confirmTapped
        case submitResult(TransferResult)
        case stateChanged(MigrationState)
        case continueTapped
        case delegate(Delegate)
    }

    enum CancelID { case stateStream }

    @Dependency(\.migrationSDK) var migrationSDK

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.totalAmount = migrationSDK.simulatedOrchardBalance()
                let current = migrationSDK.getMigrationState()

                // Already confirmed (re-entry): show the confirmed state.
                if current == .readyToPropose {
                    state.step = .confirmed
                    return .publisher {
                        migrationSDK.stateStream().map(Action.stateChanged)
                    }
                    .cancellable(id: CancelID.stateStream, cancelInFlight: true)
                }

                // A split is already pending (re-entry while waiting): just observe.
                if current == .splitPendingConfirmation {
                    state.step = .splitting
                    return .merge(
                        .run { send in
                            await send(.proposalLoaded(migrationSDK.prepareNoteSplit()))
                        },
                        .publisher {
                            migrationSDK.stateStream().map(Action.stateChanged)
                        }
                        .cancellable(id: CancelID.stateStream, cancelInFlight: true)
                    )
                }

                // Fresh: show the explainer with the prepared amounts. The split runs on Confirm.
                state.step = .explainer
                return .run { send in
                    await send(.proposalLoaded(migrationSDK.prepareNoteSplit()))
                }

            case let .proposalLoaded(proposal):
                state.proposal = proposal
                state.fee = proposal.fee
                return .none

            case .confirmTapped:
                guard state.step == .explainer else { return .none }
                state.step = .splitting
                let prepared = state.proposal
                return .merge(
                    .run { send in
                        let proposal: NoteSplitProposal
                        if let prepared {
                            proposal = prepared
                        } else {
                            proposal = await migrationSDK.prepareNoteSplit()
                        }
                        let result = await migrationSDK.submitNoteSplit(proposal)
                        await send(.submitResult(result))
                    },
                    .publisher {
                        migrationSDK.stateStream().map(Action.stateChanged)
                    }
                    .cancellable(id: CancelID.stateStream, cancelInFlight: true)
                )

            case let .submitResult(result):
                if case let .success(txId) = result {
                    state.txId = txId
                } else {
                    // The split broadcast/sign failed. Don't hang forever on the "Splitting Funds…"
                    // spinner — return to the confirm step so the user can retry. The failure detail
                    // is captured in the migration logs (`LiveMigrationEngine.logFailure`). A dedicated
                    // error screen is a follow-up.
                    state.step = .explainer
                }
                return .none

            case let .stateChanged(migrationState):
                if state.step == .splitting, migrationState == .readyToPropose {
                    state.step = .confirmed
                }
                return .none

            case .continueTapped:
                return .merge(
                    .cancel(id: CancelID.stateStream),
                    .send(.delegate(.continued))
                )

            case .delegate:
                return .none
            }
        }
    }
}
