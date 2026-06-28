//
//  MigrationNoteSplitStore.swift
//  zodl
//
//  Phase 1 — "Split Your Wallet Funds". A send-to-self that breaks the balance into smaller notes.
//  States: confirm → splitting → confirmed. On reopen while a split is pending, shows the waiting state.
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationNoteSplit {
    @ObservableState
    struct State: Equatable {
        enum Step: Equatable {
            case confirm
            case splitting
            case confirmed
        }

        var step: Step = .confirm
        var totalAmount: Zatoshi = .zero
        var fee: Zatoshi = .zero
        var noteCount = 0
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
        case stateChanged(MigrationState)
        case confirmTapped
        case submitResult(TransferResult)
        case continueTapped
        case delegate(Delegate)
    }

    enum CancelID { case stateStream }

    @Dependency(\.migrationSDK) var migrationSDK

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // If we re-entered while a split is already pending, reflect that.
                if migrationSDK.getMigrationState() == .splitPendingConfirmation {
                    state.step = .splitting
                }
                state.totalAmount = migrationSDK.simulatedOrchardBalance()
                return .merge(
                    .run { send in
                        await send(.proposalLoaded(migrationSDK.prepareNoteSplit()))
                    },
                    .publisher {
                        migrationSDK.stateStream().map(Action.stateChanged)
                    }
                    .cancellable(id: CancelID.stateStream, cancelInFlight: true)
                )

            case let .proposalLoaded(proposal):
                state.proposal = proposal
                state.fee = proposal.fee
                state.noteCount = proposal.outputNotes.count
                return .none

            case let .stateChanged(migrationState):
                if state.step == .splitting, migrationState == .readyToPropose {
                    state.step = .confirmed
                }
                return .none

            case .confirmTapped:
                guard let proposal = state.proposal else { return .none }
                state.step = .splitting
                return .run { send in
                    await send(.submitResult(migrationSDK.submitNoteSplit(proposal)))
                }

            case let .submitResult(result):
                if case let .success(txId) = result {
                    state.txId = txId
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
