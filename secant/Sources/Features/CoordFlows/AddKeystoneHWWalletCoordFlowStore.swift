//
//  AddKeystoneHWWalletCoordFlowStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-19.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct AddKeystoneHWWalletCoordFlow {
    @Reducer
    enum Path {
        case accountHWWalletSelection(AddKeystoneHWWallet)
        case estimateBirthdaysDate(WalletBirthday)
        case estimatedBirthday(WalletBirthday)
        case keystoneConnected(AddKeystoneHWWallet)
        case keystoneDeviceReady(AddKeystoneHWWallet)
        case restoreInfo(RestoreInfo)
        case scan(Scan)
        case walletBirthday(WalletBirthday)
    }
    
    @ObservableState
    struct State {
        var addKeystoneHWWalletState = AddKeystoneHWWallet.State.initial
        var birthday: BlockHeight? = nil
        var isHelpSheetPresented = false
        var path = StackState<Path.State>()

        init() { }
    }

    enum Action: BindableAction {
        case addKeystoneHWWallet(AddKeystoneHWWallet.Action)
        case binding(BindingAction<AddKeystoneHWWalletCoordFlow.State>)
        case closeHelpSheetTapped
        case path(StackActionOf<Path>)
    }

    @Dependency(\.audioServices) var audioServices
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    
    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()

        BindingReducer()

        Scope(state: \.addKeystoneHWWalletState, action: \.addKeystoneHWWallet) {
            AddKeystoneHWWallet()
        }
        
        Reduce { state, action in
            switch action {
            case .closeHelpSheetTapped:
                state.isHelpSheetPresented = false
                return .none
            default: return .none
            }
        }
        .forEach(\.path, action: \.path)
    }
}
