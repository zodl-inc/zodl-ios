//
//  MigrationNoteSplitStore.swift
//  zodl
//
//  Phase 1 — the note-split send-to-self that breaks the balance into transfer-sized notes. The split
//  is submitted automatically when the screen appears (Figma B3a lands already in progress), then the
//  user waits ~15s for the simulated on-chain confirmation before continuing (Figma B3b).
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationNoteSplit {
    @ObservableState
    struct State: Equatable {
        enum Step: Equatable {
            /// Send-to-self broadcast, waiting for confirmation.
            case splitting
            /// Confirmed — ready to continue to the schedule.
            case confirmed
        }

        var step: Step = .splitting
        var totalAmount: Zatoshi = .zero
        var fee: Zatoshi = .zero
        var txId = ""

        init() { }
    }

    enum Action {
        enum Delegate: Equatable {
            case continued
        }

        case onAppear
        case proposalLoaded(NoteSplitProposal)
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

                // Fresh: prepare and submit the split now, then wait for confirmation.
                state.step = .splitting
                return .merge(
                    .run { send in
                        let proposal = await migrationSDK.prepareNoteSplit()
                        await send(.proposalLoaded(proposal))
                        let result = await migrationSDK.submitNoteSplit(proposal)
                        await send(.submitResult(result))
                    },
                    .publisher {
                        migrationSDK.stateStream().map(Action.stateChanged)
                    }
                    .cancellable(id: CancelID.stateStream, cancelInFlight: true)
                )

            case let .proposalLoaded(proposal):
                state.fee = proposal.fee
                return .none

            case let .submitResult(result):
                if case let .success(txId) = result {
                    state.txId = txId
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
