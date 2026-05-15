//
//  AddKeystoneHWWalletCoordFlowCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-19.
//

import ComposableArchitecture

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
                
            case .path(.element(id: _, action: .restoreInfo(.gotItTapped))):
                for id in state.path.ids {
                    if case .keystoneDeviceReady = state.path[id: id] {
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
