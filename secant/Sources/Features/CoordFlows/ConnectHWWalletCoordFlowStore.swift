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
        /// The account a Ledger's viewing key already matched, set right before
        /// `isAccountAlreadyAddedSheetPresented` -- by the coordinator's own
        /// `.ledgerDevicePicker(.pairingSucceeded(_))` arm, the pre-import check that fires as
        /// soon as pairing succeeds, or by its `.ledgerDeviceReady(.accountAlreadyImported(_))`
        /// arm, the import-time backstop for a collision the pre-import check missed. Deliberately
        /// left set once the sheet is dismissed via `goToExistingAccountTapped`, since Root reads
        /// it from here.
        var alreadyAddedAccount: WalletAccount? = nil
        var birthday: BlockHeight? = nil
        var isAccountAlreadyAddedSheetPresented = false
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
        case accountAlreadyAddedCancelTapped
        case binding(BindingAction<ConnectHWWalletCoordFlow.State>)
        case cancelFailureTapped
        case chooseHWWallet(ChooseHWWallet.Action)
        case closeHelpSheetTapped
        case contactSupportTapped
        case goToExistingAccountTapped
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
                // Close the sheet and leave the whole connect flow -- see
                // leaveFlowThroughVendorInstructions.
                state.isFailureSheetPresented = false
                return leaveFlowThroughVendorInstructions(state: state)

            case .accountAlreadyAddedCancelTapped:
                state.isAccountAlreadyAddedSheetPresented = false
                return leaveFlowThroughVendorInstructions(state: state)

            case .goToExistingAccountTapped:
                // `alreadyAddedAccount` is deliberately left set here (unlike the two cancels) --
                // Root reads it off `connectHWWalletCoordFlowState` once the flow closes, to know
                // which account to switch to (RootCoordinator.swift).
                state.isAccountAlreadyAddedSheetPresented = false
                return leaveFlowThroughVendorInstructions(state: state)

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

    /// Leaves the connect flow the same way `cancelFailureTapped` always has: finds whichever
    /// vendor's instructions element is on the path and sends it `.backToHomeTapped`. That
    /// disconnects its own transport (the Ledger element disconnects the Ledger in its own
    /// reducer; Keystone's is a no-op) and Root observes the action and tears the flow down
    /// (`path = nil`), so the user is never stranded on the connection screen. Shared by
    /// `cancelFailureTapped`, `accountAlreadyAddedCancelTapped` and `goToExistingAccountTapped`.
    private func leaveFlowThroughVendorInstructions(state: State) -> Effect<Action> {
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
    }
}
