//
//  ReceiveStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 05.07.2022.
//

import Foundation
import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct Receive {
    @Reducer
    enum Path {
        case addressDetails(AddressDetails)
        case requestZec(RequestZec)
        case requestZecSummary(RequestZec)
        case zecKeyboard(ZecKeyboard)
    }
    
    @ObservableState
    struct State {
        enum AddressType {
            case saplingAddress
            case tAddress
            case uaAddress
        }

        var currentFocus = AddressType.uaAddress
        var isAddressExplainerPresented = false
        var isExplainerForShielded = false
        var memo = ""
        var path = StackState<Path.State>()
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.toast)) var toast: Toast.Edge? = nil

        var requestZecState = RequestZec.State.initial
        
        var unifiedAddress: String {
            selectedWalletAccount?.privateUnifiedAddress ?? String(localizable: .receiveErrorCantExtractUnifiedAddress)
        }

        var saplingAddress: String {
            selectedWalletAccount?.saplingAddress ?? String(localizable: .receiveErrorCantExtractSaplingAddress)
        }

        var transparentAddress: String {
            selectedWalletAccount?.transparentAddress ?? String(localizable: .receiveErrorCantExtractTransparentAddress)
        }

        init() { }
    }

    enum Action {
        case addressDetailsRequest(RedactableString, Bool)
        case backToHomeTapped
        case copyToPastboard(RedactableString)
        case infoTapped(Bool)
        case path(StackActionOf<Path>)
        case requestTapped(RedactableString, Bool)
        case updateCurrentFocus(State.AddressType)
    }
    
    @Dependency(\.pasteboard) var pasteboard

    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()
        
        Reduce { state, action in
            switch action {
            case .backToHomeTapped:
                return .none
                
            case .addressDetailsRequest:
                return .none

            case .copyToPastboard(let text):
                pasteboard.setString(text)
                state.$toast.withLock { $0 = .top(String(localizable: .generalCopiedToTheClipboard)) }
                return .none

            case .requestTapped:
                return .none
                
            case .updateCurrentFocus(let newFocus):
                state.currentFocus = newFocus
                return .none
                
            case .path:
                return .none
                
            case .infoTapped(let shielded):
                state.isAddressExplainerPresented.toggle()
                state.isExplainerForShielded = shielded
                return .none
            }
        }
        .forEach(\.path, action: \.path)
    }
}
