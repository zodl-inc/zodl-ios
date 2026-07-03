//
//  MigrationRecoveryStore.swift
//  zodl
//
//  "Reschedule Transfers" / "Transfers No Longer Valid" screen (MOB-1464, Figma S11 · spent
//  2696:5626 / expired 2973:5698). Visually complete per Figma; the `continueTapped` delegate is
//  emitted but consumed by nobody yet — wiring the real plan-recreation flow lands in MOB-1466.
//

import ComposableArchitecture

@Reducer
struct MigrationRecovery {
    @ObservableState
    struct State: Equatable {
        enum Reason: Equatable {
            case notesSpent
            case expired
        }

        var reason = Reason.notesSpent
        /// "Transfers {a}–{b}" range in copy.
        var firstTransfer = 3
        var lastTransfer = 5

        init(reason: Reason = .notesSpent, firstTransfer: Int = 3, lastTransfer: Int = 5) {
            self.reason = reason
            self.firstTransfer = firstTransfer
            self.lastTransfer = lastTransfer
        }
    }

    enum Action: Equatable {
        case continueTapped
        case delegate(Delegate)

        enum Delegate: Equatable {
            case recreate
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .continueTapped:
                return .send(.delegate(.recreate))

            case .delegate:
                return .none
            }
        }
    }
}
