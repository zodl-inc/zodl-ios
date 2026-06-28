//
//  MigrationNetworkPrivacyStore.swift
//  zodl
//
//  "Network Privacy" — optional Tor toggle (no default). Used by both the immediate and private paths.
//  Emits the chosen NetworkPrivacyOptions on continue.
//

import ComposableArchitecture
import SwiftUI

@Reducer
struct MigrationNetworkPrivacy {
    @ObservableState
    struct State: Equatable {
        var useTor = false
        /// Debug-armed "Tor unavailable" sub-state (C2).
        var torUnavailable = false

        init() { }
    }

    enum Action: BindableAction {
        enum Delegate: Equatable {
            case confirmed(NetworkPrivacyOptions)
        }

        case binding(BindingAction<State>)
        case nextTapped
        case delegate(Delegate)
    }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .nextTapped:
                return .send(.delegate(.confirmed(NetworkPrivacyOptions(useTor: state.useTor))))

            case .delegate:
                return .none
            }
        }
    }
}
