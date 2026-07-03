//
//  MigrationScheduledStore.swift
//  zodl
//
//  "Migration Scheduled" screen (MOB-1463, Figma S9 · 2630:11282). Terminal success screen shown
//  once a scheduled migration plan has been confirmed: a summary card of what's being transferred
//  and over how long. Visual-only: all fields are placeholders — the real summary data lands in
//  MOB-1466. The `doneTapped` delegate is emitted but consumed by nobody yet.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationScheduled {
    @ObservableState
    struct State: Equatable {
        /// Placeholder; real summary data lands in MOB-1466.
        var totalAmount = Zatoshi.zero
        var sentCount = 0
        var totalCount = 0
        var durationHours = 0

        init(
            totalAmount: Zatoshi = Zatoshi.zero,
            sentCount: Int = 0,
            totalCount: Int = 0,
            durationHours: Int = 0
        ) {
            self.totalAmount = totalAmount
            self.sentCount = sentCount
            self.totalCount = totalCount
            self.durationHours = durationHours
        }
    }

    enum Action: Equatable {
        case delegate(Delegate)
        case doneTapped

        enum Delegate: Equatable {
            case done
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .delegate:
                return .none

            case .doneTapped:
                return .send(.delegate(.done))
            }
        }
    }
}
