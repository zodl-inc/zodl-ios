//
//  DisconnectHWWalletStore.swift
//  Zodl
//
//  Created by Lukáš Korba on 2026-04-02
//

import ComposableArchitecture
import ZcashLightClientKit
import MessageUI

@Reducer
struct DisconnectHWWallet {
    @ObservableState
    struct State: Equatable {
        var isProcessing = false
        var isFailureSheetUp = false
        var isSheetUp = false
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []

        // support
        var canSendMail = false
        var errMsg = ""
        var messageToBeShared: String?
        var supportData: SupportData?

        init(isProcessing: Bool = false) {
            self.isProcessing = isProcessing
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<DisconnectHWWallet.State>)
        case contactSupport
        case disconnectConfirmed
        case disconnectFailed(String)
        case disconnectFinished
        case disconnectTapped
        case dismissSheet
        case onAppear
        case sendSupportMailFinished
        case shareFinished
        case tryAgain
    }

    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.canSendMail = MFMailComposeViewController.canSendMail()
                return .none

            case .binding:
                return .none

            case .disconnectTapped:
                state.isSheetUp = true
                state.isProcessing = true
                return .none

            case .disconnectConfirmed:
                state.isSheetUp = false
                var keystoneAccount: AccountUUID? = nil
                state.walletAccounts.forEach { account in
                    if account.vendor == .keystone {
                        keystoneAccount = account.id
                    }
                }
                guard let keystoneAccount else {
                    return .none
                }
                return .run { send in
                    do {
                        try await sdkSynchronizer.deleteAccount(keystoneAccount)
                        await send(.disconnectFinished)
                    } catch {
                        await send(.disconnectFailed(error.localizedDescription))
                    }
                }
                
            case .disconnectFailed(let errMsg):
                state.isProcessing = false
                state.isFailureSheetUp = true
                state.errMsg = errMsg
                return .none

            case .disconnectFinished:
                state.isProcessing = false
                return .none

            case .dismissSheet:
                state.isSheetUp = false
                state.isProcessing = false
                return .none
                
            case .tryAgain:
                state.isFailureSheetUp = false
                return .run { send in
                    try? await Task.sleep(for: .seconds(0.3))
                    await send(.disconnectConfirmed)
                }

            case .contactSupport:
                state.isFailureSheetUp = false
                let prefixMessage = "\(state.errMsg)\n\n"
                if state.canSendMail {
                    state.supportData = SupportDataGenerator.generate(prefixMessage)
                    return .none
                } else {
                    let sharePrefix =
                    """
                    ===
                    \(String(localizable: .sendFeedbackShareNotAppleMailInfo)) \(SupportDataGenerator.Constants.email)
                    ===
                    
                    \(prefixMessage)
                    """
                    let supportData = SupportDataGenerator.generate(sharePrefix)
                    state.messageToBeShared = supportData.message
                }
                return .none

            case .sendSupportMailFinished:
                state.supportData = nil
                return .none

            case .shareFinished:
                state.messageToBeShared = nil
                return .none
            }
        }
    }
}
