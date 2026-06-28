//
//  MigrationRecoveryStore.swift
//  zodl
//
//  "Transfer No Longer Valid" (Figma C5). A pre-signed transfer became invalid (its input note was
//  spent) or expired (anchor too old). The user re-creates it for the remaining amount; the other
//  transfers are kept and re-scheduled. The retryable "stalled / overdue" case lives on the status
//  screen ("Resume Migration"), not here.
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationRecovery {
    @ObservableState
    struct State: Equatable {
        var summary: MigrationSummary = .zero
        /// 1-based number of the invalid/expired transfer (0 if unknown).
        var invalidTransferNumber = 0
        var invalidAmount: Zatoshi = .zero

        init() { }
    }

    enum Action {
        enum Delegate: Equatable {
            case recreate
            /// Leading close control — closes the whole flow back to Home.
            case close
        }

        case onAppear
        case recreateTapped
        case learnMoreTapped
        case closeTapped
        case delegate(Delegate)
    }

    @Dependency(\.migrationSDK) var migrationSDK

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.summary = migrationSDK.migrationSummary()
                let rows = migrationSDK.migrationTransfers()
                if let invalid = rows.first(where: { $0.status == .invalid || $0.status == .expired }) {
                    state.invalidTransferNumber = invalid.index + 1
                    state.invalidAmount = invalid.amount
                }
                return .none

            case .recreateTapped:
                return .send(.delegate(.recreate))

            case .learnMoreTapped:
                // PROTOTYPE: the design's secondary action has no destination yet.
                return .none

            case .closeTapped:
                return .send(.delegate(.close))

            case .delegate:
                return .none
            }
        }
    }
}
