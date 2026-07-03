//
//  MigrationNotificationsStore.swift
//  zodl
//
//  "Allow Notifications" screen (MOB-1462, Figma S4 scheduled · 2840:4728 / manual · 2867:1921).
//  Explains what migration-related notifications the user will get, with copy that differs by
//  `variant` (scheduled vs. manual send cadence). Visual-only: `allowTapped` (requesting
//  `UNUserNotificationCenter` authorization) and `authorizationResult` are declared but inert —
//  wiring them up is MOB-1466's job. The `skipTapped` delegate is emitted but consumed by nobody
//  yet.
//

import ComposableArchitecture

@Reducer
struct MigrationNotifications {
    @ObservableState
    struct State: Equatable {
        enum Variant: Equatable {
            case scheduled
            case manual
        }

        var variant = Variant.scheduled

        init(variant: Variant = .scheduled) {
            self.variant = variant
        }
    }

    enum Action: Equatable {
        /// Inert now — MOB-1466 requests notification authorization.
        case allowTapped
        /// Declared for MOB-1466 — inert.
        case authorizationResult(Bool)
        case delegate(Delegate)
        case skipTapped

        enum Delegate: Equatable {
            case continued
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .allowTapped:
                return .none

            case .authorizationResult:
                return .none

            case .delegate:
                return .none

            case .skipTapped:
                return .send(.delegate(.continued))
            }
        }
    }
}
