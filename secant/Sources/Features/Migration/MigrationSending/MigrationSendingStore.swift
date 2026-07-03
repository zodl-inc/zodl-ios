//
//  MigrationSendingStore.swift
//  zodl
//
//  "Sending" / "Sent" screen (MOB-1463, Figma S8 · sending 2618:6858 / sent 2618:6895). Shown while
//  a migration transfer broadcasts, then flips to a success state. Visual-only: `txId` is a
//  placeholder and `result` is declared but inert — resubmitting after a failure and wiring the
//  real broadcast result land in MOB-1466. The `closeTapped` / `viewTransactionTapped` delegates
//  are emitted but consumed by nobody yet.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationSending {
    @ObservableState
    struct State: Equatable {
        enum Phase: Equatable {
            case sending
            case success
        }

        var phase = Phase.sending
        /// Failure sheet presented over the sending phase.
        var isFailurePresented = false
        /// Placeholder; real tx id lands in MOB-1466 (wires up View Transaction).
        var txId = ""

        init(
            phase: Phase = .sending,
            isFailurePresented: Bool = false,
            txId: String = ""
        ) {
            self.phase = phase
            self.isFailurePresented = isFailurePresented
            self.txId = txId
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        case closeTapped
        case delegate(Delegate)
        /// Declared for MOB-1466 (SDK-driven) — inert.
        case result(TransferResult)
        /// Failure sheet: dismiss — inert re-submit (MOB-1466).
        case retryTapped
        case viewTransactionTapped

        enum Delegate: Equatable {
            case closed
            case viewTransaction
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .cancelTapped:
                state.isFailurePresented = false
                return .none

            case .closeTapped:
                return .send(.delegate(.closed))

            case .delegate:
                return .none

            case .result:
                return .none

            case .retryTapped:
                state.isFailurePresented = false
                return .none

            case .viewTransactionTapped:
                return .send(.delegate(.viewTransaction))
            }
        }
    }
}
