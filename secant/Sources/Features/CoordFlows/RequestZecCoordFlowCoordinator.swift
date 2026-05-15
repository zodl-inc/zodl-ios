//
//  RequestZecCoordFlowCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-17.
//

import ComposableArchitecture

extension RequestZecCoordFlow {
    func coordinatorReduce() -> Reduce<RequestZecCoordFlow.State, RequestZecCoordFlow.Action> {
        Reduce { state, action in
            switch action {
                // MARK: - Request Zec

            case .path(.element(id: _, action: .requestZec(.requestTapped))):
                for element in state.path {
                    if case .requestZec(let requestZecState) = element {
                        state.requestZecState.memoState = requestZecState.memoState
                        break
                    }
                }
                state.path.append(.requestZecSummary(state.requestZecState))
                return .none

                // MARK: - Zec Keyboard

            case .zecKeyboard(.nextTapped):
                state.requestZecState.address = state.selectedWalletAccount?.privateUnifiedAddress?.redacted ?? "".redacted
                state.requestZecState.maxPrivacy = true
                state.requestZecState.memoState = .initial
                state.requestZecState.memoState.text = state.memo
                state.requestZecState.requestedZec = state.zecKeyboardState.amount.roundToAvoidDustSpend()
                state.path.append(.requestZec(state.requestZecState))
                return .none
                
            default: return .none
            }
        }
    }
}
