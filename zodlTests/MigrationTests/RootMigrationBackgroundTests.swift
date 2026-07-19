//
//  RootMigrationBackgroundTests.swift
//  zodlTests
//
//  Covers MOB-1467's Root-level migration BG session decision tree
//  (Features/Root/RootInitialization.swift, `.initialization(.migrationBackgroundSession)` and
//  `.appDelegate(.migrationBackgroundTaskExpired)`): every branch of the spec's ordered tree —
//  the Ironwood-activation gate (MOB-1483), plan-broken, sync-required (deferred and not), send
//  (success/success-to-complete/failure/nil), and session expiration — driven with spy
//  `MigrationBGSessionHandle`s (`rawTask: nil`, since a bare `BGProcessingTask` cannot be
//  instantiated in unit tests; see that type's doc comment).
//
//  `.serialized`: same precedent as `RootMigrationRoutingTests` — constructing `Root.State` builds
//  `migrationCoordFlowState = MigrationCoordFlow.State.initial`, which reads the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` key. Uses a plain `Store` (not `TestStore`) with
//  `withDependencies` overrides and `LockIsolated` spies + polling, mirroring
//  `RootMigrationRoutingTests`/`FlexaSecurityTests`.
//
//  `baseNoOpDependencies` defaults `migrationManager.isIronwoodActivated` to `true` — every branch
//  below except the two Branch 1 (gated) tests exists to exercise post-activation behavior, so
//  that's the natural shared baseline; the gated tests override it back to `false` locally.
//
//  MOB-1496: `migrationBackgroundSessionEffect` now needs a selected account (the real per-account
//  SDK surface) — every test below sets one via `selectedAccountState()` before constructing the
//  `Store`, mirroring `MigrationTransferPlanTests`' `walletAccount(keystone:idByte:)` fixture
//  pattern. Every migration SDK closure override gained the `AccountUUID` parameter the real
//  surface requires.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootMigrationBackgroundTests {
    private static func walletAccount(idByte: UInt8 = 1) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// `Root.State.initial` with a selected account stashed — every migration BG session test
    /// needs one (`migrationBackgroundSessionEffect` reads `state.selectedWalletAccount?.id`).
    private static func selectedAccountState() -> Root.State {
        var state = Root.State.initial
        state.$selectedWalletAccount.withLock { $0 = walletAccount() }
        return state
    }

    // MARK: - Branch 0 (MOB-1496): no selected account

    /// No selected account (e.g. a background-only cold launch that raced wallet initialization):
    /// complete immediately, no work — mirrors the pre-activation branch's shape.
    @Test func noSelectedAccountCompletesSessionWithoutAnyWork() async {
        let executeNextPendingMigrationTransferCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    executeNextPendingMigrationTransferCalls.withValue { $0 += 1 }
                    return nil
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(executeNextPendingMigrationTransferCalls.withValue { $0 } == 0)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    // MARK: - Branch 1 (MOB-1483): Ironwood not yet activated

    /// Pre-activation, the whole decision tree is a no-op: complete the handle immediately, with
    /// zero notification/scheduler/executor calls — none of the later branches (plan-broken,
    /// sync-required, send) are even consulted. `sdkSynchronizer`'s other migration-facing
    /// dependencies are deliberately left at their `baseNoOpDependencies` defaults (which would
    /// otherwise route into "plan broken") to prove the gate short-circuits before any of them
    /// are read.
    @Test func ironwoodNotActivatedCompletesSessionWithoutAnyWork() async {
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let executeNextPendingMigrationTransferCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.isIronwoodActivated = { false }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    executeNextPendingMigrationTransferCalls.withValue { $0 += 1 }
                    return nil
                }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _ in
                    notifications.withValue { $0.append(notification) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(notifications.withValue { $0 }.isEmpty)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 0)
            #expect(executeNextPendingMigrationTransferCalls.withValue { $0 } == 0)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// Mirrors `expiredSessionRearms` below, gated: the synchronizer still stops and the task
    /// still completes/releases exactly as before (expiration handling is unconditional), but the
    /// wakeup chain must NOT be kept alive — no `scheduleNextWindow` call, since branch 1 of the
    /// session tree never arms it in the first place pre-activation.
    @Test func ironwoodNotActivatedExpiredSessionDoesNotRearm() async {
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let stopCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    stop: { stopCalls.withValue { $0 += 1 } }
                )
                $0.migrationManager.isIronwoodActivated = { false }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            }

            store.send(.initialization(.appDelegate(.migrationBackgroundTaskExpired)))
            await waitForRootStore { stopCalls.withValue { $0 } == 1 }

            #expect(stopCalls.withValue { $0 } == 1)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 0)
            #expect(store.state.bgTask == nil)
        }
    }

    // MARK: - Branch 2: Plan broken

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
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.hasInvalidMigrationTransfers = { _ in true }
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
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.hasInvalidMigrationTransfers = { _ in false }
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.requiresAttention(MigrationAttentionReason.transferExpired) }
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

    // MARK: - Branch 3: Sync required

    /// MOB-1496 (W3): the SDK's own wallet-scope privacy gate (`isMigrationSyncBlocked() == true`)
    /// replaces the retired app-side `isSyncDeferredAfterBroadcast` flag: skip even the sync —
    /// re-arm only, complete the session. `state.bgTask` must NOT be touched (no sync-only session
    /// runs).
    @Test func syncRequiredButMigrationSyncBlockedOnlyRearms() async {
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.isSyncRequiredBeforeNextMigrationTransfer = { _ in true }
                $0.sdkSynchronizer.isMigrationSyncBlocked = { true }
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
    /// MOB-1496: the decision tree now sends `.migrationBackgroundSyncOnly(handle)` back into the
    /// reducer to do the `state.bgTask` stash (effects can't mutate `state` directly) — observed
    /// here exactly the same way (`store.state.bgTask`), since that's an implementation detail of
    /// how the stash happens, not what's being asserted.
    ///
    /// MOB-1496 (W3): `isMigrationSyncBlocked` is explicit `false` here (redundant with
    /// `.mocked(...)`'s own built-in default, kept for clarity) — it gates BOTH this branch's own
    /// skip check AND `.retryStart`'s new proactive check downstream of `.migrationBackgroundSyncOnly`;
    /// this test's `startCalls` assertion below proves neither one blocks the sync-only kick.
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
            let store = Store(initialState: Self.selectedAccountState()) {
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
                $0.sdkSynchronizer.isSyncRequiredBeforeNextMigrationTransfer = { _ in true }
                $0.sdkSynchronizer.isMigrationSyncBlocked = { false }
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

    // MARK: - Branch 4: Send

    /// A successful broadcast that does NOT complete the migration: records the broadcast, posts
    /// `.transferComplete` (never `.migrationComplete`), re-arms, and completes the session.
    @Test func sendSuccessNotCompleteNotifiesTransferCompleteAndRearms() async {
        // MOB-1496 (W2): the write-point for the persisted-schedule storage; `reconcile()` runs too
        // (single-account semantics here; W5 fans this whole tree out per-account).
        let recordTransferBroadcastCalls = LockIsolated<[(AccountUUID?, MigrationTransferResult)]>([])
        let reconcileCalls = LockIsolated<Int>(0)
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
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-1") }
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(progress) }
                $0.sdkSynchronizer.getMigrationProgress = { _ in progress }
                $0.migrationManager.recordTransferBroadcast = { accountUUID, result in
                    recordTransferBroadcastCalls.withValue { $0.append((accountUUID, result)) }
                }
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
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

            #expect(recordTransferBroadcastCalls.withValue { $0 }.count == 1)
            #expect(recordTransferBroadcastCalls.withValue { $0 }.first?.1 == MigrationTransferResult.success(txId: "tx-1"))
            #expect(reconcileCalls.withValue { $0 } == 1)
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

    /// MOB-1496 (W4): the BG executor's options for `executeNextPendingMigrationTransfer` come from
    /// `migrationManager.migrationNetworkOptions(_:)`, read AT EXECUTE TIME — not any stale/local
    /// value. A mocked sentinel must reach the broadcast call unchanged.
    @Test func sendReadsOptionsFromMigrationNetworkOptionsAtExecuteTime() async {
        let sentinel = MigrationNetworkPrivacyOptions(
            useTor: true,
            submissionEndpoint: LightWalletEndpoint(address: "sentinel.example.com", port: 443, secure: true, streamingCallTimeoutInMillis: 0)
        )
        let receivedOptions = LockIsolated<[MigrationNetworkPrivacyOptions]>([])
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.migrationNetworkOptions = { _ in sentinel }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, options in
                    receivedOptions.withValue { $0.append(options) }
                    return MigrationTransferResult.success(txId: "tx-1")
                }
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.complete }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(receivedOptions.withValue { $0 } == [sentinel])
        }
    }

    /// A successful broadcast that DOES complete the migration: posts `.migrationComplete`
    /// (never `.transferComplete`), cancels everything instead of re-arming, and completes the
    /// session.
    @Test func sendSuccessToCompleteNotifiesMigrationCompleteAndCancelsAll() async {
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let cancelAllCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-final") }
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.complete }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _ in
                    notifications.withValue { $0.append(notification) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

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
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.networkError(retryable: true) }
                $0.sdkSynchronizer.getMigrationProgress = { _ in progress }
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
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
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

    /// MOB-1496: a throwing broadcast attempt for any OTHER reason (NOT
    /// `ZcashError.migrationRecordFailedAfterBroadcast` — see
    /// `recordFailedAfterBroadcastBehavesExactlyLikeSuccessDuringBackgroundSend` below for that
    /// dedicated case) is treated like the `nil` "nothing executed" case: re-arm, no notification
    /// (there's no definite outcome to report), complete the session.
    @Test func throwingExecuteNextPendingTransferOnlyRearmsWithoutNotifying() async {
        struct SomeError: Error { }
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in throw SomeError() }
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

    /// MOB-1496 (W3): `ZcashError.migrationRecordFailedAfterBroadcast` — the broadcast DID land,
    /// only the engine's own recording of it failed — is routed through the SAME handling as a
    /// `.success` result (with an unknown txId): `recordTransferBroadcast` fires, `reconcile()`
    /// runs, a `.transferComplete` notification is posted (this fixture's `getMigrationState`
    /// stays `.inProgress`, never `.complete`), and the session re-arms rather than being treated
    /// as a `networkError` that would imply a re-send is needed.
    @Test func recordFailedAfterBroadcastBehavesExactlyLikeSuccessDuringBackgroundSend() async {
        struct RecordingFailure: Error { }
        let recordTransferBroadcastCalls = LockIsolated<[(AccountUUID?, MigrationTransferResult)]>([])
        let reconcileCalls = LockIsolated<Int>(0)
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let cancelAllCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        let progress = MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 4,
            remainingOrchard: Zatoshi(999),
            nextTransferReadyAtHeight: nil
        )

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    throw ZcashError.migrationRecordFailedAfterBroadcast(RecordingFailure())
                }
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(progress) }
                $0.sdkSynchronizer.getMigrationProgress = { _ in progress }
                $0.migrationManager.recordTransferBroadcast = { accountUUID, result in
                    recordTransferBroadcastCalls.withValue { $0.append((accountUUID, result)) }
                }
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _ in
                    notifications.withValue { $0.append(notification) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            // The broadcast landed — recorded with the empty-txId placeholder (storage maps it to
            // `nil`), never treated as a networkError that would need a re-send.
            #expect(recordTransferBroadcastCalls.withValue { $0 }.count == 1)
            #expect(recordTransferBroadcastCalls.withValue { $0 }.first?.0 == Self.walletAccount().id)
            #expect(recordTransferBroadcastCalls.withValue { $0 }.first?.1 == MigrationTransferResult.success(txId: ""))
            #expect(reconcileCalls.withValue { $0 } == 1)
            #expect(notifications.withValue { $0 }.count == 1)
            if case MigrationNotification.transferComplete? = notifications.withValue({ $0 }).first {
                // Exact payload fields already covered by `sendSuccessNotCompleteNotifiesTransferCompleteAndRearms`.
            } else {
                Issue.record("Expected a .transferComplete notification, got \(notifications.withValue { $0 })")
            }
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(cancelAllCalls.withValue { $0 } == 0)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    // MARK: - Expiration

    /// `.migrationBackgroundTaskExpired` must re-arm — an expired session must never orphan the
    /// wakeup chain (re-submitting with the same identifier REPLACES the pending request, so this
    /// is safe even stacked after branch 3's own up-front re-arm). Post-activation (the
    /// `baseNoOpDependencies` default) — see `ironwoodNotActivatedExpiredSessionDoesNotRearm`
    /// above for the pre-activation counterpart, which must NOT re-arm.
    @Test func expiredSessionRearms() async {
        let scheduleNextWindowCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
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

    // MARK: - MOB-1496 (W2): Root-level migration-reconcile triggers

    /// `.synchronizerStateChanged` reconciles migration state on the EDGE into `.upToDate` — a
    /// still-syncing tick does nothing, reaching `.upToDate` reconciles once, and a SECOND tick
    /// that's already `.upToDate` (no new edge) must not reconcile again.
    @Test func synchronizerStateChangedReconcilesOnceOnEdgeIntoUpToDateNotOnEveryTick() async {
        let reconcileCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            }

            // Still syncing: no edge into `.upToDate` yet -> no reconcile.
            var syncingState = SynchronizerState.zero
            syncingState.syncStatus = SyncStatus.syncing(0.5, false)
            store.send(.synchronizerStateChanged(syncingState.redacted))

            // Reaches `.upToDate`: the EDGE -> reconciles once.
            var upToDateState = SynchronizerState.zero
            upToDateState.syncStatus = SyncStatus.upToDate
            store.send(.synchronizerStateChanged(upToDateState.redacted))

            await waitForRootStore { reconcileCalls.withValue { $0 } == 1 }

            // A SECOND tick still `.upToDate` (no new edge, no reconcile storm) — settle briefly
            // and confirm the count never moves past 1.
            store.send(.synchronizerStateChanged(upToDateState.redacted))
            try? await Task.sleep(nanoseconds: 200_000_000)

            #expect(reconcileCalls.withValue { $0 } == 1)
        }
    }

    /// Leaving `.upToDate` and coming back re-arms the edge — a second genuine transition
    /// reconciles again.
    @Test func synchronizerStateChangedReconcilesAgainAfterLeavingAndReturningToUpToDate() async {
        let reconcileCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            }

            var upToDateState = SynchronizerState.zero
            upToDateState.syncStatus = SyncStatus.upToDate
            store.send(.synchronizerStateChanged(upToDateState.redacted))
            await waitForRootStore { reconcileCalls.withValue { $0 } == 1 }

            var syncingState = SynchronizerState.zero
            syncingState.syncStatus = SyncStatus.syncing(0.2, false)
            store.send(.synchronizerStateChanged(syncingState.redacted))

            store.send(.synchronizerStateChanged(upToDateState.redacted))
            await waitForRootStore { reconcileCalls.withValue { $0 } == 2 }
        }
    }

    /// `.migrationSyncGateChanged` reconciles only when `sdkSynchronizer.isMigrationSyncBlocked()`
    /// actually changes from its last-observed value — the first observed value (`false`, matching
    /// `Root.State.lastMigrationSyncGateBlocked`'s own default) doesn't reconcile, a genuine flip
    /// does, repeating the same value doesn't, and flipping back reconciles again.
    @Test func migrationSyncGateChangedReconcilesOnlyOnActualChange() async {
        let reconcileCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            }

            // Matches the state's own default -> no reconcile.
            store.send(.migrationSyncGateChanged(false))
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(reconcileCalls.withValue { $0 } == 0)

            // A genuine flip to `true` -> reconciles.
            store.send(.migrationSyncGateChanged(true))
            await waitForRootStore { reconcileCalls.withValue { $0 } == 1 }

            // Repeating the SAME value -> no additional reconcile.
            store.send(.migrationSyncGateChanged(true))
            try? await Task.sleep(nanoseconds: 200_000_000)
            #expect(reconcileCalls.withValue { $0 } == 1)

            // Flips back to `false` -> reconciles again.
            store.send(.migrationSyncGateChanged(false))
            await waitForRootStore { reconcileCalls.withValue { $0 } == 2 }
        }
    }

    // MARK: - MOB-1496 (W3): `.retryStart` deferral (SDK-owned broadcast->sync privacy gate)

    /// `preparedState` opens `.retryStart`'s own `isPrepared` guard (mirrors
    /// `syncRequiredNotDeferredRearmsAndStashesBgTaskForSyncOnlySession`'s fixture above).
    private static let preparedState: SynchronizerState = {
        var state = SynchronizerState.zero
        state.syncStatus = SyncStatus.upToDate
        return state
    }()

    /// Proactive half: `isMigrationSyncBlocked() == true` is checked BEFORE ever calling `start` —
    /// `start` itself must never fire, no alert is surfaced, and the deferral flag flips.
    @Test func retryStartProactivelyDefersWhenMigrationSyncBlockedWithoutCallingStartOrAlerting() async {
        let startCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { Self.preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                $0.sdkSynchronizer.isMigrationSyncBlocked = { true }
            }

            store.send(.initialization(.retryStart))
            await waitForRootStore { store.state.syncDeferredByMigrationGate }

            #expect(startCalls.withValue { $0 }.isEmpty)
            #expect(store.state.alert == nil)
            #expect(store.state.syncDeferredByMigrationGate == true)
        }
    }

    /// Reactive half: the proactive check passes (gate reads open), but `start` itself races the
    /// gate and throws `ZcashError.migrationSyncBlocked` — same silent deferral, no alert.
    @Test func retryStartReactivelyDefersWhenStartThrowsMigrationSyncBlockedWithoutAlerting() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { Self.preparedState },
                    start: { _ in throw ZcashError.migrationSyncBlocked }
                )
                $0.sdkSynchronizer.isMigrationSyncBlocked = { false }
            }

            store.send(.initialization(.retryStart))
            await waitForRootStore { store.state.syncDeferredByMigrationGate }

            #expect(store.state.alert == nil)
            #expect(store.state.syncDeferredByMigrationGate == true)
        }
    }

    /// Resume: `.migrationSyncGateChanged(false)` while deferred clears the flag and replays
    /// `.retryStart` — which, with the gate now genuinely open, runs the normal chain all the way
    /// to `sdkSynchronizer.start(true)`, exactly once.
    @Test func migrationSyncGateChangedToFalseResumesADeferredStartExactlyOnceAndClearsTheFlag() async {
        let startCalls = LockIsolated<[Bool]>([])

        var initialState = Self.selectedAccountState()
        initialState.syncDeferredByMigrationGate = true
        // As if the gate had been observed blocked earlier (the realistic precondition for a
        // deferred start to exist at all) — a `.migrationSyncGateChanged(false)` from this baseline
        // is a genuine transition, not swallowed by the action's own dedupe guard.
        initialState.lastMigrationSyncGateBlocked = true

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { Self.preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                $0.sdkSynchronizer.isMigrationSyncBlocked = { false }
            }

            store.send(.migrationSyncGateChanged(false))
            await waitForRootStore { startCalls.withValue { !$0.isEmpty } }

            #expect(startCalls.withValue { $0 } == [true])
            #expect(store.state.syncDeferredByMigrationGate == false)
            #expect(store.state.lastMigrationSyncGateBlocked == false)
        }
    }

    /// Guard against loops: the flag clears BEFORE `.retryStart` replays, so if that re-entry's own
    /// fresh gate read is STILL blocked (a race), it just re-defers — `start` never fires, and
    /// nothing here re-sends `.migrationSyncGateChanged` on its own, so there's no runaway loop.
    @Test func stillBlockedReEntryReDefersWithoutLooping() async {
        let startCalls = LockIsolated<[Bool]>([])
        let reconcileCalls = LockIsolated<Int>(0)

        var initialState = Self.selectedAccountState()
        initialState.syncDeferredByMigrationGate = true
        initialState.lastMigrationSyncGateBlocked = true

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { Self.preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                // `.migrationSyncGateChanged(false)`'s OWN parameter says "unblocked", but
                // `.retryStart`'s proactive re-check reads the gate FRESH — still blocked here,
                // simulating a race between the stream tick and the actual SDK state.
                $0.sdkSynchronizer.isMigrationSyncBlocked = { true }
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            }

            store.send(.migrationSyncGateChanged(false))
            await waitForRootStore { reconcileCalls.withValue { $0 } == 1 }
            // Let any further (erroneous, if a loop existed) effects settle.
            try? await Task.sleep(nanoseconds: 300_000_000)

            #expect(startCalls.withValue { $0 }.isEmpty)
            #expect(store.state.syncDeferredByMigrationGate == true)
            #expect(reconcileCalls.withValue { $0 } == 1)
        }
    }

    /// Every OTHER `start` error keeps its existing `.synchronizerStartFailed` handling —
    /// specifically, it must NEVER be mistaken for the migration gate and flip the deferral flag.
    @Test func retryStartUnrelatedErrorsNeverSetTheMigrationDeferralFlag() async {
        struct SomeOtherError: Error { }
        let startCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { Self.preparedState },
                    start: { _ in
                        startCalls.withValue { $0.append(true) }
                        throw SomeOtherError()
                    }
                )
                $0.sdkSynchronizer.isMigrationSyncBlocked = { false }
            }

            store.send(.initialization(.retryStart))
            await waitForRootStore { startCalls.withValue { !$0.isEmpty } }
            // Let the catch-all's `.synchronizerStartFailed` send complete.
            try? await Task.sleep(nanoseconds: 200_000_000)

            #expect(startCalls.withValue { $0 } == [true])
            #expect(store.state.syncDeferredByMigrationGate == false)
            #expect(store.state.alert == nil)
        }
    }

    // MARK: - MOB-1496 (W3 review fix B): resume-after-broadcast-stop via the shared flag

    /// Review scenario: a foreground broadcast stopped sync (`SDKSynchronizerClient
    /// .stopSyncBeforeMigrationBroadcast()` flips the shared `migrationStoppedSyncForBroadcast`
    /// flag), but no start was ever proactively/reactively deferred — `syncDeferredByMigrationGate`
    /// stays `false` because nobody happened to call `.retryStart` while the gate was blocked (e.g.
    /// the user was parked on the note-split progress screen). A genuine gate true->false
    /// transition must still resume sync exactly once and clear the shared flag, even though W3's
    /// OWN deferral flag was never set.
    @Test func migrationSyncGateChangedResumesWhenBroadcastStopFlagSetEvenWithoutADeferredStart() async {
        let startCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
            $migrationStoppedSyncForBroadcast.withLock { $0 = true }

            var initialState = Self.selectedAccountState()
            initialState.lastMigrationSyncGateBlocked = true

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { Self.preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                $0.sdkSynchronizer.isMigrationSyncBlocked = { false }
            }

            store.send(.migrationSyncGateChanged(false))
            await waitForRootStore { startCalls.withValue { !$0.isEmpty } }

            #expect(startCalls.withValue { $0 } == [true])
            #expect(store.state.syncDeferredByMigrationGate == false)
            #expect(migrationStoppedSyncForBroadcast == false)
        }
    }

    /// Existing behavior preserved: a genuine gate transition with NEITHER the W3 deferred-start
    /// flag NOR the new broadcast-stop flag set only reconciles — `.retryStart` must never fire.
    @Test func migrationSyncGateChangedGenuineTransitionWithNeitherFlagNeverCallsRetryStart() async {
        let startCalls = LockIsolated<[Bool]>([])
        let reconcileCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Self.selectedAccountState()
            initialState.lastMigrationSyncGateBlocked = true

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { Self.preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                $0.sdkSynchronizer.isMigrationSyncBlocked = { false }
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            }

            store.send(.migrationSyncGateChanged(false))
            await waitForRootStore { reconcileCalls.withValue { $0 } == 1 }
            // Let any further (erroneous, if `.retryStart` fired anyway) effects settle.
            try? await Task.sleep(nanoseconds: 300_000_000)

            #expect(startCalls.withValue { $0 }.isEmpty)
            #expect(reconcileCalls.withValue { $0 } == 1)
            #expect(store.state.syncDeferredByMigrationGate == false)
        }
    }

    /// The pre-flight-failure edge (brief item B): a broadcast stops sync but never reaches the
    /// SDK's actual broadcast attempt (e.g. a Tor bootstrap failure), so the gate never flips
    /// blocked — no genuine `true->false` transition will EVER arrive for it. Covered by checking
    /// the shared flag independent of the dedupe guard: the NEXT `.migrationSyncGateChanged(false)`
    /// to reach Root at all (e.g. a later successful start's own seed read — already `false`, so
    /// ordinarily swallowed by the dedupe as "no change") still resumes and clears the flag, without
    /// also re-running `reconcile()` (this is not a genuine change).
    @Test func migrationSyncGateChangedNonGenuineArrivalWithBroadcastStopFlagSetStillResumes() async {
        let startCalls = LockIsolated<[Bool]>([])
        let reconcileCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
            $migrationStoppedSyncForBroadcast.withLock { $0 = true }

            // `lastMigrationSyncGateBlocked` defaults to `false` (Root.State.initial) — the gate
            // was never observed blocked, matching the pre-flight-failure scenario exactly.
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { Self.preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                $0.sdkSynchronizer.isMigrationSyncBlocked = { false }
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            }

            store.send(.migrationSyncGateChanged(false))
            await waitForRootStore { startCalls.withValue { !$0.isEmpty } }

            #expect(startCalls.withValue { $0 } == [true])
            #expect(migrationStoppedSyncForBroadcast == false)
            #expect(reconcileCalls.withValue { $0 } == 0)
            #expect(store.state.lastMigrationSyncGateBlocked == false)
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
    values.migrationManager.isIronwoodActivated = { true }
    values.migrationManager.reentryRoute = { .entry }
    values.migrationManager.migrationMode = { nil }
    values.migrationManager.setMigrationMode = { _ in }
    values.migrationManager.setManualDelivery = { _ in }
    values.migrationManager.setNetworkPrivacyOptions = { _ in }
    values.migrationManager.acknowledgeComplete = { }
    values.migrationManager.reconcile = { }
    values.migrationManager.recordSyncCompleted = { }
    values.migrationManager.migrationNetworkOptions = { _ in
        MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
    }
    values.migrationManager.activeNetworkSnapshots = { [] }
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
