//
//  RequestZecCoordFlowStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-17.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct RequestZecCoordFlow {
    @Reducer
    enum Path {
        case requestZec(RequestZec)
        case requestZecSummary(RequestZec)
    }
    
    @ObservableState
    struct State {
        var memo = ""
        var path = StackState<Path.State>()
        var requestZecState = RequestZec.State.initial
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var zecKeyboardState = ZecKeyboard.State.initial

        init() { }
    }

    enum Action {
        case path(StackActionOf<Path>)
        case zecKeyboard(ZecKeyboard.Action)
    }

    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()

        Scope(state: \.zecKeyboardState, action: \.zecKeyboard) {
            ZecKeyboard()
        }

        Reduce { state, action in
            switch action {
            default: return .none
            }
        }
        .forEach(\.path, action: \.path)
    }
}
