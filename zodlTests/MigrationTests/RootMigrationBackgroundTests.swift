//
//  RootMigrationBackgroundTests.swift
//  zodlTests
//
//  Covers MOB-1467's Root-level migration BG session decision tree
//  (Features/Root/RootInitialization.swift, `.initialization(.migrationBackgroundSession)` and
//  `.appDelegate(.migrationBackgroundTaskExpired)`): every branch of the spec's ordered tree —
//  plan-broken, sync-required (deferred and not), send (success/success-to-complete/failure/nil),
//  and session expiration — driven with spy `MigrationBGSessionHandle`s (`rawTask: nil`, since a
//  bare `BGProcessingTask` cannot be instantiated in unit tests; see that type's doc comment).
//
//  `.serialized`: same precedent as `RootMigrationRoutingTests` — constructing `Root.State` builds
//  `migrationCoordFlowState = MigrationCoordFlow.State.initial`, which reads the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` key. Uses a plain `Store` (not `TestStore`) with
//  `withDependencies` overrides and `LockIsolated` spies + polling, mirroring
//  `RootMigrationRoutingTests`/`FlexaSecurityTests`.
//

import Foundation
import Testing
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootMigrationBackgroundTests {
    // MARK: - Branch 1: Plan broken

    /// `hasInvalidMigrationTransfers() == true` must post `.planNeedsUpdate` immediately (nil
    /// date), never re-arm (`scheduleNextWindow`/`scheduleFirstWindow` untouched), and complete
    /// the session successfully — recovery's own `scheduleFirstWindow` re-arms after the user
    /// re-creates the plan, not this session.
    @Test func planBrokenViaInvalidTransfersNotifiesWithoutRearming() async {
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.hasInvalidMigrationTransfers = { true }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, date in
                    notifications.withValue { $0.append(notification) }
                    #expect(date == nil)
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(notifications.withValue { $0 } == [MigrationNotification.planNeedsUpdate])
            #expect(scheduleNextWindowCalls.withValue { $0 } == 0)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// Same branch, reached via the state shape instead: `.requiresAttention(.transferExpired)`
    /// must also count as "plan broken", independent of `hasInvalidMigrationTransfers`.
    @Test func planBrokenViaTransferExpiredStateNotifiesWithoutRearming() async {
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.hasInvalidMigrationTransfers = { false }
                $0.sdkSynchronizer.getMigrationState = { MigrationState.requiresAttention(AttentionReason.transferExpired) }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _ in
                    notifications.withValue { $0.append(notification) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(notifications.withValue { $0 } == [MigrationNotification.planNeedsUpdate])
            #expect(scheduleNextWindowCalls.withValue { $0 } == 0)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    // MARK: - Branch 2: Sync required

    /// Within 10 min of a foreground broadcast (`isSyncDeferredAfterBroadcast() == true`): skip
    /// even the sync — re-arm only, complete the session. `state.bgTask` must NOT be touched (no
    /// sync-only session runs).
    @Test func syncRequiredButDeferredAfterBroadcastOnlyRearms() async {
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.isSyncRequiredBeforeNextMigrationTransfer = { true }
                $0.migrationManager.isSyncDeferredAfterBroadcast = { true }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
            #expect(store.state.bgTask == nil)
        }
    }

    /// Not deferred: a sync-only session. Re-arms up front, stashes `state.bgTask =
    /// handle.rawTask`, and kicks the same sync path `power_wifi_sync` uses (`.retryStart`) —
    /// asserted here by actually observing `sdkSynchronizer.start` fire (past `.retryStart`'s
    /// disk-space guard — overridden true, `RootMigrationRoutingTests`' `initialSetupsInvoke
    /// MigrationReconcile` precedent — and its own `latestState().syncStatus.isPrepared` guard,
    /// opened via a mutated `SynchronizerState.zero` with `.upToDate` status). This branch never
    /// completes `handle` itself — that's the existing `synchronizerStateChanged` machinery's job,
    /// exactly as for the `power_wifi_sync` task it mirrors — so `completeCalls` stays empty here.
    @Test func syncRequiredNotDeferredRearmsAndStashesBgTaskForSyncOnlySession() async {
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let startCalls = LockIsolated<[Bool]>([])
        let completeCalls = LockIsolated<[Bool]>([])

        let preparedState: SynchronizerState = {
            var state = SynchronizerState.zero
            state.syncStatus = SyncStatus.upToDate
            return state
        }()

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                // `latestState`/`start` are non-`@DependencyClient` `let` fields on
                // `SDKSynchronizerClient` (no per-field override) — replace the whole client via
                // its `.mocked(...)` builder (same defaults as `.noOp` for every other field), then
                // layer the ordinary `var` overrides below on top.
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                $0.sdkSynchronizer.isSyncRequiredBeforeNextMigrationTransfer = { true }
                $0.migrationManager.isSyncDeferredAfterBroadcast = { false }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { startCalls.withValue { !$0.isEmpty } }

            // Arm.
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            // Stash: `state.bgTask` takes on `handle.rawTask` (`nil` here — the spy handle shape).
            #expect(store.state.bgTask == nil)
            // Kick: `.retryStart` ran all the way to `sdkSynchronizer.start(true)`.
            #expect(startCalls.withValue { $0 } == [true])
            // This branch does not itself complete the handle.
            #expect(completeCalls.withValue { $0 }.isEmpty)
        }
    }

    // MARK: - Branch 3: Send

    /// A successful broadcast that does NOT complete the migration: records the broadcast, posts
    /// `.transferComplete` (never `.migrationComplete`), re-arms, and completes the session.
    @Test func sendSuccessNotCompleteNotifiesTransferCompleteAndRearms() async {
        let recordBroadcastCalls = LockIsolated<Int>(0)
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let cancelAllCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        let progress = MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: Zatoshi(12_345),
            nextTransferReadyAtHeight: nil
        )

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _ in TransferResult.success(txId: "tx-1") }
                $0.sdkSynchronizer.getMigrationState = { MigrationState.inProgress(progress) }
                $0.sdkSynchronizer.getMigrationProgress = { progress }
                $0.migrationManager.recordMigrationBroadcast = { recordBroadcastCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, date in
                    notifications.withValue { $0.append(notification) }
                    #expect(date == nil)
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(recordBroadcastCalls.withValue { $0 } == 1)
            #expect(notifications.withValue { $0 }.count == 1)
            if case let MigrationNotification.transferComplete(number, total, _, remaining)? = notifications.withValue({ $0 }).first {
                #expect(number == 2)
                #expect(total == 5)
                #expect(remaining == Zatoshi(12_345))
            } else {
                Issue.record("Expected a .transferComplete notification, got \(notifications.withValue { $0 })")
            }
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(cancelAllCalls.withValue { $0 } == 0)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// A successful broadcast that DOES complete the migration: posts `.migrationComplete`
    /// (never `.transferComplete`), cancels everything instead of re-arming, and completes the
    /// session.
    @Test func sendSuccessToCompleteNotifiesMigrationCompleteAndCancelsAll() async {
        let recordBroadcastCalls = LockIsolated<Int>(0)
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let cancelAllCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _ in TransferResult.success(txId: "tx-final") }
                $0.sdkSynchronizer.getMigrationState = { MigrationState.complete }
                $0.migrationManager.recordMigrationBroadcast = { recordBroadcastCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _ in
                    notifications.withValue { $0.append(notification) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(recordBroadcastCalls.withValue { $0 } == 1)
            #expect(notifications.withValue { $0 } == [MigrationNotification.migrationComplete])
            #expect(scheduleNextWindowCalls.withValue { $0 } == 0)
            #expect(cancelAllCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// A failed send (`.networkError`) posts `.transferWaiting(number:)` — 1-based, derived from
    /// `getMigrationProgress()?.completedTransfers ?? 0` + 1 — and re-arms.
    @Test func sendFailureNotifiesTransferWaitingAndRearms() async {
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        let progress = MigrationProgress(
            completedTransfers: 3,
            totalTransfers: 6,
            remainingOrchard: Zatoshi(500),
            nextTransferReadyAtHeight: nil
        )

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _ in TransferResult.networkError(retryable: true) }
                $0.sdkSynchronizer.getMigrationProgress = { progress }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _ in
                    notifications.withValue { $0.append(notification) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(notifications.withValue { $0 } == [MigrationNotification.transferWaiting(number: 4)])
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// Nothing pending (`nil` result): re-arm only, no notification, complete the session. (The
    /// LiveKey's own complete-check choke point is what converts a stray re-arm into `cancelAll`
    /// once the migration is actually done — this test only asserts the Root-level tree calls
    /// `scheduleNextWindow`, not what that call internally decides.)
    @Test func nilPendingTransferOnlyRearms() async {
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _ in nil }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _ in
                    notifications.withValue { $0.append(notification) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(notifications.withValue { $0 }.isEmpty)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    // MARK: - Expiration

    /// `.migrationBackgroundTaskExpired` must re-arm — an expired session must never orphan the
    /// wakeup chain (re-submitting with the same identifier REPLACES the pending request, so this
    /// is safe even stacked after branch 2's own up-front re-arm).
    @Test func expiredSessionRearms() async {
        let scheduleNextWindowCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            }

            store.send(.initialization(.appDelegate(.migrationBackgroundTaskExpired)))
            await waitForRootStore { scheduleNextWindowCalls.withValue { $0 } == 1 }

            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(store.state.bgTask == nil)
        }
    }
}

// MARK: - Shared dependency baseline (mirrors RootMigrationRoutingTests.swift)

@MainActor
private func baseNoOpDependencies(_ values: inout DependencyValues) {
    values.databaseFiles = .noOp
    values.derivationTool = .liveValue
    values.diskSpaceChecker = .mockFullDisk
    values.flexaHandler = .noOp
    values.localAuthentication = .mockAuthenticationSucceeded
    values.mainQueue = .immediate
    values.mnemonic = .mock
    values.migrationBGScheduler.backgroundRefreshStatus = { .available }
    values.migrationBGScheduler.scheduleFirstWindow = { }
    values.migrationBGScheduler.scheduleNextWindow = { }
    values.migrationBGScheduler.cancelAll = { }
    values.migrationManager.bannerVariant = { _ in nil }
    values.migrationManager.reentryRoute = { .entry }
    values.migrationManager.migrationMode = { nil }
    values.migrationManager.setMigrationMode = { _ in }
    values.migrationManager.setManualDelivery = { _ in }
    values.migrationManager.setNetworkPrivacyOptions = { _ in }
    values.migrationManager.acknowledgeComplete = { }
    values.migrationManager.recordMigrationBroadcast = { }
    values.migrationManager.reconcile = { }
    values.migrationManager.isSyncDeferredAfterBroadcast = { false }
    values.migrationManager.networkPrivacyOptions = { NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil) }
    values.readTransactionsStorage.resetZashi = { }
    values.sdkSynchronizer = .noOp
    values.userMetadataProvider.load = { _ in }
    values.userNotifications.authorizationStatus = { .notDetermined }
    values.userNotifications.requestAuthorization = { false }
    values.userNotifications.scheduleMigrationNotification = { _, _ in }
    values.userNotifications.cancelMigrationNotifications = { }
    values.userNotifications.clearDeliveredMigrationNotifications = { }
    values.walletStorage = .noOp
    values.zcashSDKEnvironment = .testnet
}

@MainActor
private func waitForRootStore(
    timeoutNanoseconds: UInt64 = 15_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for migration-background Root store state", sourceLocation: sourceLocation)
}
