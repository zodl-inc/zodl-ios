//
//  RootInitialization.swift
//  Zashi
//
//  Created by Lukáš Korba on 01.12.2022.
//

import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import BackgroundTasks
@preconcurrency import ZcashLightClientKit

/// Wraps a `BGProcessingTask` for the migration BG session decision tree (MOB-1467). A bare
/// `BGProcessingTask` cannot be instantiated in unit tests, so the AppDelegate-facing
/// `.migrationBackgroundTask(BGProcessingTask)` action is immediately wrapped into this handle
/// and forwarded to `.migrationBackgroundSession`, the action the reducer's tree — and every
/// `RootMigrationBackgroundTests` case — actually drives. `rawTask` is `nil` in tests (spy
/// handles); `complete` is always a real, observable closure (`LockIsolated` spy in tests, real
/// `task.setTaskCompleted(success:)` in production via the AppDelegate-side `live` initializer).
/// `@unchecked Sendable`: `BGProcessingTask` (a system framework type, `@preconcurrency`-imported
/// above) is safe to hand across the effect boundary here the same way the existing
/// `power_wifi_sync`/`scheduler` tasks already are (`Root.State.bgTask`, `AppDelegate`'s
/// `task.expirationHandler`) — it is only ever read or completed, never mutated concurrently.
struct MigrationBGSessionHandle: @unchecked Sendable {
    let rawTask: BGProcessingTask?
    let complete: @Sendable (Bool) -> Void

    init(rawTask: BGProcessingTask?, complete: @escaping @Sendable (Bool) -> Void) {
        self.rawTask = rawTask
        self.complete = complete
    }

    /// Production convenience: wraps a live task, completing it via its own
    /// `setTaskCompleted(success:)` when the session decides it's done.
    static func live(_ task: BGProcessingTask) -> MigrationBGSessionHandle {
        MigrationBGSessionHandle(rawTask: task, complete: { task.setTaskCompleted(success: $0) })
    }
}

extension MigrationBGSessionHandle: Equatable {
    /// `complete` is a closure and can't be compared — identity of the wrapped task (or "both
    /// nil", the spy-handle shape every test uses) is the only meaningful equality here.
    static func == (lhs: MigrationBGSessionHandle, rhs: MigrationBGSessionHandle) -> Bool {
        lhs.rawTask === rhs.rawTask
    }
}

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
        case staleWalletDatabaseHealed
        case initialSetups
        case initializationFailed(ZcashError)
        case initializationSuccessfullyDone
        case loadedWalletAccounts([WalletAccount])
        case migrationBackgroundSession(MigrationBGSessionHandle)
        /// MOB-1496: the migration BG decision tree's "sync required, not deferred" branch needs to
        /// mutate `state.bgTask` — effects can't do that directly, so the async decision tree
        /// (`migrationBackgroundSessionEffect`'s `.run`) sends this back into the reducer instead of
        /// setting it inline the way the pre-real-SDK synchronous version did.
        case migrationBackgroundSyncOnly(MigrationBGSessionHandle)
        /// MOB-1496 (W3): `.retryStart`'s `.run` effect can't mutate `state` directly — sent back
        /// into the reducer (proactively, before ever calling `start`, or reactively after `start`
        /// throws `ZcashError.migrationSyncBlocked`) to set `state.syncDeferredByMigrationGate`.
        case migrationSyncDeferredByGate
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
                // MOB-1466: reconcile migration state on every foreground entry (idempotent
                // `initializeMigrationPostUpgrade()` + the stale-acknowledge reset) so a banner/
                // re-entry route that changed while backgrounded is picked up promptly. Banner
                // freshness itself stays reactive (SmartBanner's own subscription + walk) — this
                // is deliberately the minimal Root-side hook the spec calls for.
                let reconcileEffect: Effect<Action> = .run { [migrationManager] _ in await migrationManager.reconcile() }
                // MOB-1467: opening the app clears stale migration notifications from Notification
                // Center — the banner/re-entry route now carries the current state. Delivered ONLY:
                // a pending manual-mode "ready to send" reminder must survive foreground entry.
                let clearDeliveredEffect: Effect<Action> = .run { [userNotifications] _ in
                    await userNotifications.clearDeliveredMigrationNotifications()
                }
                if state.isLockedInKeychainUnavailableState || !sdkSynchronizer.latestState().syncStatus.isPrepared {
                    return .merge(reconcileEffect, clearDeliveredEffect, .send(.initialization(.initialSetups)))
                } else {
                    return .merge(reconcileEffect, clearDeliveredEffect, .send(.initialization(.retryStart)))
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

            case .initialization(.appDelegate(.migrationBackgroundTask(let task))):
                // Immediately wrapped so the decision tree below (`.migrationBackgroundSession`)
                // never touches a raw `BGProcessingTask` directly — that type can't be
                // instantiated in unit tests, so `RootMigrationBackgroundTests` drives
                // `.migrationBackgroundSession` with spy handles instead (`rawTask: nil`).
                return .send(.initialization(.migrationBackgroundSession(MigrationBGSessionHandle.live(task))))

            case .initialization(.migrationBackgroundSession(let handle)):
                return migrationBackgroundSessionEffect(state: &state, handle: handle)

            case .initialization(.migrationBackgroundSyncOnly(let handle)):
                // Sync-only session: never broadcasts. Re-arm up front, then reuse the
                // `power_wifi_sync` handler's own sync-kick verbatim (`state.bgTask` + `.retryStart`)
                // — `synchronizerStateChanged` completes `state.bgTask` on
                // `.upToDate`/`.stopped`/`.error` exactly as it does for that task. `handle.rawTask`
                // may be `nil` in tests (spy handles); that completion is then a no-op, which is
                // acceptable — this branch is asserted on the arm + kick + stash, not on task
                // completion.
                state.bgTask = handle.rawTask
                return .concatenate(
                    .run { [migrationBGScheduler] _ in await migrationBGScheduler.scheduleNextWindow() },
                    .send(.initialization(.retryStart))
                )

            case .initialization(.appDelegate(.migrationBackgroundTaskExpired)):
                // Mirror `didEnterBackground`'s expiration handling for the existing
                // `power_wifi_sync` task: stop the synchronizer and release `state.bgTask` (a
                // sync-only session may have set it), then re-arm — an expired session must never
                // orphan the wakeup chain. Re-submitting with the same identifier REPLACES the
                // pending request, so this is safe even if branch 3's up-front re-arm already ran
                // in this same session.
                sdkSynchronizer.stop()
                state.bgTask?.setTaskCompleted(success: false)
                state.bgTask = nil
                // MOB-1483: pre-activation, branch 1 of the decision tree below never arms in the
                // first place — skip the re-arm here too, for the same reason: there's nothing to
                // keep alive, so let the wakeup chain lapse rather than resurrect a stale one.
                if !migrationManager.isIronwoodActivated() {
                    return .none
                }
                return .run { [migrationBGScheduler] _ in await migrationBGScheduler.scheduleNextWindow() }

            case .initialization(.appDelegate(.migrationNotificationTapped)):
                // Same gate as `checkBackupPhraseValidation` uses for `isAtDeeplinkWarningScreen`:
                // `.initialized` is set exactly once, at that checkpoint, so it doubles as "Home
                // is up" here. If we're not there yet (cold start still in flight), stash the
                // request — `checkBackupPhraseValidation` fires it once initialization completes.
                guard state.appInitializationState == .initialized else {
                    state.pendingMigrationDeepLink = true
                    return .none
                }
                return migrationNotificationTappedRoutingEffect(state: &state)

            case .synchronizerStateChanged(let latestState):
                let snapshot = SyncStatusSnapshot.snapshotFor(state: latestState.data.syncStatus)

                // MOB-1496 (W2): reconcile migration state on the EDGE into `.upToDate` — not on
                // every tick while already synced (would storm `reconcile()` on every subsequent
                // tick at the tip). Piggybacks on this existing `stateStream()` subscription
                // (`.registerForSynchronizersUpdate` below) rather than opening a second one.
                // MOB-1496 (W3): `recordSyncCompleted()` re-keys the app's send gate off this SAME
                // edge — once per completed sync, not per tick, exactly like `reconcile()` beside
                // it (see `MigrationManagerClient.recordSyncCompleted`'s doc).
                let didJustReachUpToDate = snapshot.syncStatus == .upToDate && !state.wasSyncUpToDateForMigration
                state.wasSyncUpToDateForMigration = snapshot.syncStatus == .upToDate
                let migrationReconcileEffect: Effect<Action> = didJustReachUpToDate
                    ? .run { [migrationManager] _ in
                        migrationManager.recordSyncCompleted()
                        await migrationManager.reconcile()
                      }
                    : .none

                guard let account = state.selectedWalletAccount else {
                    return migrationReconcileEffect
                }

                // update flexa balance
                if let accountBalance = latestState.data.accountsBalances[account.id] {
                    let shieldedBalance = accountBalance.shieldedSpendableValue
                    let shieldedWithPendingBalance = accountBalance.shieldedTotal()

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

                // handle BCGTask
                guard state.bgTask != nil else {
                    return .merge(migrationReconcileEffect, .send(.initialization(.checkRestoreWalletFlag(snapshot.syncStatus))))
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
                        migrationReconcileEffect,
                        .cancel(id: state.CancelStateId),
                        .cancel(id: state.CancelTransactionsStateId)
                    )
                }

                return .merge(migrationReconcileEffect, .send(.initialization(.checkRestoreWalletFlag(snapshot.syncStatus))))

            // MOB-1496 (W2): gate-flip migration-reconcile trigger — see
            // `.registerForSynchronizersUpdate`'s `migrationSyncGateEffect` for how this is fed.
            // MOB-1496 (W3): also the resume point for `.retryStart`'s deferral — a flip to
            // NOT-blocked while a start was deferred clears the flag and replays `.retryStart` so
            // the normal chain resumes identically to an ungated launch. The flag clears BEFORE
            // the replay, so a still-blocked re-entry (the proactive check in `.retryStart` reads
            // the gate fresh) just re-defers rather than looping.
            case .migrationSyncGateChanged(let isBlocked):
                guard state.lastMigrationSyncGateBlocked != isBlocked else { return .none }
                state.lastMigrationSyncGateBlocked = isBlocked
                let reconcileEffect: Effect<Action> = .run { [migrationManager] _ in await migrationManager.reconcile() }

                guard !isBlocked, state.syncDeferredByMigrationGate else {
                    return reconcileEffect
                }

                state.syncDeferredByMigrationGate = false
                return .merge(reconcileEffect, .send(.initialization(.retryStart)))

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
                    // MOB-1496 (W3): proactive half of the SDK's post-broadcast privacy gate —
                    // checked before ever calling `start`, so a still-blocked window never even
                    // attempts it: no error, no alert, nothing downstream of a successful start
                    // runs. `.migrationSyncGateChanged(false)` (below) replays `.retryStart` once
                    // the gate clears, so the normal chain (start -> registerForSynchronizersUpdate
                    // -> refreshAutomaticServer) resumes identically to an ungated launch.
                    if await sdkSynchronizer.isMigrationSyncBlocked() {
                        await send(.initialization(.migrationSyncDeferredByGate))
                        return
                    }
                    do {
                        try await sdkSynchronizer.start(true)
                        if state.bgTask != nil {
                            LoggerProxy.event("BGTask synchronizer.start() PASSED")
                        }
                        await send(.initialization(.registerForSynchronizersUpdate))
                        await send(.refreshAutomaticServer)
                    } catch ZcashError.migrationSyncBlocked {
                        // MOB-1496 (W3): reactive half — `start` itself raced the gate (blocked in
                        // the window between the proactive check above and the SDK's own attempt).
                        // Same silent deferral; every other error keeps its existing handling below.
                        await send(.initialization(.migrationSyncDeferredByGate))
                    } catch {
                        if state.bgTask != nil {
                            LoggerProxy.event("BGTask synchronizer.start() failed \(error.toZcashError())")
                        }
                        await send(.initialization(.synchronizerStartFailed(error.toZcashError())))
                    }
                }

            case .initialization(.migrationSyncDeferredByGate):
                state.syncDeferredByMigrationGate = true
                return .none

            case .initialization(.registerForSynchronizersUpdate):
                let stateStreamEffect = Effect.publisher {
                    sdkSynchronizer.stateStream()
                        .throttle(for: .seconds(0.2), scheduler: mainQueue, latest: true)
                        .map { $0.redacted }
                        .map(Root.Action.synchronizerStateChanged)
                }
                .cancellable(id: state.CancelStateId, cancelInFlight: true)

                // MOB-1496 (W2): gate-flip migration-reconcile trigger. An initial
                // `isMigrationSyncBlocked()` read (its stream seeds a conservative `false`
                // synchronously, corrected asynchronously — see `migrationSyncBlockedStream`'s
                // doc) is `.concatenate`d ahead of the live stream itself (its own first/seed
                // emission dropped, since the initial read already has the real value), under one
                // cancel id so both start/stop together with this subscription's own lifetime.
                let migrationSyncGateEffect = Effect.concatenate(
                    .run { [sdkSynchronizer] send in
                        await send(.migrationSyncGateChanged(await sdkSynchronizer.isMigrationSyncBlocked()))
                    },
                    Effect.publisher {
                        sdkSynchronizer.migrationSyncBlockedStream()
                            .dropFirst()
                            .map(Root.Action.migrationSyncGateChanged)
                    }
                )
                .cancellable(id: state.migrationSyncGateCancelId, cancelInFlight: true)

                if state.bgTask != nil {
                    return .merge(stateStreamEffect, migrationSyncGateEffect)
                } else {
                    return .merge(
                        stateStreamEffect,
                        migrationSyncGateEffect,
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
                if !diskSpaceChecker.hasEnoughFreeSpaceForSync() {
                    state.destinationState.preNotEnoughFreeSpaceDestination = state.destinationState.internalDestination
                    return .send(.destination(.updateDestination(.notEnoughFreeSpace)))
                } else if let preNotEnoughFreeSpaceDestination = state.destinationState.preNotEnoughFreeSpaceDestination {
                    state.destinationState.internalDestination = preNotEnoughFreeSpaceDestination
                    state.destinationState.preNotEnoughFreeSpaceDestination = nil
                }
                // TODO: [#524] finish all the wallet events according to definition, https://github.com/Electric-Coin-Company/zashi-ios/issues/524
                LoggerProxy.event(".appDelegate(.didFinishLaunching)")
                /// We need to fetch data from keychain, in order to be 100% sure the keychain can be read we delay the check a bit
                return .merge(
                    // MOB-1466: reconcile migration state once per launch — off the hot path
                    // (`initializeMigrationPostUpgrade()` is idempotent), so it never blocks or
                    // reorders the existing wallet-initialization sequence below.
                    .run { [migrationManager] _ in await migrationManager.reconcile() },
                    .send(.initialization(.checkWalletInitialization))
                )

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
                do {
                    let storedWallet: StoredWallet
                    do {
                        storedWallet = try walletStorage.exportWallet()
                    } catch {
                        return .send(.destination(.updateDestination(.osStatusError)))
                    }
                    let birthday = storedWallet.birthday?.value() ?? zcashSDKEnvironment.latestCheckpoint()
                    try mnemonic.isValid(storedWallet.seedPhrase.value())
                    let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                    
                    return .run { send in
                        do {
                            // [#1755] The SDK derives the init flow from the birthday: a brand-new wallet
                            // passes nil (the SDK picks a reorg-safe recent height), restore/existing pass
                            // the stored birthday. `walletMode` is no longer handed to the SDK.
                            let result = try await sdkSynchronizer.prepareWith(
                                seedBytes,
                                walletMode == .newWallet ? nil : birthday,
                                String(localizable: .accountsZashi),
                                String(localizable: .accountsZashi).lowercased()
                            )

                            let healed: Bool
                            switch result {
                            case .seedRequired:
                                throw ZcashError.synchronizerNotPrepared
                            case .seedNotRelevant, .success:
                                healed = try await Root.reconcileWalletDatabaseWithSeed(
                                    knownStale: result == .seedNotRelevant,
                                    seedBytes: seedBytes,
                                    isSeedRelevant: { try await sdkSynchronizer.isSeedRelevantToAnyDerivedAccount($0) },
                                    hasSeedDerivedAccount: {
                                        let accounts = try await sdkSynchronizer.walletAccounts()
                                        return accounts.contains { $0.zip32AccountIndex != nil }
                                    },
                                    clearDeviceScopedState: {
                                        Root.clearDeviceScopedWalletState(
                                            userDefaults: userDefaults,
                                            flexaHandler: flexaHandler,
                                            userStoredPreferences: userStoredPreferences,
                                            readTransactionsStorage: readTransactionsStorage
                                        )
                                    },
                                    wipe: {
                                        guard let wipePublisher = sdkSynchronizer.wipe() else {
                                            throw Root.WalletDatabaseHealError.wipeUnavailable
                                        }
                                        for try await _ in wipePublisher.values { }
                                    },
                                    reprepare: {
                                        let reprepareResult = try await sdkSynchronizer.prepareWith(
                                            seedBytes,
                                            birthday,
                                            String(localizable: .accountsZashi),
                                            String(localizable: .accountsZashi).lowercased()
                                        )
                                        guard reprepareResult == .success else {
                                            throw ZcashError.synchronizerNotPrepared
                                        }
                                    }
                                )
                            }
                            if healed {
                                await send(.initialization(.staleWalletDatabaseHealed))
                            }

                            await send(.fetchTransactionsForTheSelectedAccount)
                            /// The TCA spins an async Task in `fetchTransactionsForTheSelectedAccount` and it's needed to run
                            /// before next code here therefore Task is asleep for 0.01s. The purpose is also to not block the main thread
                            /// so await of mainQueue is not used.
                            try? await Task.sleep(nanoseconds: 10_000_000)

                            let walletAccounts = try await sdkSynchronizer.walletAccounts()
                            await send(.initialization(.loadedWalletAccounts(walletAccounts)))
                            await send(.resolveMetadataEncryptionKeys)
                            await send(.loadUserMetadata)

                            try await sdkSynchronizer.start(false)

                            var selectedAccount: WalletAccount?
                            
                            for account in walletAccounts {
                                if account.vendor == .zcash {
                                    selectedAccount = account
                                }
                            }

                            exchangeRate.refreshExchangeRateUSD()

                            if let account = selectedAccount {
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
                        } catch Root.WalletDatabaseHealError.reprepareFailed {
                            // The stale database was already wiped before re-prepare failed, so
                            // there is no database left to leave the user staring at a dead-end
                            // `initializationFailed` alert for (that only recovers on relaunch).
                            // Recompute wallet-initialization state in-session instead: with the
                            // database gone this resolves to `.filesMissing`, which re-enters the
                            // existing restore path.
                            await send(.initialization(.checkWalletInitialization))
                        } catch {
                            await send(.initialization(.initializationFailed(error.toZcashError())))
                        }
                    }
                } catch {
                    return .send(.initialization(.initializationFailed(error.toZcashError())))
                }

            case .initialization(.staleWalletDatabaseHealed):
                state.isRestoringWallet = true
                userDefaults.setValue(true, Constants.udIsRestoringWallet)
                state.$walletStatus.withLock { $0 = .restoring }
                state.alert = AlertState.staleWalletDatabaseHealed()
                return .none

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
                do {
                    let storedWallet: StoredWallet
                    do {
                        storedWallet = try walletStorage.exportWallet()
                    } catch {
                        return .send(.destination(.updateDestination(.osStatusError)))
                    }
                    try mnemonic.isValid(storedWallet.seedPhrase.value())
                    let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                    
                    return .run { [walletAccounts = state.walletAccounts] send in
                        do {
                            
                            for account in walletAccounts {
                                let userMetadataEncryptionKeys = try? walletStorage.exportUserMetadataEncryptionKeys(account.account)
                                if userMetadataEncryptionKeys == nil {
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
                                        // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                                    }
                                }
                            }
                        }
                    }
                } catch { }
                return .none
                
            case .initialization(.checkBackupPhraseValidation):
                do {
                    let _ = try walletStorage.exportWallet()
                } catch {
                    return .send(.destination(.updateDestination(.osStatusError)))
                }

                state.appInitializationState = .initialized
                let isAtDeeplinkWarningScreen = state.destinationState.destination == .deeplinkWarning

                // MOB-1467: this is the checkpoint that already knows "we just reached Home from
                // cold start" — mirrors `isAtDeeplinkWarningScreen` immediately above: snapshot +
                // clear the pending flag now, fire its routing in the same delayed effect that
                // sends Home, right alongside it.
                let hasPendingMigrationDeepLink = state.pendingMigrationDeepLink
                state.pendingMigrationDeepLink = false

                return .run { send in
                    // Delay the splash overlay dismissal
                    try await mainQueue.sleep(for: .seconds(0.5))
                    if !isAtDeeplinkWarningScreen {
                        await send(.destination(.updateDestination(Root.DestinationState.Destination.home)))
                    }
                    if hasPendingMigrationDeepLink {
                        await send(.initialization(.appDelegate(.migrationNotificationTapped)))
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
                Root.clearDeviceScopedWalletState(
                    userDefaults: userDefaults,
                    flexaHandler: flexaHandler,
                    userStoredPreferences: userStoredPreferences,
                    readTransactionsStorage: readTransactionsStorage
                )
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

                // TODO: [#1627] validate whether this code makes sense
                // https://github.com/zodl-inc/zodl-ios/issues/1627
//                if state.appInitializationState == .keysMissing && state.onboardingState.isImportingWallet {
//                    state.appInitializationState = .uninitialized
//                    return .cancel(id: SynchronizerCancelId)
//                } else if state.appInitializationState == .keysMissing && state.onboardingState.destination == .createNewWallet {
//                    state.appInitializationState = .uninitialized
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.onboarding(.createNewWalletRequested))
//                    )
//                } else {
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.initialization(.checkWalletInitialization))
//                    )
//                }

                // TODO: [#1627] this might need to be recreated
                // https://github.com/zodl-inc/zodl-ios/issues/1627
//                if state.appInitializationState == .keysMissing && state.onboardingState.destination == .importExistingWallet {
//                    state.appInitializationState = .uninitialized
//                    return .cancel(id: SynchronizerCancelId)
//                } else if state.appInitializationState == .keysMissing && state.onboardingState.destination == .createNewWallet {
//                    state.appInitializationState = .uninitialized
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.onboarding(.createNewWalletRequested))
//                    )
//                } else {
//                    return .concatenate(
//                        .cancel(id: SynchronizerCancelId),
//                        .send(.initialization(.checkWalletInitialization))
//                    )
//                }
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

    // MARK: - MOB-1467: Migration BG session decision tree

    /// The migration BG session's decision tree (spec "Root: BG session decision tree"), checked
    /// in this exact order:
    /// 0. No selected account (MOB-1496: e.g. a background-only cold launch that raced wallet
    ///    initialization) — nothing to evaluate against; complete without notifying/re-arming so a
    ///    later session (once an account is selected) re-attempts.
    /// 1. Ironwood not yet activated (MOB-1483) — there is no migration work to do
    ///    pre-activation. Complete the session immediately: no notification, no executor call,
    ///    and deliberately no re-arm — a task chain armed before activation (or before this gate
    ///    landed) is left to lapse here rather than kept alive; the next arm happens once
    ///    `isIronwoodActivated()` flips true (self-healing).
    /// 2. Plan broken (invalid transfer, or expired-attention state) — notify, do NOT re-arm.
    /// 3. Sync required before the next transfer — either skip (the SDK's own
    ///    `isMigrationSyncBlocked()` wallet-scope privacy gate, MOB-1496 W3) or run a sync-only
    ///    session that never broadcasts, reusing the existing `power_wifi_sync` sync-kick
    ///    machinery verbatim (`state.bgTask` + `.retryStart`; `synchronizerStateChanged` completes
    ///    the task on `.upToDate`/`.stopped`/`.error`).
    /// 4. Otherwise, send: `executeNextPendingMigrationTransfer` and notify/re-arm per outcome. A
    ///    thrown `ZcashError.migrationRecordFailedAfterBroadcast` (MOB-1496 W3) is routed through
    ///    the SAME landed-broadcast handling as a `.success` result — the broadcast DID land, only
    ///    the engine's own recording of it failed, so the session must not re-send or treat it as a
    ///    `networkError`.
    /// Every branch except the sync-only session completes `handle` itself (that session's
    /// completion is the existing `synchronizerStateChanged` machinery, exactly like the
    /// `power_wifi_sync` task it mirrors).
    ///
    /// MOB-1496: every migration SDK read here is `async throws` (the real per-account surface) —
    /// the whole tree now runs inside one `.run`, and the "sync required, not deferred" branch
    /// sends `.migrationBackgroundSyncOnly(handle)` back into the reducer to mutate `state.bgTask`
    /// (effects can't mutate `state` directly). Every SDK read is wrapped so a thrown error
    /// degrades to "treat as false/skip" and completes the session rather than crashing a
    /// background launch; `single-account semantics preserved in W1` — a later task fans this
    /// decision tree out per-account.
    private func migrationBackgroundSessionEffect(
        state: inout Root.State,
        handle: MigrationBGSessionHandle
    ) -> Effect<Root.Action> {
        if !migrationManager.isIronwoodActivated() {
            return .run { _ in handle.complete(true) }
        }

        guard let accountUUID = state.selectedWalletAccount?.id else {
            LoggerProxy.event("BGTask migration session: no selected account yet, completing.")
            return .run { _ in handle.complete(true) }
        }

        return .run { [migrationManager, sdkSynchronizer, migrationBGScheduler, userNotifications, accountUUID] send in
            // [MOB-1496] Shared by the `.success` outcome below and the
            // `ZcashError.migrationRecordFailedAfterBroadcast` catch clause — the broadcast landed
            // either way (only the engine's own recording of it failed in the latter case), so both
            // paths persist the sent record, reconcile, and notify/re-arm (or cancel-on-complete)
            // identically. Mirrors the same rationale `MigrationSendingStore`/
            // `MigrationNoteSplitStore` already apply for their own foreground broadcasts.
            func handleLandedBroadcast(_ result: MigrationTransferResult) async {
                await migrationManager.recordTransferBroadcast(accountUUID, result)
                await migrationManager.reconcile()

                let migrationState = try? await sdkSynchronizer.getMigrationState(accountUUID)
                if migrationState == MigrationState.complete {
                    await userNotifications.scheduleMigrationNotification(MigrationNotification.migrationComplete, nil)
                    await migrationBGScheduler.cancelAll()
                } else {
                    let notification = await Self.transferCompleteNotification(accountUUID: accountUUID, sdkSynchronizer: sdkSynchronizer)
                    await userNotifications.scheduleMigrationNotification(notification, nil)
                    await migrationBGScheduler.scheduleNextWindow()
                }
            }

            let isPlanBroken: Bool
            do {
                let migrationState = try await sdkSynchronizer.getMigrationState(accountUUID)
                let hasInvalid = try await sdkSynchronizer.hasInvalidMigrationTransfers(accountUUID)
                isPlanBroken = hasInvalid
                    || migrationState == MigrationState.requiresAttention(MigrationAttentionReason.transferExpired)
            } catch {
                LoggerProxy.error("BGTask migration session: plan-broken check failed \(error)")
                handle.complete(true)
                return
            }

            if isPlanBroken {
                await userNotifications.scheduleMigrationNotification(MigrationNotification.planNeedsUpdate, nil)
                handle.complete(true)
                return
            }

            let isSyncRequired: Bool
            do {
                isSyncRequired = try await sdkSynchronizer.isSyncRequiredBeforeNextMigrationTransfer(accountUUID)
            } catch {
                LoggerProxy.error("BGTask migration session: sync-required check failed \(error)")
                handle.complete(true)
                return
            }

            if isSyncRequired {
                // MOB-1496 (W3): the SDK now owns the broadcast->sync direction outright — skip the
                // sync session while it reports the wallet-scope privacy gate blocked (same outward
                // behavior the retired app-side `isSyncDeferredAfterBroadcast` flag produced).
                if await sdkSynchronizer.isMigrationSyncBlocked() {
                    await migrationBGScheduler.scheduleNextWindow()
                    handle.complete(true)
                    return
                }

                await send(.initialization(.migrationBackgroundSyncOnly(handle)))
                return
            }

            let options = migrationManager.networkPrivacyOptions()
            do {
                let result = try await sdkSynchronizer.executeNextPendingMigrationTransfer(accountUUID, options)

                switch result {
                case .success:
                    // [MOB-1496] W2: persist the sent record + reconcile (this op's success is one
                    // of `reconcile()`'s triggers) — single-account semantics here, matching the
                    // rest of this decision tree (W5 fans the whole tree out per-account).
                    if let result {
                        await handleLandedBroadcast(result)
                    }

                case .networkError, .invalidNote, .expired:
                    let progress = (try? await sdkSynchronizer.getMigrationProgress(accountUUID)) ?? nil
                    let nextNumber = (progress?.completedTransfers ?? 0) + 1
                    await userNotifications.scheduleMigrationNotification(MigrationNotification.transferWaiting(number: nextNumber), nil)
                    await migrationBGScheduler.scheduleNextWindow()

                case nil:
                    await migrationBGScheduler.scheduleNextWindow()
                }
            } catch ZcashError.migrationRecordFailedAfterBroadcast(_) {
                // [MOB-1496] The broadcast DID land; only the engine's own recording of it failed —
                // route through the SAME handling as a `.success` result, with an unknown txId
                // (`MigrationScheduleStorage` maps an empty string to `nil`). The BG session must
                // not re-send (this isn't a networkError) and must not skip the notification/re-arm
                // a landed transfer deserves. Mirrors `MigrationSendingStore`/`MigrationNoteSplitStore`'s
                // identical foreground rationale for this same error.
                await handleLandedBroadcast(MigrationTransferResult.success(txId: ""))
            } catch {
                // A throwing broadcast attempt for any OTHER reason is not itself a definite
                // outcome to notify about — treat it like the `nil` "nothing executed" case: re-arm
                // the next window and let that session's own outcome (or the engine's self-heal)
                // settle it, without a possibly-wrong notification.
                LoggerProxy.error("BGTask migration session: executeNextPendingMigrationTransfer failed \(error)")
                await migrationBGScheduler.scheduleNextWindow()
            }

            handle.complete(true)
        }
    }

    /// Builds the `.transferComplete` notification payload from the freshly-updated migration
    /// state: `number`/`total`/`remaining` from `getMigrationProgress()`, `nextInHours` from the
    /// same cadence-window derivation `MigrationBGSchedulerClient`'s `arm(margin:)` uses (§8.3's
    /// next-window margin, `estimateTimestamp` as the preferred source), rounded to hours.
    private static func transferCompleteNotification(
        accountUUID: AccountUUID,
        sdkSynchronizer: SDKSynchronizerClient
    ) async -> MigrationNotification {
        // Flatten the `try?`-around-an-Optional-returning-throwing-function double-optional
        // (`MigrationProgress??`) down to a plain `MigrationProgress?` — a read failure and "no
        // progress in flight" both mean the same thing to this notification (fall back to 0/0/zero).
        let progressResult = try? await sdkSynchronizer.getMigrationProgress(accountUUID)
        let progress = progressResult ?? nil

        let preferredExecutableAt = progress?.nextTransferReadyAtHeight.flatMap { height in
            sdkSynchronizer.estimateTimestamp(height).map { Date(timeIntervalSince1970: $0) }
        }
        let now = Date()
        let window = MigrationCadence.window(
            margin: MigrationCadence.nextWindowMargin,
            preferredExecutableAt: preferredExecutableAt,
            now: now
        )
        let nextInHours = Int((window.timeIntervalSince(now) / 3600).rounded())

        return MigrationNotification.transferComplete(
            number: progress?.completedTransfers ?? 0,
            total: progress?.totalTransfers ?? 0,
            nextInHours: nextInHours,
            remaining: progress?.remainingOrchard ?? Zatoshi.zero
        )
    }

    // MARK: - MOB-1467: Migration notification-tap deep link

    /// Exactly the SmartBanner-tap routing (`RootCoordinator`'s
    /// `.home(.smartBanner(.migrationScreenRequested))`): fresh flow state, open the migration
    /// path. Shared by the immediate (Home already up) and deferred (fired from
    /// `checkBackupPhraseValidation` once initialization reaches Home) call sites.
    private func migrationNotificationTappedRoutingEffect(state: inout Root.State) -> Effect<Root.Action> {
        state.migrationCoordFlowState = MigrationCoordFlow.State.initial
        state.path = Root.State.Path.migrationCoordFlow
        return .none
    }
}
