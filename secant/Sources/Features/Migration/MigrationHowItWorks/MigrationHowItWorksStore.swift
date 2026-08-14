//
//  MigrationHowItWorksStore.swift
//  zodl
//
//  "How This Works" explainer screen (MOB-1478 W3; restructured MOB-1494 round 4), pushed after
//  Entry for the scheduled/private path. Pure explainer — four steps (Split and schedule/Approve
//  once/If something fails/Large balance) plus a dust footnote; no timeline, no plan numbers,
//  nothing parameterized. The `continueTapped` delegate is consumed by
//  `MigrationCoordFlowCoordinator`, which gates on the Tor bottom sheet (W2, back on this path
//  since MOB-1494) before continuing into the permission-step chain.
//

import ComposableArchitecture

@Reducer
struct MigrationHowItWorks {
    @ObservableState
    struct State: Equatable {
        init() { }
    }

    enum Action: Equatable {
        case continueTapped
        case delegate(Delegate)

        enum Delegate: Equatable {
            case continueTapped
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { _, action in
            switch action {
            case .continueTapped:
                return .send(.delegate(.continueTapped))

            case .delegate:
                return .none
            }
        }
    }
}
