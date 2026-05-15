//
//  RequestZecStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-20-2024.
//

import Foundation
import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import ZcashPaymentURI

@Reducer
struct RequestZec {
    @ObservableState
    struct State: Equatable {
        var cancelId = UUID()

        var address: RedactableString = .empty
        var encryptedOutput: String?
        var encryptedOutputToBeShared: String?
        var isQRCodeEnlarged = false
        var maxPrivacy = false
        var memoState: MessageEditor.State = .initial
        var requestedZec: Zatoshi = .zero
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var storedEnlargedQR: CGImage?
        var storedQR: CGImage?

        init() {}
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<RequestZec.State>)
        case cancelRequestTapped
        case generateEnlargedQRCode
        case generateQRCode(Bool)
        case memo(MessageEditor.Action)
        case onAppear
        case onDisappear
        case qrCodeTapped
        case rememberEnlargedQR(CGImage?)
        case rememberQR(CGImage?)
        case requestTapped
        case shareFinished
        case shareQR
    }
    
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    
    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Scope(state: \.memoState, action: \.memo) {
            MessageEditor()
        }
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.memoState.charLimit = zcashSDKEnvironment.memoCharLimit
                state.encryptedOutput = nil
                return .send(.generateEnlargedQRCode)

            case .onDisappear:
                // __LD2 TESTing
                return .cancel(id: state.cancelId)

            case .binding:
                return .none
                
            case .cancelRequestTapped:
                return .none
                
            case .memo:
                return .none
            
            case .requestTapped:
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

            case .generateQRCode:
                if let recipient = RecipientAddress(value: state.address.data, context: ParserContext.from(networkType: zcashSDKEnvironment.network.networkType)) {
                    do {
                        // TODO: handle this error. there's a problem either with the recipient address or the amount requested
                        let payment = try Payment(
                            recipientAddress: recipient,
                            amount: try Amount(value: state.requestedZec.decimalValue.doubleValue),
                            memo: state.memoState.text.isEmpty ? nil : try MemoBytes(utf8String: state.memoState.text),
                            label: nil,
                            message: nil,
                            otherParams: nil
                        )
                        
                        let encryptedOutput = ZIP321.request(payment, formattingOptions: .useEmptyParamIndex(omitAddressLabel: true))
                        state.encryptedOutput = encryptedOutput
                        return .publisher {
                            QRCodeGenerator.generate(
                                from: encryptedOutput,
                                maxPrivacy: state.maxPrivacy,
                                vendor: .zashi,
                                color: Asset.Colors.primary.systemColor
                            )
                            .map(Action.rememberQR)
                        }
                        .cancellable(id: state.cancelId)
                    } catch {
                        return .none
                    }
                }
                return .none
                
            case .generateEnlargedQRCode:
                if let recipient = RecipientAddress(value: state.address.data, context: ParserContext.from(networkType: zcashSDKEnvironment.network.networkType)) {
                    do {
                        let payment = try Payment(
                            recipientAddress: recipient,
                            amount: try Amount(value: state.requestedZec.decimalValue.doubleValue),
                            memo: state.memoState.text.isEmpty ? nil : try MemoBytes(utf8String: state.memoState.text),
                            label: nil,
                            message: nil,
                            otherParams: nil
                        )
                        
                        let encryptedOutput = ZIP321.request(payment, formattingOptions: .useEmptyParamIndex(omitAddressLabel: true))
                        state.encryptedOutput = encryptedOutput
                        return .publisher {
                            QRCodeGenerator.generate(
                                from: encryptedOutput,
                                maxPrivacy: state.maxPrivacy,
                                vendor: .zashi,
                                color: .black
                            )
                            .map(Action.rememberEnlargedQR)
                        }
                        .cancellable(id: state.cancelId)
                    } catch {
                        return .none
                    }
                }
                return .none

            case .shareFinished:
                state.encryptedOutputToBeShared = nil
                return .none
                
            case .shareQR:
                state.encryptedOutputToBeShared = state.encryptedOutput
                return .none
            }
        }
    }
}
