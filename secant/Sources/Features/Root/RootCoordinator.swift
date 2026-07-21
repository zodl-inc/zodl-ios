//
//  RootCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 07.03.2025.
//

import Combine
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
                // MOB-1509 (defensive): no UI path reaches the switcher while a migration coord
                // flow covers Home today, but any future dispatcher of this action would silently
                // repoint the flow's live handlers (they read `selectedWalletAccount` fresh) at the
                // new account mid-run. Tear the flow down first — the shared helper cancels a
                // stranded Keystone ceremony on its recorded owner and clears the run's snapshots —
                // then apply the switch.
                var migrationTeardownEffect = Effect<Root.Action>.none
                if state.path == Root.State.Path.migrationCoordFlow {
                    migrationTeardownEffect = tearDownMigrationCoordFlow(state: &state)
                    state.migrationCoordFlowState = MigrationCoordFlow.State.initial
                    state.path = nil
                }
                state.$selectedWalletAccount.withLock { $0 = walletAccount }
                state.homeState.transactionListState.isInvalidated = true
                state.autoUpdateSwapCandidates.removeAll()
                return .merge(
                    migrationTeardownEffect,
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

                // MARK: - Migration Coord Flow

            case .home(.smartBanner(.migrationScreenRequested)):
                state.migrationCoordFlowState = MigrationCoordFlow.State.initial
                state.path = .migrationCoordFlow
                return .none

                // MARK: - Migration Simulator Panel (MOB-1480, debug-only)

            case .home(.migrationSimulator(.presented(.delegate(.openMigrationFlow)))):
                state.migrationCoordFlowState = MigrationCoordFlow.State.initial
                state.path = .migrationCoordFlow
                return .none

            case .home(.migrationSimulator(.presented(.delegate(.runBackgroundSession)))):
                return .send(
                    .initialization(
                        .migrationBackgroundSession(MigrationBGSessionHandle(rawTask: nil, complete: { _ in }))
                    )
                )

            case .migrationCoordFlow(.flowFinished):
                // `.flowFinished` is the Root-side terminal signal for every flow-root close
                // (Sending's own exit, and recovery/scheduled/reviewTransfer/complete's own delegates
                // — see the cases below), so this closes any path where the coordinator finishes.
                // MOB-1497 (T4): the teardown (defensive hold release + provisional/abandoned snapshot
                // clears) is shared with `.switchServerRequested` below via `tearDownMigrationCoordFlow`
                // so the two stay in lockstep; this case then closes the path back to Home.
                let teardownEffect = tearDownMigrationCoordFlow(state: &state)
                state.path = nil
                return teardownEffect

            case .migrationCoordFlow(.switchServerRequested):
                // MOB-1497 (T4): the custom-server Tor sheet's "Switch Server" — the abandoned attempt
                // persisted nothing (its network snapshot is still provisional, discarded by the
                // shared teardown), so instead of closing to Home this opens Server Setup with
                // back-to-Home, mirroring the smart-banner `.serverSwitchRequested` entry's own state
                // prep (`ServerSetup.State.initial` + `.serverSwitch`).
                let switchTeardownEffect = tearDownMigrationCoordFlow(state: &state)
                state.serverSetupState = ServerSetup.State.initial
                state.path = .serverSwitch
                return switchTeardownEffect

            case .migrationCoordFlow(
                .path(.element(id: _, action: .sending(.delegate(.viewTransaction))))
            ):
                // The migration Sending delegate carries only a bare `txId: String`
                // (`MigrationSending.State.txId`), never a real `TransactionState` — but
                // `TransactionsCoordFlow`'s existing open-a-transaction plumbing (mirrored from
                // `.home(.transactionList(.transactionTapped))` above) requires a non-optional
                // `TransactionState` looked up from `state.transactions`, and the app exposes no
                // by-txid lookup to fall back to. The txid is real now, but it still won't be in
                // `state.transactions` at tap time: ordinary sync is deliberately paused right after
                // a migration broadcast (`stopSyncBeforeMigrationBroadcast`) and stays gated behind
                // the post-broadcast privacy buffer, so the wallet hasn't scanned the transaction
                // back in yet. Treat View Transaction as a flow close rather than a broken/empty
                // detail screen until a by-txid lookup exists.
                // TODO: [MOB-1458] route to transaction detail once a by-txid transaction lookup exists
                //
                // R8-T6 fix-wave (Critical-1): also a defensive release (BEFORE the pop) — `View
                // Transaction` only ever renders once the Sending screen has already reached
                // `.success`, by which point `.sendNowGateResolved(.allowed)` has already cleared
                // the hold itself, so this is a no-op in practice; kept for the same "Root pops the
                // flow from outside the store's own exit" reasoning as `.flowFinished` above.
                // (MOB-1497 fix wave: the provisional-snapshot clear that briefly lived here was a
                // documented dead no-op — `.flowFinished` is the one live provisional-teardown site.)
                let releaseEffect = releaseSendWaitHold()
                // MOB-1496: same defensive reasoning for a live Keystone signing ceremony — by the
                // `.success` phase `pendingKeystoneSigning` is already `nil` in every reachable case
                // (the Keystone resume chain clears it well before Sending is ever pushed), so this
                // too is a no-op in practice; kept for symmetry with `.flowFinished` above.
                let cancelEffect = cancelAbandonedKeystoneMigrationRun(state: state)
                state.path = nil
                return .merge(releaseEffect, cancelEffect)

                // MARK: - Keystone

            case .sendCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.rejectTapped)))),
                    .signWithKeystoneCoordFlow(.sendConfirmation(.rejectTapped)),
                    .swapAndPayCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.rejectTapped)))):
                state.path = nil
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
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .sendCoordFlow(.path(.element(id: _, action: .transactionDetails(.closeDetailTapped)))):
                state.path = nil
                return .none

                // MARK: - Sign with Keystone Coord Flow

            case .signWithKeystoneCoordFlow(.path(.element(id: _, action: .sendResultSuccess(.closeTapped)))),
                    .signWithKeystoneCoordFlow(.path(.element(id: _, action: .sendResultFailure(.closeTapped)))),
                    .signWithKeystoneCoordFlow(.path(.element(id: _, action: .sendResultPending(.closeTapped)))):
                state.signWithKeystoneCoordFlowBinding = false
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .signWithKeystoneCoordFlow(.path(.element(id: _, action: .transactionDetails(.closeDetailTapped)))):
                state.signWithKeystoneCoordFlowBinding = false
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

                // MARK: - Migration Tor Failure Prompt (MOB-1497 T6)

            case .checkMigrationTorFailurePrompt:
                // Foreground gate — present the "Couldn't Connect to Tor" sheet over Home iff Home is
                // fully visible (no Root path pushed, Server Setup cover down), nothing is already
                // presented, it hasn't been offered yet THIS foreground, a selected account exists,
                // and that account's BACKGROUND Tor-failure latch is armed. `isPendingBackgroundTorPrompt`
                // is a synchronous UserDefaults read, so the whole gate resolves inline. When the gate
                // fails for path/cover reasons the latch is left untouched (`didOffer` stays false), so
                // a later foreground with Home visible still presents.
                guard state.path == nil,
                    !state.serverSetupViewBinding,
                    !state.isTorFailurePromptPresented,
                    !state.didOfferTorFailurePromptThisForeground,
                    let accountUUID = state.selectedWalletAccount?.id,
                    migrationManager.isPendingBackgroundTorPrompt(accountUUID)
                else {
                    return .none
                }
                state.didOfferTorFailurePromptThisForeground = true
                state.torFailurePromptState = MigrationTorFailureSheet.State()
                state.isTorFailurePromptPresented = true
                return .none

            case .torFailurePromptPresentationChanged(let isPresented):
                // Swipe-dismiss sends `false` (the latch stays armed — the next foreground re-checks).
                // A failed in-sheet retry sends `true` to re-present (bypassing the once-per-foreground
                // gate deliberately — see `attemptForegroundMigrationTorRetry`).
                state.isTorFailurePromptPresented = isPresented
                return .none

            case .torFailurePrompt(.delegate(.continueWithoutTor)):
                // The sheet's `MigrationRisksCard` is the R15 clearnet-consent surface (no second
                // alert): turn Tor off for the REST of this run BEFORE the attempt, then clear the
                // latch and run one foreground broadcast.
                state.isTorFailurePromptPresented = false
                guard let accountUUID = state.selectedWalletAccount?.id else { return .none }
                migrationManager.overrideTorForRun(accountUUID, false)
                return clearLatchAndAttemptForegroundTorRetry(accountUUID)

            case .torFailurePrompt(.delegate(.tryAgain)):
                // Keeps Tor on — clear the latch and run one foreground broadcast; a Tor-class failure
                // re-arms the latch and re-presents from inside the attempt.
                state.isTorFailurePromptPresented = false
                guard let accountUUID = state.selectedWalletAccount?.id else { return .none }
                return clearLatchAndAttemptForegroundTorRetry(accountUUID)

            default: return .none
            }
        }
    }

    /// MOB-1497 (T4): the migration flow's shared teardown — run by BOTH
    /// `.migrationCoordFlow(.flowFinished)` (which then closes the path back to Home) and
    /// `.migrationCoordFlow(.switchServerRequested)` (which then routes to Server Setup) so the two
    /// stay in lockstep. Does NOT touch `state.path` — each caller sets its own destination after.
    ///
    /// The three effects, in order:
    /// - `releaseSendWaitHold()`: a defensive release — normally a no-op (the Sending store's own
    ///   exit already clears the hold), but every flow-root close lands here, so this covers any
    ///   path where the coordinator finishes without that exit running. Read here, BEFORE the caller
    ///   repoints `state.path`.
    /// - `clearProvisionalNetworkSnapshot(nil)`: discards the account's network snapshot iff it is
    ///   still PROVISIONAL (never committed to a schedule this run); a no-op against an
    ///   already-committed one, which stays until its own run-end clear. `nil` resolves the selected
    ///   account, same convention as every other manager member.
    /// - `clearAbandonedNetworkSnapshot(accountUUID)` (fire-and-forget): covers an abandoned
    ///   pre-commit confirm lane that took a snapshot on its first `migrationNetworkOptions` read but
    ///   never committed a schedule. Itself a no-op unless the account's engine state is genuinely
    ///   `.notStarted` with no stored schedule payload, so it is safe to fire on EVERY flow close.
    private func tearDownMigrationCoordFlow(state: inout Root.State) -> Effect<Root.Action> {
        let releaseEffect = releaseSendWaitHold()
        // MOB-1496 (abandon reconciliation): a live Keystone signing ceremony means the engine
        // already created the run at PCZT-build time and would silently resume it (stale PCZTs) on
        // the next attempt — cancel it on any external teardown, Switch Server included. Read
        // BEFORE the callers reset/replace `migrationCoordFlowState`; see
        // `cancelAbandonedKeystoneMigrationRun`'s doc.
        let cancelEffect = cancelAbandonedKeystoneMigrationRun(state: state)
        migrationManager.clearProvisionalNetworkSnapshot(nil)
        return .merge(
            releaseEffect,
            cancelEffect,
            .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] _ in
                await migrationManager.clearAbandonedNetworkSnapshot(accountUUID)
            }
        )
    }
}
