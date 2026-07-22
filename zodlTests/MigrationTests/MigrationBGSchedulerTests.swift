//
//  MigrationBGSchedulerTests.swift
//  zodlTests
//
//  Covers the pure `WakeupAction.decide` decision function
//  (Dependencies/MigrationBGScheduler/MigrationBGSchedulerLiveKey.swift) for MOB-1467: the
//  (state, isManualDelivery, window, nextTransferNumber) table — scheduled mode submits a BG
//  task, manual mode schedules the "ready" notification, and `.complete` always wins with
//  `.cancelAll` regardless of delivery mode. Pure enum/function, no SDK or framework touched
//  (never `BGTaskScheduler`/`UNUserNotificationCenter` in this file) -> no shared state ->
//  no `.serialized`.
//
//  MOB-1496 (W5): also covers `MigrationBGSchedulerImpl.arm(margin:)` itself (the second `@Suite`
//  below, `MigrationBGSchedulerArmTests`) — see that suite's own doc for why it's split out.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationBGSchedulerTests {
    private static let window = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Non-complete states x scheduled/manual

    @Test func scheduledModeSubmitsTaskWithTheGivenWindow() {
        let action = WakeupAction.decide(
            state: MigrationState.notStarted,
            isManualDelivery: false,
            window: Self.window,
            nextTransferNumber: 1,
            accountUUID: nil
        )

        #expect(action == WakeupAction.submitTask(earliestBeginDate: Self.window))
    }

    @Test func manualModeSchedulesReadyNotificationWithGivenWindowAndNumber() {
        let action = WakeupAction.decide(
            state: MigrationState.notStarted,
            isManualDelivery: true,
            window: Self.window,
            nextTransferNumber: 3,
            accountUUID: nil
        )

        #expect(action == WakeupAction.scheduleReadyNotification(number: 3, at: Self.window, accountUUID: nil))
    }

    /// R8-T5 (S4): `decide`'s `accountUUID` rides along into `.scheduleReadyNotification` unchanged
    /// — the pure per-row pass-through the LiveKey's `execute(_:)` then hands to
    /// `userNotifications.scheduleMigrationNotification`.
    @Test func manualModeSchedulesReadyNotificationCarryingTheGivenAccountUUID() {
        let action = WakeupAction.decide(
            state: MigrationState.notStarted,
            isManualDelivery: true,
            window: Self.window,
            nextTransferNumber: 3,
            accountUUID: "abc123"
        )

        #expect(action == WakeupAction.scheduleReadyNotification(number: 3, at: Self.window, accountUUID: "abc123"))
    }

    @Test func inProgressScheduledModeSubmitsTask() {
        let progress = MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 100
        )

        let action = WakeupAction.decide(
            state: MigrationState.inProgress(progress),
            isManualDelivery: false,
            window: Self.window,
            nextTransferNumber: 3,
            accountUUID: nil
        )

        #expect(action == WakeupAction.submitTask(earliestBeginDate: Self.window))
    }

    @Test func inProgressManualModeSchedulesReadyNotification() {
        let progress = MigrationProgress(
            completedTransfers: 2,
            totalTransfers: 5,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 100
        )

        let action = WakeupAction.decide(
            state: MigrationState.inProgress(progress),
            isManualDelivery: true,
            window: Self.window,
            nextTransferNumber: 3,
            accountUUID: "acct-1"
        )

        #expect(action == WakeupAction.scheduleReadyNotification(number: 3, at: Self.window, accountUUID: "acct-1"))
    }

    @Test func requiresAttentionScheduledModeSubmitsTask() {
        let action = WakeupAction.decide(
            state: MigrationState.requiresAttention(MigrationAttentionReason.transferExpired),
            isManualDelivery: false,
            window: Self.window,
            nextTransferNumber: 2,
            accountUUID: nil
        )

        #expect(action == WakeupAction.submitTask(earliestBeginDate: Self.window))
    }

    @Test func requiresAttentionManualModeSchedulesReadyNotification() {
        let action = WakeupAction.decide(
            state: MigrationState.requiresAttention(MigrationAttentionReason.invalidTransfer(transferId: "t1")),
            isManualDelivery: true,
            window: Self.window,
            nextTransferNumber: 1,
            accountUUID: "acct-2"
        )

        #expect(action == WakeupAction.scheduleReadyNotification(number: 1, at: Self.window, accountUUID: "acct-2"))
    }

    // MARK: - .complete always wins, regardless of mode

    @Test func completeStateCancelsAllInScheduledMode() {
        let action = WakeupAction.decide(
            state: MigrationState.complete,
            isManualDelivery: false,
            window: Self.window,
            nextTransferNumber: 1,
            accountUUID: nil
        )

        #expect(action == WakeupAction.cancelAll)
    }

    @Test func completeStateCancelsAllInManualMode() {
        let action = WakeupAction.decide(
            state: MigrationState.complete,
            isManualDelivery: true,
            window: Self.window,
            nextTransferNumber: 1,
            accountUUID: "acct-3"
        )

        #expect(action == WakeupAction.cancelAll)
    }

    // MARK: - Full table

    @Test func decisionTable() {
        struct Row {
            let name: String
            let state: MigrationState
            let isManualDelivery: Bool
            let nextTransferNumber: Int
            let expected: WakeupAction
        }

        let progress = MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 4,
            remainingOrchard: Zatoshi(1_000),
            nextTransferReadyAtHeight: 50
        )

        let rows: [Row] = [
            Row(
                name: "notStarted/scheduled",
                state: MigrationState.notStarted,
                isManualDelivery: false,
                nextTransferNumber: 1,
                expected: WakeupAction.submitTask(earliestBeginDate: Self.window)
            ),
            Row(
                name: "notStarted/manual",
                state: MigrationState.notStarted,
                isManualDelivery: true,
                nextTransferNumber: 1,
                expected: WakeupAction.scheduleReadyNotification(number: 1, at: Self.window, accountUUID: "acct-table")
            ),
            Row(
                name: "inProgress/scheduled",
                state: MigrationState.inProgress(progress),
                isManualDelivery: false,
                nextTransferNumber: 2,
                expected: WakeupAction.submitTask(earliestBeginDate: Self.window)
            ),
            Row(
                name: "inProgress/manual",
                state: MigrationState.inProgress(progress),
                isManualDelivery: true,
                nextTransferNumber: 2,
                expected: WakeupAction.scheduleReadyNotification(number: 2, at: Self.window, accountUUID: "acct-table")
            ),
            Row(
                name: "complete/scheduled",
                state: MigrationState.complete,
                isManualDelivery: false,
                nextTransferNumber: 5,
                expected: WakeupAction.cancelAll
            ),
            Row(
                name: "complete/manual",
                state: MigrationState.complete,
                isManualDelivery: true,
                nextTransferNumber: 5,
                expected: WakeupAction.cancelAll
            )
        ]

        for row in rows {
            let action = WakeupAction.decide(
                state: row.state,
                isManualDelivery: row.isManualDelivery,
                window: Self.window,
                nextTransferNumber: row.nextTransferNumber,
                accountUUID: "acct-table"
            )

            #expect(action == row.expected, "Row \(row.name) expected \(row.expected) but got \(action)")
        }
    }
}

// MARK: - MigrationBGSchedulerImpl.arm(margin:) — per-account fan-out (MOB-1496 W5)

/// Unlike `MigrationBGSchedulerTests` above (pure `WakeupAction.decide`, no shared state), this
/// suite drives the impl class directly — same testability pattern `MigrationManagerImpl` already
/// uses (a non-`private` class with `@Dependency`-wrapped fields, instantiated inside a
/// `withDependencies { } operation: { }` scope so its internal dependency reads resolve to the
/// overrides). `.serialized` + `defaultInMemoryStorage = InMemoryStorage()`: `impl`'s
/// `@Shared(.inMemory(.selectedWalletAccount))`/`@Shared(.inMemory(.walletAccounts))` fields would
/// otherwise share process-global storage with every other suite touching the same keys.
///
/// Only the MANUAL-delivery path is asserted here (`scheduleMigrationNotification`, a mockable
/// `@Dependency`) — the scheduled path's `.submitTask` branch calls the real, unmockable
/// `BGTaskScheduler.shared.submit(_:)`, which isn't observable from a unit test. `WakeupAction
/// .decide` itself (shared by both paths) is already exhaustively covered above; these tests only
/// need to prove `arm(margin:)` gathers per-account data and reduces it correctly before handing off
/// to that pure function.
@Suite(.serialized) @MainActor struct MigrationBGSchedulerArmTests {
    private static func walletAccount(idByte: UInt8) -> WalletAccount {
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

    /// `nonisolated`: called from inside `@Sendable` dependency-closure overrides below, which run
    /// off the main actor — `MigrationTransferProposal` is itself `Sendable`, so no `(unsafe)` is
    /// needed (mirrors `RootMigrationBackgroundTests`'s identical fixture helper).
    private nonisolated static func proposal(nextExecutableAfterHeight: BlockHeight) -> MigrationTransferProposal {
        MigrationTransferProposal(
            id: "t-\(nextExecutableAfterHeight)",
            amount: Zatoshi(1_000),
            anchorHeight: 0,
            nextExecutableAfterHeight: nextExecutableAfterHeight,
            expiryHeight: nextExecutableAfterHeight + 1_000
        )
    }

    @Test func noAccountsSkipsWithoutSchedulingAnything() async {
        let scheduleCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
            @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
            $selectedWalletAccount.withLock { $0 = nil }
            $walletAccounts.withLock { $0 = [] }

            await withDependencies {
                $0.migrationManager.isManualDelivery = { true }
                $0.userNotifications.scheduleMigrationNotification = { _, _, _ in scheduleCalls.withValue { $0 += 1 } }
            } operation: {
                let impl = MigrationBGSchedulerImpl()
                await impl.arm(margin: MigrationCadence.nextWindowMargin)
            }

            #expect(scheduleCalls.withValue { $0 } == 0)
        }
    }

    /// Two accounts, distinct next-executable heights: the EARLIER one's window/number reaches
    /// `WakeupAction.decide` — asserted via the manual-delivery notification it produces. R8-T5
    /// (S4): also asserts the notification's `accountUUID` payload is the EARLIER (winning)
    /// account's own hex-encoded id, not the selected account's — proving `arm(margin:)` attributes
    /// the notification to the account it's actually about.
    @Test func armUsesTheEarliestAcrossAccountsWindowAndItsOwnTransferNumber() async {
        let selected = Self.walletAccount(idByte: 1)
        let second = Self.walletAccount(idByte: 2)
        let laterProgress = MigrationProgress(completedTransfers: 5, totalTransfers: 9, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil)
        let earlierProgress = MigrationProgress(completedTransfers: 1, totalTransfers: 9, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil)
        let scheduled = LockIsolated<[(number: Int, at: Date, accountUUID: String?)]>([])

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
            @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
            $selectedWalletAccount.withLock { $0 = selected }
            $walletAccounts.withLock { $0 = [selected, second] }

            await withDependencies {
                $0.migrationManager.isManualDelivery = { true }
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.getMigrationState = { accountUUID in
                    accountUUID == selected.id ? MigrationState.inProgress(laterProgress) : MigrationState.inProgress(earlierProgress)
                }
                $0.sdkSynchronizer.getMigrationProgress = { accountUUID in
                    accountUUID == selected.id ? laterProgress : earlierProgress
                }
                $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { accountUUID in
                    accountUUID == selected.id ? Self.proposal(nextExecutableAfterHeight: 900) : Self.proposal(nextExecutableAfterHeight: 100)
                }
                $0.sdkSynchronizer.estimateTimestamp = { height in TimeInterval(height) }
                $0.userNotifications.scheduleMigrationNotification = { notification, at, accountUUID in
                    if case let MigrationNotification.manualTransferReady(number) = notification, let at {
                        scheduled.withValue { $0.append((number, at, accountUUID)) }
                    }
                }
            } operation: {
                let impl = MigrationBGSchedulerImpl()
                await impl.arm(margin: MigrationCadence.nextWindowMargin)
            }

            #expect(scheduled.withValue { $0 }.count == 1)
            #expect(scheduled.withValue { $0 }.first?.number == earlierProgress.completedTransfers + 1)
            // height 100 -> estimateTimestamp -> epoch+100s, well before now+margin -> the margin
            // floor from `MigrationCadence.window` wins; asserting the NUMBER (which account won)
            // is the multi-account-specific behavior under test here, matching `MigrationCadenceTests
            // .planRearm`'s dedicated height-math coverage.
            #expect(scheduled.withValue { $0 }.first?.accountUUID == Data(second.id.id).hexEncodedString())
        }
    }

    /// Every account `.complete`/`.notStarted`: `WakeupAction.decide` resolves to `.cancelAll`,
    /// which `execute(_:)` runs through `userNotifications.cancelMigrationNotifications()` — the one
    /// piece of `.cancelAll`'s effect this suite can observe without touching `BGTaskScheduler
    /// .shared` directly.
    ///
    /// R8-T5 (#8-c): this is also the guard that the conservative-active fix doesn't kill the
    /// LEGITIMATE cancelAll path — no account here is unreadable, so `cancelAll` must still fire.
    @Test func armCancelsAllWhenEveryAccountIsCompleteOrNotStarted() async {
        let selected = Self.walletAccount(idByte: 1)
        let second = Self.walletAccount(idByte: 2)
        let cancelCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
            @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
            $selectedWalletAccount.withLock { $0 = selected }
            $walletAccounts.withLock { $0 = [selected, second] }

            await withDependencies {
                $0.migrationManager.isManualDelivery = { false }
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.getMigrationState = { accountUUID in
                    accountUUID == selected.id ? MigrationState.complete : MigrationState.notStarted
                }
                $0.userNotifications.cancelMigrationNotifications = { cancelCalls.withValue { $0 += 1 } }
            } operation: {
                let impl = MigrationBGSchedulerImpl()
                await impl.arm(margin: MigrationCadence.nextWindowMargin)
            }

            #expect(cancelCalls.withValue { $0 } == 1)
        }
    }

    // MARK: - R8-T5 (#8): conservative-active — a throwing account must never cause a wrongful cancelAll

    private struct ArmTestReadFailure: Error { }

    /// #8-a: one account's SDK read throws, the other is genuinely `.complete`. The throwing
    /// account must NOT be silently treated as done: `cancelMigrationNotifications` must never fire
    /// (no cancelAll), and a retry window IS armed instead (the manual-ready notification schedule
    /// call — the one piece of a non-cancelAll outcome this suite can observe without touching
    /// `BGTaskScheduler.shared` directly). RED against the pre-fix `arm(margin:)`: its catch branch
    /// dropped the throwing account from `rearmInputs` entirely, leaving only the genuinely-complete
    /// account, so `planRearm` resolved `.complete` and `WakeupAction.decide` returned `.cancelAll`.
    @Test func armDoesNotCancelAllWhenOneAccountThrows() async {
        let selected = Self.walletAccount(idByte: 1)
        let second = Self.walletAccount(idByte: 2)
        let cancelCalls = LockIsolated<Int>(0)
        let scheduleCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
            @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
            $selectedWalletAccount.withLock { $0 = selected }
            $walletAccounts.withLock { $0 = [selected, second] }

            await withDependencies {
                $0.migrationManager.isManualDelivery = { true }
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.getMigrationState = { accountUUID in
                    if accountUUID == selected.id {
                        throw ArmTestReadFailure()
                    }
                    return MigrationState.complete
                }
                $0.userNotifications.scheduleMigrationNotification = { _, _, _ in scheduleCalls.withValue { $0 += 1 } }
                $0.userNotifications.cancelMigrationNotifications = { cancelCalls.withValue { $0 += 1 } }
            } operation: {
                let impl = MigrationBGSchedulerImpl()
                await impl.arm(margin: MigrationCadence.nextWindowMargin)
            }

            #expect(cancelCalls.withValue { $0 } == 0)
            #expect(scheduleCalls.withValue { $0 } == 1)
        }
    }

    /// #8-b: EVERY account's SDK read throws — must still arm a retry window at `margin`, never
    /// skip arming entirely. RED against the pre-fix `arm(margin:)`: every account dropped on catch
    /// left `rearmInputs` empty, and the function returned having armed NOTHING — silently killing
    /// the wakeup chain, since no other call site re-attempts `arm(margin:)` on its own
    /// (`willEnterForeground` only calls `migrationManager.reconcile()`, which does not re-arm).
    @Test func armArmsRetryWindowWhenAllAccountsThrow() async {
        let selected = Self.walletAccount(idByte: 1)
        let scheduleCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
            @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
            $selectedWalletAccount.withLock { $0 = selected }
            $walletAccounts.withLock { $0 = [selected] }

            await withDependencies {
                $0.migrationManager.isManualDelivery = { true }
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.getMigrationState = { _ in throw ArmTestReadFailure() }
                $0.userNotifications.scheduleMigrationNotification = { _, _, _ in scheduleCalls.withValue { $0 += 1 } }
            } operation: {
                let impl = MigrationBGSchedulerImpl()
                await impl.arm(margin: MigrationCadence.nextWindowMargin)
            }

            // A retry window IS armed: the manual-delivery notification path fires (scheduled mode
            // would instead hit the real, unmockable `BGTaskScheduler.shared.submit(_:)` — see this
            // suite's own header doc for why only the manual path is asserted here).
            #expect(scheduleCalls.withValue { $0 } == 1)
        }
    }
}
