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
            nextTransferNumber: 1
        )

        #expect(action == WakeupAction.submitTask(earliestBeginDate: Self.window))
    }

    @Test func manualModeSchedulesReadyNotificationWithGivenWindowAndNumber() {
        let action = WakeupAction.decide(
            state: MigrationState.notStarted,
            isManualDelivery: true,
            window: Self.window,
            nextTransferNumber: 3
        )

        #expect(action == WakeupAction.scheduleReadyNotification(number: 3, at: Self.window))
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
            nextTransferNumber: 3
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
            nextTransferNumber: 3
        )

        #expect(action == WakeupAction.scheduleReadyNotification(number: 3, at: Self.window))
    }

    @Test func requiresAttentionScheduledModeSubmitsTask() {
        let action = WakeupAction.decide(
            state: MigrationState.requiresAttention(MigrationAttentionReason.transferExpired),
            isManualDelivery: false,
            window: Self.window,
            nextTransferNumber: 2
        )

        #expect(action == WakeupAction.submitTask(earliestBeginDate: Self.window))
    }

    @Test func requiresAttentionManualModeSchedulesReadyNotification() {
        let action = WakeupAction.decide(
            state: MigrationState.requiresAttention(MigrationAttentionReason.invalidTransfer(transferId: "t1")),
            isManualDelivery: true,
            window: Self.window,
            nextTransferNumber: 1
        )

        #expect(action == WakeupAction.scheduleReadyNotification(number: 1, at: Self.window))
    }

    // MARK: - .complete always wins, regardless of mode

    @Test func completeStateCancelsAllInScheduledMode() {
        let action = WakeupAction.decide(
            state: MigrationState.complete,
            isManualDelivery: false,
            window: Self.window,
            nextTransferNumber: 1
        )

        #expect(action == WakeupAction.cancelAll)
    }

    @Test func completeStateCancelsAllInManualMode() {
        let action = WakeupAction.decide(
            state: MigrationState.complete,
            isManualDelivery: true,
            window: Self.window,
            nextTransferNumber: 1
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
                expected: WakeupAction.scheduleReadyNotification(number: 1, at: Self.window)
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
                expected: WakeupAction.scheduleReadyNotification(number: 2, at: Self.window)
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
                nextTransferNumber: row.nextTransferNumber
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
                $0.userNotifications.scheduleMigrationNotification = { _, _ in scheduleCalls.withValue { $0 += 1 } }
            } operation: {
                let impl = MigrationBGSchedulerImpl()
                await impl.arm(margin: MigrationCadence.nextWindowMargin)
            }

            #expect(scheduleCalls.withValue { $0 } == 0)
        }
    }

    /// Two accounts, distinct next-executable heights: the EARLIER one's window/number reaches
    /// `WakeupAction.decide` — asserted via the manual-delivery notification it produces.
    @Test func armUsesTheEarliestAcrossAccountsWindowAndItsOwnTransferNumber() async {
        let selected = Self.walletAccount(idByte: 1)
        let second = Self.walletAccount(idByte: 2)
        let laterProgress = MigrationProgress(completedTransfers: 5, totalTransfers: 9, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil)
        let earlierProgress = MigrationProgress(completedTransfers: 1, totalTransfers: 9, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil)
        let scheduled = LockIsolated<[(number: Int, at: Date)]>([])

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
                $0.userNotifications.scheduleMigrationNotification = { notification, at in
                    if case let MigrationNotification.manualTransferReady(number) = notification, let at {
                        scheduled.withValue { $0.append((number, at)) }
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
        }
    }

    /// Every account `.complete`/`.notStarted`: `WakeupAction.decide` resolves to `.cancelAll`,
    /// which `execute(_:)` runs through `userNotifications.cancelMigrationNotifications()` — the one
    /// piece of `.cancelAll`'s effect this suite can observe without touching `BGTaskScheduler
    /// .shared` directly.
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
}
