//
//  ReceiveStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 05.07.2022.
//

import Foundation
import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit
import Pasteboard
import Generated
import Utils
import UIComponents
import Models

// Path
import AddressDetails
import RequestZec
import ZecKeyboard

@Reducer
public struct Receive {
    @Reducer
    public enum Path {
        case addressDetails(AddressDetails)
        case requestZec(RequestZec)
        case requestZecSummary(RequestZec)
        case zecKeyboard(ZecKeyboard)
    }
    
    @ObservableState
    public struct State {
        public enum AddressType {
            case saplingAddress
            case tAddress
            case uaAddress
        }

        public var currentFocus = AddressType.uaAddress
        public var isAddressExplainerPresented = false
        public var isExplainerForShielded = false
        public var memo = ""
        public var path = StackState<Path.State>()
        @Shared(.inMemory(.selectedWalletAccount)) public var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.toast)) public var toast: Toast.Edge? = nil

        // Path
        public var requestZecState = RequestZec.State.initial
        
        public var unifiedAddress: String {
            selectedWalletAccount?.privateUnifiedAddress ?? L10n.Receive.Error.cantExtractUnifiedAddress
        }

        public var saplingAddress: String {
            selectedWalletAccount?.saplingAddress ?? L10n.Receive.Error.cantExtractSaplingAddress
        }

        public var transparentAddress: String {
            selectedWalletAccount?.transparentAddress ?? L10n.Receive.Error.cantExtractTransparentAddress
        }

        public init() { }
    }

    public enum Action {
        case addressDetailsRequest(RedactableString, Bool)
        case backToHomeTapped
        case copyToPastboard(RedactableString)
        case infoTapped(Bool)
        case path(StackActionOf<Path>)
        case requestTapped(RedactableString, Bool)
        case updateCurrentFocus(State.AddressType)
    }
    
    @Dependency(\.pasteboard) var pasteboard

    public init() { }

    public var body: some Reducer<State, Action> {
        coordinatorReduce()
        
        Reduce { state, action in
            switch action {
            case .backToHomeTapped:
                return .none
                
            case .addressDetailsRequest:
                return .none

            case .copyToPastboard(let text):
                pasteboard.setString(text)
                state.$toast.withLock { $0 = .top(L10n.General.copiedToTheClipboard) }
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
