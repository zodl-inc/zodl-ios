//
//  WalletBackupCoordFlowStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-04-18.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct WalletBackupCoordFlow {
    @Reducer
    enum Path {
        case phrase(RecoveryPhraseDisplay)
    }
    
    @ObservableState
    struct State {
        var isHelpSheetPresented = false
        var path = StackState<Path.State>()
        var recoveryPhraseDisplayState = RecoveryPhraseDisplay.State.initial

        init() { }
    }

    enum Action: BindableAction {
        case binding(BindingAction<WalletBackupCoordFlow.State>)
        case backToHomeTapped
        case helpSheetRequested
        case path(StackActionOf<Path>)
        case recoveryPhraseDisplay(RecoveryPhraseDisplay.Action)
    }

    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()

        BindingReducer()
        
        Scope(state: \.recoveryPhraseDisplayState, action: \.recoveryPhraseDisplay) {
            RecoveryPhraseDisplay()
        }

        Reduce { state, action in
            switch action {
            case .helpSheetRequested:
                state.isHelpSheetPresented.toggle()
                return .none

            default: return .none
            }
        }
        .forEach(\.path, action: \.path)
    }
}
