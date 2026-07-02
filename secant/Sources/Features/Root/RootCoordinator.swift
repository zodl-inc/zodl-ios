//
//  RootCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 07.03.2025.
//

import Combine
import Dispatch
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension Root {
    func coordinatorReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
                
                // MARK: - Returns to Home

            case .settings(.backToHomeTapped),
                .receive(.backToHomeTapped),
                .walletBackupCoordFlow(.backToHomeTapped),
                .torSetup(.backToHomeTapped),
                .currencyConversionSetup(.backToHomeTapped),
                .backToHomeFromServerSwitchTapped,
                .sendCoordFlow(.sendForm(.dismissRequired)):
                state.path = nil
                return .none
                
                // MARK: - Accounts

            case .home(.walletAccountTapped(let walletAccount)):
                guard state.selectedWalletAccount != walletAccount else {
                    return .none
                }
                state.$selectedWalletAccount.withLock { $0 = walletAccount }
                state.homeState.transactionListState.isInvalidated = true
                state.autoUpdateSwapCandidates.removeAll()
                return .merge(
                    .send(.home(.smartBanner(.walletAccountChanged))),
                    .send(.home(.walletBalances(.updateBalances))),
                    .send(.loadContacts),
                    .concatenate(
                        .send(.resolveMetadataEncryptionKeys),
                        .send(.loadUserMetadata)
                    ),
                    .send(.fetchTransactionsForTheSelectedAccount),
                    // SECURITY (MOB-1352): end any open Flexa session bound to the previous account so a
                    // pending Flexa transaction request can't bind to the newly-selected account.
                    .cancel(id: state.CancelFlexaId)
                )

                // MARK: - Add Keystone HW Wallet Coord Flow

            case .addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .restoreInfo(.gotItTapped)))):
                var leavesScreenOpenMutable = false
                for element in state.addKeystoneHWWalletCoordFlowState.path {
                    if case .restoreInfo(let restoreInfoState) = element {
                        leavesScreenOpenMutable = restoreInfoState.isAcknowledged
                    }
                }
                let leavesScreenOpen = leavesScreenOpenMutable
                userDefaults.setValue(leavesScreenOpen, Constants.udLeavesScreenOpen)
                return .run { _ in await autolockHandler.value(leavesScreenOpen) }

            case .addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .accountHWWalletSelection(.forgetThisDeviceTapped)))),
                .addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .keystoneDeviceReady(.forgetThisDeviceTapped)))):
                state.path = nil
                return .none

            case .addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .accountHWWalletSelection(.accountImportSucceeded)))):
                state.path = nil
                state.autoUpdateSwapCandidates.removeAll()
                return .merge(
                    .send(.loadContacts),
                    .concatenate(
                        .send(.resolveMetadataEncryptionKeys),
                        .send(.loadUserMetadata)
                    ),
                    .send(.fetchTransactionsForTheSelectedAccount)
                )

            case .addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .keystoneConnected(.closeTapped)))):
                state.path = nil
                state.autoUpdateSwapCandidates.removeAll()
                return .merge(
                    .send(.loadContacts),
                    .concatenate(
                        .send(.resolveMetadataEncryptionKeys),
                        .send(.loadUserMetadata)
                    ),
                    .send(.fetchTransactionsForTheSelectedAccount)
                )
                
            case .addKeystoneHWWalletCoordFlow(.addKeystoneHWWallet(.backToHomeTapped)):
                state.path = nil
                return .none

                // MARK: - Add Keystone HW Wallet from Settings

            case .settings(.path(.element(id: _, action: .accountHWWalletSelection(.accountImportSucceeded)))):
                state.path = nil
                state.autoUpdateSwapCandidates.removeAll()
                return .merge(
                    .send(.loadContacts),
                    .concatenate(
                        .send(.resolveMetadataEncryptionKeys),
                        .send(.loadUserMetadata)
                    ),
                    .send(.fetchTransactionsForTheSelectedAccount)
                )
                
                // MARK: - Resync Wallet

            case .settings(.resyncFinished):
                guard let birthday = state.settingsState.resyncBirthday else {
                    return .none
                }
                var leavesScreenOpen = false
                for element in state.settingsState.path {
                    if case .resyncRestoreInfo(let restoreInfoState) = element {
                        leavesScreenOpen = restoreInfoState.isAcknowledged
                    }
                }
                userDefaults.setValue(leavesScreenOpen, Constants.udLeavesScreenOpen)
                state.path = nil
                state.isRestoringWallet = true
                userDefaults.setValue(true, Constants.udIsResyncingWallet)
                state.$walletStatus.withLock { $0 = .resyncing }
                let leavesScreenOpenFixed = leavesScreenOpen
                return .concatenate(
                    .run { _ in
                        await autolockHandler.value(leavesScreenOpenFixed)
                    },
                    .publisher {
                        sdkSynchronizer.rewind(.height(blockheight: birthday))
                            .replaceEmpty(with: Void())
                            .map { _ in
                                Root.Action.rewindDone(nil)
                            }
                            .catch { error in
                                Just(Root.Action.rewindDone(error.toZcashError()))
                                    .eraseToAnyPublisher()
                            }
                            .receive(on: mainQueue)
                    }
                    .cancellable(id: state.CancelResyncStateId, cancelInFlight: true),
                    .send(.batteryStateChanged)
                )
                
            case .rewindDone(let zcashError):
                if zcashError == nil {
                    //return .send(.home(.smartBanner(.evaluatePriority45)))
                }
                return .none

                // MARK: - Flexa

            case .flexaOpenRequest:
                flexaHandler.open()
                return .publisher {
                    flexaHandler.onTransactionRequest()
                        .map(Root.Action.flexaOnTransactionRequest)
                        .receive(on: mainQueue)
                }
                .cancellable(id: state.CancelFlexaId, cancelInFlight: true)
                
                // MARK: - Currency Conversion Setup
                
            case .currencyConversionSetup(.skipTapped), .currencyConversionSetup(.enableTapped):
                state.path = nil
                state.homeState.isRateEducationEnabled = false
                return .send(.home(.smartBanner(.closeAndCleanupBanner)))

                // MARK: - Home

            case .home(.settingsTapped):
                state.settingsState = .initial
                state.path = .settings
                return .none
                
            case .home(.receiveTapped):
                state.receiveState = .initial
                state.path = .receive
                return .none

            case .home(.sendTapped):
                state.sendCoordFlowState = .initial
                state.path = .sendCoordFlow
                exchangeRate.refreshExchangeRateUSD()
                return .none

            case .home(.scanTapped):
                state.scanCoordFlowState = .initial
                state.path = .scanCoordFlow
                return .none

            case .home(.flexaTapped), .settings(.payWithFlexaTapped):
                return .send(.flexaOpenRequest)
                
            case .home(.addKeystoneHWWalletTapped):
                state.addKeystoneHWWalletCoordFlowState = .initial
                state.path = .addKeystoneHWWalletCoordFlow
                return .none
                
            case .home(.swapWithNearTapped):
                state.swapAndPayCoordFlowState = .initial
                state.swapAndPayCoordFlowState.isSwapExperience = true
                state.swapAndPayCoordFlowState.swapAndPayState.isSwapExperienceEnabled = true
                state.path = .swapAndPayCoordFlow
                // whether to start on SwapToZEC or fromZEC
                return .send(.swapAndPayCoordFlow(.swapAndPay(.enableSwapToZecExperience)))

            case .home(.payWithNearTapped):
                state.swapAndPayCoordFlowState = .initial
                state.swapAndPayCoordFlowState.isSwapExperience = false
                state.swapAndPayCoordFlowState.swapAndPayState.isSwapExperienceEnabled = false
                state.path = .swapAndPayCoordFlow
                return .none

            case .home(.transactionList(.transactionTapped(let txId))):
                state.transactionsCoordFlowState = .initial
                state.transactionsCoordFlowState.transactionToOpen = txId
                if let index = state.transactions.index(id: txId) {
                    state.transactionsCoordFlowState.transactionDetailsState.transaction = state.transactions[index]
                }
                state.path = .transactionsCoordFlow
                return .none

            case .home(.seeAllTransactionsTapped):
                state.transactionsCoordFlowState = .initial
                state.path = .transactionsCoordFlow
                return .none
                
            case .home(.currencyConversionSetupTapped):
                state.currencyConversionSetupState = .initial
                state.path = .currencyConversionSetup
                return .none

            case .home(.torSetupTapped(let settingsView)):
                state.torSetupState = .initial
                state.torSetupState.isSettingsView = settingsView
                state.path = .torSetup
                return .none

            case .home(.smartBanner(.walletBackupTapped)):
                state.walletBackupCoordFlowState = .initial
                state.path = .walletBackup
                return .none
                
            case .home(.smartBanner(.serverSwitchRequested)):
                state.serverSetupState = .initial
                state.path = .serverSwitch
                return .none

                // MARK: - Keystone

            case .sendCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.rejectTapped)))),
                    .swapAndPayCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.rejectTapped)))):
                state.path = nil
                return .none

            case .signWithKeystoneCoordFlow(.sendConfirmation(.rejectTapped)):
                // The standalone Keystone sign flow (shield-from-Keystone) is presented via the
                // `signWithKeystoneCoordFlowBinding` binding, not `path`, so the shared `path = nil` above
                // was a no-op for it: on iOS only the popover's interactive swipe dismissed it, and the
                // macOS full-window takeover would have no way out at all. Flip the binding so Reject
                // actually closes the flow on both platforms.
                state.signWithKeystoneCoordFlowBinding = false
                // Clear the processor's replayed `.proposal` (CurrentValueSubject) so a later
                // SmartBanner re-subscription can't receive the stale state and instantly close a
                // freshly-opened shield banner (field bug: banner dismissed on every account switch
                // AFTER one rejected Keystone shield).
                shieldingProcessor.reset()
                return .none

            case .signWithKeystoneRequested:
                state.signWithKeystoneCoordFlowBinding = true
                return .send(.signWithKeystoneCoordFlow(.sendConfirmation(.resolvePCZT)))
                
                // MARK: - Request Zec

            case .requestZecCoordFlow(.path(.element(id: _, action: .requestZecSummary(.cancelRequestTapped)))):
                state.path = nil
                return .none

                // MARK: - Reset Zashi

            case .settings(.path(.element(id: _, action: .disconnectHWWallet(.disconnectFinished)))):
                state.path = nil
                state.$selectedWalletAccount.withLock { $0 = nil }
                return .run { send in
                    let walletAccounts = try await sdkSynchronizer.walletAccounts()
                    await send(.initialization(.loadedWalletAccounts(walletAccounts)))
                    await send(.fetchTransactionsForTheSelectedAccount)
                    await send(.home(.walletBalances(.updateBalances)))
                    /// The TCA spins an async Task in `fetchTransactionsForTheSelectedAccount` and it's needed to run
                    /// before next code here therefore Task is asleep for 0.01s. The purpose is also to not block the main thread
                    /// so await of mainQueue is not used.
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    await send(.resolveMetadataEncryptionKeys)
                    await send(.loadUserMetadata)
                }

            case .settings(.path(.element(id: _, action: .resetZashi(.deleteTapped(let areMetadataPreserved))))):
                return .send(.initialization(.resetZashiRequest(areMetadataPreserved)))

                // MARK: - Restore Wallet Coord Flow from Onboarding

            case .onboarding(.seedNotRelevantToExistingDB):
                // Preventive guard ([#1024]): the entered seed doesn't match the wallet DB already on disk.
                // Funnel through the single mismatch sink (`seedValidationResult(false)` → `differentSeed()`:
                // "Start over" wipes via resetZashi, "Try again" dismisses) — before the seed is ever written
                // to the keychain.
                return .send(.initialization(.seedValidationResult(false)))

            case .onboarding(.path(.element(id: _, action: .restoreInfo(.gotItTapped)))):
                var leavesScreenOpen = false
                for element in state.onboardingState.path {
                    if case .restoreInfo(let restoreInfoState) = element {
                        leavesScreenOpen = restoreInfoState.isAcknowledged
                    }
                }
                userDefaults.setValue(leavesScreenOpen, Constants.udLeavesScreenOpen)
                state.isRestoringWallet = true
                userDefaults.setValue(true, Constants.udIsRestoringWallet)
                state.$walletStatus.withLock { $0 = .restoring }
                return .concatenate(
                    .send(.initialization(.initializeSDK(.restoreWallet))),
                    .send(.initialization(.checkBackupPhraseValidation)),
                    .send(.batteryStateChanged)
                )

                // MARK: - Scan Coord Flow
                
            case .scanCoordFlow(.scan(.cancelTapped)):
                state.path = nil
                return .none
                
            case .scanCoordFlow(.path(.element(id: _, action: .sendForm(.dismissRequired)))):
                state.path = nil
                return .none

            case .scanCoordFlow(.path(.element(id: _, action: .transactionDetails(.closeDetailTapped)))):
                state.path = nil
                return .none

            case .scanCoordFlow(.path(.element(id: _, action: .sendResultSuccess(.closeTapped)))),
                    .scanCoordFlow(.path(.element(id: _, action: .sendResultFailure(.closeTapped)))),
                    .scanCoordFlow(.path(.element(id: _, action: .sendResultPending(.closeTapped)))):
                state.path = nil
                state.macRedirectToActivityAfterClose = true
                return .send(.fetchTransactionsForTheSelectedAccount)

                // MARK: - Self

            case .sendAgainRequested(let transactionState):
                state.sendCoordFlowState = .initial
                state.path = .sendCoordFlow
                state.sendCoordFlowState.sendFormState.memoState.text = state.transactionMemos[transactionState.id]?.first ?? ""
                return .merge(
                    .send(.sendCoordFlow(.sendForm(.zecAmountUpdated(transactionState.amountWithoutFee.decimalString().redacted)))),
                    .send(.sendCoordFlow(.sendForm(.addressUpdated(transactionState.address.redacted))))
                )
                
            case .deeplinkWarning(.rescanInZashi):
                state = .initial
                state.splashAppeared = true
                return .merge(
                    .send(.destination(.updateDestination(.home))),
                    .send(.home(.scanTapped))
                )

                // MARK: - Send Coord Flow
                
            case .sendCoordFlow(.path(.element(id: _, action: .sendResultSuccess(.closeTapped)))),
                    .sendCoordFlow(.path(.element(id: _, action: .sendResultFailure(.closeTapped)))),
                    .sendCoordFlow(.path(.element(id: _, action: .sendResultPending(.closeTapped)))):
                state.path = nil
                state.macRedirectToActivityAfterClose = true
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .sendCoordFlow(.path(.element(id: _, action: .transactionDetails(.closeDetailTapped)))):
                state.path = nil
                return .none

                // MARK: - Sign with Keystone Coord Flow

            case .signWithKeystoneCoordFlow(.path(.element(id: _, action: .sendResultSuccess(.closeTapped)))),
                    .signWithKeystoneCoordFlow(.path(.element(id: _, action: .sendResultFailure(.closeTapped)))),
                    .signWithKeystoneCoordFlow(.path(.element(id: _, action: .sendResultPending(.closeTapped)))):
                state.signWithKeystoneCoordFlowBinding = false
                state.macRedirectToActivityAfterClose = true
                // See the reject case above — clear the processor's replayed terminal state.
                shieldingProcessor.reset()
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .signWithKeystoneCoordFlow(.path(.element(id: _, action: .transactionDetails(.closeDetailTapped)))):
                state.signWithKeystoneCoordFlowBinding = false
                shieldingProcessor.reset()
                return .none

                // MARK: - Tor Setup
                
            case .torSetup(.disableTapped), .torSetup(.enableTapped):
                state.path = nil
                return .send(.home(.smartBanner(.closeAndCleanupBanner)))

                // MARK: - Swap and Pay Coord Flow

            case .swapAndPayCoordFlow(.path(.element(id: _, action: .swapToZecSummary(.sentTheFundsButtonTapped)))):
                state.path = nil
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .swapAndPayCoordFlow(.customBackRequired):
                state.path = nil
                return .none

            case .swapAndPayCoordFlow(.swapAndPay(.customBackRequired)):
                state.path = nil
                return .none

            case .swapAndPayCoordFlow(.path(.element(id: _, action: .swapAndPayOptInForced(.customBackRequired)))):
                state.path = nil
                return .none

            case .swapAndPayCoordFlow(.swapAndPay(.cancelPaymentTapped)):
                state.path = nil
                return .none
                
            case .swapAndPayCoordFlow(.path(.element(id: _, action: .sendResultSuccess(.closeTapped)))),
                    .swapAndPayCoordFlow(.path(.element(id: _, action: .sendResultFailure(.closeTapped)))),
                    .swapAndPayCoordFlow(.path(.element(id: _, action: .sendResultPending(.closeTapped)))):
                state.path = nil
                state.macRedirectToActivityAfterClose = true
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .swapAndPayCoordFlow(.path(.element(id: _, action: .transactionDetails(.closeDetailTapped)))):
                state.path = nil
                return .none

                // MARK: - Transactions Coord Flow
                
            case .transactionsCoordFlow(.transactionDetails(.closeDetailTapped)):
                state.path = nil
                return .none

            case .transactionsCoordFlow(.transactionsManager(.dismissRequired)):
                state.path = nil
                return .none

            case .transactionsCoordFlow(.transactionDetails(.sendAgainTapped)):
                state.path = nil
                let transactionState = state.transactionsCoordFlowState.transactionDetailsState.transaction
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(0.8))
                    await send(.sendAgainRequested(transactionState))
                }
                
            case .transactionsCoordFlow(.path(.element(id: _, action: .transactionDetails(.sendAgainTapped)))):
                for element in state.transactionsCoordFlowState.path {
                    if case .transactionDetails(let transactionDetailsState) = element {
                        state.path = nil
                        return .run { send in
                            try? await mainQueue.sleep(for: .seconds(0.8))
                            await send(.sendAgainRequested(transactionDetailsState.transaction))
                        }
                    }
                }
                return .none

                // MARK: - Wallet Backup Coord Flow

            case .walletBackupCoordFlow(.path(.element(id: _, action: .phrase(.remindMeLaterTapped)))):
                state.path = nil
                return .send(.home(.smartBanner(.remindMeLaterTapped(.priority6))))

            case .walletBackupCoordFlow(.path(.element(id: _, action: .phrase(.seedSavedTapped)))):
                state.path = nil
                do {
                    try walletStorage.markUserPassedPhraseBackupTest(true)
                } catch {
                    state.alert = AlertState.cantStoreThatUserPassedPhraseBackupTest(error.toZcashError())
                }
                return .merge(
                    .send(.home(.smartBanner(.closeAndCleanupBanner))),
                    .send(.home(.smartBanner(.closeSheetTapped)))
                )

            default: return .none
            }
        }
    }
}
