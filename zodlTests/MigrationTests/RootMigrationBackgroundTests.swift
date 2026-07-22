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
//  MOB-1496 (W5): the tree now fans out over EVERY wallet account (selected first, then the rest
//  in stored order), classifying each independently before resolving to a single session action —
//  see `migrationBackgroundSessionEffect`'s own doc for the ordered classification/resolution.
//  Two consequences for every single-account test below:
//  (1) `getMigrationState`'s default (`.noOp`'s `.notStarted`) now short-circuits an account straight
//      into "nothing to do" BEFORE the plan-broken/sync-required checks ever run — every test whose
//      account needs to reach one of those checks now sets `getMigrationState` to a non-`.complete`/
//      `.notStarted`/`.readyToPropose` state explicitly (`baseNoOpDependencies` deliberately leaves
//      the bare default alone — see its own doc for why).
//  (2) A brand-new probe, `rescheduleOverdueMigrationTransfer`, gates broadcast candidacy (its
//      non-nil return is what makes an account a candidate at all — see the tree's own "height-due
//      semantics" doc). `.noOp`'s own bare default (`{ _ in nil }`) means NO account is ever a
//      broadcast candidate — every single-account "Branch 4: Send" test below sets a non-nil
//      proposal explicitly. (Fix-wave: an earlier `baseNoOpDependencies` override defaulted this to
//      a non-nil sentinel instead, which accidentally erased ALL coverage of the nil-probe/
//      `activeNoCandidate` path — reverted back to the safe-by-default nil, with the override
//      pushed to each test that actually needs a candidate.) A test exercising multiple accounts'
//      relative ordering overrides it explicitly per account too.
//  New tests below (`MARK: - Branch 1.5/4.5 (MOB-1496 W5): multi-account fan-out`) cover the
//  multi-account resolution itself: earliest-height/overdue/tie-break candidate selection,
//  per-account `migrationNetworkOptions` threading, sync-needed deferring every broadcast, plan-
//  broken not blocking a healthy account's broadcast, and the all-complete/one-active cancelAll
//  split. Further additions (`MARK: - Fix wave`) pin the review's findings: the nil-probe/
//  `activeNoCandidate` path itself, the invariant that a winner completing must NOT `cancelAll`/
//  announce `.migrationComplete` while another account is still active (finding 1), its sibling
//  legitimate-cancelAll case, and the planner-level `readyToPropose` nuance.
//

import Foundation
import Testing
@preconcurrency import Combine
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
    /// R8-T4 (#7): also `.initialized` — `Root.State.initial`'s own default (`.uninitialized`,
    /// from `Root.State.init`'s default parameter) would otherwise hit
    /// `.migrationBackgroundSession`'s NEW stash guard and never reach the decision tree at all.
    /// Every test below that specifically wants the PRE-init stash behavior overrides this back to
    /// `.uninitialized` afterward (see the R8-T4 #7 section).
    private static func selectedAccountState() -> Root.State {
        var state = Root.State.initial
        state.appInitializationState = InitializationState.initialized
        state.$selectedWalletAccount.withLock { $0 = walletAccount() }
        return state
    }

    /// MOB-1496 (W5): a second (Keystone-flavored) account for the multi-account fan-out tests —
    /// distinct `idByte` from `walletAccount()`'s default (1).
    private static func secondAccount(idByte: UInt8 = 2) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Keystone",
                keySource: String(localizable: .accountsKeystone).lowercased(),
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// `Root.State.initial` with TWO accounts stashed: `walletAccount()` selected, `secondAccount()`
    /// the rest of the wallet's accounts — the account-set order the tree fans out over (selected
    /// first, then stored order). R8-T4 (#7): also `.initialized` — see `selectedAccountState()`'s
    /// twin doc.
    private static func twoAccountState() -> Root.State {
        var state = Root.State.initial
        state.appInitializationState = InitializationState.initialized
        let selected = walletAccount()
        let second = secondAccount()
        state.$selectedWalletAccount.withLock { $0 = selected }
        state.$walletAccounts.withLock { $0 = [selected, second] }
        return state
    }

    /// A minimal "account has an active run" progress payload — used wherever a test just needs to
    /// escape the tree's `.complete`/`.notStarted`/`.readyToPropose` "nothing to do" bucket without
    /// caring about the progress fields themselves. `nonisolated`: referenced from inside
    /// `@Sendable` dependency-closure overrides below, which run off the main actor —
    /// `MigrationProgress` is itself `Sendable`, so no `(unsafe)` is needed.
    private nonisolated static let placeholderProgress = MigrationProgress(
        completedTransfers: 0,
        totalTransfers: 1,
        remainingOrchard: Zatoshi(1_000),
        nextTransferReadyAtHeight: nil
    )

    /// A minimal `rescheduleOverdueMigrationTransfer` proposal at the given height — the tree only
    /// reads `nextExecutableAfterHeight` off this (via the classification's `broadcastCandidate`
    /// case); the other fields are placeholders. `nonisolated`: see `placeholderProgress`'s doc.
    private nonisolated static func proposal(nextExecutableAfterHeight: BlockHeight) -> MigrationTransferProposal {
        MigrationTransferProposal(
            id: "t-\(nextExecutableAfterHeight)",
            amount: Zatoshi(1_000),
            anchorHeight: 0,
            nextExecutableAfterHeight: nextExecutableAfterHeight,
            expiryHeight: nextExecutableAfterHeight + 1_000
        )
    }

    // MARK: - Branch 0 (MOB-1496): no selected account

    /// No selected account (e.g. a background-only cold launch that raced wallet initialization):
    /// complete immediately, no send/notification work — mirrors the pre-activation branch's shape.
    /// R8-T4 (#7): re-targeted — this branch now ALSO re-arms (`scheduleNextWindow`), since
    /// `.migrationBackgroundSession`'s own stash guard (see its doc) means it only ever runs
    /// POST-hydration now; no path out of the decision tree may consume the BG request without
    /// re-arming (see `migrationBackgroundSessionEffect`'s updated doc for branches 0/1).
    @Test func noSelectedAccountCompletesSessionWithoutAnyWorkButStillRearms() async {
        let executeNextPendingMigrationTransferCalls = LockIsolated<Int>(0)
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Root.State.initial
            // R8-T4 (#7): `.initialized` — see `selectedAccountState()`'s twin doc; this test
            // deliberately uses bare `Root.State.initial` (no selected account) rather than that
            // helper, so it needs the SAME override applied directly here.
            initialState.appInitializationState = InitializationState.initialized

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    executeNextPendingMigrationTransferCalls.withValue { $0 += 1 }
                    return nil
                }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(executeNextPendingMigrationTransferCalls.withValue { $0 } == 0)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    // MARK: - Branch 1 (MOB-1483): Ironwood not yet activated

    /// Pre-activation, the whole decision tree short-circuits before any later branch (plan-broken,
    /// sync-required, send) is even consulted — zero notification/executor calls, and
    /// `sdkSynchronizer`'s other migration-facing dependencies are deliberately left at their
    /// `baseNoOpDependencies` defaults (which would otherwise route into "plan broken") to prove
    /// that. R8-T4 (#7): re-targeted — this branch now ALSO re-arms; see the twin comment on
    /// `noSelectedAccountCompletesSessionWithoutAnyWorkButStillRearms` above for why (this branch's
    /// own updated doc in `migrationBackgroundSessionEffect` has the full rationale: pre-fix, a cold
    /// launch racing this exact check could read a not-yet-`prepare`d `isIronwoodActivated()` as
    /// false and permanently kill the wakeup chain by completing without re-arming; the new
    /// `.migrationBackgroundSession` stash guard means this branch only runs post-hydration now, so
    /// re-arming unconditionally is safe and removes that dependency entirely).
    @Test func ironwoodNotActivatedCompletesSessionWithoutAnyWorkButStillRearms() async {
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
                $0.userNotifications.scheduleMigrationNotification = { notification, _, _ in
                    notifications.withValue { $0.append(notification) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(notifications.withValue { $0 }.isEmpty)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
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
        let notifiedAccountUUIDs = LockIsolated<[String?]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                // MOB-1496 (W5): escape the "nothing to do" bucket (`.noOp`'s bare `.notStarted`
                // default) so classification actually reaches the `hasInvalidMigrationTransfers`
                // check below — an active run is the realistic shape for this signal anyway (the
                // SDK's own doc: "spendable Orchard remains but no scheduled transfer covers it").
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.hasInvalidMigrationTransfers = { _ in true }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, date, accountUUID in
                    notifications.withValue { $0.append(notification) }
                    notifiedAccountUUIDs.withValue { $0.append(accountUUID) }
                    #expect(date == nil)
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(notifications.withValue { $0 } == [MigrationNotification.planNeedsUpdate])
            // R8-T5 (S4-a): the `.planNeedsUpdate` notification is attributed to the (single, here)
            // plan-broken account.
            #expect(notifiedAccountUUIDs.withValue { $0 } == [Data(Self.walletAccount().id.id).hexEncodedString()])
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
                $0.userNotifications.scheduleMigrationNotification = { notification, _, _ in
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
                // MOB-1496 (W5): escape the "nothing to do" bucket — `.requiresAttention
                // (.syncRequiredBeforeNext)` is the thematically exact state for this test, and (like
                // every OTHER `MigrationAttentionReason` besides `.transferExpired`/`.invalidTransfer`)
                // does not also trip the plan-broken state check.
                $0.sdkSynchronizer.getMigrationState = { _ in
                    MigrationState.requiresAttention(MigrationAttentionReason.syncRequiredBeforeNext)
                }
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
                // MOB-1496 (W5): escape the "nothing to do" bucket — see the twin comment in
                // `syncRequiredButMigrationSyncBlockedOnlyRearms` above.
                $0.sdkSynchronizer.getMigrationState = { _ in
                    MigrationState.requiresAttention(MigrationAttentionReason.syncRequiredBeforeNext)
                }
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
        let notifiedAccountUUIDs = LockIsolated<[String?]>([])
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
                // MOB-1496 (fix-wave): `rescheduleOverdueMigrationTransfer` now defaults to nil
                // (IMPORTANT-2) — escape it explicitly so classification reaches the broadcast at all.
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-1") }
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(progress) }
                $0.sdkSynchronizer.getMigrationProgress = { _ in progress }
                $0.migrationManager.recordTransferBroadcast = { accountUUID, result in
                    recordTransferBroadcastCalls.withValue { $0.append((accountUUID, result)) }
                }
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, date, accountUUID in
                    notifications.withValue { $0.append(notification) }
                    notifiedAccountUUIDs.withValue { $0.append(accountUUID) }
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
            // R8-T5 (S4-a): attributed to the account whose broadcast just landed.
            #expect(notifiedAccountUUIDs.withValue { $0 } == [Data(Self.walletAccount().id.id).hexEncodedString()])
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
                // MOB-1496 (fix-wave): `rescheduleOverdueMigrationTransfer` now defaults to nil
                // (IMPORTANT-2) — escape it explicitly so classification reaches the broadcast at all.
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.migrationManager.migrationNetworkOptions = { _ in sentinel }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, options in
                    receivedOptions.withValue { $0.append(options) }
                    return MigrationTransferResult.success(txId: "tx-1")
                }
                // MOB-1496 (W5): must NOT be `.complete` — the tree now reads `getMigrationState`
                // BEFORE ever attempting a send (the "nothing to do" classification bucket), so a
                // `.complete` account here would never reach `executeNextPendingMigrationTransfer`
                // at all. `.inProgress` is read a second time too (inside `handleLandedBroadcast`'s
                // post-send check) — staying non-`.complete` there as well is fine, this test only
                // cares about the options threading, not the post-send notification.
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(receivedOptions.withValue { $0 } == [sentinel])
        }
    }

    /// A successful broadcast that DOES complete the migration, with NO remainder pending (the
    /// once-per-transition evaluation inside `reconcile()` found genuinely nothing left — see
    /// `MigrationManagerImpl.evaluateMigrationRemainder`'s doc): posts `.migrationComplete` (never
    /// `.transferComplete`), cancels everything instead of re-arming, and completes the session.
    /// Its remainder-pending sibling is
    /// `sendSuccessToCompleteWithRemainderPendingNotifiesMigrationBatchCompleteAndCancelsAll` below.
    @Test func sendSuccessToCompleteNotifiesMigrationCompleteAndCancelsAll() async {
        let notifications = LockIsolated<[MigrationNotification]>([])
        let notifiedAccountUUIDs = LockIsolated<[String?]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let cancelAllCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])
        // MOB-1496 (W5): `getMigrationState` is now read TWICE for a landed broadcast — once during
        // pre-flight classification (must NOT be `.complete`, or the account is classified "nothing
        // to do" and the send is never attempted at all) and once inside `handleLandedBroadcast`'s
        // post-send check (WANTS `.complete`, to prove this send finished the run). A call-counted
        // stub models exactly that: in-progress the first time, complete from then on.
        let getMigrationStateCallCount = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                // MOB-1496 (fix-wave): `rescheduleOverdueMigrationTransfer` now defaults to nil
                // (IMPORTANT-2) — escape it explicitly so classification reaches the broadcast at all.
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-final") }
                $0.sdkSynchronizer.getMigrationState = { _ in
                    let call = getMigrationStateCallCount.withValue { count -> Int in
                        count += 1
                        return count
                    }
                    return call == 1 ? MigrationState.inProgress(Self.placeholderProgress) : MigrationState.complete
                }
                // MOB-1496: explicit (`baseNoOpDependencies` already defaults this to `false`) —
                // pins THIS test as the remainder-false half of the completion matrix.
                $0.migrationManager.isMigrationRemainderPending = { _ in false }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _, accountUUID in
                    notifications.withValue { $0.append(notification) }
                    notifiedAccountUUIDs.withValue { $0.append(accountUUID) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(notifications.withValue { $0 } == [MigrationNotification.migrationComplete])
            // R8-T5 (S4-a): attributed to the account whose broadcast just completed the migration.
            #expect(notifiedAccountUUIDs.withValue { $0 } == [Data(Self.walletAccount().id.id).hexEncodedString()])
            #expect(scheduleNextWindowCalls.withValue { $0 } == 0)
            #expect(cancelAllCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// The remainder-pending sibling of `sendSuccessToCompleteNotifiesMigrationCompleteAndCancelsAll`
    /// above: an otherwise IDENTICAL landed broadcast that completes the stored run, but where the
    /// once-per-transition remainder evaluation found a genuinely non-empty fresh plan
    /// (`isMigrationRemainderPending == true`). MOB-1496: posts `.migrationBatchComplete` instead of
    /// `.migrationComplete` — and still `cancelAll`s (nothing is broadcastable until the user
    /// consents to a NEW run; that run's own confirm/commit is what re-arms scheduling).
    @Test func sendSuccessToCompleteWithRemainderPendingNotifiesMigrationBatchCompleteAndCancelsAll() async {
        let notifications = LockIsolated<[MigrationNotification]>([])
        let notifiedAccountUUIDs = LockIsolated<[String?]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let cancelAllCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])
        let getMigrationStateCallCount = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-final") }
                $0.sdkSynchronizer.getMigrationState = { _ in
                    let call = getMigrationStateCallCount.withValue { count -> Int in
                        count += 1
                        return count
                    }
                    return call == 1 ? MigrationState.inProgress(Self.placeholderProgress) : MigrationState.complete
                }
                $0.migrationManager.isMigrationRemainderPending = { _ in true }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _, accountUUID in
                    notifications.withValue { $0.append(notification) }
                    notifiedAccountUUIDs.withValue { $0.append(accountUUID) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(notifications.withValue { $0 } == [MigrationNotification.migrationBatchComplete])
            #expect(notifiedAccountUUIDs.withValue { $0 } == [Data(Self.walletAccount().id.id).hexEncodedString()])
            #expect(scheduleNextWindowCalls.withValue { $0 } == 0)
            #expect(cancelAllCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// A failed send (`.networkError`) posts `.transferWaiting(number:)` — 1-based, derived from
    /// `getMigrationProgress()?.completedTransfers ?? 0` + 1 — and re-arms.
    @Test func sendFailureNotifiesTransferWaitingAndRearms() async {
        let notifications = LockIsolated<[MigrationNotification]>([])
        let notifiedAccountUUIDs = LockIsolated<[String?]>([])
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
                // MOB-1496 (W5): escape the "nothing to do" bucket — reuses the SAME `progress` this
                // test already mocks `getMigrationProgress` with, so both reads describe one
                // consistent in-progress account.
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(progress) }
                // MOB-1496 (fix-wave): `rescheduleOverdueMigrationTransfer` now defaults to nil
                // (IMPORTANT-2) — escape it explicitly so classification reaches the broadcast at all.
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.networkError(retryable: true) }
                $0.sdkSynchronizer.getMigrationProgress = { _ in progress }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _, accountUUID in
                    notifications.withValue { $0.append(notification) }
                    notifiedAccountUUIDs.withValue { $0.append(accountUUID) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(notifications.withValue { $0 } == [MigrationNotification.transferWaiting(number: 4)])
            // R8-T5 (S4-a): attributed to the account this failed broadcast attempt was for.
            #expect(notifiedAccountUUIDs.withValue { $0 } == [Data(Self.walletAccount().id.id).hexEncodedString()])
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
                // MOB-1496 (W5): escape the "nothing to do" bucket so classification reaches the
                // broadcast-candidate probe at all.
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                // MOB-1496 (fix-wave): `rescheduleOverdueMigrationTransfer` now defaults to nil
                // (IMPORTANT-2) — escape it explicitly so classification reaches the broadcast at all.
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _, _ in
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
                // MOB-1496 (W5): escape the "nothing to do" bucket so classification reaches the
                // broadcast-candidate probe at all.
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                // MOB-1496 (fix-wave): `rescheduleOverdueMigrationTransfer` now defaults to nil
                // (IMPORTANT-2) — escape it explicitly so classification reaches the broadcast at all.
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in throw SomeError() }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _, _ in
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
                // MOB-1496 (fix-wave): `rescheduleOverdueMigrationTransfer` now defaults to nil
                // (IMPORTANT-2) — escape it explicitly so classification reaches the broadcast at all.
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
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
                $0.userNotifications.scheduleMigrationNotification = { notification, _, _ in
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

    // MARK: - Multi-account fan-out (MOB-1496 W5)

    /// Two accounts, both broadcast candidates (neither overdue): the earlier
    /// `nextExecutableAfterHeight` wins, and exactly ONE `executeNextPendingMigrationTransfer` call
    /// happens — the loser's candidacy never reaches the broadcaster at all.
    @Test func bothAccountsDueEarliestNextExecutableAfterHeightWinsWithExactlyOneExecuteCall() async {
        let selected = Self.walletAccount()
        let second = Self.secondAccount()
        let executedAccountUUIDs = LockIsolated<[AccountUUID]>([])
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.twoAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { accountUUID in
                    accountUUID == selected.id ? Self.proposal(nextExecutableAfterHeight: 300) : Self.proposal(nextExecutableAfterHeight: 100)
                }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { accountUUID, _ in
                    executedAccountUUIDs.withValue { $0.append(accountUUID) }
                    return MigrationTransferResult.success(txId: "tx-winner")
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(executedAccountUUIDs.withValue { $0 } == [second.id])
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// The winner's OWN `migrationNetworkOptions(_:)` — not the loser's — is what reaches
    /// `executeNextPendingMigrationTransfer`. Mocks two accounts with distinct sentinel endpoints.
    @Test func winnerAccountsMigrationNetworkOptionsReachTheBroadcastCall() async {
        let selected = Self.walletAccount()
        let second = Self.secondAccount()
        let selectedOptions = MigrationNetworkPrivacyOptions(
            useTor: false,
            submissionEndpoint: LightWalletEndpoint(address: "selected.example.com", port: 1)
        )
        let secondOptions = MigrationNetworkPrivacyOptions(
            useTor: true,
            submissionEndpoint: LightWalletEndpoint(address: "second.example.com", port: 2)
        )
        let receivedOptions = LockIsolated<[MigrationNetworkPrivacyOptions]>([])
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.twoAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                // Selected account is due earliest -> it wins.
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { accountUUID in
                    accountUUID == selected.id ? Self.proposal(nextExecutableAfterHeight: 100) : Self.proposal(nextExecutableAfterHeight: 300)
                }
                $0.migrationManager.migrationNetworkOptions = { accountUUID in
                    accountUUID == selected.id ? selectedOptions : secondOptions
                }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, options in
                    receivedOptions.withValue { $0.append(options) }
                    return MigrationTransferResult.success(txId: "tx-winner")
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(receivedOptions.withValue { $0 } == [selectedOptions])
        }
    }

    /// The overdue flag beats an earlier `nextExecutableAfterHeight` — an overdue candidate wins
    /// even against a non-overdue candidate whose height is earlier.
    @Test func overdueCandidateWinsEvenWithALaterHeightThanANonOverdueCandidate() async {
        let selected = Self.walletAccount()
        let second = Self.secondAccount()
        let executedAccountUUIDs = LockIsolated<[AccountUUID]>([])
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.twoAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                // `second` has the EARLIER height but is NOT overdue; `selected` is overdue despite
                // a LATER height -> `selected` must still win.
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { accountUUID in
                    accountUUID == selected.id ? Self.proposal(nextExecutableAfterHeight: 500) : Self.proposal(nextExecutableAfterHeight: 100)
                }
                $0.sdkSynchronizer.hasOverdueMigrationTransfers = { accountUUID in accountUUID == selected.id }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { accountUUID, _ in
                    executedAccountUUIDs.withValue { $0.append(accountUUID) }
                    return MigrationTransferResult.success(txId: "tx-winner")
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(executedAccountUUIDs.withValue { $0 } == [selected.id])
        }
    }

    /// A tie (same height, same overdue flag) breaks toward the selected account — the account-set
    /// order the tree fans out over (selected first) IS the tie-break.
    @Test func tiedCandidatesPreferTheSelectedAccount() async {
        let selected = Self.walletAccount()
        let second = Self.secondAccount()
        let executedAccountUUIDs = LockIsolated<[AccountUUID]>([])
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.twoAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                // Identical height for both accounts, neither overdue (the `.noOp`/baseNoOp default)
                // -> a true tie.
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 200) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { accountUUID, _ in
                    executedAccountUUIDs.withValue { $0.append(accountUUID) }
                    return MigrationTransferResult.success(txId: "tx-winner")
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(executedAccountUUIDs.withValue { $0 } == [selected.id])
        }
    }

    /// ZIP-0318: a background session either syncs or broadcasts, never both — one account needing
    /// sync defers EVERY account's broadcast this session, even a healthy due account.
    @Test func oneSyncNeededAndOtherDueProducesSyncOnlySessionWithZeroBroadcasts() async {
        let selected = Self.walletAccount()
        let second = Self.secondAccount()
        let executedCount = LockIsolated<Int>(0)
        let startCalls = LockIsolated<[Bool]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)

        let preparedState: SynchronizerState = {
            var state = SynchronizerState.zero
            state.syncStatus = SyncStatus.upToDate
            return state
        }()

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.twoAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.isSyncRequiredBeforeNextMigrationTransfer = { accountUUID in accountUUID == selected.id }
                $0.sdkSynchronizer.isMigrationSyncBlocked = { false }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    executedCount.withValue { $0 += 1 }
                    return MigrationTransferResult.success(txId: "should-not-be-called")
                }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { _ in }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { startCalls.withValue { !$0.isEmpty } }

            #expect(executedCount.withValue { $0 } == 0)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(startCalls.withValue { $0 } == [true])
        }
    }

    /// One account's plan-broken state posts a single `.planNeedsUpdate` notification for the whole
    /// session, but does NOT turn the session sync-only or block a healthy account's own broadcast.
    ///
    /// R8-T5 (S4-a): also the key attribution test — `selected` is plan-broken, `second` is the
    /// session's broadcast WINNER, so a naive "attribute every notification to the winner" fix
    /// would have attached `.planNeedsUpdate` to `second` (wrong: `second` isn't the account that
    /// needs attention). RED against a winner-only fix: `notifiedAccountUUIDs.first` would read
    /// `second.id`'s hex string instead of `selected.id`'s.
    @Test func onePlanBrokenAndOtherDueNotifiesOnceAndStillBroadcastsTheHealthyAccount() async {
        let selected = Self.walletAccount()
        let second = Self.secondAccount()
        let notifications = LockIsolated<[MigrationNotification]>([])
        let notifiedAccountUUIDs = LockIsolated<[String?]>([])
        let executedAccountUUIDs = LockIsolated<[AccountUUID]>([])
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.twoAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.hasInvalidMigrationTransfers = { accountUUID in accountUUID == selected.id }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { accountUUID, _ in
                    executedAccountUUIDs.withValue { $0.append(accountUUID) }
                    return MigrationTransferResult.success(txId: "tx-healthy")
                }
                $0.userNotifications.scheduleMigrationNotification = { notification, _, accountUUID in
                    notifications.withValue { $0.append(notification) }
                    notifiedAccountUUIDs.withValue { $0.append(accountUUID) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(notifications.withValue { $0 }.first == MigrationNotification.planNeedsUpdate)
            #expect(notifiedAccountUUIDs.withValue { $0 }.first == Data(selected.id.id).hexEncodedString())
            #expect(executedAccountUUIDs.withValue { $0 } == [second.id])
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// Every account `.complete`/`.notStarted` (no active run anywhere) -> `cancelAll`, mirroring
    /// the single-account complete->cancelAll precedent extended across the whole account set.
    @Test func allAccountsCompleteCancelsAll() async {
        let cancelAllCalls = LockIsolated<Int>(0)
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.twoAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.complete }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(cancelAllCalls.withValue { $0 } == 1)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 0)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// One account already `.complete` BEFORE the session even starts (i.e. the NON-winner — the
    /// winner is the other, active account), the other active: `cancelAll` must NOT fire, and the
    /// active account's own broadcast still proceeds. Named to be explicit about which direction
    /// this covers — the `.complete` account here never reaches `handleLandedBroadcast`'s own
    /// post-broadcast complete-check at all (it's not the winner); the sibling direction, where
    /// the WINNER's OWN broadcast is what completes it while the other account is still active, is
    /// `winnerCompletingWhileOtherAccountStillActiveDoesNotCancelAllAndRearms` below (fix-wave
    /// finding 1 — review confirmed this test alone doesn't pin that invariant).
    @Test func oneCompleteNonWinnerOneActiveDoesNotCancelAllAndActiveProceeds() async {
        let selected = Self.walletAccount()
        let second = Self.secondAccount()
        let cancelAllCalls = LockIsolated<Int>(0)
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let executedAccountUUIDs = LockIsolated<[AccountUUID]>([])
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.twoAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { accountUUID in
                    accountUUID == selected.id ? MigrationState.complete : MigrationState.inProgress(Self.placeholderProgress)
                }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { accountUUID, _ in
                    executedAccountUUIDs.withValue { $0.append(accountUUID) }
                    return MigrationTransferResult.success(txId: "tx-active")
                }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(cancelAllCalls.withValue { $0 } == 0)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(executedAccountUUIDs.withValue { $0 } == [second.id])
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    // MARK: - Fix wave (review findings): nil-probe coverage + winner-completes-while-another-
    // account-is-active invariant (finding 1) + its sibling legitimate-cancelAll case + the
    // planner-level `readyToPropose` nuance.

    /// IMPORTANT-2: an active (`.inProgress`) account whose `rescheduleOverdueMigrationTransfer`
    /// probe returns nil is `.activeNoCandidate` — never a broadcast candidate, and (unlike
    /// `.complete`/`.notStarted`) never counts as "done" for the cancel-all gate either, so the
    /// session just re-arms.
    @Test func activeAccountWithNilProbeIsNotABroadcastCandidate() async {
        let executeNextPendingMigrationTransferCalls = LockIsolated<Int>(0)
        let cancelAllCalls = LockIsolated<Int>(0)
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in nil }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    executeNextPendingMigrationTransferCalls.withValue { $0 += 1 }
                    return MigrationTransferResult.success(txId: "should-not-be-called")
                }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(executeNextPendingMigrationTransferCalls.withValue { $0 } == 0)
            #expect(cancelAllCalls.withValue { $0 } == 0)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// Fix-wave finding 1 (the review's headline SPEC violation) — THIS IS THE PINNING TEST: two
    /// accounts, the winner's OWN broadcast finishes IT (`getMigrationState(winner)` reads
    /// `.complete` on the post-broadcast check), but the OTHER account is still `.inProgress` with
    /// its own broadcast candidate (i.e. still has an active run). The session must NOT
    /// `cancelAll`/announce `.migrationComplete` — that would kill the wakeup chain and orphan the
    /// other account's migration. Instead: `.transferComplete` (an ordinary successful-transfer
    /// notification) and `scheduleNextWindow()` so the other account's chain continues. Winner-
    /// scoped bookkeeping (`recordTransferBroadcast`/`reconcile`) still runs exactly as it would
    /// for any other landed broadcast.
    ///
    /// Recorded RED against the unfixed code (review IMPORTANT-1): `cancelAllCalls == 1`,
    /// `notifications == [.migrationComplete]` — see the fix-wave report's red-run evidence.
    @Test func winnerCompletingWhileOtherAccountStillActiveDoesNotCancelAllAndRearms() async {
        let selected = Self.walletAccount()
        let recordTransferBroadcastCalls = LockIsolated<[(AccountUUID?, MigrationTransferResult)]>([])
        let reconcileCalls = LockIsolated<Int>(0)
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let cancelAllCalls = LockIsolated<Int>(0)
        let executedAccountUUIDs = LockIsolated<[AccountUUID]>([])
        let completeCalls = LockIsolated<[Bool]>([])
        // The winner (`selected`)'s `getMigrationState` must read `.inProgress` during pre-flight
        // classification (else it short-circuits to "nothing to do" and is never a candidate at
        // all) and `.complete` on `handleLandedBroadcast`'s post-broadcast check — a call-counted
        // stub models exactly that, mirroring `sendSuccessToCompleteNotifiesMigrationCompleteAndCancelsAll`'s
        // single-account precedent. `second` stays `.inProgress` on every read — it's the account
        // that must still be "active" when the winner's own completion is evaluated.
        let selectedGetMigrationStateCallCount = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.twoAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { accountUUID in
                    guard accountUUID == selected.id else {
                        return MigrationState.inProgress(Self.placeholderProgress)
                    }
                    let call = selectedGetMigrationStateCallCount.withValue { count -> Int in
                        count += 1
                        return count
                    }
                    return call == 1 ? MigrationState.inProgress(Self.placeholderProgress) : MigrationState.complete
                }
                // `selected` due earliest (height 100) -> wins; `second` also a candidate (height
                // 200, still active) but loses and must stay untouched (never executed).
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { accountUUID in
                    accountUUID == selected.id
                        ? Self.proposal(nextExecutableAfterHeight: 100)
                        : Self.proposal(nextExecutableAfterHeight: 200)
                }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { accountUUID, _ in
                    executedAccountUUIDs.withValue { $0.append(accountUUID) }
                    return MigrationTransferResult.success(txId: "tx-selected-final")
                }
                $0.migrationManager.recordTransferBroadcast = { accountUUID, result in
                    recordTransferBroadcastCalls.withValue { $0.append((accountUUID, result)) }
                }
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _, _ in
                    notifications.withValue { $0.append(notification) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(executedAccountUUIDs.withValue { $0 } == [selected.id])
            #expect(recordTransferBroadcastCalls.withValue { $0 }.count == 1)
            #expect(recordTransferBroadcastCalls.withValue { $0 }.first?.1 == MigrationTransferResult.success(txId: "tx-selected-final"))
            #expect(reconcileCalls.withValue { $0 } == 1)
            #expect(cancelAllCalls.withValue { $0 } == 0)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(notifications.withValue { $0 }.count == 1)
            if case MigrationNotification.transferComplete? = notifications.withValue({ $0 }).first {
                // Exact payload fields already covered by `sendSuccessNotCompleteNotifiesTransferCompleteAndRearms`.
            } else {
                Issue.record("Expected a .transferComplete notification, got \(notifications.withValue { $0 })")
            }
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// The sibling legitimate-cancelAll case at the multi-account level: the winner's OWN
    /// broadcast finishes it, and the OTHER account is ALREADY done (`.complete`, i.e.
    /// `nothingToDo`) — every account is now done, so `cancelAll` + `.migrationComplete` fire
    /// exactly as the single-account precedent (`sendSuccessToCompleteNotifiesMigrationCompleteAndCancelsAll`)
    /// always has.
    @Test func winnerCompletingWithAllOtherAccountsDoneCancelsAllAndNotifiesComplete() async {
        let selected = Self.walletAccount()
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let cancelAllCalls = LockIsolated<Int>(0)
        let executedAccountUUIDs = LockIsolated<[AccountUUID]>([])
        let completeCalls = LockIsolated<[Bool]>([])
        let selectedGetMigrationStateCallCount = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.twoAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { accountUUID in
                    guard accountUUID == selected.id else {
                        return MigrationState.complete
                    }
                    let call = selectedGetMigrationStateCallCount.withValue { count -> Int in
                        count += 1
                        return count
                    }
                    return call == 1 ? MigrationState.inProgress(Self.placeholderProgress) : MigrationState.complete
                }
                // `second` is `nothingToDo(.complete)` -> its probe is never even read; only
                // `selected` needs a candidate proposal to become the (sole) winner.
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { accountUUID, _ in
                    executedAccountUUIDs.withValue { $0.append(accountUUID) }
                    return MigrationTransferResult.success(txId: "tx-selected-final")
                }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _, _ in
                    notifications.withValue { $0.append(notification) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(executedAccountUUIDs.withValue { $0 } == [selected.id])
            #expect(notifications.withValue { $0 } == [MigrationNotification.migrationComplete])
            #expect(scheduleNextWindowCalls.withValue { $0 } == 0)
            #expect(cancelAllCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// MINOR-3: the planner's cancel-all gate requires `.nothingToDo(state)` with `state ==
    /// .complete || .notStarted` — a `.readyToPropose` account (real balance, no committed plan
    /// yet) is deliberately EXCLUDED, so it must force a re-arm instead of `cancelAll`, keeping the
    /// wakeup chain alive in case the user eventually commits a plan. Only `MigrationCadence
    /// .planRearm`'s adjacent nuance had store-independent coverage before this; `MigrationSessionPlanner`
    /// itself is `private`, so this pins it the only way available — via the Root store.
    @Test func oneCompleteOneReadyToProposeDoesNotCancelAllAndRearms() async {
        let cancelAllCalls = LockIsolated<Int>(0)
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let selected = Self.walletAccount()
            let store = Store(initialState: Self.twoAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { accountUUID in
                    accountUUID == selected.id ? MigrationState.complete : MigrationState.readyToPropose
                }
                $0.migrationBGScheduler.cancelAll = { cancelAllCalls.withValue { $0 += 1 } }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(cancelAllCalls.withValue { $0 } == 0)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
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

    // MARK: - MOB-1496 (R8-T4, #7): BG session dispatched before init — stash, then replay

    /// A cold launch races `.migrationBackgroundSession` against wallet-state hydration — mirrors
    /// `RootMigrationRoutingTests`' `pendingMigrationDeepLink` precedent exactly: stashed rather
    /// than evaluated against not-yet-hydrated state (an unprepared `isIronwoodActivated()`/empty
    /// `walletAccounts` would otherwise misclassify a genuinely activated/populated wallet as
    /// neither, per branches 0/1's updated doc). The decision tree must NOT run at all while
    /// stashed.
    @Test func migrationBackgroundSessionBeforeInitializedStashesWithoutRunningTheDecisionTree() async {
        let executeNextPendingMigrationTransferCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Self.selectedAccountState()
            initialState.appInitializationState = InitializationState.uninitialized

            let store = Store(initialState: initialState) {
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
            await waitForRootStore { store.state.pendingMigrationBackgroundSession != nil }

            #expect(store.state.pendingMigrationBackgroundSession == handle)
            #expect(store.state.activeMigrationBackgroundSessionHandle == nil)
            #expect(executeNextPendingMigrationTransferCalls.withValue { $0 } == 0)
            #expect(completeCalls.withValue { $0 }.isEmpty)
        }
    }

    /// The stash replays at `checkBackupPhraseValidation` — the SAME checkpoint that replays
    /// `pendingMigrationDeepLink` — and the decision tree then runs normally (this test's only
    /// concern is that it runs at all, so a "nothing to do" completion is enough to prove it).
    @Test func migrationBackgroundSessionStashReplaysAtCheckBackupPhraseValidation() async {
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Self.selectedAccountState()
            initialState.appInitializationState = InitializationState.uninitialized

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { store.state.pendingMigrationBackgroundSession != nil }

            store.send(.initialization(.checkBackupPhraseValidation))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(store.state.pendingMigrationBackgroundSession == nil)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// Expiration while a session is stashed (pre-init) — completes it `false` immediately rather
    /// than betting hydration replays it before the OS reclaims the task, re-arms so the wakeup
    /// chain survives regardless, and clears the stash.
    @Test func migrationBackgroundTaskExpiredWhileStashedCompletesFalseAndRearmsAndClearsStash() async {
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = Self.selectedAccountState()
            initialState.appInitializationState = InitializationState.uninitialized

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { store.state.pendingMigrationBackgroundSession != nil }

            store.send(.initialization(.appDelegate(.migrationBackgroundTaskExpired)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(completeCalls.withValue { $0 } == [false])
            #expect(store.state.pendingMigrationBackgroundSession == nil)
            // `scheduleNextWindow()` runs inside its own async effect, spawned alongside (not
            // before) the synchronous `complete(false)` call above — wait for it explicitly rather
            // than assuming it has already landed by the time `completeCalls` flips.
            await waitForRootStore { scheduleNextWindowCalls.withValue { $0 } == 1 }
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
        }
    }

    // MARK: - MOB-1496 (R8-T4, #11): expiration cancels the tree and completes exactly once

    /// Expiration mid-session cancels the ACTIVE tree — proven via a cancellation handler on the
    /// broadcast call the tree is suspended in, not just via the expiration handler's own bookkeeping
    /// — completes the handle `false` through the STORED handle (never `state.bgTask`, which stays
    /// `nil` for this plan; see `MigrationBGSessionHandle`'s doc), and re-arms.
    @Test func migrationBackgroundTaskExpiredMidSessionCancelsTreeCompletesFalseAndRearms() async {
        let cancellationObserved = LockIsolated<Bool>(false)
        let executeStarted = LockIsolated<Bool>(false)
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    executeStarted.setValue(true)
                    return try await withTaskCancellationHandler {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                        return MigrationTransferResult.success(txId: "should-not-land")
                    } onCancel: {
                        cancellationObserved.setValue(true)
                    }
                }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { executeStarted.withValue { $0 } }
            #expect(store.state.activeMigrationBackgroundSessionHandle == handle)

            // A brief settle so the stubbed broadcast call has genuinely reached `Task.sleep` (and
            // registered its cancellation handler) before expiring — not required for correctness
            // (Swift guarantees `onCancel` fires even for an already-cancelled task), just extra
            // margin against scheduling jitter.
            try? await Task.sleep(nanoseconds: 50_000_000)
            store.send(.initialization(.appDelegate(.migrationBackgroundTaskExpired)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(completeCalls.withValue { $0 } == [false])
            #expect(store.state.activeMigrationBackgroundSessionHandle == nil)
            await waitForRootStore { cancellationObserved.withValue { $0 } }
            #expect(cancellationObserved.withValue { $0 } == true)
            // `scheduleNextWindow()` runs inside its own async effect (merged alongside the
            // synchronous `complete(false)` + `.cancel(id:)` above) — wait for it explicitly. The
            // cancelled tree's own recovery path (its generic `catch` in `executeBroadcastAction`)
            // may ALSO call `scheduleNextWindow()` once the cancellation surfaces as a thrown error
            // — re-submitting with the same identifier is idempotent (the existing `power_wifi_sync`
            // precedent), so this only waits for/asserts AT LEAST the expiration handler's own
            // explicit re-arm, not an exact count.
            await waitForRootStore { scheduleNextWindowCalls.withValue { $0 } >= 1 }
            #expect(scheduleNextWindowCalls.withValue { $0 } >= 1)

            // Let the cancelled tree's own (safely guarded) recovery finish settling, then confirm it
            // did NOT also complete the handle a second time.
            try? await Task.sleep(nanoseconds: 300_000_000)
            #expect(completeCalls.withValue { $0 } == [false])
        }
    }

    /// Normal completion clears the stored handle FIRST — a LATE expiration arriving afterward finds
    /// the slot already `nil` and falls through to the untouched sync-bgTask tail (harmless: `state
    /// .bgTask` is `nil` for this plan too) rather than completing the same `BGProcessingTask` twice.
    @Test func normalCompletionThenLateExpirationOnlyCompletesOnce() async {
        let completeCalls = LockIsolated<[Bool]>([])
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
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            // `.mocked(...)`'s own `getMigrationState` default (`.notStarted`) resolves this
            // single-account session to `cancelAll` (every account already "done") — an ordinary
            // normal completion, exactly what this test needs.
            #expect(completeCalls.withValue { $0 } == [true])
            #expect(store.state.activeMigrationBackgroundSessionHandle == nil)

            store.send(.initialization(.appDelegate(.migrationBackgroundTaskExpired)))
            await waitForRootStore { stopCalls.withValue { $0 } == 1 }

            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    // MARK: - R8 final cumulative review (Finding 2): guard the sync-only hand-off

    /// `completeSyncOnlySession` sends `.migrationBackgroundSyncOnly(handle)` back into the reducer
    /// to do its `state.bgTask` stash — but `.migrationBackgroundTaskExpired` can win the race
    /// against that in-flight send (which survives the tree's own `.cancellable` cancellation),
    /// completing the session FIRST via its guarded active-session branch (clearing
    /// `activeMigrationBackgroundSessionHandle` — see `normalCompletionThenLateExpirationOnlyCompletesOnce`
    /// above for the identical "drive the first event for real, then manually deliver the second to
    /// represent a late arrival" technique used to simulate this deterministically). The hand-off
    /// must then be a no-op: no `state.bgTask` adoption, no re-arm, no `.retryStart` kick, and no
    /// second completion of any kind. FAILS against HEAD f6882a1e — the hand-off adopts/kicks
    /// unconditionally, re-arming a SECOND time and reaching `start()`.
    @Test func migrationBackgroundSyncOnlyGuardsAgainstAnAlreadyCompletedSession() async {
        let completeCalls = LockIsolated<[Bool]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let startCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }

            // As if `migrationBackgroundSessionEffect` had already stashed this handle for a
            // genuinely mid-flight session (the real precondition for either expiration branch or
            // the sync-only hand-off to matter at all).
            var initialState = Self.selectedAccountState()
            initialState.activeMigrationBackgroundSessionHandle = handle

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
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            }

            // `.migrationBackgroundTaskExpired` wins the race: completes the handle via the guarded
            // ACTIVE-session branch, clears the live-session marker, re-arms once.
            store.send(.initialization(.appDelegate(.migrationBackgroundTaskExpired)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(completeCalls.withValue { $0 } == [false])
            #expect(store.state.activeMigrationBackgroundSessionHandle == nil)
            await waitForRootStore { scheduleNextWindowCalls.withValue { $0 } == 1 }
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)

            // The sync-only hand-off `completeSyncOnlySession` had already sent is delivered anyway,
            // AFTER expiration already cleared the live-session marker.
            store.send(.initialization(.migrationBackgroundSyncOnly(handle)))
            // Let any (erroneous, if the guard were missing) adoption/re-arm/kick effects settle
            // before asserting their absence — same idiom as `notificationTapTeardownWithNoHoldActiveNeverNudgesGate`
            // in `RootMigrationRoutingTests`.
            try? await Task.sleep(nanoseconds: 300_000_000)

            // No re-arm beyond expiration's own, no `.retryStart` kick, and no second completion.
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(startCalls.withValue { $0 }.isEmpty)
            #expect(completeCalls.withValue { $0 } == [false])
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

    // MARK: - MOB-1496 (R8-T4, #2): `.initializeSDK` cold-start gate deferral

    /// `.initializeSDK` falling through to `.initializationSuccessfullyDone` (per the fix — see that
    /// case's doc) reaches dependencies neither `RootMigrationBackgroundTests` nor
    /// `RootMigrationRoutingTests` had ever exercised before (both stop earlier in the init chain):
    /// `exchangeRate`/`autolockHandler`/`userDefaults`/`shieldingProcessor` each have NO `testValue`
    /// of their own (same "whole-client, any member" gotcha `baseNoOpDependencies` documents for
    /// `migrationManager`/`sdkSynchronizer` above) — customizing one member of each unlocks it.
    @MainActor
    private func initializeSDKDependencies(_ values: inout DependencyValues) {
        baseNoOpDependencies(&values)
        values.exchangeRate.refreshExchangeRateUSD = { }
        values.autolockHandler.value = { _ in }
        values.userDefaults.objectForKey = { _ in nil }
        values.shieldingProcessor.observe = { Empty().eraseToAnyPublisher() }
    }

    /// Proactive half, mirroring `.retryStart`'s own EXACTLY: `isMigrationSyncBlocked() == true` is
    /// checked BEFORE ever calling `start` — `start` itself must never fire, no failure alert
    /// surfaces, and `appInitializationState` never flips `.failed`. Unlike `.retryStart` (see
    /// `initializeSDKDeferralStillReachesRegisterForSynchronizersUpdateSoALaterGateClearReplaysRetryStart`
    /// below for the end-to-end proof), the rest of THIS chain still runs.
    @Test func initializeSDKProactivelyDefersWhenMigrationSyncBlockedWithoutFailingOrCallingStart() async {
        let startCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                initializeSDKDependencies(&$0)
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                // MOB-1512 heal: `.mocked` answers the relevance probe `false` over an empty
                // account list, which the heal reads as a view-only stale database and aborts the
                // init chain with `viewOnlyDatabase` before this test's gate logic is ever reached.
                // A relevant seed makes the heal the no-op these scenarios always assumed.
                $0.sdkSynchronizer.isSeedRelevantToAnyDerivedAccount = { _ in true }
                $0.sdkSynchronizer.isMigrationSyncBlocked = { true }
            }

            store.send(.initialization(.initializeSDK(.existingWallet)))
            await waitForRootStore { store.state.syncDeferredByMigrationGate }

            #expect(startCalls.withValue { $0 }.isEmpty)
            #expect(store.state.alert == nil)
            #expect(store.state.appInitializationState != InitializationState.failed)
            #expect(store.state.syncDeferredByMigrationGate == true)
        }
    }

    /// Reactive half: the proactive check passes (gate reads open), but `start` itself races the
    /// gate and throws `ZcashError.migrationSyncBlocked` — same silent deferral, no alert, no
    /// failed state; every OTHER error keeps the existing generic catch (`.initializationFailed`).
    ///
    /// `isMigrationSyncBlocked` is call-counted (false first, true after) rather than a fixed
    /// `false`: a fixed-false stub is unrealistic here — once this chain falls through to
    /// `.initializationSuccessfullyDone` -> `.registerForSynchronizersUpdate`, THAT subscription's
    /// own initial gate read would ALSO see the fixed `false` and immediately resume/clear the very
    /// flag this test is checking (a genuine race that flips `start()` blocked would leave the gate
    /// observably blocked moments later too, which is what the call-counted stub simulates).
    @Test func initializeSDKReactivelyDefersWhenStartThrowsMigrationSyncBlockedWithoutFailingOrAlerting() async {
        let isMigrationSyncBlockedCallCount = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                initializeSDKDependencies(&$0)
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    start: { _ in throw ZcashError.migrationSyncBlocked }
                )
                // MOB-1512 heal: `.mocked` answers the relevance probe `false` over an empty
                // account list, which the heal reads as a view-only stale database and aborts the
                // init chain with `viewOnlyDatabase` before this test's gate logic is ever reached.
                // A relevant seed makes the heal the no-op these scenarios always assumed.
                $0.sdkSynchronizer.isSeedRelevantToAnyDerivedAccount = { _ in true }
                $0.sdkSynchronizer.isMigrationSyncBlocked = {
                    isMigrationSyncBlockedCallCount.withValue { count -> Bool in
                        count += 1
                        return count > 1
                    }
                }
            }

            store.send(.initialization(.initializeSDK(.existingWallet)))
            await waitForRootStore { store.state.syncDeferredByMigrationGate }

            #expect(store.state.alert == nil)
            #expect(store.state.appInitializationState != InitializationState.failed)
            #expect(store.state.syncDeferredByMigrationGate == true)
        }
    }

    /// End-to-end: a cold start whose gate is blocked must still reach
    /// `.registerForSynchronizersUpdate` (observers register even inside the deferral) — proven by
    /// the ONLY way that could happen: a LATER `.migrationSyncGateChanged(false)` replays
    /// `.retryStart`, which then runs the deferred start for real. If `.initializeSDK` had returned
    /// early instead of falling through to `.initializationSuccessfullyDone`, nothing would ever be
    /// subscribed to observe the gate clearing, and this `start` call could never happen — this is
    /// the existing gate-clear resume machinery (`.migrationSyncGateChanged`), pinned end-to-end
    /// from a COLD-START deferral instead of `.retryStart`'s own.
    @Test func initializeSDKDeferralStillReachesRegisterForSynchronizersUpdateSoALaterGateClearReplaysRetryStart() async {
        let startCalls = LockIsolated<[Bool]>([])
        // Toggled `true` -> `false` between the cold start (gate blocked) and the later gate-clear
        // event, mirroring the gate ACTUALLY clearing in reality — a fixed stub could never let
        // `.retryStart`'s own fresh re-check see anything other than what it saw the first time.
        let isMigrationSyncBlockedValue = LockIsolated<Bool>(true)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Root.State.initial) {
                Root()
            } withDependencies: {
                initializeSDKDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { Self.preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                // MOB-1512 heal: `.mocked` answers the relevance probe `false` over an empty
                // account list, which the heal reads as a view-only stale database and aborts the
                // init chain with `viewOnlyDatabase` before this test's gate logic is ever reached.
                // A relevant seed makes the heal the no-op these scenarios always assumed.
                $0.sdkSynchronizer.isSeedRelevantToAnyDerivedAccount = { _ in true }
                $0.sdkSynchronizer.isMigrationSyncBlocked = { isMigrationSyncBlockedValue.withValue { $0 } }
            }

            store.send(.initialization(.initializeSDK(.existingWallet)))
            await waitForRootStore { store.state.syncDeferredByMigrationGate }
            #expect(startCalls.withValue { $0 }.isEmpty)

            // The gate clears for real — `.registerForSynchronizersUpdate`'s own subscription
            // (seeded despite the deferral) is what delivers this.
            isMigrationSyncBlockedValue.setValue(false)
            store.send(.migrationSyncGateChanged(false))
            await waitForRootStore { startCalls.withValue { !$0.isEmpty } }

            #expect(startCalls.withValue { $0 } == [true])
            #expect(store.state.syncDeferredByMigrationGate == false)
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

    // MARK: - MOB-1496 (R8-T4, #3): app-side migration sync gate feed merge

    /// `.registerForSynchronizersUpdate` merges `migrationManager.migrationSyncGateFeed()` into the
    /// SAME `.migrationSyncGateChanged` mapping the SDK's own stream feeds. The SDK's own gate reads
    /// BLOCKED only for the INITIAL synchronous read (`migrationSyncBlockedStream` itself stays at
    /// its never-emitting default throughout) — the ONLY `false` this test ever produces comes
    /// through the NEW app-side feed, isolating the merge itself from the pre-existing SDK-stream
    /// path. With `migrationStoppedSyncForBroadcast` set and that fed value `false`, this must
    /// resume (`.retryStart` replays, reaching `start`) and clear the flag — exactly like a genuine
    /// SDK gate transition would (the existing `migrationSyncGateChangedResumesWhenBroadcastStopFlagSet...`
    /// tests above pin that same resume logic; this test pins the NEW feed actually reaching it).
    ///
    /// `isMigrationSyncBlocked` is call-counted (true first, false after) rather than a fixed
    /// `true`: a fixed-true stub is unrealistic AND self-defeating here — `.retryStart`'s OWN
    /// proactive re-check (once replayed by the resume this fed value triggers) reads the SAME
    /// dependency, and a fixed `true` would make it immediately re-defer instead of ever reaching
    /// `start`. A real gate that the app-side feed is nudging about clearing would read `false` on
    /// that very next check too, which is what the call-counted stub simulates.
    @Test func migrationSyncGateFeedValueReachesMigrationSyncGateChangedAndResumesWhenBroadcastStopFlagSet() async {
        let startCalls = LockIsolated<[Bool]>([])
        let isMigrationSyncBlockedCallCount = LockIsolated<Int>(0)
        let feedContinuationBox = LockIsolated<AsyncStream<Bool>.Continuation?>(nil)
        let feedStream = AsyncStream<Bool> { continuation in
            feedContinuationBox.setValue(continuation)
        }

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
            $migrationStoppedSyncForBroadcast.withLock { $0 = true }

            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { Self.preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                $0.sdkSynchronizer.isMigrationSyncBlocked = {
                    isMigrationSyncBlockedCallCount.withValue { count -> Bool in
                        count += 1
                        return count == 1
                    }
                }
                $0.migrationManager.migrationSyncGateFeed = { feedStream }
            }

            store.send(.initialization(.registerForSynchronizersUpdate))
            await waitForRootStore { store.state.lastMigrationSyncGateBlocked }

            // Sanity: the SDK's own initial (blocked) read must not itself have resumed anything.
            #expect(startCalls.withValue { $0 }.isEmpty)

            // The merged feed-consuming effect is spawned as its own Task alongside
            // `.registerForSynchronizersUpdate`'s other effects — `lastMigrationSyncGateBlocked`
            // flipping only proves ONE of them (the SDK-stream branch) has started, not this one.
            // Give the feed's own `for await` a generous settle window to actually begin consuming
            // before yielding into it (AsyncStream buffers regardless, but the SPAWNED Task needs a
            // scheduling slice first), then retry the yield on a short poll — idempotent once the
            // flag clears, so re-yielding costs nothing — to absorb whatever scheduling gap remains
            // under load.
            let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
            try? await Task.sleep(nanoseconds: 500_000_000)
            while startCalls.withValue({ $0 }).isEmpty, DispatchTime.now().uptimeNanoseconds < deadline {
                feedContinuationBox.withValue { $0 }?.yield(false)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            #expect(startCalls.withValue { $0 } == [true])
            #expect(migrationStoppedSyncForBroadcast == false)
        }
    }

    // MARK: - R8-T6 (V8 fix, MANDATORY TRACE fence): the send-wait hold

    /// `.retryStart`'s NEW proactive section (ahead of the SDK gate check): `migrationSendWaitActive`
    /// set -> deferred the SAME silent way as the SDK gate (`syncDeferredByMigrationGate`), `start`
    /// never fires, no alert. `isMigrationSyncBlocked` is pinned `false` so ONLY the hold flag could
    /// be causing the defer, isolating this fence from the pre-existing SDK-gate check beside it.
    @Test func retryStartDefersWhenMigrationSendWaitActiveWithoutCallingStartOrAlerting() async {
        let startCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
            $migrationSendWaitActive.withLock { $0 = true }

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
            }

            store.send(.initialization(.retryStart))
            await waitForRootStore { store.state.syncDeferredByMigrationGate }

            #expect(startCalls.withValue { $0 }.isEmpty)
            #expect(store.state.alert == nil)
            #expect(store.state.syncDeferredByMigrationGate == true)

            $migrationSendWaitActive.withLock { $0 = false }
        }
    }

    /// Resume: the hold clears, then a `.migrationSyncGateChanged(false)` reaches Root (exactly the
    /// shape `MigrationSendingStore.waitCancelTapped`'s `refreshMigrationSyncGate()` nudge produces,
    /// per the feed-merge mechanism `migrationSyncGateFeedValueReachesMigrationSyncGateChangedAndResumesWhenBroadcastStopFlagSet`
    /// above already pins) — `.retryStart` replays and, with the hold now clear AND the SDK gate
    /// open, runs the normal chain all the way to `start`, exactly once.
    @Test func migrationSendWaitActiveClearedThenGateChangeResumesADeferredStartExactlyOnce() async {
        let startCalls = LockIsolated<[Bool]>([])

        var initialState = Self.selectedAccountState()
        // As if an earlier `.retryStart` had already deferred while the hold was active (the
        // realistic precondition for a deferred start to exist at all).
        initialState.syncDeferredByMigrationGate = true
        initialState.lastMigrationSyncGateBlocked = true

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
            // Cancel/broadcast-start already cleared the hold before this event arrives — mirrors
            // `MigrationSendingStore.setSendWaitActive(false)` running BEFORE its nudge call.
            $migrationSendWaitActive.withLock { $0 = false }

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
        }
    }

    /// Guard against loops: a `.migrationSyncGateChanged(false)` replays `.retryStart`, but the hold
    /// is STILL active (a race / the nudge arrived ahead of the hold actually clearing) — `.retryStart`'s
    /// own fresh re-check just re-defers, `start` never fires, and nothing here re-sends
    /// `.migrationSyncGateChanged` on its own, so there's no runaway loop. Mirrors
    /// `stillBlockedReEntryReDefersWithoutLooping`'s identical proof for the SDK gate above.
    @Test func stillHeldReEntryReDefersWithoutLooping() async {
        let startCalls = LockIsolated<[Bool]>([])
        let reconcileCalls = LockIsolated<Int>(0)

        var initialState = Self.selectedAccountState()
        initialState.syncDeferredByMigrationGate = true
        initialState.lastMigrationSyncGateBlocked = true

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
            $migrationSendWaitActive.withLock { $0 = true }

            let store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { Self.preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                // The SDK's own gate reads OPEN here — proves the re-defer is coming from the hold
                // flag specifically, not a coincidental SDK-gate block.
                $0.sdkSynchronizer.isMigrationSyncBlocked = { false }
                $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            }

            store.send(.migrationSyncGateChanged(false))
            await waitForRootStore { reconcileCalls.withValue { $0 } == 1 }
            // Let any further (erroneous, if a loop existed) effects settle.
            try? await Task.sleep(nanoseconds: 300_000_000)

            #expect(startCalls.withValue { $0 }.isEmpty)
            #expect(store.state.syncDeferredByMigrationGate == true)
            #expect(reconcileCalls.withValue { $0 } == 1)

            $migrationSendWaitActive.withLock { $0 = false }
        }
    }

    // MARK: - R8 final cumulative review (Finding 1): the hold-release nudge must fire unconditionally

    /// Reproduces the cumulative review's stranding trace end-to-end. A live send-wait hold is up;
    /// an UNRELATED `.migrationSyncGateChanged(false)` (e.g. a prior Send-now's SDK gate expiring
    /// mid-wait) legitimately consumes `migrationStoppedSyncForBroadcast` via `shouldResume` and
    /// replays `.retryStart`, which re-defers on the STILL-live hold and sets
    /// `syncDeferredByMigrationGate`. The external teardown (`RootMigrationRoutingTests`'
    /// `notificationTapTeardown...` tests exercise the SAME `openMigrationCoordFlow` route) then
    /// clears the hold — with the fix, `releaseSendWaitHold()`'s nudge fires unconditionally on that
    /// clear (independent of `migrationStoppedSyncForBroadcast`, already consumed above), its
    /// resulting gate value reaches the merged subscription
    /// (`migrationSyncGateFeedValueReachesMigrationSyncGateChangedAndResumesWhenBroadcastStopFlagSet`
    /// above pins that merge itself), resumes off the still-set `syncDeferredByMigrationGate`, and
    /// the deferred start genuinely replays. FAILS against HEAD f6882a1e — the nudge is gated on
    /// `migrationStoppedSyncForBroadcast`, which the resume replay already consumed, so it's skipped
    /// and NEITHER spy below is ever populated (`waitForRootStore` times out).
    @Test func releaseSendWaitHoldNudgesUnconditionallyAfterAnUnrelatedResumeReplayConsumedTheBroadcastStopFlag() async {
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let startCalls = LockIsolated<[Bool]>([])
        let seedReadCalls = LockIsolated<Int>(0)
        let feedContinuationBox = LockIsolated<AsyncStream<Bool>.Continuation?>(nil)
        let feedStream = AsyncStream<Bool> { continuation in
            feedContinuationBox.setValue(continuation)
        }

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
            @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
            $migrationSendWaitActive.withLock { $0 = false }
            $migrationStoppedSyncForBroadcast.withLock { $0 = false }

            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    latestState: { Self.preparedState },
                    start: { _ in startCalls.withValue { $0.append(true) } }
                )
                $0.sdkSynchronizer.isMigrationSyncBlocked = {
                    seedReadCalls.withValue { $0 += 1 }
                    return false
                }
                $0.migrationManager.migrationSyncGateFeed = { feedStream }
                $0.migrationManager.refreshMigrationSyncGate = {
                    refreshMigrationSyncGateCalls.withValue { $0 += 1 }
                    // Mirrors production: the nudge re-reads the manager's gate and republishes it
                    // onto the SAME feed `.registerForSynchronizersUpdate` merges below.
                    feedContinuationBox.withValue { $0 }?.yield(false)
                }
            }

            // Establish the merged gate subscription (SDK stream + manager feed) — mirrors a normal
            // launch's `.retryStart` success already having registered it long before any send-wait
            // begins. The seed read is a genuine no-op here (neither flag set yet, `false` matching
            // `Root.State.initial`'s own `lastMigrationSyncGateBlocked` default).
            store.send(.initialization(.registerForSynchronizersUpdate))
            await waitForRootStore { seedReadCalls.withValue { $0 } == 1 }
            #expect(startCalls.withValue { $0 }.isEmpty)

            // WAITING active: a live send-wait hold, with sync genuinely stopped for its broadcast.
            $migrationSendWaitActive.withLock { $0 = true }
            $migrationStoppedSyncForBroadcast.withLock { $0 = true }

            // An UNRELATED gate-false event legitimately consumes `migrationStoppedSyncForBroadcast`
            // and replays `.retryStart`, which re-defers on the still-live hold.
            store.send(.migrationSyncGateChanged(false))
            await waitForRootStore { store.state.syncDeferredByMigrationGate == true }

            #expect(store.state.syncDeferredByMigrationGate == true)
            #expect(migrationStoppedSyncForBroadcast == false)
            #expect(migrationSendWaitActive == true)
            #expect(startCalls.withValue { $0 }.isEmpty)

            // The external teardown: a migration-notification tap resets the flow via
            // `openMigrationCoordFlow`, releasing the hold BEFORE the reset.
            store.send(.initialization(.appDelegate(.migrationNotificationTapped(accountUUID: nil, isTorFailure: false))))
            await waitForRootStore { migrationSendWaitActive == false }
            #expect(migrationSendWaitActive == false)

            // With the fix: the nudge fires unconditionally, and the deferred start genuinely
            // replays through the SAME merged subscription/resume machinery.
            await waitForRootStore { refreshMigrationSyncGateCalls.withValue { $0 } == 1 }
            #expect(refreshMigrationSyncGateCalls.withValue { $0 } == 1)
            await waitForRootStore { startCalls.withValue { !$0.isEmpty } }
            #expect(startCalls.withValue { $0 } == [true])
            #expect(store.state.syncDeferredByMigrationGate == false)
        }
    }

    // MARK: - Branch 0 (MOB-1496): no selected account

    // MARK: - Branch 1 (MOB-1483): Ironwood not yet activated

    // MARK: - R7-T3 (MOB-1497): failure routing — BG maps every route to re-arm-only

    /// The transport-outcome failure branch classifies + routes BEFORE its existing notification —
    /// `.networkError(retryable: true)` reaches `routeBroadcastFailure` as `.endpointUnreachable`,
    /// and the notification/rearm are byte-for-byte the SAME as `sendFailureNotifiesTransferWaitingAndRearms`
    /// (which relies on `baseNoOpDependencies`' own `.plainRetry` default) — pinned here with EVERY
    /// route explicitly, proving the outward behavior is route-agnostic.
    @Test func networkErrorFailureRoutesAndRearmsIdenticallyRegardlessOfRoute() async {
        let routes: [MigrationBroadcastFailureRoute] = [
            MigrationBroadcastFailureRoute.torFirstRunChoice,
            MigrationBroadcastFailureRoute.torHold,
            MigrationBroadcastFailureRoute.retryRotated,
            MigrationBroadcastFailureRoute.plainRetry,
            MigrationBroadcastFailureRoute.providerExhausted(torEnabled: true),
            MigrationBroadcastFailureRoute.providerExhausted(torEnabled: false)
        ]

        for (index, route) in routes.enumerated() {
            let notifications = LockIsolated<[MigrationNotification]>([])
            let scheduleNextWindowCalls = LockIsolated<Int>(0)
            let completeCalls = LockIsolated<[Bool]>([])
            let capturedFailureClass = LockIsolated<MigrationBroadcastFailureClass?>(nil)
            let overrideBroadcastEndpointCalls = LockIsolated<Int>(0)
            let overrideTorCalls = LockIsolated<Int>(0)
            let progress = MigrationProgress(
                completedTransfers: 2, totalTransfers: 6, remainingOrchard: Zatoshi(500), nextTransferReadyAtHeight: nil
            )

            await withDependencies {
                $0.defaultInMemoryStorage = InMemoryStorage()
            } operation: {
                var accountState = Self.selectedAccountState()
                // Deterministic per-account key so the 6 iterations of this loop never share
                // persisted `@Shared` in-memory state across each other via the account identity.
                accountState.$selectedWalletAccount.withLock { $0 = Self.walletAccount(idByte: UInt8(60 + index)) }

                let store = Store(initialState: accountState) {
                    Root()
                } withDependencies: {
                    baseNoOpDependencies(&$0)
                    $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(progress) }
                    $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                    $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.networkError(retryable: true) }
                    $0.sdkSynchronizer.getMigrationProgress = { _ in progress }
                    $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                    $0.userNotifications.scheduleMigrationNotification = { notification, _, _ in
                        notifications.withValue { $0.append(notification) }
                    }
                    $0.migrationManager.routeBroadcastFailure = { _, failureClass in
                        capturedFailureClass.setValue(failureClass)
                        return route
                    }
                    $0.migrationManager.overrideBroadcastEndpointToSyncServer = { _ in
                        overrideBroadcastEndpointCalls.withValue { $0 += 1 }
                    }
                    $0.migrationManager.overrideTorForRun = { _, _ in overrideTorCalls.withValue { $0 += 1 } }
                }

                let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
                store.send(.initialization(.migrationBackgroundSession(handle)))
                await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }
            }

            #expect(capturedFailureClass.value == MigrationBroadcastFailureClass.endpointUnreachable, "route: \(route)")
            #expect(notifications.withValue { $0 } == [MigrationNotification.transferWaiting(number: 3)], "route: \(route)")
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1, "route: \(route)")
            #expect(completeCalls.withValue { $0 } == [true], "route: \(route)")
            // Consent is foreground-only, always — no route ever triggers either sanctioned mutation
            // from the BG lane.
            #expect(overrideBroadcastEndpointCalls.withValue { $0 } == 0, "route: \(route)")
            #expect(overrideTorCalls.withValue { $0 } == 0, "route: \(route)")
        }
    }

    /// The GENERIC catch (any throw other than `migrationRecordFailedAfterBroadcast`) also classifies
    /// + routes — `ZcashError.migrationTorUnavailable` reaches `routeBroadcastFailure` as
    /// `.torUnavailable`, and the outward behavior (re-arm only, no notification — mirrors
    /// `throwingExecuteNextPendingTransferOnlyRearmsWithoutNotifying`) is unaffected by which R14/R15
    /// route comes back.
    @Test func torUnavailableThrowFromBackgroundClassifiesAsTorUnavailableAndOnlyRearms() async {
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])
        let capturedFailureClass = LockIsolated<MigrationBroadcastFailureClass?>(nil)
        let overrideTorCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in throw ZcashError.migrationTorUnavailable }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _, _ in
                    notifications.withValue { $0.append(notification) }
                }
                $0.migrationManager.routeBroadcastFailure = { _, failureClass in
                    capturedFailureClass.setValue(failureClass)
                    return MigrationBroadcastFailureRoute.torFirstRunChoice
                }
                $0.migrationManager.overrideTorForRun = { _, _ in overrideTorCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(capturedFailureClass.value == MigrationBroadcastFailureClass.torUnavailable)
            #expect(notifications.withValue { $0 }.isEmpty)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
            #expect(overrideTorCalls.withValue { $0 } == 0)
        }
    }

    // MARK: - R7 final review (Important-1, spec §G): the Tor-hold indicator persists through BG

    /// The BG lane discards the ROUTE by design (see the section above) — but the persisted Tor-hold
    /// indicator (read by `MigrationStatusStore`'s resume presentation and the SmartBanner
    /// transfer-waiting variant) must still end up set, since that indicator is the ENTIRE mechanism
    /// spec §G relies on to make a BG mid-run Tor outage diagnosable. Unlike this file's other R7-T3
    /// tests, `routeBroadcastFailure` is wired to a REAL `MigrationManagerImpl` (isolated storages),
    /// not a canned mock — a canned `{ _, _ in .torHold }` mock would bypass the indicator entirely
    /// (it lives inside the real routing member's own body), so this is the one test in this file
    /// that must NOT mock that member away.
    @Test func backgroundTorClassMidRunFailureLeavesTheTorHoldIndicatorSetThroughExecuteBroadcastAction() async throws {
        let account = Self.walletAccount(idByte: 77)
        let routingSuite = "testBackgroundTorClassMidRunFailureLeavesTheTorHoldIndicatorSet_routing"
        let snapshotSuite = "testBackgroundTorClassMidRunFailureLeavesTheTorHoldIndicatorSet_snapshot"
        let routingUserDefaults = try #require(UserDefaults(suiteName: routingSuite))
        let snapshotUserDefaults = try #require(UserDefaults(suiteName: snapshotSuite))
        defer {
            routingUserDefaults.removePersistentDomain(forName: routingSuite)
            snapshotUserDefaults.removePersistentDomain(forName: snapshotSuite)
        }

        let failureRoutingStorage = MigrationFailureRoutingStorage(userDefaults: routingUserDefaults)
        let snapshotStorage = MigrationSnapshotStorage(userDefaults: snapshotUserDefaults)
        // Mid-run: a broadcast has already landed this run, so a Tor-class failure routes `.torHold`
        // (R15), not `.torFirstRunChoice` (R14) — `.torHold` is the ONE route that sets the
        // indicator.
        failureRoutingStorage.markHadBroadcast(for: account.id)
        snapshotStorage.recordSnapshot(
            MigrationNetworkSnapshot(
                useTor: true,
                syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: "zec.rocks", port: 443, secure: true),
                broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: "us.zec.stardust.rest", port: 443, secure: true),
                takenAt: Date(),
                committedAt: Date()
            ),
            for: account.id
        )
        let realImpl = MigrationManagerImpl(snapshotStorage: snapshotStorage, failureRoutingStorage: failureRoutingStorage)

        var accountState = Self.selectedAccountState()
        accountState.$selectedWalletAccount.withLock { $0 = account }
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: accountState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in throw ZcashError.migrationTorUnavailable }
                $0.migrationManager.routeBroadcastFailure = { accountUUID, failureClass in
                    await realImpl.routeBroadcastFailure(accountUUID: accountUUID, failureClass: failureClass)
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }
        }

        #expect(completeCalls.withValue { $0 } == [true])
        #expect(failureRoutingStorage.torHoldActive(for: account.id) == true)
    }

    // MARK: - MOB-1497 (T5): the BG lane arms the per-account pending-Tor-prompt latch on a Tor-class
    // route — read on foreground by T6 to surface the "Couldn't Connect to Tor" sheet over Home.

    /// A BACKGROUND broadcast that fails on a Tor-class route MID-run (a broadcast already landed, so
    /// the failure routes R15 `.torHold`) must persist the per-account latch through
    /// `executeBroadcastAction`. Wired to a REAL `MigrationManagerImpl` (isolated storages) — both
    /// `routeBroadcastFailure` (computes the real route) and `setPendingBackgroundTorPrompt` (persists
    /// the real latch) go through it — since the arming lives in the executor's own body reacting to
    /// the returned route.
    @Test func backgroundTorClassMidRunFailureArmsThePendingTorPromptThroughExecuteBroadcastAction() async throws {
        let account = Self.walletAccount(idByte: 78)
        let routingSuite = "testBackgroundTorClassMidRunFailureArmsThePendingTorPrompt_routing"
        let snapshotSuite = "testBackgroundTorClassMidRunFailureArmsThePendingTorPrompt_snapshot"
        let routingUserDefaults = try #require(UserDefaults(suiteName: routingSuite))
        let snapshotUserDefaults = try #require(UserDefaults(suiteName: snapshotSuite))
        defer {
            routingUserDefaults.removePersistentDomain(forName: routingSuite)
            snapshotUserDefaults.removePersistentDomain(forName: snapshotSuite)
        }

        let failureRoutingStorage = MigrationFailureRoutingStorage(userDefaults: routingUserDefaults)
        let snapshotStorage = MigrationSnapshotStorage(userDefaults: snapshotUserDefaults)
        // Mid-run: a broadcast already landed this run, so a Tor-class failure routes `.torHold` (R15).
        failureRoutingStorage.markHadBroadcast(for: account.id)
        snapshotStorage.recordSnapshot(
            MigrationNetworkSnapshot(
                useTor: true,
                syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: "zec.rocks", port: 443, secure: true),
                broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: "us.zec.stardust.rest", port: 443, secure: true),
                takenAt: Date(),
                committedAt: Date()
            ),
            for: account.id
        )
        let realImpl = MigrationManagerImpl(snapshotStorage: snapshotStorage, failureRoutingStorage: failureRoutingStorage)

        var accountState = Self.selectedAccountState()
        accountState.$selectedWalletAccount.withLock { $0 = account }
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: accountState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in throw ZcashError.migrationTorUnavailable }
                $0.migrationManager.routeBroadcastFailure = { accountUUID, failureClass in
                    await realImpl.routeBroadcastFailure(accountUUID: accountUUID, failureClass: failureClass)
                }
                $0.migrationManager.setPendingBackgroundTorPrompt = { accountUUID, isPending in
                    realImpl.setPendingBackgroundTorPrompt(accountUUID: accountUUID, isPending: isPending)
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }
        }

        #expect(completeCalls.withValue { $0 } == [true])
        #expect(failureRoutingStorage.pendingBackgroundTorPrompt(for: account.id) == true)
    }

    /// T5 arms on BOTH Tor-class routes: a FIRST-run Tor failure (no landed broadcast yet, so the
    /// failure routes R14 `.torFirstRunChoice`) leaves the run just as stalled on Tor with no
    /// foreground UI shown, so it must arm the latch too. Same real-impl wiring as the mid-run twin.
    @Test func backgroundTorClassFirstRunFailureArmsThePendingTorPromptThroughExecuteBroadcastAction() async throws {
        let account = Self.walletAccount(idByte: 79)
        let routingSuite = "testBackgroundTorClassFirstRunFailureArmsThePendingTorPrompt_routing"
        let snapshotSuite = "testBackgroundTorClassFirstRunFailureArmsThePendingTorPrompt_snapshot"
        let routingUserDefaults = try #require(UserDefaults(suiteName: routingSuite))
        let snapshotUserDefaults = try #require(UserDefaults(suiteName: snapshotSuite))
        defer {
            routingUserDefaults.removePersistentDomain(forName: routingSuite)
            snapshotUserDefaults.removePersistentDomain(forName: snapshotSuite)
        }

        let failureRoutingStorage = MigrationFailureRoutingStorage(userDefaults: routingUserDefaults)
        let snapshotStorage = MigrationSnapshotStorage(userDefaults: snapshotUserDefaults)
        // First-run: NO prior landed broadcast, so a Tor-class failure routes `.torFirstRunChoice` (R14).
        snapshotStorage.recordSnapshot(
            MigrationNetworkSnapshot(
                useTor: true,
                syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: "zec.rocks", port: 443, secure: true),
                broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: "us.zec.stardust.rest", port: 443, secure: true),
                takenAt: Date(),
                committedAt: Date()
            ),
            for: account.id
        )
        let realImpl = MigrationManagerImpl(snapshotStorage: snapshotStorage, failureRoutingStorage: failureRoutingStorage)

        var accountState = Self.selectedAccountState()
        accountState.$selectedWalletAccount.withLock { $0 = account }
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: accountState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in throw ZcashError.migrationTorUnavailable }
                $0.migrationManager.routeBroadcastFailure = { accountUUID, failureClass in
                    await realImpl.routeBroadcastFailure(accountUUID: accountUUID, failureClass: failureClass)
                }
                $0.migrationManager.setPendingBackgroundTorPrompt = { accountUUID, isPending in
                    realImpl.setPendingBackgroundTorPrompt(accountUUID: accountUUID, isPending: isPending)
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }
        }

        #expect(completeCalls.withValue { $0 } == [true])
        #expect(failureRoutingStorage.pendingBackgroundTorPrompt(for: account.id) == true)
    }

    /// The catch-path route discriminator is strict: a NON-Tor route (here `.retryRotated`, from an
    /// endpoint-class throw) must NOT arm the latch — only `.torFirstRunChoice`/`.torHold` do. Spies on
    /// `setPendingBackgroundTorPrompt` to prove it is never called.
    @Test func backgroundNonTorRouteFromAThrowDoesNotArmThePendingTorPrompt() async {
        struct SomeError: Error { }
        let setPendingCalls = LockIsolated<[(AccountUUID, Bool)]>([])
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in throw SomeError() }
                $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.retryRotated }
                $0.migrationManager.setPendingBackgroundTorPrompt = { accountUUID, isPending in
                    setPendingCalls.withValue { $0.append((accountUUID, isPending)) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }
        }

        #expect(completeCalls.withValue { $0 } == [true])
        #expect(setPendingCalls.withValue { $0 }.isEmpty)
    }

    /// The endpoint-class RESULT path (a `.networkError` return, not a throw) can never yield a Tor
    /// route (`MigrationBroadcastFailureClass.classify(result:)` only ever produces
    /// `.endpointUnreachable`), so it must never arm the latch either. Spies to prove no call.
    @Test func backgroundNetworkErrorResultDoesNotArmThePendingTorPrompt() async {
        let setPendingCalls = LockIsolated<[(AccountUUID, Bool)]>([])
        let completeCalls = LockIsolated<[Bool]>([])
        let progress = MigrationProgress(
            completedTransfers: 1, totalTransfers: 6, remainingOrchard: Zatoshi(500), nextTransferReadyAtHeight: nil
        )

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(progress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.networkError(retryable: true) }
                $0.sdkSynchronizer.getMigrationProgress = { _ in progress }
                $0.migrationManager.setPendingBackgroundTorPrompt = { accountUUID, isPending in
                    setPendingCalls.withValue { $0.append((accountUUID, isPending)) }
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }
        }

        #expect(completeCalls.withValue { $0 } == [true])
        #expect(setPendingCalls.withValue { $0 }.isEmpty)
    }

    /// A landed broadcast (`.success`, and its `migrationRecordFailedAfterBroadcast` twin) is never a
    /// failure to route — `routeBroadcastFailure` must stay uncalled on both paths.
    @Test func landedBroadcastNeverCallsRouteBroadcastFailure() async {
        let routeBroadcastFailureCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-landed") }
                $0.migrationManager.recordTransferBroadcast = { _, _ in }
                $0.migrationManager.reconcile = { }
                $0.migrationBGScheduler.scheduleNextWindow = { }
                $0.userNotifications.scheduleMigrationNotification = { _, _, _ in }
                $0.migrationManager.routeBroadcastFailure = { _, _ in
                    routeBroadcastFailureCalls.withValue { $0 += 1 }
                    return MigrationBroadcastFailureRoute.plainRetry
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(routeBroadcastFailureCalls.withValue { $0 } == 0)
        }
    }

    // MARK: - R9-T7 (MOB-1497 review remediation, finding 9): BG lane stops sync before broadcasting

    /// The BG lane now mirrors every foreground broadcast lane (same idiom as
    /// `MigrationSendingTests.onAppearWhileSyncingStopsSyncBeforeExecutingScheduledTransfer`):
    /// `sdkSynchronizer.isSyncing() == true` -> `stop()` fires BEFORE `executeNextPendingMigrationTransfer`,
    /// in that order (shared call-order log), and flips the shared `migrationStoppedSyncForBroadcast`
    /// flag — Root's own resume machinery (`.migrationSyncGateChanged`) keys off that flag exactly
    /// like it already does for every foreground lane.
    @Test func executeBroadcastActionStopsSyncBeforeExecutingTheBroadcast() async {
        let callOrder = LockIsolated<[String]>([])
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            // R9-T7: `@Shared(.inMemory(...))` resolves `defaultInMemoryStorage` at declaration
            // time — declared HERE (inside `operation:`, after the fresh isolated storage above is
            // installed) rather than outside, mirroring every other `migrationStoppedSyncForBroadcast`
            // read in this file (e.g. `migrationSyncGateChangedResumesWhenBroadcastStopFlagSetEvenWithoutADeferredStart`).
            // Declaring it outside would bind to the ambient/default storage instead, silently
            // missing the write `stopSyncBeforeMigrationBroadcast()` makes against THIS test's own
            // isolated instance.
            @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
            $migrationStoppedSyncForBroadcast.withLock { $0 = false }

            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                    stop: { callOrder.withValue { $0.append("stop") } },
                    isSyncing: { true }
                )
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    callOrder.withValue { $0.append("execute") }
                    return nil
                }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(callOrder.withValue { $0 } == ["stop", "execute"])
            #expect(migrationStoppedSyncForBroadcast == true)
        }
    }

    /// R9-T7 (finding 9): the SDK's during-sync guard (`ZcashError.migrationBroadcastDuringSync`,
    /// ZRUST0126) is a pure pre-flight rejection — nothing was ever attempted — so it must NEVER
    /// reach `routeBroadcastFailure`'s stateful routing (no episode write, no rotation):
    /// `MigrationBroadcastFailureClass.classify(error:)`'s dedicated carve-out returns `nil` for it,
    /// and the shared classify -> route entry point short-circuits on a `nil` class WITHOUT ever
    /// calling the raw `routeBroadcastFailure` closure this test counts — proving the persisted
    /// routing episode stays untouched (nothing else could have mutated it). Mirrors
    /// `torUnavailableThrowFromBackgroundClassifiesAsTorUnavailableAndOnlyRearms`'s shape, inverted:
    /// same re-arm-only outward behavior, but the counted stub must stay at ZERO instead of
    /// capturing a class. Also proves Half 1's nudge still resumes sync for exactly this scenario —
    /// the stop above ran and this attempt never landed, so `refreshMigrationSyncGate()` must fire
    /// despite the unclassified/unrouted error (this is the actual defect this task fixes: pre-fix,
    /// the BG lane never stopped sync OR nudged at all, and an overlap here would have misclassified
    /// into `.endpointUnreachable` — see this suite's own R7-T3 section above).
    @Test func duringSyncThrowFromBackgroundNeverRoutesButStillRearmsAndNudges() async {
        let notifications = LockIsolated<[MigrationNotification]>([])
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])
        let routeBroadcastFailureCalls = LockIsolated<Int>(0)
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in throw ZcashError.migrationBroadcastDuringSync }
                $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
                $0.userNotifications.scheduleMigrationNotification = { notification, _, _ in
                    notifications.withValue { $0.append(notification) }
                }
                $0.migrationManager.routeBroadcastFailure = { _, _ in
                    routeBroadcastFailureCalls.withValue { $0 += 1 }
                    return MigrationBroadcastFailureRoute.plainRetry
                }
                $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(routeBroadcastFailureCalls.withValue { $0 } == 0)
            #expect(notifications.withValue { $0 }.isEmpty)
            #expect(scheduleNextWindowCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
            #expect(refreshMigrationSyncGateCalls.withValue { $0 } == 1)
        }
    }

    /// Nudge parity (R9-T7 outcome table, row 2): a non-landed transport failure after a real stop
    /// nudges Root's gate feed exactly once — the SDK's own gate transition only covers a landed
    /// broadcast, so an attempt that stopped sync but never reached one must resume it directly.
    /// Mirrors `MigrationSendingTests.onAppearWithFailureResultPresentsFailureSheetAndStopsSequence`'s
    /// identical nudge assertion.
    @Test func networkErrorFailureAfterStopNudgesGateExactlyOnce() async {
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.networkError(retryable: true) }
                $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(refreshMigrationSyncGateCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// Nudge parity (R9-T7 outcome table, row 3): nothing pending, but the stop above still ran —
    /// nudges exactly like the transport-failure case (mirrors Sending's own `nil`-result nudge).
    @Test func nilPendingTransferNudgesGateExactlyOnce() async {
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
                $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(refreshMigrationSyncGateCalls.withValue { $0 } == 1)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// Nudge parity (R9-T7 outcome table, row 1): a landed broadcast must NOT nudge — the SDK's own
    /// gate transition (on a successful broadcast) already covers the resume; mirrors Sending's
    /// identical `.success` case.
    @Test func landedBroadcastSuccessDoesNotNudgeGate() async {
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-landed") }
                $0.migrationManager.recordTransferBroadcast = { _, _ in }
                $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(refreshMigrationSyncGateCalls.withValue { $0 } == 0)
            #expect(completeCalls.withValue { $0 } == [true])
        }
    }

    /// Nudge parity (R9-T7 outcome table, row 4): the broadcast DID land — only recording failed —
    /// treated exactly like `.success`, so no nudge here either (mirrors Sending's identical catch
    /// clause, which never even checks the flag).
    @Test func recordFailedAfterBroadcastDoesNotNudgeGate() async {
        struct RecordingFailure: Error { }
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let completeCalls = LockIsolated<[Bool]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: Self.selectedAccountState()) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.sdkSynchronizer.getMigrationState = { _ in MigrationState.inProgress(Self.placeholderProgress) }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in Self.proposal(nextExecutableAfterHeight: 100) }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                    throw ZcashError.migrationRecordFailedAfterBroadcast(RecordingFailure())
                }
                $0.migrationManager.recordTransferBroadcast = { _, _ in }
                $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            }

            let handle = MigrationBGSessionHandle(rawTask: nil) { success in completeCalls.withValue { $0.append(success) } }
            store.send(.initialization(.migrationBackgroundSession(handle)))
            await waitForRootStore { completeCalls.withValue { !$0.isEmpty } }

            #expect(refreshMigrationSyncGateCalls.withValue { $0 } == 0)
            #expect(completeCalls.withValue { $0 } == [true])
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
    values.migrationManager.migrationMode = { _ in nil }
    values.migrationManager.setMigrationMode = { _, _ in }
    values.migrationManager.setManualDelivery = { _, _ in }
    values.migrationManager.setNetworkPrivacyOptions = { _ in }
    values.migrationManager.formNetworkSnapshot = { _ in }
    values.migrationManager.markNetworkSnapshotCommitted = { _ in }
    values.migrationManager.clearProvisionalNetworkSnapshot = { _ in }
    values.migrationManager.acknowledgeComplete = { _ in }
    // MOB-1496: default false — the existing single-account/multi-account "landed broadcast
    // reaches .complete" tests below all assume the plain `.migrationComplete` notification
    // (no remainder pending); the one test that DOES want `.migrationBatchComplete` overrides
    // this back to `true` locally.
    values.migrationManager.isMigrationRemainderPending = { _ in false }
    values.migrationManager.reconcile = { }
    values.migrationManager.clearAbandonedNetworkSnapshot = { _ in }
    values.migrationManager.recordSyncCompleted = { }
    values.migrationManager.migrationNetworkOptions = { _ in
        MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
    }
    values.migrationManager.activeNetworkSnapshots = { [] }
    // R9-T7 (MOB-1497 review remediation, finding 9): the BG lane's own stop-before-broadcast fix
    // nudges this on every non-landed outcome (see `RootInitialization.executeBroadcastAction`'s
    // doc) — a silent no-op default here so every EXISTING test below (none of which cares about the
    // nudge) is unaffected; the dedicated R9-T7 section overrides this locally with a counting spy.
    values.migrationManager.refreshMigrationSyncGate = { }
    // R7-T3 (MOB-1497): the BG lane's outward behavior (notification + re-arm) is identical for
    // EVERY route (see `RootInitialization.executeBroadcastAction`'s doc) — `.plainRetry` is the
    // least-eventful default so every existing failure-path test below keeps passing unchanged.
    // Tests that care about a SPECIFIC route (the dedicated R7-T3 section) override this locally.
    values.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.plainRetry }
    // MOB-1497 (T5): the BG lane arms this per-account latch on a Tor-class route (see
    // `RootInitialization.executeBroadcastAction`). These are live-context `Store` tests, so an
    // un-overridden member hits the live impl (real `UserDefaults`) — baseline it to a no-op so only
    // the dedicated T5 tests below observe it (they override it locally, to a spy or the real impl).
    values.migrationManager.setPendingBackgroundTorPrompt = { _, _ in }
    values.readTransactionsStorage.resetZashi = { }
    values.sdkSynchronizer = .noOp
    // MOB-1496 (fix-wave, review IMPORTANT-2): deliberately left at `.noOp`'s own bare default
    // (`{ _ in nil }`, i.e. no account is ever a broadcast candidate) — a prior override here (a
    // non-nil sentinel proposal) accidentally erased the ONLY coverage of the nil-probe/
    // `activeNoCandidate` path (an active account whose probe returns nil must never become a
    // broadcast candidate AND must never count as "done" for cancelAll). Every single-account
    // "Branch 4: Send" test below that needs a candidate now sets
    // `rescheduleOverdueMigrationTransfer` explicitly instead of being silently satisfied by a
    // shared default — the same "explicit per-test choice" precedent this file's own header doc
    // already calls out for `getMigrationState`.
    values.userMetadataProvider.load = { _ in }
    values.userNotifications.authorizationStatus = { .notDetermined }
    values.userNotifications.requestAuthorization = { false }
    values.userNotifications.scheduleMigrationNotification = { _, _, _ in }
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
