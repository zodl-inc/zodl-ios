//
//  ConnectHWWalletCoordFlowStore.swift
//  Zashi
//
//  MOB-2020 UI round 2: merges AddKeystoneHWWalletCoordFlow and AddLedgerHWWalletCoordFlow into
//  one flow whose root is the vendor chooser (`ChooseHWWallet`) instead of jumping straight into
//  a single vendor's instructions. Both vendors' screens are now `Path` elements reached from
//  that root, so Back from either vendor's instructions screen pops to the chooser instead of
//  leaving no way to pick the other vendor. See ConnectHWWalletCoordFlowCoordinator.swift for the
//  merged navigation.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@preconcurrency import MessageUI

@Reducer
struct ConnectHWWalletCoordFlow {
    @Reducer
    enum Path {
        // Keystone
        case addKeystoneHWWallet(AddKeystoneHWWallet)
        case scan(Scan)
        case accountHWWalletSelection(AddKeystoneHWWallet)
        case keystoneDeviceReady(AddKeystoneHWWallet)
        case keystoneConnected(AddKeystoneHWWallet)
        // Ledger
        case addLedgerHWWallet(AddLedgerHWWallet)
        case ledgerDevicePicker(AddLedgerHWWallet)
        case ledgerAccount(AddLedgerHWWallet)
        case ledgerDeviceReady(AddLedgerHWWallet)
        case ledgerConnected(AddLedgerHWWallet)
        // Shared
        case estimateBirthdaysDate(WalletBirthday)
        case estimatedBirthday(WalletBirthday)
        case restoreInfo(RestoreInfo)
        case walletBirthday(WalletBirthday)
    }

    @ObservableState
    struct State {
        var chooseHWWalletState = ChooseHWWallet.State.initial
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
        case binding(BindingAction<ConnectHWWalletCoordFlow.State>)
        case cancelFailureTapped
        case chooseHWWallet(ChooseHWWallet.Action)
        case closeHelpSheetTapped
        case contactSupportTapped
        case path(StackActionOf<Path>)
        case sendSupportMailFinished
        case shareFinished
    }

    @Dependency(\.audioServices) var audioServices

    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()

        BindingReducer()

        Scope(state: \.chooseHWWalletState, action: \.chooseHWWallet) {
            ChooseHWWallet()
        }

        Reduce { state, action in
            switch action {
            case .closeHelpSheetTapped:
                state.isHelpSheetPresented = false
                return .none

            case .cancelFailureTapped:
                // Close the sheet and leave the whole connect flow. The vendor instructions
                // element (whichever one is on the path) disconnects its own transport as needed
                // (the Ledger one disconnects the Ledger in its own reducer; Keystone's is a
                // no-op) and Root observes `backToHomeTapped` and tears the flow down
                // (path = nil), so the user is never stranded on the connection screen.
                state.isFailureSheetPresented = false
                for id in state.path.ids {
                    switch state.path[id: id] {
                    case .addKeystoneHWWallet:
                        return .send(.path(.element(id: id, action: .addKeystoneHWWallet(.backToHomeTapped))))
                    case .addLedgerHWWallet:
                        return .send(.path(.element(id: id, action: .addLedgerHWWallet(.backToHomeTapped))))
                    default:
                        continue
                    }
                }
                return .none

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
