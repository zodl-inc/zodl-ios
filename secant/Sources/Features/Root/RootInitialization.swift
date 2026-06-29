//
//  RootInitialization.swift
//  Zashi
//
//  Created by Lukáš Korba on 01.12.2022.
//

import ComposableArchitecture
import Combine
import Foundation
@preconcurrency import ZcashLightClientKit

/// In this file is a collection of helpers that control all state and action related operations
/// for the `Root` with a connection to the app/wallet initialization and erasure of the wallet.
extension Root {
    enum Constants {
        static let udIsRestoringWallet = "udIsRestoringWallet"
        static let udIsResyncingWallet = "udIsResyncingWallet"
        static let udLeavesScreenOpen = "udLeaves_screen_open"
        static let noAuthenticationWithinXMinutes = 15
    }
    
    enum InitializationAction {
        case appDelegate(AppDelegateAction)
        case checkBackupPhraseValidation
        case checkRestoreWalletFlag(SyncStatus)
        case checkWalletInitialization
        case checkWalletConfig
        case initializeSDK(WalletInitMode)
        case initialSetups
        case initializationFailed(ZcashError)
        case initializationSuccessfullyDone
        case loadedWalletAccounts([WalletAccount])
        case resetZashi
        case resetZashiRequest(Bool)
        case resetZashiRequestCanceled
        case respondToWalletInitializationState(InitializationState)
        case restoreExistingWallet
        case seedValidationResult(Bool)
        case synchronizerStartFailed(ZcashError)
        case registerForSynchronizersUpdate
        case retryStart
        case walletConfigChanged(WalletConfig)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func initializationReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .initialization(.appDelegate(.didFinishLaunching)):
                state.appStartState = .didFinishLaunching
                // TODO: [#704], trigger the review request logic when approved by the team,
                // https://github.com/Electric-Coin-Company/zashi-ios/issues/704
                return .run { send in
                        try await mainQueue.sleep(for: .seconds(0.5))
                        await send(.initialization(.initialSetups))
                    }
                    .cancellable(id: state.DidFinishLaunchingId, cancelInFlight: true)

            case .initialization(.appDelegate(.willEnterForeground)):
                if state.featureFlags.appLaunchBiometric {
                    let now = Date()
                    let before = Date.init(timeIntervalSince1970: TimeInterval(state.lastAuthenticationTimestamp))
                    if let xMinutesAgo = Calendar.current.date(byAdding: .minute, value: -Constants.noAuthenticationWithinXMinutes, to: now),
                       before < xMinutesAgo {
                        state.splashAppeared = false
                    }
                }
                state.appStartState = .willEnterForeground
                if state.isLockedInKeychainUnavailableState || !sdkSynchronizer.latestState().syncStatus.isPrepared {
                    return .send(.initialization(.initialSetups))
                } else {
                    return .send(.initialization(.retryStart))
                }
                
            case .initialization(.appDelegate(.didEnterBackground)):
                sdkSynchronizer.stop()
                state.bgTask?.setTaskCompleted(success: false)
                state.bgTask = nil
                state.appStartState = .didEnterBackground
                state.isLockedInKeychainUnavailableState = false
                return .merge(
                    .cancel(id: state.CancelStateId),
                    .cancel(id: state.CancelTransactionsStateId)
                )

            case .initialization(.appDelegate(.backgroundTask(let task))):
                let keysPresent: Bool = (try? walletStorage.areKeysPresent()) ?? false
                if state.appStartState == .didFinishLaunching {
                    state.appStartState = .backgroundTask
                    if keysPresent {
                        state.bgTask = task
                        return .none
                    } else {
                        state.isLockedInKeychainUnavailableState = true
                        task.setTaskCompleted(success: false)
                        return .cancel(id: state.DidFinishLaunchingId)
                    }
                } else {
                    state.bgTask = task
                    state.appStartState = .backgroundTask
                    return .run { send in
                        await send(.initialization(.retryStart))
                    }
                }
                
            case .synchronizerStateChanged(let latestState):
                let snapshot = SyncStatusSnapshot.snapshotFor(state: latestState.data.syncStatus)

                guard let account = state.selectedWalletAccount else {
                    return .none
                }
                
                // update flexa balance
                if let accountBalance = latestState.data.accountsBalances[account.id] {
                    let shieldedBalance = accountBalance.saplingBalance.spendableValue + accountBalance.orchardBalance.spendableValue
                    let shieldedWithPendingBalance = accountBalance.saplingBalance.total() + accountBalance.orchardBalance.total()

                    flexaHandler.updateBalance(shieldedWithPendingBalance, shieldedBalance)
                }

                // handle possible service unavailability
                if case .error(let error) = snapshot.syncStatus, checkUnavailableService(error) {
                    if state.walletStatus != .disconnected {
                        state.alert = AlertState.serviceUnavailable()
                    }
                    state.wasRestoringWhenDisconnected = state.walletStatus == .restoring
                    state.$walletStatus.withLock { $0 = .disconnected }
                } else if case .syncing = snapshot.syncStatus, state.walletStatus == .disconnected {
                    state.$walletStatus.withLock { $0 = state.wasRestoringWhenDisconnected ? .restoring : .none }
                }

                // [#1755 / slipstream] Drive the restoring/resyncing LABEL from the SDK's durable
                // `isRecovering` signal (recovery_progress incomplete = a from-birthday backfill is in
                // progress). It's recomputed from data.db every launch, so a kill mid-restore relaunches
                // as .restoring with no reliance on a persisted guess, and a stale flag self-corrects.
                // A user-initiated RESYNC is the same engine operation (isRecovering can't see intent),
                // so we honor the persisted resync intent for the label. `.disconnected` (set above) is
                // left untouched; resync completion still clears via the existing up-to-date path.
                let recovering = latestState.data.isRecovering
                if state.walletStatus != .disconnected {
                    if recovering {
                        if state.walletStatus != .restoring, state.walletStatus != .resyncing {
                            let resyncing = userDefaults.objectForKey(Constants.udIsResyncingWallet) as? Bool ?? false
                            state.$walletStatus.withLock { $0 = resyncing ? .resyncing : .restoring }
                        }
                        state.isRestoringWallet = true
                    } else if state.walletStatus == .restoring {
                        state.isRestoringWallet = false
                        userDefaults.remove(Constants.udIsRestoringWallet)
                        userDefaults.remove(Constants.udIsResyncingWallet)
                        state.$walletStatus.withLock { $0 = .none }
                    }
                }

                // handle BCGTask
                guard state.bgTask != nil else {
                    return .send(.initialization(.checkRestoreWalletFlag(snapshot.syncStatus)))
                }
                
                var finishBGTask = false
                var successOfBGTask = false
                
                switch snapshot.syncStatus {
                case .upToDate:
                    successOfBGTask = true
                    finishBGTask = true
                    if state.isRestoringWallet {
                        userDefaults.remove(Constants.udIsRestoringWallet)
                        userDefaults.remove(Constants.udIsResyncingWallet)
                        state.$walletStatus.withLock { $0 = .none }
                    }
                    state.isRestoringWallet = false
                case .stopped, .error:
                    successOfBGTask = false
                    finishBGTask = true
                default: break
                }
                
                if finishBGTask  {
                    LoggerProxy.event("BGTask setTaskCompleted(success: \(successOfBGTask)) from TCA")
                    state.bgTask?.setTaskCompleted(success: successOfBGTask)
                    state.bgTask = nil
                    return .merge(
                        .cancel(id: state.CancelStateId),
                        .cancel(id: state.CancelTransactionsStateId)
                    )
                }

                return .send(.initialization(.checkRestoreWalletFlag(snapshot.syncStatus)))
                
            case .initialization(.checkRestoreWalletFlag(let syncStatus)):
                if state.isRestoringWallet && syncStatus == .upToDate {
                    state.isRestoringWallet = false
                    userDefaults.remove(Constants.udIsRestoringWallet)
                    userDefaults.remove(Constants.udIsResyncingWallet)
                    state.$walletStatus.withLock { $0 = .none }
                }
                return .none

            case .initialization(.synchronizerStartFailed):
                return .none
                
            case .initialization(.retryStart):
                if !diskSpaceChecker.hasEnoughFreeSpaceForSync() {
                    state.destinationState.preNotEnoughFreeSpaceDestination = state.destinationState.internalDestination
                    return .send(.destination(.updateDestination(.notEnoughFreeSpace)))
                } else if let preNotEnoughFreeSpaceDestination = state.destinationState.preNotEnoughFreeSpaceDestination {
                    state.destinationState.internalDestination = preNotEnoughFreeSpaceDestination
                    state.destinationState.preNotEnoughFreeSpaceDestination = nil
                }
                // Try the start only if the synchronizer has been already prepared
                guard sdkSynchronizer.latestState().syncStatus.isPrepared else {
                    return .none
                }
                return .run { [state] send in
                    do {
                        // TODO: [#1755] T6.8-L1: resolve server selection BEFORE first start so the
                        // automatic race completes while the synchronizer is still idle. Without this
                        // the race finished ~10-20s into the first pass and triggered a switchTo
                        // restart ([WARNING] switchTo during active sync — pass will restart).
                        // Skip during background tasks (matches the .refreshAutomaticServer guard).
                        // mid-session re-selection (post-start) is kept via .refreshAutomaticServer.
                        if state.bgTask == nil {
                            // zcash #1757 split refreshIfEnabled() into findBestServer + applySwitch.
                            // Pre-start the synchronizer is idle, so applySwitch (switchIfIdle) applies
                            // immediately — same intent. findBestServer() returns nil when Automatic is
                            // off / nothing better, so this is a no-op in manual mode.
                            if let best = await autoServerSelection.findBestServer() {
                                _ = await autoServerSelection.applySwitch(best)
                            }
                        }
                        try await sdkSynchronizer.start(true)
                        if state.bgTask != nil {
                            LoggerProxy.event("BGTask synchronizer.start() PASSED")
                        }
                        await send(.initialization(.registerForSynchronizersUpdate))
                        await send(.observeTransactions)
                        await send(.refreshAutomaticServer)
                    } catch {
                        if state.bgTask != nil {
                            LoggerProxy.event("BGTask synchronizer.start() failed \(error.toZcashError())")
                        }
                        await send(.initialization(.synchronizerStartFailed(error.toZcashError())))
                    }
                }
                
            case .initialization(.registerForSynchronizersUpdate):
                let stateStreamEffect = Effect.publisher {
                    sdkSynchronizer.stateStream()
                        .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                        .map { $0.redacted }
                        .map(Root.Action.synchronizerStateChanged)
                }
                .cancellable(id: state.CancelStateId, cancelInFlight: true)
                if state.bgTask != nil {
                    return stateStreamEffect
                } else {
                    return .merge(
                        stateStreamEffect,
                        .send(.home(.smartBanner(.evaluatePriority1)))
                    )
                }

            case .initialization(.checkWalletConfig):
                return .run { send in
                    let walletConfig = await walletConfigProvider.load()
                    await send(.walletConfigLoaded(walletConfig))
                }
                .cancellable(id: state.WalletConfigCancelId, cancelInFlight: true)

            case .walletConfigLoaded(let walletConfig):
                if walletConfig == WalletConfig.initial {
                    return .send(.initialization(.initialSetups))
                } else {
                    return .send(.initialization(.walletConfigChanged(walletConfig)))
                }
                
            case .initialization(.walletConfigChanged(let walletConfig)):
                return .concatenate(
                    .send(.updateStateAfterConfigUpdate(walletConfig)),
                    .send(.initialization(.initialSetups))
                )
                
            case .initialization(.initialSetups):
                // macOS without a Secure Enclave (pre-T2 Intel): the seed can't be stored securely and
                // there's no plaintext fallback, so create/restore would hard-error. Surface a clear info
                // screen instead. Always true on iOS and on Secure-Enclave Macs → no behavior change there.
                if !walletStorage.isSecureStorageAvailable() {
                    state.osStatusErrorState.secureEnclaveUnavailable = true
                    return .send(.destination(.updateDestination(.osStatusError)))
                }
                if !diskSpaceChecker.hasEnoughFreeSpaceForSync() {
                    state.destinationState.preNotEnoughFreeSpaceDestination = state.destinationState.internalDestination
                    return .send(.destination(.updateDestination(.notEnoughFreeSpace)))
                } else if let preNotEnoughFreeSpaceDestination = state.destinationState.preNotEnoughFreeSpaceDestination {
                    state.destinationState.internalDestination = preNotEnoughFreeSpaceDestination
                    state.destinationState.preNotEnoughFreeSpaceDestination = nil
                }
                // TODO: [#524] finish all the wallet events according to definition, https://github.com/Electric-Coin-Company/zashi-ios/issues/524
                LoggerProxy.event(".appDelegate(.didFinishLaunching)")
                /// We need to fetch data from keychain, in order to be 100% sure the keychain can be read we delay the check a bit.
                /// macOS: first transparently migrate any legacy plaintext seed into the Secure Enclave, so an
                /// un-migrated wallet isn't seen as "keysMissing" and sent to onboarding (no-op on iOS / once done).
                return .run { send in
                    try? await walletStorage.migrateToSecureEnclave()
                    await send(.initialization(.checkWalletInitialization))
                }

                /// Evaluate the wallet's state based on keychain keys and database files presence
            case .initialization(.checkWalletInitialization):
                let walletState = Root.walletInitializationState(
                    databaseFiles: databaseFiles,
                    walletStorage: walletStorage,
                    zcashNetwork: zcashSDKEnvironment.network()
                )
                return .send(.initialization(.respondToWalletInitializationState(walletState)))

                /// Respond to all possible states of the wallet and initiate appropriate side effects including errors handling
            case .initialization(.respondToWalletInitializationState(let walletState)):
                switch walletState {
                case .osStatus(let osStatus):
                    state.osStatusErrorState.osStatus = osStatus
                    return .send(.destination(.updateDestination(.osStatusError)))
                case .failed:
                    state.appInitializationState = .failed
                    state.alert = AlertState.walletStateFailed(walletState)
                    return .none
                case .keysMissing:
                    state.appInitializationState = .keysMissing
                    return .send(.destination(.updateDestination(.onboarding)))
                case .filesMissing:
                    state.appInitializationState = .filesMissing
                    state.isRestoringWallet = true
                    userDefaults.setValue(true, Constants.udIsRestoringWallet)
                    state.$walletStatus.withLock { $0 = .restoring }
                    return .concatenate(
                        .send(.initialization(.initializeSDK(.restoreWallet))),
                        .send(.initialization(.checkBackupPhraseValidation))
                    )
                case .initialized:
                    if let isRestoringWallet = userDefaults.objectForKey(Constants.udIsRestoringWallet) as? Bool, isRestoringWallet {
                        state.isRestoringWallet = true
                        state.$walletStatus.withLock { $0 = .restoring }
                        return .concatenate(
                            .send(.initialization(.initializeSDK(.restoreWallet))),
                            .send(.initialization(.checkBackupPhraseValidation))
                        )
                    } else if let isResyncingWallet = userDefaults.objectForKey(Constants.udIsResyncingWallet) as? Bool, isResyncingWallet {
                        state.isRestoringWallet = true
                        state.$walletStatus.withLock { $0 = .resyncing }
                        return .concatenate(
                            .send(.initialization(.initializeSDK(.restoreWallet))),
                            .send(.initialization(.checkBackupPhraseValidation))
                        )
                    }
                    return .concatenate(
                        .send(.initialization(.initializeSDK(.existingWallet))),
                        .send(.initialization(.checkBackupPhraseValidation))
                    )
                case .uninitialized:
                    state.appInitializationState = .uninitialized
                    return .run { send in
                        try await mainQueue.sleep(for: .seconds(0.5))
                        await send(.destination(.updateDestination(.onboarding)))
                    }
                    .cancellable(id: state.CancelId, cancelInFlight: true)
                }
                
                /// Stored wallet is present, database files may or may not be present, trying to initialize app state variables and environments.
                /// When initialization succeeds user is taken to the home screen.
            case .initialization(.initializeSDK(let walletMode)):
                let dbFilesPresent = databaseFiles.areDbFilesPresentFor(zcashSDKEnvironment.network())
                return .run { send in
                        do {
                            // Seed handling (docs/macos/KEYCHAIN_SE_HARDENING.md): the macOS seed is
                            // Secure-Enclave-wrapped, so decrypting it prompts. The SDK's `prepare` takes
                            // an OPTIONAL seed — once the wallet exists in `data.db` we prepare WITHOUT it
                            // (no prompt on normal launches). The seed is decrypted only on FIRST init
                            // (the user just supplied it) and reused for the seed-derived keys below.
                            let seedBytes: [UInt8]?
                            let birthday: BlockHeight
                            if dbFilesPresent {
                                seedBytes = nil
                                birthday = (try? walletStorage.exportWalletMetadata().birthday?.value())
                                    ?? zcashSDKEnvironment.latestCheckpoint()
                            } else {
                                let storedWallet: StoredWallet
                                do {
                                    storedWallet = try await walletStorage.exportWallet()
                                } catch {
                                    await send(.destination(.updateDestination(.osStatusError)))
                                    return
                                }
                                try mnemonic.isValid(storedWallet.seedPhrase.value())
                                seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                                birthday = storedWallet.birthday?.value() ?? zcashSDKEnvironment.latestCheckpoint()
                            }

                            try await sdkSynchronizer.prepareWith(
                                seedBytes,
                                birthday,
                                walletMode,
                                String(localizable: .accountsZashi),
                                String(localizable: .accountsZashi).lowercased()
                            )

                            await send(.fetchTransactionsForTheSelectedAccount)
                            /// The TCA spins an async Task in `fetchTransactionsForTheSelectedAccount` and it's needed to run
                            /// before next code here therefore Task is asleep for 0.01s. The purpose is also to not block the main thread
                            /// so await of mainQueue is not used.
                            try? await Task.sleep(nanoseconds: 10_000_000)

                            let walletAccounts = try await sdkSynchronizer.walletAccounts()
                            await send(.initialization(.loadedWalletAccounts(walletAccounts)))

                            // First init only (we still hold the seed): derive the seed-derived metadata
                            // encryption keys HERE, reusing `seedBytes`, so the async
                            // resolveMetadataEncryptionKeys below finds them present and never re-decrypts
                            // the Secure-Enclave seed. Together with WalletStorage's primed-seed reuse,
                            // restore/create fires ZERO seed prompts (docs/macos/KEYCHAIN_SE_HARDENING.md).
                            // Existing-wallet launches keep seedBytes == nil, so the standard
                            // resolveMetadataEncryptionKeys recovery path is unchanged.
                            if let seedBytes {
                                for account in walletAccounts
                                where (try? walletStorage.exportUserMetadataEncryptionKeys(account.account)) == nil {
                                    do {
                                        var keys = UserMetadataEncryptionKeys.empty
                                        try keys.cacheFor(
                                            seed: seedBytes,
                                            account: account.account,
                                            network: zcashSDKEnvironment.network().networkType
                                        )
                                        try walletStorage.importUserMetadataEncryptionKeys(keys, account.account)
                                    } catch {
                                        LoggerProxy.event("first-init metadata key derivation failed for '\(account.account.name ?? "?")': \(error)")
                                    }
                                }
                            }

                            await send(.resolveMetadataEncryptionKeys)
                            await send(.loadUserMetadata)

                            // TODO: [#1755] T6.8-L1: resolve server selection BEFORE first start.
                            // The automatic race completes here while the synchronizer is still idle;
                            // previously it ran post-start and triggered a switchTo restart ~10-20s
                            // into the first pass ([WARNING] switchTo during active sync — pass will
                            // restart), wasting ~50s on iPad A10 / ~5-10s on iPhone.
                            // evaluateBestOf is bounded by evaluationTimeoutSeconds=5.0 (existing
                            // constant in AutoServerSelectionConstants) so no new timeout is needed.
                            // zcash #1757 split refreshIfEnabled() into findBestServer + applySwitch.
                            // findBestServer() returns nil when Automatic is off, so this stays a
                            // no-op in manual mode; pre-start the synchronizer is idle so applySwitch
                            // (switchIfIdle) applies immediately — same intent as before.
                            if let best = await autoServerSelection.findBestServer() {
                                _ = await autoServerSelection.applySwitch(best)
                            }
                            try await sdkSynchronizer.start(false)

                            var selectedAccount: WalletAccount?
                            
                            for account in walletAccounts {
                                if account.vendor == .zcash {
                                    selectedAccount = account
                                }
                            }

                            exchangeRate.refreshExchangeRateUSD()

                            // Address-book keys are seed-derived — derive only when we actually hold the
                            // seed (first init) and they're missing. On normal launches `seedBytes` is nil
                            // and they're already cached, so this is skipped (no prompt).
                            if let account = selectedAccount, let seedBytes {
                                let addressBookEncryptionKeys = try? walletStorage.exportAddressBookEncryptionKeys()
                                if addressBookEncryptionKeys == nil {
                                    do {
                                        var keys = AddressBookEncryptionKeys.empty
                                        try keys.cacheFor(
                                            seed: seedBytes,
                                            account: account.account,
                                            network: zcashSDKEnvironment.network().networkType
                                        )
                                        try walletStorage.importAddressBookEncryptionKeys(keys)
                                    } catch {
                                        // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                                    }
                                }

                                await send(.initialization(.initializationSuccessfullyDone))
                            } else {
                                await send(.initialization(.initializationSuccessfullyDone))
                            }
                        } catch {
                            await send(.initialization(.initializationFailed(error.toZcashError())))
                        }
                    }

            case .initialization(.initializationSuccessfullyDone):
                return .merge(
                    .send(.initialization(.registerForSynchronizersUpdate)),
                    .publisher {
                        autolockHandler.batteryStatePublisher()
                            .map { _ in Root.Action.batteryStateChanged }
                    }
                    .cancellable(id: state.CancelBatteryStateId, cancelInFlight: true),
                    .send(.batteryStateChanged),
                    .send(.observeTransactions),
                    .send(.observeShieldingProcessor),
                    .send(.observeTorInit),
                    .send(.refreshAutomaticServer)
                )
                
            case .initialization(.loadedWalletAccounts(let walletAccounts)):
                state.$walletAccounts.withLock { $0 = walletAccounts }
                if state.selectedWalletAccount == nil {
                    for account in walletAccounts {
                        if account.vendor == .zcash {
                            state.$selectedWalletAccount.withLock { $0 = account }
                            state.$zashiWalletAccount.withLock { $0 = account }
                            break
                        }
                    }
                }
                return .merge(
                    .send(.loadContacts),
                    .send(.loadUserMetadata),
                    .send(.loadSwapAPIAccess)
                )

            case .resolveMetadataEncryptionKeys:
                return .run { [walletAccounts = state.walletAccounts] send in
                    // Decrypt the seed only if some account is actually missing its metadata keys
                    // (promptless otherwise — docs/macos/KEYCHAIN_SE_HARDENING.md). The keys are
                    // seed-derived, so on normal launches they're already cached and this never decrypts.
                    let accountsMissingKeys = walletAccounts.filter {
                        (try? walletStorage.exportUserMetadataEncryptionKeys($0.account)) == nil
                    }
                    guard !accountsMissingKeys.isEmpty else { return }

                    guard
                        let storedWallet = try? await walletStorage.exportWallet(),
                        let seedBytes = try? mnemonic.toSeed(storedWallet.seedPhrase.value())
                    else { return }

                    for account in accountsMissingKeys {
                        do {
                            var keys = UserMetadataEncryptionKeys.empty
                            try keys.cacheFor(
                                seed: seedBytes,
                                account: account.account,
                                network: zcashSDKEnvironment.network().networkType
                            )
                            try walletStorage.importUserMetadataEncryptionKeys(keys, account.account)
                            await send(.loadUserMetadata)
                        } catch {
                            LoggerProxy.event("resolveMetadataEncryptionKeys: failed to derive metadata keys for account '\(account.account.name ?? "?")': \(error)")
                        }
                    }
                }
                
            case .initialization(.checkBackupPhraseValidation):
                // Existence check only (promptless) — do NOT decrypt the seed here.
                guard (try? walletStorage.areKeysPresent()) == true else {
                    return .send(.destination(.updateDestination(.osStatusError)))
                }

                state.appInitializationState = .initialized
                let isAtDeeplinkWarningScreen = state.destinationState.destination == .deeplinkWarning

                return .run { send in
#if !os(macOS)
                    // iOS-only launch-time desync check ([#1024]): the keychain seed reads without a
                    // prompt here, so re-confirm it still matches the wallet DB and warn if it drifted.
                    // Only a definitive `false` warns; any error defaults to relevant so a transient rust
                    // hiccup never falsely locks a valid wallet, and hardware-only wallets are skipped by
                    // `try?`. Intentionally NOT done on macOS: the seed is Secure-Enclave-wrapped, so this
                    // would prompt on EVERY launch, and the preventive guard at restore (`resolveRestore`,
                    // which uses the freshly-typed seed — no decrypt) already prevents the desync at its
                    // source. Re-checking every launch buys nothing there but a biometric.
                    if databaseFiles.areDbFilesPresentFor(zcashSDKEnvironment.network()),
                       let storedWallet = try? await walletStorage.exportWallet(),
                       let seedBytes = try? mnemonic.toSeed(storedWallet.seedPhrase.value()) {
                        let relevant = (try? await sdkSynchronizer.isSeedRelevantToAnyDerivedAccount(seedBytes)) ?? true
                        if !relevant {
                            await send(.initialization(.seedValidationResult(false)))
                        }
                    }
#endif

                    // Delay the splash overlay dismissal
                    try await mainQueue.sleep(for: .seconds(0.5))
                    if !isAtDeeplinkWarningScreen {
                        await send(.destination(.updateDestination(Root.DestinationState.Destination.home)))
                    }
                }
                .cancellable(id: state.CancelId, cancelInFlight: true)
                
            case .initialization(.resetZashiRequest(let areMetadataPreserved)):
                state.areMetadataPreserved = areMetadataPreserved
                return .send(.initialization(.resetZashi))
                
            case .initialization(.resetZashiRequestCanceled):
                state.alert = nil
                for (id, element) in zip(state.settingsState.path.ids, state.settingsState.path) {
                    if element.is(\.resetZashi) {
                        return .send(.settings(.path(.element(id: id, action: .resetZashi(.deleteCanceled)))))
                    }
                }
                return .none

            case .initialization(.resetZashi):
                guard let wipePublisher = sdkSynchronizer.wipe() else {
                    return .send(.resetZashiSDKFailed)
                }
                return .publisher {
                    wipePublisher
                        .replaceEmpty(with: Void())
                        .map { _ in return Root.Action.resetZashiSDKSucceeded }
                        .replaceError(with: Root.Action.resetZashiSDKFailed)
                        .receive(on: mainQueue)
                }
                .cancellable(id: state.SynchronizerCancelId, cancelInFlight: true)

            case .resetZashiSDKSucceeded:
                state.splashAppeared = true
                state.isRestoringWallet = false
                userDefaults.remove(Constants.udIsRestoringWallet)
                userDefaults.remove(Constants.udIsResyncingWallet)
                userDefaults.remove(Constants.udLeavesScreenOpen)
                userDefaults.remove(.hasSeenHowToVote)
                userDefaults.remove(.hasSeenHowToVoteKeystone)
                // Drop the user-supplied voting chain override and the saved
                // custom-chain list. Without this wipe, the next wallet on
                // this device would silently resolve voting through whatever
                // third-party host the previous owner had pointed at.
                userDefaults.remove(.votingConfigOverrideURL)
                userDefaults.remove(.votingCustomChains)
                // Delete the voting SQLite DB so per-round share delegation
                // history, vote records, and stored TX hashes from the
                // previous wallet don't leak across the reset boundary. The
                // file is recreated empty on the next voting flow entry.
                if let documents = FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask)
                    .first {
                    let votingDbURL = documents.appendingPathComponent("voting.sqlite3")
                    try? FileManager.default.removeItem(at: votingDbURL)
                }
                // Belt-and-suspenders: voting drafts and vote records live in
                // the encrypted per-account `votingMetadata` file now, which
                // resetAccount() below removes. This sweep catches any stale
                // plaintext entries from the previous UserDefaults-based
                // storage that hung around on internal dev devices.
                let standardDefaults = UserDefaults.standard
                for key in standardDefaults.dictionaryRepresentation().keys
                    where key.hasPrefix("voting.voteRecord.") || key.hasPrefix("voting.draftVotes.") {
                    standardDefaults.removeObject(forKey: key)
                }
                flexaHandler.signOut()
                userStoredPreferences.removeAll()
                try? readTransactionsStorage.resetZashi()
                if !state.areMetadataPreserved {
                    state.walletAccounts.forEach { account in
                        try? userMetadataProvider.resetAccount(account.account)
                        try? addressBook.resetAccount(account.account)
                        try? votingMetadata.resetAccount(account.account)
                    }
                }
                state.walletAccounts.forEach { account in
                    try? walletStorage.clearEncryptionKeys(account.account)
                }
                state.autoUpdateSwapCandidates.removeAll()
                try? userMetadataProvider.reset()
                votingMetadata.reset()
                state.$walletStatus.withLock { $0 = .none }
                state.$selectedWalletAccount.withLock { $0 = nil }
                state.$walletAccounts.withLock { $0 = [] }
                state.$zashiWalletAccount.withLock { $0 = nil }
                state.$transactionMemos.withLock { $0 = [:] }
                state.$addressBookContacts.withLock { $0 = .empty }
                state.$transactions.withLock { $0 = [] }
                state.path = nil
                if state.appInitializationState != .keysMissing {
                    state = .initial
                }

                return .send(.resetZashiKeychainRequest)
                
            case .resetZashiKeychainRequest:
                return .run { send in
                    do {
                        try walletStorage.resetZashi()
                        await send(.resetZashiFinishProcessing)
                    } catch WalletStorage.KeychainError.unknown(let osStatus) {
                        await send(.resetZashiKeychainFailed(osStatus))
                    }
                }

            case .resetZashiFinishProcessing:
                do {
                    let areKeysPresent = try walletStorage.areKeysPresent()
                    if areKeysPresent {
                        return .send(.resetZashiKeychainFailedWithCorruptedData("Keychain keys are still present"))
                    }
                } catch WalletStorage.WalletStorageError.alreadyImported {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("alreadyImported"))
                } catch WalletStorage.WalletStorageError.uninitializedAddressBookEncryptionKeys {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("uninitializedAddressBookEncryptionKeys"))
                } catch WalletStorage.WalletStorageError.storageError(let error) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("storageError, \(error.localizedDescription)"))
                } catch WalletStorage.WalletStorageError.unsupportedVersion(let version) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("unsupportedVersion \(version)"))
                } catch WalletStorage.WalletStorageError.unsupportedLanguage(let language) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("unsupportedLanguage, \(language)"))
                } catch WalletStorage.KeychainError.decoding {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("decoding"))
                } catch WalletStorage.KeychainError.duplicate {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("duplicate"))
                } catch WalletStorage.KeychainError.encoding {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("encoding"))
                } catch WalletStorage.KeychainError.noDataFound {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("noDataFound"))
                } catch WalletStorage.KeychainError.unknown(let osStatus) {
                    return .send(.resetZashiKeychainFailedWithCorruptedData("unknown, OSStatus \(osStatus)"))
                } catch WalletStorage.WalletStorageError.uninitializedWallet {
                    // this is valid state and what we expect
                } catch {
                    return .send(.resetZashiKeychainFailedWithCorruptedData(error.localizedDescription))
                }

                return .concatenate(
                    .cancel(id: state.SynchronizerCancelId),
                    .send(.initialization(.checkWalletInitialization))
                )

            case .resetZashiKeychainFailedWithCorruptedData(let errMsg):
                for element in state.settingsState.path {
                    if case .resetZashi(var resetZashiState) = element {
                        resetZashiState.isProcessing = false
                        break
                    }
                }
                state.alert = AlertState.wipeKeychainFailed(errMsg)
                return .cancel(id: state.SynchronizerCancelId)

            case .resetZashiKeychainFailed(let osStatus):
                guard state.maxResetZashiAppAttempts == 0 else {
                    state.maxResetZashiAppAttempts -= 1
                    return .send(.resetZashiKeychainRequest)
                }
                state.maxResetZashiAppAttempts = ResetZashiConstants.maxResetZashiAppAttempts
                for element in state.settingsState.path {
                    if case .resetZashi(var resetZashiState) = element {
                        resetZashiState.isProcessing = false
                        break
                    }
                }
                state.alert = AlertState.wipeFailed(osStatus)
                return .cancel(id: state.SynchronizerCancelId)

            case .resetZashiSDKFailed:
                guard state.maxResetZashiSDKAttempts == 0 else {
                    state.maxResetZashiSDKAttempts -= 1
                    return .concatenate(
                        .cancel(id: state.SynchronizerCancelId),
                        .send(.initialization(.resetZashi))
                    )
                }
                state.maxResetZashiSDKAttempts = ResetZashiConstants.maxResetZashiSDKAttempts
                for element in state.settingsState.path {
                    if case .resetZashi(var resetZashiState) = element {
                        resetZashiState.isProcessing = false
                        break
                    }
                }
                state.alert = AlertState.wipeFailed(Int32.max)
                return .cancel(id: state.SynchronizerCancelId)

            case .phraseDisplay(.finishedTapped), .onboarding(.newWalletSuccessfulyCreated):
                state.destinationState.destination = .home
                return .none

            case .onboarding(.createNewWalletTapped):
                if state.appInitializationState == .keysMissing {
                    state.alert = AlertState.existingWallet()
                    return .none
                } else {
                    return .send(.onboarding(.createNewWalletRequested))
                }

            case .initialization(.restoreExistingWallet):
                return .run { send in
                    await send(.onboarding(.dismissDestination))
                    try await mainQueue.sleep(for: .seconds(1))
                    await send(.onboarding(.importExistingWallet))
                }

            case .initialization(.seedValidationResult(let validSeed)):
                if !validSeed {
                    state.alert = AlertState.differentSeed()
                }
                return .none

            case .updateStateAfterConfigUpdate(let walletConfig):
                state.walletConfig = walletConfig
                return .none

            case .initialization(.initializationFailed(let error)):
                state.appInitializationState = .failed
                state.alert = AlertState.initializationFailed(error)
                return .none

            default:
                return .none
            }
        }
    }
    
    private func checkUnavailableService(_ error: Error) -> Bool {
        switch error {
        case ZcashError.serviceGetInfoFailed(.timeOut),
            ZcashError.serviceLatestBlockFailed(.timeOut),
            ZcashError.serviceLatestBlockHeightFailed(.timeOut),
            ZcashError.serviceBlockRangeFailed(.timeOut),
            ZcashError.serviceSubmitFailed(.timeOut),
            ZcashError.serviceFetchTransactionFailed(.timeOut),
            ZcashError.serviceFetchUTXOsFailed(.timeOut),
            ZcashError.serviceBlockStreamFailed(.timeOut),
            ZcashError.serviceSubtreeRootsStreamFailed(.timeOut):
            return true
        default: return false
        }
    }
}
