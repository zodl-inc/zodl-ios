//
//  MigrationNoteSplitStore.swift
//  zodl
//
//  "Split Your Wallet Funds" screen (MOB-1461, Figma S2 · 2867:10535 explainer / 2867:10741
//  progress / 2867:10645 success / 2670:15570 failure sheet). One screen, three phases (explainer
//  -> splitting -> confirmed) plus a failure bottom sheet presented over the splitting phase.
//  Visual-only: SDK-driven actions (`splitConfirmed`, `splitResult`) are declared but inert, and the
//  screen never transitions phases itself — wiring that up against the SDK is MOB-1466's job. The
//  `continueTapped` delegate is emitted but consumed by nobody yet.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationNoteSplit {
    @ObservableState
    struct State: Equatable {
        enum Phase: Equatable {
            case explainer
            case splitting
            case confirmed
        }

        var phase = Phase.explainer
        /// Placeholder; real proposal data lands in MOB-1466.
        var amount = Zatoshi.zero
        var fee = Zatoshi.zero
        /// Shown from the splitting phase on.
        var txId = ""
        /// Failure sheet presented over the splitting phase.
        var isFailurePresented = false
        @Shared(.inMemory(.toast)) var toast: Toast.Edge? = nil

        init(
            phase: Phase = .explainer,
            amount: Zatoshi = Zatoshi.zero,
            fee: Zatoshi = Zatoshi.zero,
            txId: String = "",
            isFailurePresented: Bool = false
        ) {
            self.phase = phase
            self.amount = amount
            self.fee = fee
            self.txId = txId
            self.isFailurePresented = isFailurePresented
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        /// Explainer CTA — inert now; MOB-1466 submits the split.
        case confirmTapped
        /// Confirmed CTA.
        case continueTapped
        case copyTxIdTapped
        case delegate(Delegate)
        /// Failure sheet: dismiss — inert re-submit (MOB-1466).
        case retryTapped
        /// Declared for MOB-1466 (SDK-driven) — inert.
        case splitConfirmed
        /// Declared for MOB-1466 (SDK-driven) — inert.
        case splitResult(TransferResult)

        enum Delegate: Equatable {
            case continued
        }
    }

    @Dependency(\.pasteboard) var pasteboard

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

            case .confirmTapped:
                return .none

            case .continueTapped:
                return .send(.delegate(.continued))

            case .copyTxIdTapped:
                pasteboard.setString(state.txId.redacted)
                state.$toast.withLock { $0 = .top(String(localizable: .generalCopiedToTheClipboard)) }
                return .none

            case .delegate:
                return .none

            case .retryTapped:
                state.isFailurePresented = false
                return .none

            case .splitConfirmed:
                return .none

            case .splitResult:
                return .none
            }
        }
    }
}
