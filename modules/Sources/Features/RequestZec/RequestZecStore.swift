//
//  RequestZecStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-20-2024.
//

import Foundation
import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit
import Pasteboard
import Generated
import Utils
import UIComponents
import ZcashSDKEnvironment
import ZcashPaymentURI
import Models
import URIParser

@Reducer
public struct RequestZec {
    @ObservableState
    public struct State: Equatable {
        public var cancelId = UUID()

        public var address: RedactableString = .empty
        public var encryptedOutput: String?
        public var encryptedOutputToBeShared: String?
        public var isQRCodeAppreanceFlipped = false
        public var maxPrivacy = false
        public var memoState: MessageEditor.State = .initial
        public var requestedZec: Zatoshi = .zero
        @Shared(.inMemory(.selectedWalletAccount)) public var selectedWalletAccount: WalletAccount? = nil
        public var storedQR: CGImage?

        public init() {}
    }

    public enum Action: Equatable {
        case cancelRequestTapped
        case generateQRCode(Bool)
        case memo(MessageEditor.Action)
        case onAppear
        case onDisappear
        case qrCodeTapped
        case rememberQR(CGImage?)
        case requestTapped
        case shareFinished
        case shareQR
    }
    
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    
    public init() { }

    public var body: some Reducer<State, Action> {
        Scope(state: \.memoState, action: \.memo) {
            MessageEditor()
        }
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.memoState.charLimit = zcashSDKEnvironment.memoCharLimit
                state.isQRCodeAppreanceFlipped = false
                state.encryptedOutput = nil
                return .none

            case .onDisappear:
                // __LD2 TESTing
                return .cancel(id: state.cancelId)

            case .cancelRequestTapped:
                return .none
                
            case .memo:
                return .none
            
            case .requestTapped:
                return .none

            case .qrCodeTapped:
                guard state.storedQR != nil else {
                    return .none
                }
                state.isQRCodeAppreanceFlipped.toggle()
                return .send(.generateQRCode(true))
                
            case let .rememberQR(image):
                state.storedQR = image
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
                                color: state.isQRCodeAppreanceFlipped
                                ? .black
                                : Asset.Colors.primary.systemColor
                            )
                            .map(Action.rememberQR)
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
