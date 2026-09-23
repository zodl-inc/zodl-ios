//
//  RestoreInfoStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 06-03-2024
//

import ComposableArchitecture

@Reducer
struct RestoreInfo {
    @ObservableState
    struct State: Equatable {
        /// The hardware wallet this `isKeystoneFlow` flow is connecting, which picks the warning
        /// copy below; read only when `isKeystoneFlow`.
        var hardwareWalletVendor: WalletAccount.Vendor = .keystone
        var isAcknowledged = true
        var isKeystoneFlow = false
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
