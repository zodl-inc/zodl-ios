//
//  AddLedgerHWWalletCoordFlowCoordinator.swift
//  Zashi
//
//  MOB-2020 Phase 1.3. Mirrors AddKeystoneHWWalletCoordFlowCoordinator's navigation shape.
//

import ComposableArchitecture
@preconcurrency import MessageUI

extension AddLedgerHWWalletCoordFlow {
    func coordinatorReduce() -> Reduce<AddLedgerHWWalletCoordFlow.State, AddLedgerHWWalletCoordFlow.Action> {
        Reduce { state, action in
            switch action {

                // MARK: - Self

            case .addLedgerHWWallet(.connectTapped):
                state.path.append(.devicePicker(AddLedgerHWWallet.State.initial))
                return .none

                // MARK: - Device Picker

            case .path(.element(id: _, action: .devicePicker(.pairingSucceeded(let pairing)))):
                for element in state.path {
                    if case .devicePicker(var devicePickerState) = element {
                        devicePickerState.pairing = pairing
                        state.path.append(.account(devicePickerState))
                    }
                }
                return .none

                // MARK: - Account

            case .path(.element(id: _, action: .account(.nextTapped))):
                for element in state.path {
                    if case .account(let accountState) = element {
                        state.path.append(.deviceReady(accountState))
                    }
                }
                return .none

                // MARK: - Device Ready

            case .path(.element(id: _, action: .deviceReady(.setBirthdayTapped))):
                var birthdayState = WalletBirthday.State.initial
                birthdayState.isKeystoneFlow = true
                state.path.append(.estimateBirthdaysDate(birthdayState))
                return .none

            case .path(.element(id: _, action: .deviceReady(.accountImportSucceeded))):
                state.path.append(.connected(AddLedgerHWWallet.State.initial))
                return .none

            case .path(.element(id: _, action: .deviceReady(.accountImportFailed(let errMsg)))):
                for id in state.path.ids {
                    if case .restoreInfo = state.path[id: id] {
                        state.path[id: id, case: \.restoreInfo]?.isProcessing = false
                    }
                }
                // A failure arriving after the success screen is on the stack can only be a
                // stray duplicate attempt — the account is imported, so don't cover the success
                // screen with the failure sheet.
                for element in state.path {
                    if case .connected = element {
                        LoggerProxy.warn("Ledger account import failure suppressed (success screen already on stack): \(errMsg)")
                        return .none
                    }
                }
                state.errMsg = errMsg
                // TCA Store is @MainActor; reducer body always runs on main.
                state.canSendMail = MainActor.assumeIsolated { MFMailComposeViewController.canSendMail() }
                state.isFailureSheetPresented = true
                return .none

                // MARK: - Estimate Birthday's Date (Ledger entry point)

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

                // MARK: - Estimated Birthday

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

                // MARK: - Wallet Birthday (manual entry follow-up)

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

                // MARK: - RestoreInfo

            case .path(.element(id: let restoreInfoId, action: .restoreInfo(.gotItTapped))):
                for id in state.path.ids {
                    if case .deviceReady = state.path[id: id] {
                        state.path[id: restoreInfoId, case: \.restoreInfo]?.isProcessing = true
                        return .send(.path(.element(id: id, action: .deviceReady(.unlockTapped(state.birthday)))))
                    }
                }
                return .none

            default: return .none
            }
        }
    }
}
