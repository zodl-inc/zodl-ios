//
//  MigrationBackgroundDeliveryStore.swift
//  zodl
//
//  "Allow Background Delivery" screen (MOB-1462, Figma S3 · 2840:4480). Explains why ZODL needs
//  Background App Refresh to send migration transfers at their scheduled times. `allowTapped` opens
//  the Settings deep-link from the view (`@Environment(\.openURL)`) — the action here is just the
//  tap signal. `scenePhaseActive` re-checks Background App Refresh on return and auto-advances via
//  `.continued(backgroundAllowed: true)` once it becomes available (MOB-1466). The `skipTapped`
//  delegate is consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//

import ComposableArchitecture

@Reducer
struct MigrationBackgroundDelivery {
    @ObservableState
    struct State: Equatable {
    }

    enum Action: Equatable {
        /// The Settings deep-link opens from the view; this action is just the tap signal.
        case allowTapped
        case delegate(Delegate)
        /// Re-checks Background App Refresh on return; auto-advances when it becomes available.
        case scenePhaseActive
        case skipTapped

        enum Delegate: Equatable {
            case continued(backgroundAllowed: Bool)
        }
    }

    @Dependency(\.migrationBGScheduler) var migrationBGScheduler

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .allowTapped:
                return .none

            case .delegate:
                return .none

            case .scenePhaseActive:
                return .run { send in
                    let status = await migrationBGScheduler.backgroundRefreshStatus()
                    guard status == .available else { return }
                    await send(.delegate(.continued(backgroundAllowed: true)))
                }

            case .skipTapped:
                return .send(.delegate(.continued(backgroundAllowed: false)))
            }
        }
    }
}
