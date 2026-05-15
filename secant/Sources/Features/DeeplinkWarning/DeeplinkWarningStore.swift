//
//  DeeplinkWarningStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 06-12-2024.
//

import ComposableArchitecture

@Reducer
struct DeeplinkWarning {
    @ObservableState
    struct State: Equatable {
        init() { }
    }

    enum Action: Equatable {
        case rescanInZashi
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .rescanInZashi:
                return .none
            }
        }
    }
}
