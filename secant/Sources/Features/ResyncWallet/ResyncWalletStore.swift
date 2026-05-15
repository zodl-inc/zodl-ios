//
//  ResyncWalletStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 04-09-2025.
//

import Foundation
import ComposableArchitecture
import MessageUI
@preconcurrency import ZcashLightClientKit

@Reducer
struct ResyncWallet {
    @ObservableState
    struct State: Equatable {
        var isFailureSheetUp = false

        // support
        var birthday: BlockHeight? = nil
        var birthdayDate = ""
        var birthdayBlocks = ""
        var birthdayMonth = ""
        var birthdayYear = 0
        var canSendMail = false
        var errMsg = ""
        var messageToBeShared: String?
        var supportData: SupportData?

        init() { }
    }
    
    enum Action: BindableAction, Equatable {
        case binding(BindingAction<ResyncWallet.State>)
        case changeBirthdayTapped
        case contactSupport
        case onAppear
        case sendSupportMailFinished
        case shareFinished
        case startResyncTapped
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
                state.birthday = try? walletStorage.exportWallet().birthday?.value()
                if let birthday = state.birthday, let timeInterval = sdkSynchronizer.estimateTimestamp(birthday) {
                    let date = Date(timeIntervalSince1970: timeInterval)
                    let formatter = DateFormatter()
                    formatter.dateFormat = "LLLL yyyy"
                    formatter.locale = Locale.current
                    state.birthdayDate = formatter.string(from: date)
                    state.birthdayBlocks = Zatoshi(Int64(birthday) * 100_000_000).decimalString()
                    state.birthdayMonth = date.formatted(.dateTime.month(.wide))
                    state.birthdayYear = Calendar.current.component(.year, from: date)
                }
                return .none
                
            case .binding:
                return .none
            
            case .changeBirthdayTapped:
                return .none

            case .startResyncTapped:
                return .none
                
            case .tryAgain:
                state.isFailureSheetUp = false
                return .run { send in
                    try? await Task.sleep(for: .seconds(0.3))
                    await send(.startResyncTapped)
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
