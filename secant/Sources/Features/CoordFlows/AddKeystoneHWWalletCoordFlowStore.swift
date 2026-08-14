//
//  AddKeystoneHWWalletCoordFlowStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-19.
//

import SwiftUI
import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
#if canImport(MessageUI)
@preconcurrency import MessageUI
#endif

@Reducer
struct AddKeystoneHWWalletCoordFlow {
    @Reducer
    enum Path {
        case accountHWWalletSelection(AddKeystoneHWWallet)
        case estimateBirthdaysDate(WalletBirthday)
        case estimatedBirthday(WalletBirthday)
        case keystoneConnected(AddKeystoneHWWallet)
        case keystoneDeviceReady(AddKeystoneHWWallet)
        case restoreInfo(RestoreInfo)
        case scan(Scan)
        case walletBirthday(WalletBirthday)
    }
    
    @ObservableState
    struct State {
        var addKeystoneHWWalletState = AddKeystoneHWWallet.State.initial
        var birthday: BlockHeight? = nil
        var isFailureSheetPresented = false
        var isHelpSheetPresented = false
        var path = StackState<Path.State>()

        // support
        var canSendMail = false
        var errMsg = ""
        var messageToBeShared: String?
        var supportData: SupportData?

        init() { }
    }

    enum Action: BindableAction {
        case addKeystoneHWWallet(AddKeystoneHWWallet.Action)
        case binding(BindingAction<AddKeystoneHWWalletCoordFlow.State>)
        case cancelFailureTapped
        case closeHelpSheetTapped
        case contactSupportTapped
        case path(StackActionOf<Path>)
        case sendSupportMailFinished
        case shareFinished
    }

    @Dependency(\.audioServices) var audioServices
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    
    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()

        BindingReducer()

        Scope(state: \.addKeystoneHWWalletState, action: \.addKeystoneHWWallet) {
            AddKeystoneHWWallet()
        }
        
        Reduce { state, action in
            switch action {
            case .closeHelpSheetTapped:
                state.isHelpSheetPresented = false
                return .none

            case .cancelFailureTapped:
                // Close the sheet and leave the whole add-Keystone flow. Root
                // observes `backToHomeTapped` and tears the flow down (path = nil),
                // so the user is never stranded on the connection screen.
                state.isFailureSheetPresented = false
                return .send(.addKeystoneHWWallet(.backToHomeTapped))

            case .contactSupportTapped:
                state.isFailureSheetPresented = false
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

            default: return .none
            }
        }
        .forEach(\.path, action: \.path)
    }
}
