//
//  AddressDetailsStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-19-2024.
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

@Reducer
public struct AddressDetails {
    @ObservableState
    public struct State: Equatable {
        public var cancelId = UUID()
        
        public var address: RedactableString
        public var addressTitle: String
        public var addressToShare: RedactableString?
        public var isAddressExpanded = false
        public var isQRCodeAppreanceFlipped = false
        public var maxPrivacy = false
        @Shared(.inMemory(.selectedWalletAccount)) public var selectedWalletAccount: WalletAccount? = nil
        public var storedQR: CGImage?
        @Shared(.inMemory(.toast)) public var toast: Toast.Edge? = nil

        public init(
            address: RedactableString = .empty,
            addressTitle: String = "",
            maxPrivacy: Bool = false
        ) {
            self.address = address
            self.addressTitle = addressTitle
            self.maxPrivacy = maxPrivacy
        }
    }

    public enum Action: Equatable {
        case addressTapped
        case copyToPastboard
        case generateQRCode(Bool)
        case onAppear
        case onDisappear
        case qrCodeTapped
        case rememberQR(CGImage?)
        case shareFinished
        case shareQR
    }
    
    @Dependency(\.pasteboard) var pasteboard

    public init() { }

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .addressTapped:
                state.isAddressExpanded.toggle()
                return .none

            case .onAppear:
                // __LD TESTED
                state.isAddressExpanded = false
                state.isQRCodeAppreanceFlipped = false
                return .none

            case .onDisappear:
                // __LD2 TESTing
                return .cancel(id: state.cancelId)

            case .qrCodeTapped:
                guard state.storedQR != nil else {
                    return .none
                }
                state.isQRCodeAppreanceFlipped.toggle()
                return .send(.generateQRCode(true))

            case let .rememberQR(image):
                state.storedQR = image
                return .none

            case .copyToPastboard:
                pasteboard.setString(state.address)
                state.$toast.withLock { $0 = .top(L10n.General.copiedToTheClipboard) }
                return .none

            case .generateQRCode:
                return .publisher {
                    QRCodeGenerator.generate(
                        from: state.address.data,
                        maxPrivacy: state.maxPrivacy,
                        vendor: .zashi,
                        color: state.isQRCodeAppreanceFlipped
                        ? .black
                        : Asset.Colors.primary.systemColor
                    )
                    .map(Action.rememberQR)
                }
                .cancellable(id: state.cancelId)

            case .shareFinished:
                state.addressToShare = nil
                return .none
                
            case .shareQR:
                state.addressToShare = state.address
                return .none
            }
        }
    }
}
