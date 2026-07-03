//
//  MigrationRecoveryStore.swift
//  zodl
//
//  "Reschedule Transfers" / "Transfers No Longer Valid" screen (MOB-1464, Figma S11 · spent
//  2696:5626 / expired 2973:5698). When this screen is the coordinator's re-entry root
//  (`isFlowRoot`), its back control closes the flow (`closeTapped` -> `.delegate(.close)`) instead
//  of popping (MOB-1466). The `continueTapped` delegate is emitted but consumed by nobody yet —
//  wiring the real plan-recreation flow is the coordinator's job (phase 3).
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
        /// True when this screen is the coordinator's re-entry root — its back control then closes
        /// the flow instead of popping.
        var isFlowRoot = false

        init(
            reason: Reason = .notesSpent,
            firstTransfer: Int = 3,
            lastTransfer: Int = 5,
            isFlowRoot: Bool = false
        ) {
            self.reason = reason
            self.firstTransfer = firstTransfer
            self.lastTransfer = lastTransfer
            self.isFlowRoot = isFlowRoot
        }
    }

    enum Action: Equatable {
        /// Flow-root back control: closes the flow instead of popping.
        case closeTapped
        case continueTapped
        case delegate(Delegate)

        enum Delegate: Equatable {
            case close
            case recreate
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .closeTapped:
                return .send(.delegate(.close))

            case .continueTapped:
                return .send(.delegate(.recreate))

            case .delegate:
                return .none
            }
        }
    }
}
