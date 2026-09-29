//
//  ConnectHWWalletCoordFlowCoordinator.swift
//  Zashi
//
//  MOB-2020 UI round 2: merges AddKeystoneHWWalletCoordFlowCoordinator and
//  AddLedgerHWWalletCoordFlowCoordinator's navigation into one flat `Path`, rooted at the vendor
//  chooser instead of at either vendor's own instructions screen. Vendor-specific arms keep their
//  old bodies unchanged (only the case names are renamed for Ledger, to fit the merged `Path`);
//  the shared birthday/help arms -- identical in both old coordinators -- appear once.
//

import ComposableArchitecture
@preconcurrency import MessageUI

extension ConnectHWWalletCoordFlow {
    func coordinatorReduce() -> Reduce<ConnectHWWalletCoordFlow.State, ConnectHWWalletCoordFlow.Action> {
        Reduce { state, action in
            switch action {

                // MARK: - Choose HW Wallet (flow root)

            case .chooseHWWallet(.keystoneTapped):
                state.path.append(.addKeystoneHWWallet(AddKeystoneHWWallet.State.initial))
                return .none

            case .chooseHWWallet(.ledgerTapped):
                state.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
                return .none

            case .chooseHWWallet(.closeTapped):
                // Root observes this and tears the whole flow down (path = nil).
                return .none

                // MARK: - Add Keystone HW Wallet (instructions, now a path element)

            case .path(.element(id: _, action: .addKeystoneHWWallet(.readyToScanTapped))):
                var scanState = Scan.State.initial
                scanState.checkers = [.keystoneScanChecker]
                scanState.instructions = String(localizable: .keystoneScanInfo)
                scanState.forceLibraryToHide = true
                state.path.append(.scan(scanState))
                return .none

                // MARK: - Scan

            case .path(.element(id: _, action: .scan(.foundAccounts(let account)))):
                var addKeystoneHWWalletState = AddKeystoneHWWallet.State.initial
                addKeystoneHWWalletState.zcashAccounts = account
                state.path.append(.accountHWWalletSelection(addKeystoneHWWalletState))
                audioServices.systemSoundVibrate()
                return .none

            case .path(.element(id: _, action: .scan(.cancelTapped))):
                let _ = state.path.popLast()
                return .none

                // MARK: - Account HW Wallet Selection

            case .path(.element(id: _, action: .accountHWWalletSelection(.nextTapped))):
                for element in state.path {
                    if case .accountHWWalletSelection(let selectionState) = element {
                        state.path.append(.keystoneDeviceReady(selectionState))
                    }
                }
                return .none

                // MARK: - Keystone Device Ready

            case .path(.element(id: _, action: .keystoneDeviceReady(.accountImportSucceeded))):
                state.path.append(.keystoneConnected(AddKeystoneHWWallet.State.initial))
                return .none

            case .path(.element(id: _, action: .keystoneDeviceReady(.accountImportFailed(let errMsg)))):
                for id in state.path.ids {
                    if case .restoreInfo = state.path[id: id] {
                        state.path[id: id, case: \.restoreInfo]?.isProcessing = false
                    }
                }
                // A failure arriving after the success screen is on the stack can
                // only be a stray duplicate attempt — the account is imported, so
                // don't cover the success screen with the failure sheet.
                for element in state.path {
                    if case .keystoneConnected = element {
                        LoggerProxy.warn("Keystone account import failure suppressed (success screen already on stack): \(errMsg)")
                        return .none
                    }
                }
                state.errMsg = errMsg
                // TCA Store is @MainActor; reducer body always runs on main.
                state.canSendMail = MainActor.assumeIsolated { MFMailComposeViewController.canSendMail() }
                state.isFailureSheetPresented = true
                return .none

            case .path(.element(id: _, action: .keystoneDeviceReady(.setBirthdayTapped))):
                var birthdayState = WalletBirthday.State.initial
                birthdayState.isKeystoneFlow = true
                birthdayState.hardwareWalletVendor = hardwareWalletVendor(on: state.path)
                state.path.append(.estimateBirthdaysDate(birthdayState))
                return .none

                // MARK: - Add Ledger HW Wallet (instructions, now a path element)

            case .path(.element(id: _, action: .addLedgerHWWallet(.connectTapped))):
                state.path.append(.ledgerTurnOn(AddLedgerHWWallet.State.initial))
                return .none

                // MARK: - Ledger Turn On (step 1, Figma 1599:11369/1599:11430)

                // MOB-2020: Continue pushes the device picker, same as the intro's Get Started
                // used to -- but first, when Bluetooth authorization has never been asked, requests
                // it (which shows the iOS prompt) and waits for it to settle. `requestAuthorization`
                // never reports the answer: a denial still pushes the picker, whose own scan
                // reports "Bluetooth Access Required" (LedgerIssue.bluetoothUnauthorized).
            case .path(.element(id: _, action: .ledgerTurnOn(.connectTapped))):
                guard bluetoothPermission.authorizationStatus() == .notDetermined else {
                    state.path.append(.ledgerDevicePicker(AddLedgerHWWallet.State.initial))
                    return .none
                }
                return .run { send in
                    await bluetoothPermission.requestAuthorization()
                    await send(.ledgerBluetoothPermissionSettled)
                }

            case .ledgerBluetoothPermissionSettled:
                // A no-op if the user already backed out of the Turn On step while the request
                // was in flight -- only push the picker while it's still the element on top.
                guard case .ledgerTurnOn = state.path.last else { return .none }
                state.path.append(.ledgerDevicePicker(AddLedgerHWWallet.State.initial))
                return .none

                // MARK: - Ledger Device Picker

                // MOB-2020 (Android aac01e65): the picker's own Connect (`.approveOnDeviceTapped`)
                // bonds right there now (AddLedgerHWWalletStore), never pushing anything until
                // the bond settles -- this arm only reacts to its outcome. Both branches copy the
                // picker's state (keeping `selectedDevice`), the same way `.ledgerAccount(…)`
                // below carries a picker/approve state forward on success.
            case let .path(.element(id: _, action: .ledgerDevicePicker(.deviceBonded(isZcashAppRunning)))):
                for element in state.path {
                    guard case .ledgerDevicePicker(let devicePickerState) = element else { continue }
                    if isZcashAppRunning {
                        // Android efe21904: the device already runs the Zcash app -- step 3 goes
                        // on the stack idle (never opening anything on its own), under step 4,
                        // which starts pairing at once, same as a fresh push always has. Back
                        // from step 4 then lands on that idle step 3.
                        var openAppState = devicePickerState
                        openAppState.isConnecting = false
                        openAppState.isOpenAppScreen = true
                        openAppState.autoOpenZcashApp = false
                        state.path.append(.ledgerOpenApp(openAppState))

                        var approveState = devicePickerState
                        approveState.isConnecting = false
                        approveState.isApproveScreen = true
                        state.path.append(.ledgerApproveOnDevice(approveState))

                        // Starts the pairing at once, on the JUST-pushed element -- never
                        // `.ledgerDevicePicker(.connectDeviceTapped)`, which would connect right
                        // on the picker (LedgerDevicePickerView's own Connect button sends
                        // `.approveOnDeviceTapped`, not `connectDeviceTapped`, for exactly this
                        // reason).
                        if let last = state.path.ids.last {
                            return .send(.path(.element(id: last, action: .ledgerApproveOnDevice(.connectDeviceTapped))))
                        }
                    } else {
                        // The app is elsewhere -- step 3 opens it automatically as soon as it
                        // appears.
                        var openAppState = devicePickerState
                        openAppState.isConnecting = false
                        openAppState.isOpenAppScreen = true
                        openAppState.autoOpenZcashApp = true
                        state.path.append(.ledgerOpenApp(openAppState))
                    }
                }
                return .none

                // MARK: - Ledger Open the Zcash App (step 3, MOB-2020)

                // Android 8cf16518/efe21904: the request succeeded -- pushes step 4, a copy of
                // this state, which starts pairing at once (see the `.deviceBonded` arm above for
                // why never `.ledgerOpenApp(.connectDeviceTapped)` directly).
            case .path(.element(id: _, action: .ledgerOpenApp(.zcashAppOpened))):
                for element in state.path {
                    if case .ledgerOpenApp(let openAppState) = element {
                        var approveState = openAppState
                        approveState.isOpeningApp = false
                        approveState.isOpenAppScreen = false
                        approveState.isApproveScreen = true
                        state.path.append(.ledgerApproveOnDevice(approveState))
                    }
                }
                if let last = state.path.ids.last {
                    return .send(.path(.element(id: last, action: .ledgerApproveOnDevice(.connectDeviceTapped))))
                }
                return .none

                // `.ledgerOpenApp(.cancelTapped)`'s own pop lives in ConnectHWWalletCoordFlowStore's
                // trailing `Reduce`, not here -- see that arm's comment (and this file's own
                // comment on `.ledgerApproveOnDevice(.cancelTapped)`) for why: `coordinatorReduce()`
                // runs BEFORE `.forEach`, so popping the element here would leave `.forEach` unable
                // to route this same action into the element's own reducer (AddLedgerHWWalletStore's
                // `cancelTapped`, which cancels the request and disconnects) -- "received an action
                // for a missing element".

                // MARK: - Ledger Approve on Device
                //
                // `.pairingSucceeded`'s own handling lives in ConnectHWWalletCoordFlowStore's
                // trailing `Reduce`, not here -- see that arm's comment for why: it replaces the
                // approve element's own case (`.ledgerApproveOnDevice` -> `.ledgerAccount`) at
                // the SAME id this same action targets, which `.forEach(\.path, …)` must still be
                // able to route into when it runs its own reducer for this dispatch. Doing that
                // replace in `coordinatorReduce()`, which (like this whole function) runs BEFORE
                // `.forEach`, leaves `.forEach` routing into a slot that no longer matches the
                // case its action expects -- the same "received an action for a missing element"
                // failure the `.cancelTapped` arm avoids, just via a changed case instead of a
                // removed one.

                // MARK: - Ledger Account

            case .path(.element(id: _, action: .ledgerAccount(.nextTapped))):
                for element in state.path {
                    if case .ledgerAccount(let accountState) = element {
                        state.path.append(.ledgerDeviceReady(accountState))
                    }
                }
                return .none

                // MARK: - Ledger Device Ready

            case .path(.element(id: _, action: .ledgerDeviceReady(.setBirthdayTapped))):
                var birthdayState = WalletBirthday.State.initial
                birthdayState.isKeystoneFlow = true
                birthdayState.hardwareWalletVendor = hardwareWalletVendor(on: state.path)
                state.path.append(.estimateBirthdaysDate(birthdayState))
                return .none

            case .path(.element(id: _, action: .ledgerDeviceReady(.accountImportSucceeded))):
                state.path.append(.ledgerConnected(AddLedgerHWWallet.State.initial))
                return .none

            case .path(.element(id: _, action: .ledgerDeviceReady(.accountImportFailed(let errMsg)))):
                for id in state.path.ids {
                    if case .restoreInfo = state.path[id: id] {
                        state.path[id: id, case: \.restoreInfo]?.isProcessing = false
                    }
                }
                // A failure arriving after the success screen is on the stack can only be a
                // stray duplicate attempt — the account is imported, so don't cover the success
                // screen with the failure sheet.
                for element in state.path {
                    if case .ledgerConnected = element {
                        LoggerProxy.warn("Ledger account import failure suppressed (success screen already on stack): \(errMsg)")
                        return .none
                    }
                }
                state.errMsg = errMsg
                // TCA Store is @MainActor; reducer body always runs on main.
                state.canSendMail = MainActor.assumeIsolated { MFMailComposeViewController.canSendMail() }
                state.isFailureSheetPresented = true
                return .none

            case .path(.element(id: _, action: .ledgerDeviceReady(.accountAlreadyImported(let account)))):
                for id in state.path.ids {
                    if case .restoreInfo = state.path[id: id] {
                        state.path[id: id, case: \.restoreInfo]?.isProcessing = false
                    }
                }
                state.alreadyAddedAccount = account
                state.isAccountAlreadyAddedSheetPresented = true
                return .none

                // MARK: - Estimate Birthday's Date (shared entry point)

            case .path(.element(id: _, action: .estimateBirthdaysDate(.enterManuallyTapped))):
                var birthdayState = WalletBirthday.State.initial
                birthdayState.isKeystoneFlow = true
                birthdayState.hardwareWalletVendor = hardwareWalletVendor(on: state.path)
                state.path.append(.walletBirthday(birthdayState))
                return .none

            case .path(.element(id: _, action: .estimateBirthdaysDate(.helpSheetRequested))),
                .path(.element(id: _, action: .estimatedBirthday(.helpSheetRequested))),
                .path(.element(id: _, action: .walletBirthday(.helpSheetRequested))):
                state.isHelpSheetPresented.toggle()
                return .none

            case .path(.element(id: _, action: .estimateBirthdaysDate(.estimateHeightReady))):
                for element in state.path {
                    if case .estimateBirthdaysDate(let estimateBirthdaysDateState) = element {
                        state.path.append(.estimatedBirthday(estimateBirthdaysDateState))
                    }
                }
                return .none

                // MARK: - Estimated Birthday (shared)

            case .path(.element(id: _, action: .estimatedBirthday(.enterManuallyTapped))):
                var birthdayState = WalletBirthday.State.initial
                birthdayState.isKeystoneFlow = true
                birthdayState.hardwareWalletVendor = hardwareWalletVendor(on: state.path)
                state.path.append(.walletBirthday(birthdayState))
                return .none

            case .path(.element(id: _, action: .estimatedBirthday(.restoreTapped))):
                for element in state.path {
                    if case .estimatedBirthday(let estimatedBirthdayState) = element {
                        state.birthday = estimatedBirthdayState.estimatedHeight
                    }
                }
                var restoreInfoState = RestoreInfo.State.initial
                restoreInfoState.isKeystoneFlow = true
                restoreInfoState.hardwareWalletVendor = hardwareWalletVendor(on: state.path)
                state.path.append(.restoreInfo(restoreInfoState))
                return .none

                // MARK: - Wallet Birthday, manual entry follow-up (shared)

            case .path(.element(id: _, action: .walletBirthday(.restoreTapped))):
                for element in state.path {
                    if case .walletBirthday(let walletBirthdayState) = element {
                        state.birthday = walletBirthdayState.estimatedHeight
                    }
                }
                var restoreInfoState = RestoreInfo.State.initial
                restoreInfoState.isKeystoneFlow = true
                restoreInfoState.hardwareWalletVendor = hardwareWalletVendor(on: state.path)
                state.path.append(.restoreInfo(restoreInfoState))
                return .none

                // MARK: - RestoreInfo (shared)

            case .path(.element(id: let restoreInfoId, action: .restoreInfo(.gotItTapped))):
                // Targets the LAST `.keystoneDeviceReady` or `.ledgerDeviceReady` element on the
                // path -- in practice at most one vendor's chain is ever on the path at a time
                // (popping back to the chooser prunes everything above it), but the search always
                // takes the last match rather than assuming that.
                var deviceReadyId: StackElementID?
                for id in state.path.ids {
                    switch state.path[id: id] {
                    case .keystoneDeviceReady, .ledgerDeviceReady:
                        deviceReadyId = id
                    default:
                        break
                    }
                }
                guard let deviceReadyId else { return .none }
                state.path[id: restoreInfoId, case: \.restoreInfo]?.isProcessing = true
                if case .keystoneDeviceReady = state.path[id: deviceReadyId] {
                    return .send(.path(.element(id: deviceReadyId, action: .keystoneDeviceReady(.unlockTapped(state.birthday)))))
                } else {
                    return .send(.path(.element(id: deviceReadyId, action: .ledgerDeviceReady(.unlockTapped(state.birthday)))))
                }

            default: return .none
            }
        }
    }

    /// `.ledger` when a Ledger element (`.addLedgerHWWallet`, `.ledgerTurnOn`,
    /// `.ledgerDevicePicker`, `.ledgerOpenApp`, `.ledgerApproveOnDevice`, `.ledgerAccount`,
    /// `.ledgerDeviceReady` or `.ledgerConnected`) is anywhere on `path`, else `.keystone` -- the
    /// same "is a Ledger element on the path" rule as `ConnectHWWalletCoordFlowView.isLedgerFailure`.
    /// Used to stamp `hardwareWalletVendor` on every `WalletBirthday.State`/`RestoreInfo.State` this
    /// coordinator pushes.
    private func hardwareWalletVendor(on path: StackState<ConnectHWWalletCoordFlow.Path.State>) -> WalletAccount.Vendor {
        for element in path {
            switch element {
            case .addLedgerHWWallet, .ledgerTurnOn, .ledgerDevicePicker, .ledgerOpenApp, .ledgerApproveOnDevice, .ledgerAccount, .ledgerDeviceReady, .ledgerConnected:
                return .ledger
            default:
                continue
            }
        }
        return .keystone
    }
}
