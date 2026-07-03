//
//  MigrationCompleteStore.swift
//  zodl
//
//  "Migration Complete" screen (MOB-1464, Figma S12 · 2696:7267). Visually complete per Figma; all
//  summary fields are placeholders — wiring the real data lands in MOB-1466. The `gotItTapped`
//  delegate is emitted but consumed by nobody yet.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationComplete {
    @ObservableState
    struct State: Equatable {
        var totalTransferred = Zatoshi.zero
        var dust = Zatoshi.zero
        var transfersSent = 0
        var transfersTotal = 0
        var durationHours = 0

        var hasDust: Bool {
            dust.amount > 0
        }

        init(
            totalTransferred: Zatoshi = .zero,
            dust: Zatoshi = .zero,
            transfersSent: Int = 0,
            transfersTotal: Int = 0,
            durationHours: Int = 0
        ) {
            self.totalTransferred = totalTransferred
            self.dust = dust
            self.transfersSent = transfersSent
            self.transfersTotal = transfersTotal
            self.durationHours = durationHours
        }
    }

    enum Action: Equatable {
        case delegate(Delegate)
        case gotItTapped

        enum Delegate: Equatable {
            case done
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .gotItTapped:
                return .send(.delegate(.done))

            case .delegate:
                return .none
            }
        }
    }
}
