//
//  MigrationReviewTransferStore.swift
//  zodl
//
//  "Review Transfer" screen (MOB-1463, Figma S7 · immediate 2867:5924 / manual "3 of 5" 2729:8544,
//  equivalent to frame 2712:7779 which fails to render via MCP). Final confirmation before a
//  migration transfer is sent — either the single immediate transfer, or one step of a scheduled
//  plan. Visual-only: `amount`/`fee` are placeholders and `sendResult` is declared but inert —
//  submitting the transfer lands in MOB-1466. The `confirmTapped` delegate is emitted but consumed
//  by nobody yet.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationReviewTransfer {
    @ObservableState
    struct State: Equatable {
        enum Mode: Equatable {
            case immediate
            case manualStep(number: Int, total: Int)
        }

        var mode = Mode.immediate
        /// Placeholder; real proposal data lands in MOB-1466.
        var amount = Zatoshi.zero
        var fee = Zatoshi.zero

        init(
            mode: Mode = .immediate,
            amount: Zatoshi = Zatoshi.zero,
            fee: Zatoshi = Zatoshi.zero
        ) {
            self.mode = mode
            self.amount = amount
            self.fee = fee
        }
    }

    enum Action: Equatable {
        /// Inert now; MOB-1466 submits the transfer.
        case confirmTapped
        case delegate(Delegate)
        /// Declared for MOB-1466 (SDK-driven) — inert.
        case sendResult(TransferResult)

        enum Delegate: Equatable {
            case confirmed
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .confirmTapped:
                return .send(.delegate(.confirmed))

            case .delegate:
                return .none

            case .sendResult:
                return .none
            }
        }
    }
}
