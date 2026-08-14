//
//  AddKeystoneHWWalletCoordFlowCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-19.
//

import ComposableArchitecture
#if canImport(MessageUI)
@preconcurrency import MessageUI
#endif

extension AddKeystoneHWWalletCoordFlow {
    func coordinatorReduce() -> Reduce<AddKeystoneHWWalletCoordFlow.State, AddKeystoneHWWalletCoordFlow.Action> {
        Reduce { state, action in
            switch action {
                
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
                // Cross-platform: MessageUI's composer is iOS-only (see `MailSupport`).
                state.canSendMail = MailSupport.canSendMail()
                state.isFailureSheetPresented = true
                return .none

            case .path(.element(id: _, action: .keystoneDeviceReady(.setBirthdayTapped))):
                var birthdayState = WalletBirthday.State.initial
                birthdayState.isKeystoneFlow = true
                state.path.append(.estimateBirthdaysDate(birthdayState))
                return .none

                // MARK: - Estimate Birthday's Date (Keystone entry point)

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
                    if case .keystoneDeviceReady = state.path[id: id] {
                        // [B4-4 class] OK triggers the import running BEHIND this screen
                        // (engine stop → drain → anchor fetch → import → restart —
                        // seconds). Reflect it on the visible OK button (spinner +
                        // disabled); without this the wait reads as a broken screen.
                        state.path[id: restoreInfoId, case: \.restoreInfo]?.isProcessing = true
                        return .send(.path(.element(id: id, action: .keystoneDeviceReady(.unlockTapped(state.birthday)))))
                    }
                }
                return .none

                // MARK: - Self

            case .addKeystoneHWWallet(.readyToScanTapped):
                var scanState = Scan.State.initial
                scanState.checkers = [.keystoneScanChecker]
                scanState.instructions = String(localizable: .keystoneScanInfo)
                scanState.forceLibraryToHide = true
                state.path.append(.scan(scanState))
                return .none

            default: return .none
            }
        }
    }
}
