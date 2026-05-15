//
//  SettingsCoordinator.swift
//  modules
//
//  Created by Lukáš Korba on 2025-03-17.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension Settings {
    func coordinatorReduce() -> Reduce<Settings.State, Settings.Action> {
        Reduce { state, action in
            switch action {
                // MARK: - Add Keystone HW Wallet

            case .path(.element(id: _, action: .addKeystoneHWWallet(.readyToScanTapped))):
                var scanState = Scan.State.initial
                scanState.checkers = [.keystoneScanChecker]
                scanState.instructions = String(localizable: .keystoneScanInfo)
                scanState.forceLibraryToHide = true
                state.path.append(.scan(scanState))
                return .none

            case .path(.element(id: _, action: .accountHWWalletSelection(.forgetThisDeviceTapped))):
                return .none

                // MARK: - Address Book

            case let .path(.element(id: _, action: .addressBook(.editId(_, id)))):
                var addressBookContactState = AddressBook.State.initial
                addressBookContactState.editId = id
                addressBookContactState.isNameFocused = true
                addressBookContactState.context = .settings
                state.path.append(.addressBookContact(addressBookContactState))
                return .none

            case .path(.element(id: _, action: .addressBook(.addManualButtonTapped))):
                var addressBookState = AddressBook.State.initial
                addressBookState.context = .settings
                state.path.append(.addressBookContact(addressBookState))
                return .none
                
            case .path(.element(id: _, action: .addressBook(.scanButtonTapped))):
                var scanState = Scan.State.initial
                scanState.checkers = [.zcashAddressScanChecker, .swapStringScanChecker]
                state.path.append(.scan(scanState))
                return .none

                // MARK: - Address Book Contact
                
            case .path(.element(id: _, action: .addressBookContact(.dismissAddContactRequired))):
                let _ = state.path.popLast()
                for element in state.path {
                    if element.is(\.scan) {
                        let _ = state.path.popLast()
                        return .none
                    }
                }
                return .none

            case .path(.element(id: _, action: .addressBookContact(.dismissDeleteContactRequired))):
                let _ = state.path.popLast()
                return .none
                
                // MARK: - Advanced Settings

            case .path(.element(id: _, action: .advancedSettings(.operationAccessGranted(let operation)))):
                switch operation {
                case .recoveryPhrase:
                    state.path.append(.recoveryPhrase(RecoveryPhraseDisplay.State.initial))
                case .exportPrivateData:
                    state.path.append(.exportPrivateData(PrivateDataConsent.State.initial))
                case .exportTaxFile:
                    state.path.append(.exportTransactionHistory(ExportTransactionHistory.State.initial))
                case .chooseServer:
                    state.path.append(.chooseServerSetup(ServerSetup.State.initial))
                case .disconnectHWWallet:
                    state.path.append(.disconnectHWWallet(DisconnectHWWallet.State.initial))
                case .torSetup:
                    var torSetupState = TorSetup.State.initial
                    torSetupState.isSettingsView = true
                    state.path.append(.torSetup(torSetupState))
                case .resyncWallet:
                    state.path.append(.resyncWallet(ResyncWallet.State.initial))
                case .resetZashi:
                    state.path.append(.resetZashi(DeleteWallet.State.initial))
                }
                return .none
                
                // MARK: - Resync Wallet

            case .path(.element(id: _, action: .resyncWallet(.changeBirthdayTapped))):
                var birthdayState = WalletBirthday.State.initial
                birthdayState.isResyncFlow = true
                for element in state.path {
                    if case .resyncWallet(let resyncWalletState) = element {
                        birthdayState.estimatedHeight = resyncWalletState.birthday ?? BlockHeight(0)
                        birthdayState.selectedYear = resyncWalletState.birthdayYear
                        birthdayState.selectedMonth = resyncWalletState.birthdayMonth
                    }
                }
                state.path.append(.resyncEstimateBirthdaysDate(birthdayState))
                return .none

            case .path(.element(id: _, action: .resyncEstimateBirthdaysDate(.enterManuallyTapped))):
                var birthdayState = WalletBirthday.State.initial
                birthdayState.isResyncFlow = true
                state.path.append(.resyncWalletBirthday(birthdayState))
                return .none

            case .path(.element(id: _, action: .resyncEstimateBirthdaysDate(.helpSheetRequested))),
                .path(.element(id: _, action: .resyncEstimatedBirthday(.helpSheetRequested))),
                .path(.element(id: _, action: .resyncWalletBirthday(.helpSheetRequested))):
                state.isResyncHelpSheetPresented.toggle()
                return .none

            case .path(.element(id: _, action: .resyncEstimateBirthdaysDate(.estimateHeightReady))):
                for element in state.path {
                    if case .resyncEstimateBirthdaysDate(let estimateBirthdaysDateState) = element {
                        state.path.append(.resyncEstimatedBirthday(estimateBirthdaysDateState))
                    }
                }
                return .none

            case .path(.element(id: _, action: .resyncEstimatedBirthday(.enterManuallyTapped))):
                var birthdayState = WalletBirthday.State.initial
                birthdayState.isResyncFlow = true
                state.path.append(.resyncWalletBirthday(birthdayState))
                return .none

            case .path(.element(id: _, action: .resyncEstimatedBirthday(.restoreTapped))):
                for element in state.path {
                    if case .resyncEstimatedBirthday(let estimatedBirthdayState) = element {
                        state.resyncBirthday = estimatedBirthdayState.estimatedHeight
                    }
                }
                var restoreInfoState = RestoreInfo.State.initial
                restoreInfoState.isResyncFlow = true
                state.path.append(.resyncRestoreInfo(restoreInfoState))
                return .none

            case .path(.element(id: _, action: .resyncWalletBirthday(.restoreTapped))):
                for element in state.path {
                    if case .resyncWalletBirthday(let walletBirthdayState) = element {
                        state.resyncBirthday = walletBirthdayState.estimatedHeight
                    }
                }
                var restoreInfoState = RestoreInfo.State.initial
                restoreInfoState.isResyncFlow = true
                state.path.append(.resyncRestoreInfo(restoreInfoState))
                return .none
                
            case .path(.element(id: _, action: .resyncWallet(.startResyncTapped))):
                for element in state.path {
                    if case .resyncWallet(let resyncWalletState) = element {
                        state.resyncBirthday = resyncWalletState.birthday
                    }
                }
                var restoreInfoState = RestoreInfo.State.initial
                restoreInfoState.isResyncFlow = true
                state.path.append(.resyncRestoreInfo(restoreInfoState))
                return .none

            case .path(.element(id: _, action: .resyncRestoreInfo(.gotItTapped))):
                return .send(.resyncFinished)

                // MARK: - Currency Conversion
            
            case .path(.element(id: _, action: .currencyConversionSetup(.backToHomeTapped))):
                let _ = state.path.popLast()
                return .none

            case .path(.element(id: _, action: .currencyConversionSetup(.delayedDismisalRequested))):
                let _ = state.path.popLast()
                return .none

                // MARK: - Scan
                
            case .path(.element(id: _, action: .scan(.foundAccounts(let account)))):
                for element in state.path {
                    if element.is(\.addKeystoneHWWallet) {
                        var addKeystoneHWWalletState = AddKeystoneHWWallet.State.initial
                        addKeystoneHWWalletState.zcashAccounts = account
                        state.path.append(.accountHWWalletSelection(addKeystoneHWWalletState))
                        audioServices.systemSoundVibrate()
                        break
                    }
                }
                return .none
                
            case .path(.element(id: _, action: .scan(.foundAddress(let address)))):
                for element in state.path {
                    if element.is(\.addressBook) {
                        var addressBookState = AddressBook.State.initial
                        addressBookState.address = address.data
                        addressBookState.isValidZcashAddress = true
                        addressBookState.isNameFocused = true
                        addressBookState.context = .settings
                        state.path.append(.addressBookContact(addressBookState))
                        audioServices.systemSoundVibrate()
                        return .none
                    }
                }
                return .none

            case .path(.element(id: _, action: .scan(.foundString(let address)))):
                for element in state.path {
                    if element.is(\.addressBook) {
                        var addressBookState = AddressBook.State.initial
                        addressBookState.address = address
                        addressBookState.isNameFocused = true
                        addressBookState.context = .settings
                        state.path.append(.addressBookContact(addressBookState))
                        audioServices.systemSoundVibrate()
                        return .none
                    }
                }
                return .none

            case .path(.element(id: _, action: .scan(.cancelTapped))):
                let _ = state.path.popLast()
                return .none
                
                // MARK: - Settings

            case .addressBookTapped:
                var addressBookState = AddressBook.State.initial
                addressBookState.context = .settings
                state.path.append(.addressBook(addressBookState))
                return .none

            case .advancedSettingsTapped:
                state.path.append(.advancedSettings(AdvancedSettings.State.initial))
                return .none

            case .coinholderPollingTapped:
                guard let account = state.selectedWalletAccount else { return .none }
                var votingState = Voting.State()
                votingState.isKeystoneUser = state.isKeystoneAccount
                votingState.walletId = account.id.id.map { String(format: "%02x", $0) }.joined()
                if votingState.hasSeenHowToVoteForCurrentWallet {
                    votingState.screenStack = [.loading]
                }
                state.path.append(.voting(votingState))
                return .none

            case .path(.element(id: _, action: .voting(.dismissFlow))):
                let _ = state.path.popLast()
                return .none

            case .whatsNewTapped:
                state.path.append(.whatsNew(WhatsNew.State.initial))
                return .none

            case .aboutTapped:
                state.path.append(.about(About.State.initial))
                return .none

            case .sendUsFeedbackTapped:
                state.path.append(.sendUsFeedback(SendFeedback.State.initial))
                return .none
                
                // MARK: - Self
                
            case .currencyConversionTapped:
                var currencyConversionSetupState = CurrencyConversionSetup.State.initial
                currencyConversionSetupState.isSettingsView = true
                state.path.append(.currencyConversionSetup(currencyConversionSetupState))
                return .none

                
                // MARK: - Tor Setup

            case .path(.element(id: _, action: .torSetup(.backToHomeTapped))):
                let _ = state.path.popLast()
                return .none

            default: return .none
            }
        }
    }
}
