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
        case ledgerTurnOn(AddLedgerHWWallet)
        case ledgerDevicePicker(AddLedgerHWWallet)
        /// Step 3, "Open the Zcash App" (MOB-2020, Android aac01e65). Pushed by
        /// `.ledgerDevicePicker(.deviceBonded)`; `AddLedgerHWWallet.State.autoOpenZcashApp` says
        /// whether it opens the app on its own as soon as it appears.
        case ledgerOpenApp(AddLedgerHWWallet)
        case ledgerApproveOnDevice(AddLedgerHWWallet)
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
        /// `.ledgerApproveOnDevice(.pairingSucceeded(_))` arm, the pre-import check that fires as
        /// soon as pairing succeeds, or by its `.ledgerDeviceReady(.accountAlreadyImported(_))`
        /// arm, the import-time backstop for a collision the pre-import check missed. Deliberately
        /// left set once the sheet is dismissed via `goToExistingAccountTapped`, since Root reads
        /// it from here. MOB-2020 (Android b013b7c2, Rebound): that same arm also sets this,
        /// without ever presenting the sheet, when the matched account had no stored binding and
        /// this pairing's binding was just stored onto it instead -- see `ledgerPairingRebound`.
        var alreadyAddedAccount: WalletAccount? = nil
        var birthday: BlockHeight? = nil
        var isAccountAlreadyAddedSheetPresented = false
        var isFailureSheetPresented = false
        var isHelpSheetPresented = false
        /// MOB-2020 (Android d1506d0d): set when Root opened this flow from the sign sheet's Pair
        /// Ledger, to the account it should pair again -- `nil` while adding a new Ledger.
        /// `.ledgerApproveOnDevice(.pairingSucceeded)` checks the paired viewing key against this
        /// account instead of importing a new one when it is set. `.home(.connectHWWalletTapped)`
        /// always resets this whole state first, which leaves it `nil`; in memory only, like
        /// `AddLedgerHWWallet.State.selectedDevice` -- process death empties it too, and pairing
        /// without a target still refuses a second Ledger (see the no-target branch below).
        var ledgerRepairTarget: AccountUUID? = nil
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
        /// MOB-2020: the Turn On and Unlock step's Continue requested Bluetooth access (it wasn't
        /// determined yet) and the request has settled, whatever the answer -- see
        /// `coordinatorReduce()`'s `.ledgerTurnOn(.connectTapped)` arm.
        case ledgerBluetoothPermissionSettled
        /// MOB-2020 (Android b013b7c2, Rebound): the coordinator's `.ledgerApproveOnDevice(.pairingSucceeded)`
        /// arm found a matched account with a stored binding already, or this pairing's own binding
        /// failed to store onto an unbound match -- either way, present "Account Already Added" the
        /// way that arm always has.
        case ledgerPairingAlreadyAdded(WalletAccount)
        /// MOB-2020 (Android b013b7c2, Rebound): the matched account had no stored binding, and the
        /// coordinator's own effect just stored this pairing's binding onto it -- show Connected
        /// the way a fresh import's `.accountImportSucceeded` does, with no sheet ever shown.
        case ledgerPairingRebound(WalletAccount)
        case path(StackActionOf<Path>)
        case sendSupportMailFinished
        case shareFinished
    }

    @Dependency(\.audioServices) var audioServices
    @Dependency(\.bluetoothPermission) var bluetoothPermission
    @Dependency(\.walletStorage) var walletStorage

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

            case let .ledgerPairingAlreadyAdded(account):
                state.alreadyAddedAccount = account
                state.isAccountAlreadyAddedSheetPresented = true
                return .none

            case let .ledgerPairingRebound(account):
                // Unlike `goToExistingAccountTapped` above, this never leaves the flow -- it
                // shows Connected, the same as a fresh import's `.accountImportSucceeded` arm
                // (ConnectHWWalletCoordFlowCoordinator.swift), with Close doing the leaving once
                // the user taps it.
                state.alreadyAddedAccount = account
                // MOB-2020 (Android d1506d0d): a repair that reaches Rebound has paired its
                // target successfully -- clear it so a later, unrelated pairing never reads it as
                // a stale target. A no-op when this Rebound came from today's no-target path,
                // where it is already `nil`.
                state.ledgerRepairTarget = nil
                state.path.append(.ledgerConnected(AddLedgerHWWallet.State.initial))
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

                // MARK: - Ledger Approve on Device: pairingSucceeded / cancelTapped
                //
                // Both arms below have to live in the Reduce `.forEach(\.path, …)` wraps -- which
                // runs AFTER the element, per TCA's ordering -- rather than in
                // `coordinatorReduce()`, which runs BEFORE it: mutating the SAME id this same
                // action targets there (replacing the element's case, or removing it) would leave
                // `.forEach`'s own routing, which runs after, unable to find the
                // `.ledgerApproveOnDevice`-shaped destination its action still expects --
                // StackReducer reports that as "received an action for a missing element" (fails
                // a TestStore). See ConnectHWWalletCoordFlowCoordinator's own comment at this
                // Path case for the fuller explanation.

                // MOB-2020 (Android 7cd09f72/aa6d098a): moved from the old
                // `.ledgerDevicePicker(.pairingSucceeded)` arm now that the picker no longer
                // pairs. Figma (node 1073:13304) and Android raise "Account Already Added" as
                // soon as pairing succeeds, instead of making the user step through every
                // birthday screen first. The import-time arm
                // (`.ledgerDeviceReady(.accountAlreadyImported)`) stays as the backstop for a key
                // librustzcash matches at import but that this pre-import check missed.
            case let .path(.element(id: id, action: .ledgerApproveOnDevice(.pairingSucceeded(pairing)))):
                guard case .ledgerApproveOnDevice(var approveState) = state.path[id: id] else { return .none }
                let existingAccount = LedgerAccountCollision.existingAccount(
                    matching: pairing.ufvk,
                    among: approveState.walletAccounts
                )

                // MOB-2020 (Android d1506d0d, 6bef6fd2): the sign sheet's Pair Ledger set a
                // target account to pair again. A viewing key that matches anything else -- no
                // account, or a different one -- is the wrong Ledger here, reported directly
                // instead of imported; a key that matches the target is stored onto it whatever
                // binding it already had, since the one it had may be exactly why the user is
                // pairing again.
                if let target = state.ledgerRepairTarget {
                    guard let existingAccount, existingAccount.id == target else {
                        // Nothing imported or stored. The target stays set -- Retry
                        // (`AddLedgerHWWalletStore.issuePrimaryTapped`, `isApproveScreen == true`)
                        // pairs the same device again against the same target.
                        approveState.issue = .deviceMismatch
                        approveState.isIssueSheetPresented = true
                        approveState.pairing = nil
                        state.path[id: id] = .ledgerApproveOnDevice(approveState)
                        return .none
                    }
                    // Cleared here, before the store below even runs (mirroring Android's
                    // `PairLedgerDeviceUseCase.repair`) -- the target's only job was deciding
                    // whether this Ledger was the right one, which is settled the moment the id
                    // matches, whatever the store outcome turns out to be.
                    state.ledgerRepairTarget = nil
                    return .run { send in
                        // MOB-2020 (Android 6bef6fd2): stores the pairing's binding whatever
                        // binding the target already had -- the stored one may be unusable (the
                        // very reason `.notPaired` on the sign sheet offered Pair Ledger).
                        // `importLedgerBinding` refuses a duplicate, so the old binding (if any --
                        // a missing one is fine) is deleted first; it is read back first too, so a
                        // failed store below can restore it rather than leaving the account with
                        // no binding at all.
                        let oldBinding = try? walletStorage.exportLedgerBinding(target)
                        try? walletStorage.deleteLedgerBinding(target)
                        do {
                            try walletStorage.importLedgerBinding(pairing.binding, target)
                            await send(.ledgerPairingRebound(existingAccount))
                        } catch {
                            if let oldBinding {
                                do {
                                    try walletStorage.importLedgerBinding(oldBinding, target)
                                } catch {
                                    // Best-effort: never logs the binding/account data the error
                                    // could carry, and a failure here leaves the account no worse
                                    // off than it was before this attempt.
                                    LoggerProxy.warn(
                                        "Ledger: restoring the account's binding after a failed repair failed (\(type(of: error)))"
                                    )
                                }
                            }
                            // A failing store must not strand the user -- fall back to "Account
                            // Already Added", exactly as the no-target rebind below does.
                            LoggerProxy.warn("Ledger: storing a repair binding failed (\(type(of: error)))")
                            await send(.ledgerPairingAlreadyAdded(existingAccount))
                        }
                    }
                }

                if let existingAccount {
                    // MOB-2020: the Rebound path below is only for a LEDGER
                    // account that lost its binding -- not a non-Ledger account that merely
                    // shares this pairing's UFVK (a Zodl seed account, or a Keystone
                    // account, that shares the Ledger's recovery phrase). Such an account
                    // has no Ledger binding to lose, so `exportLedgerBinding` throws the
                    // identical `uninitializedLedgerBinding`, and rebinding it would hand a
                    // Ledger binding to an account nothing else expects to have one.
                    // Android filters to Ledger accounts first.
                    guard existingAccount.vendor == .ledger else {
                        return .send(.ledgerPairingAlreadyAdded(existingAccount))
                    }
                    // MOB-2020 (Android b013b7c2, Rebound): a match with no stored binding
                    // can never sign again -- store this pairing's binding onto it instead
                    // of reporting "Account Already Added" for an account that's a dead end.
                    // `importLedgerBinding` refuses a duplicate, so an existing binding that
                    // merely failed to decode (still `uninitializedLedgerBinding`, the same as a
                    // missing one) is deleted first -- a missing one is fine too. The keychain
                    // work (the check, the delete, and the write) runs in this effect, never the
                    // reducer body, mirroring `SendConfirmationStore.ledgerSignRequest`'s own
                    // export/catch shape.
                    return .run { send in
                        do {
                            _ = try walletStorage.exportLedgerBinding(existingAccount.id)
                            await send(.ledgerPairingAlreadyAdded(existingAccount))
                        } catch WalletStorage.WalletStorageError.uninitializedLedgerBinding {
                            do {
                                try? walletStorage.deleteLedgerBinding(existingAccount.id)
                                try walletStorage.importLedgerBinding(pairing.binding, existingAccount.id)
                                await send(.ledgerPairingRebound(existingAccount))
                            } catch {
                                // A failing store must not strand the user -- fall back to
                                // today's "Account Already Added", exactly as if it had a
                                // binding already. Logs only the error's type, never the
                                // binding or account data it could carry.
                                LoggerProxy.warn("Ledger: storing a rebind binding failed (\(type(of: error)))")
                                await send(.ledgerPairingAlreadyAdded(existingAccount))
                            }
                        } catch {
                            await send(.ledgerPairingAlreadyAdded(existingAccount))
                        }
                    }
                }

                // MOB-2020 (Android d1506d0d): with no target, the wallet still holds at most one
                // Ledger account -- an unknown key while one already exists is the wrong Ledger
                // too, not a second account to add. This is the same guard the target branch
                // above enforces, kept here for when process death emptied the target in between.
                if approveState.walletAccounts.contains(where: { $0.vendor == .ledger }) {
                    approveState.issue = .deviceMismatch
                    approveState.isIssueSheetPresented = true
                    approveState.pairing = nil
                    state.path[id: id] = .ledgerApproveOnDevice(approveState)
                    return .none
                }

                // MOB-2020: replaces the approve element in place (not a push), so backing out
                // of the account screen lands on the picker, as on Android, instead of revealing
                // a mid-pairing approve screen underneath it.
                approveState.pairing = pairing
                state.path[id: id] = .ledgerAccount(approveState)
                return .none

                // MOB-2020: pops the approve screen back to the picker, whose `onAppear` rescans.
                // The element's own reducer (AddLedgerHWWalletStore) does the cancel-and-disconnect.
            case .path(.element(id: _, action: .ledgerApproveOnDevice(.cancelTapped))):
                let _ = state.path.popLast()
                return .none

                // MOB-2020 (Android 76e345e5): pops step 3 back to the picker, the same way and
                // for the same reason as the approve screen's own arm just above -- this element's
                // reducer (AddLedgerHWWalletStore's `cancelTapped`) cancels the open-app request
                // and disconnects; this must stay in this trailing `Reduce`, not coordinatorReduce()
                // (which runs BEFORE `.forEach`), or `.forEach` cannot route into an element this
                // same dispatch already popped.
            case .path(.element(id: _, action: .ledgerOpenApp(.cancelTapped))):
                let _ = state.path.popLast()
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
