//
//  MigrationBackgroundDeliveryStore.swift
//  zodl
//
//  "Allow Background Delivery" screen (MOB-1462, Figma S3 · 2840:4480). Explains why ZODL needs
//  Background App Refresh to send migration transfers at their scheduled times. Visual-only:
//  `allowTapped` (opening the Settings deep-link) and `scenePhaseActive` (re-checking BAR on
//  return) are declared but inert — wiring them up is MOB-1466's job. The `skipTapped` delegate is
//  emitted but consumed by nobody yet.
//

import ComposableArchitecture

@Reducer
struct MigrationBackgroundDelivery {
    @ObservableState
    struct State: Equatable {
    }

    enum Action: Equatable {
        /// Inert now — MOB-1466 opens the Settings deep-link.
        case allowTapped
        case delegate(Delegate)
        /// Declared for MOB-1466 (re-check Background App Refresh on return) — inert.
        case scenePhaseActive
        case skipTapped

        enum Delegate: Equatable {
            case continued(backgroundAllowed: Bool)
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .allowTapped:
                return .none

            case .delegate:
                return .none

            case .scenePhaseActive:
                return .none

            case .skipTapped:
                return .send(.delegate(.continued(backgroundAllowed: false)))
            }
        }
    }
}
