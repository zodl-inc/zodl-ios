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

        /// Audit 2026-08-03 (C10): single-flight for BOTH CTAs — two fast taps used to emit two
        /// `.continued` delegates, and each pushed its own Transfer Plan, whose duplicate propose
        /// overwrote the SDK's one-slot plan cache (the `migrationPlanStale` race the plan's own
        /// `isConfirming` exists to prevent). Mirrors `MigrationComplete.isMigratingAnyway`;
        /// re-armed by `.onAppear` when the user backs onto this screen.
        var isProceeding = false
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
        case onAppear
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
                guard !state.isProceeding else { return .none }
                state.isProceeding = true
                return .run { send in
                    let isAuthorized = await userNotifications.requestAuthorization()
                    await send(.authorizationResult(isAuthorized))
                }

            case .authorizationResult:
                return .send(.delegate(.continued))

            case .delegate:
                return .none

            case .onAppear:
                state.isProceeding = false
                return .none

            case .skipTapped:
                guard !state.isProceeding else { return .none }
                state.isProceeding = true
                return .send(.delegate(.continued))
            }
        }
    }
}
