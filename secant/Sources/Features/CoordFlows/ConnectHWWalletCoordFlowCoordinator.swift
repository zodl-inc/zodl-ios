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
                state.path.append(.estimateBirthdaysDate(birthdayState))
                return .none

                // MARK: - Add Ledger HW Wallet (instructions, now a path element)

            case .path(.element(id: _, action: .addLedgerHWWallet(.connectTapped))):
                state.path.append(.ledgerDevicePicker(AddLedgerHWWallet.State.initial))
                return .none

                // MARK: - Ledger Device Picker

            case .path(.element(id: _, action: .ledgerDevicePicker(.pairingSucceeded(let pairing)))):
                for element in state.path {
                    if case .ledgerDevicePicker(var devicePickerState) = element {
                        devicePickerState.pairing = pairing
                        state.path.append(.ledgerAccount(devicePickerState))
                    }
                }
                return .none

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

                // MARK: - Estimate Birthday's Date (shared entry point)

            case .path(.element(id: _, action: .estimateBirthdaysDate(.enterManuallyTapped))):
                var birthdayState = WalletBirthday.State.initial
                birthdayState.isKeystoneFlow = true
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
}
