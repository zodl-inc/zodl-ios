//
//  WalletBackupCoordFlowStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-04-18.
//

import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit

import RecoveryPhraseDisplay

// Path

@Reducer
public struct WalletBackupCoordFlow {
    @Reducer
    public enum Path {
        case phrase(RecoveryPhraseDisplay)
    }
    
    @ObservableState
    public struct State {
        public var isHelpSheetPresented = false
        public var path = StackState<Path.State>()
        public var recoveryPhraseDisplayState = RecoveryPhraseDisplay.State.initial

        public init() { }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<WalletBackupCoordFlow.State>)
        case backToHomeTapped
        case helpSheetRequested
        case path(StackActionOf<Path>)
        case recoveryPhraseDisplay(RecoveryPhraseDisplay.Action)
    }

    public init() { }

    public var body: some Reducer<State, Action> {
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
