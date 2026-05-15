//
//  AddressDetailsStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-19-2024.
//

import Foundation
import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct AddressDetails {
    @ObservableState
    struct State: Equatable {
        var cancelId = UUID()
        
        var address: RedactableString
        var addressTitle: String
        var addressToShare: RedactableString?
        var isAddressExpanded = false
        var isQRCodeEnlarged = false
        var maxPrivacy = false
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var storedQR: CGImage?
        var storedEnlargedQR: CGImage?
        @Shared(.inMemory(.toast)) var toast: Toast.Edge? = nil

        init(
            address: RedactableString = .empty,
            addressTitle: String = "",
            maxPrivacy: Bool = false
        ) {
            self.address = address
            self.addressTitle = addressTitle
            self.maxPrivacy = maxPrivacy
        }
    }

    enum Action: BindableAction, Equatable {
        case addressTapped
        case binding(BindingAction<AddressDetails.State>)
        case copyToPastboard
        case generateEnlargedQRCode
        case generateQRCode(Bool)
        case onAppear
        case onDisappear
        case qrCodeTapped
        case rememberEnlargedQR(CGImage?)
        case rememberQR(CGImage?)
        case shareFinished
        case shareQR
    }
    
    @Dependency(\.pasteboard) var pasteboard

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.isAddressExpanded = false
                return .send(.generateEnlargedQRCode)

            case .onDisappear:
                // __LD2 TESTing
                return .cancel(id: state.cancelId)
                
            case .binding:
                return .none

            case .addressTapped:
                state.isAddressExpanded.toggle()
                return .none

            case .qrCodeTapped:
                state.isQRCodeEnlarged = true
                guard state.storedEnlargedQR != nil else {
                    return .send(.generateEnlargedQRCode)
                }
                return .none

            case let .rememberQR(image):
                state.storedQR = image
                return .none

            case let .rememberEnlargedQR(image):
                state.storedEnlargedQR = image
                return .none

            case .copyToPastboard:
                pasteboard.setString(state.address)
                state.$toast.withLock { $0 = .top(String(localizable: .generalCopiedToTheClipboard)) }
                return .none

            case .generateQRCode:
                return .publisher {
                    QRCodeGenerator.generate(
                        from: state.address.data,
                        maxPrivacy: state.maxPrivacy,
                        vendor: .zashi,
                        color: Asset.Colors.primary.systemColor
                    )
                    .map(Action.rememberQR)
                }
                .cancellable(id: state.cancelId)
                
            case .generateEnlargedQRCode:
                return .publisher {
                    QRCodeGenerator.generate(
                        from: state.address.data,
                        maxPrivacy: state.maxPrivacy,
                        vendor: .zashi,
                        color: .black
                    )
                    .map(Action.rememberEnlargedQR)
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
