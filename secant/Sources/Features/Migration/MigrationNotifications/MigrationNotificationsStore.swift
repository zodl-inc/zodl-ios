//
//  MigrationNotificationsStore.swift
//  zodl
//
//  "Allow Notifications" screen (MOB-1462, Figma S4 scheduled · 2840:4728 / manual · 2867:1921).
//  Explains what migration-related notifications the user will get, with copy that differs by
//  `variant` (scheduled vs. manual send cadence). `allowTapped` requests `UNUserNotificationCenter`
//  authorization; either outcome continues the flow — permission is a nice-to-have, not a blocker
//  (MOB-1466). The `skipTapped`/`.continued` delegate is consumed by `MigrationCoordFlowCoordinator`
//  (MOB-1466).
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
        /// Requests notification authorization.
        case allowTapped
        /// `requestAuthorization()` result — either outcome continues the flow.
        case authorizationResult(Bool)
        case delegate(Delegate)
        case skipTapped

        enum Delegate: Equatable {
            case continued
        }
    }

    @Dependency(\.userNotifications) var userNotifications

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .allowTapped:
                return .run { send in
                    let isAuthorized = await userNotifications.requestAuthorization()
                    await send(.authorizationResult(isAuthorized))
                }

            case .authorizationResult:
                return .send(.delegate(.continued))

            case .delegate:
                return .none

            case .skipTapped:
                return .send(.delegate(.continued))
            }
        }
    }
}
