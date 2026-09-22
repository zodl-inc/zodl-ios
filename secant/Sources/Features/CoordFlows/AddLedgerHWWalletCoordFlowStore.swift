//
//  AddLedgerHWWalletCoordFlowStore.swift
//  Zashi
//
//  MOB-2020 Phase 1.3. Mirrors AddKeystoneHWWalletCoordFlowStore's shape: the instructions
//  screen is the flow's root (`addLedgerHWWalletState`, not a `Path` element), and the path
//  covers device selection, pairing, account confirmation, the birthday sub-flow (shared,
//  vendor-neutral screens), and the success screen.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@preconcurrency import MessageUI

@Reducer
struct AddLedgerHWWalletCoordFlow {
    @Reducer
    enum Path {
        case account(AddLedgerHWWallet)
        case connected(AddLedgerHWWallet)
        case devicePicker(AddLedgerHWWallet)
        case deviceReady(AddLedgerHWWallet)
        case estimateBirthdaysDate(WalletBirthday)
        case estimatedBirthday(WalletBirthday)
        case pairing(AddLedgerHWWallet)
        case restoreInfo(RestoreInfo)
        case walletBirthday(WalletBirthday)
    }

    @ObservableState
    struct State {
        var addLedgerHWWalletState = AddLedgerHWWallet.State.initial
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
        case addLedgerHWWallet(AddLedgerHWWallet.Action)
        case binding(BindingAction<AddLedgerHWWalletCoordFlow.State>)
        case cancelFailureTapped
        case closeHelpSheetTapped
        /// A pairing transport failure, deferred one cycle past the `.pairing` element's own
        /// `.pairingFailed` handling — see the coordinator's comment on this arm.
        case connectionLostWhilePairing
        case contactSupportTapped
        case path(StackActionOf<Path>)
        case sendSupportMailFinished
        case shareFinished
    }

    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()

        BindingReducer()

        Scope(state: \.addLedgerHWWalletState, action: \.addLedgerHWWallet) {
            AddLedgerHWWallet()
        }

        Reduce { state, action in
            switch action {
            case .closeHelpSheetTapped:
                state.isHelpSheetPresented = false
                return .none

            case .cancelFailureTapped:
                // Close the sheet and leave the whole add-Ledger flow. Root observes
                // `backToHomeTapped` and tears the flow down (path = nil), so the user is never
                // stranded on the connection screen.
                state.isFailureSheetPresented = false
                return .send(.addLedgerHWWallet(.backToHomeTapped))

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
