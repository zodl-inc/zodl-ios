//
//  RestoreInfoStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 06-03-2024
//

import ComposableArchitecture
import Combine

@Reducer
struct RestoreInfo {
    @ObservableState
    struct State: Equatable {
        var isAcknowledged = true
        var isKeystoneFlow = false
        /// [B4-4 class] TRUE while the work OK triggered is running behind this screen
        /// (the Keystone flow's `importAccount`: engine stop → drain → anchor fetch →
        /// import → restart, seconds). Set/cleared by the OWNING coordinator — this
        /// screen only renders it (spinner + disabled OK) so the wait never reads as a
        /// dead button.
        var isProcessing = false
        var isResyncFlow = false
    }
    
    enum Action: BindableAction, Equatable {
        case binding(BindingAction<RestoreInfo.State>)
        case gotItTapped
    }

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .binding:
                return .none
                
            case .gotItTapped:
                return .none
            }
        }
    }
}
