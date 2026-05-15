//
//  ReceiveCoordinator.swift
//  modules
//
//  Created by Lukáš Korba on 2025-03-17.
//

import ComposableArchitecture

extension Receive {
    func coordinatorReduce() -> Reduce<Receive.State, Receive.Action> {
        Reduce { state, action in
            switch action {
                // MARK: Receive

            case let .addressDetailsRequest(address, maxPrivacy):
                var addressDetailsState = AddressDetails.State.initial
                addressDetailsState.address = address
                addressDetailsState.maxPrivacy = maxPrivacy
                if state.selectedWalletAccount?.vendor == .keystone {
                    addressDetailsState.addressTitle = maxPrivacy
                    ? String(localizable: .accountsKeystoneShieldedAddress)
                    : String(localizable: .accountsKeystoneTransparentAddress)
                } else {
                    addressDetailsState.addressTitle = maxPrivacy
                    ? String(localizable: .accountsZashiShieldedAddress)
                    : String(localizable: .accountsZashiTransparentAddress)
                }
                state.path.append(.addressDetails(addressDetailsState))
                return .none
                
            case let .requestTapped(address, maxPrivacy):
                state.path.append(.zecKeyboard(ZecKeyboard.State.initial))
                state.memo = ""
                state.requestZecState = RequestZec.State.initial
                state.requestZecState.address = address
                state.requestZecState.maxPrivacy = maxPrivacy
                return .none
                
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

            case .path(.element(id: _, action: .requestZecSummary(.cancelRequestTapped))):
                state.path.removeAll()
                return .none

                // MARK: - Zec Keyboard

            case .path(.element(id: _, action: .zecKeyboard(.nextTapped))):
                for element in state.path {
                    if case .zecKeyboard(let zecKeyboardState) = element {
                        state.requestZecState.memoState.text = state.memo
                        state.requestZecState.requestedZec = zecKeyboardState.amount.roundToAvoidDustSpend()
                        break
                    }
                }
                state.path.append(.requestZec(state.requestZecState))
                return .none
                
            default: return .none
            }
        }
    }
}
