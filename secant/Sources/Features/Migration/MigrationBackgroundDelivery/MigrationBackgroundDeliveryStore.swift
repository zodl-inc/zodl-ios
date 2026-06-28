//
//  MigrationBackgroundDeliveryStore.swift
//  zodl
//
//  "Allow Background Delivery" — explains background sending and requests notification authorization.
//  Allow or Skip both continue the flow (best-effort, never described as guaranteed).
//

import ComposableArchitecture
import SwiftUI

@Reducer
struct MigrationBackgroundDelivery {
    @ObservableState
    struct State: Equatable {
        init() { }
    }

    enum Action {
        enum Delegate: Equatable {
            case continued
        }

        case allowTapped
        case skipTapped
        case delegate(Delegate)
    }

    @Dependency(\.localNotification) var localNotification

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .allowTapped:
                return .run { send in
                    _ = await localNotification.requestAuthorization()
                    await send(.delegate(.continued))
                }

            case .skipTapped:
                return .send(.delegate(.continued))

            case .delegate:
                return .none
            }
        }
    }
}
