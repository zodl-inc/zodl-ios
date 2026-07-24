//
//  AdvancedSettingsDebugMigrationTests.swift
//  zodlTests
//
//  MOB-1513: covers the DEBUG-builds-only Advanced Settings actions that let QA fast-reschedule a
//  committed migration schedule (`debugRescheduleMigrationTransfers`) and manually deliver the
//  next due migration transfer (`executeNextPendingMigrationTransfer`) without waiting out ZIP
//  318's privacy delay. Both rows render only in DEBUG builds (see `AdvancedSettingsView`'s
//  `#if DEBUG` section), but the tests below need no `#if DEBUG` guard of their own — the test
//  target always builds DEBUG, so the feature under test is always compiled in.
//
//  Row 1 (`debugMigrationRescheduleTapped`): reschedule -> reconcile -> scheduleFirstWindow, in
//  that order, then a result alert (count > 0 / count == 0 / thrown error).
//
//  Row 2 (`debugMigrationDeliverTapped`): reads `migrationNetworkOptions`, stops sync BEFORE
//  calling `executeNextPendingMigrationTransfer`, then a result alert (delivered / nothing due /
//  thrown error). No manual sync-resume call is made — see `AdvancedSettingsStore`'s doc for the
//  finding on why that mirrors `MigrationSendingStore` only partially.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct AdvancedSettingsDebugMigrationTests {
    private static let account = WalletAccount(
        Account(
            id: AccountUUID(id: [UInt8](repeating: 7, count: 16)),
            name: "Zodl",
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        )
    )

    /// Every effect under test resolves the selected account — seeds one by default, same idiom
    /// as `MigrationSendingTests`' `init()`.
    init() {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account }
    }

    private func noAccountSelected() {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = nil }
    }

    // MARK: - Row 1: debugMigrationRescheduleTapped

    /// Happy path, call-order assertion: reschedule -> reconcile -> scheduleFirstWindow, matching
    /// the task's specified effect chain exactly.
    @MainActor @Test func rescheduleTappedCallsRescheduleThenReconcileThenScheduleFirstWindowInOrder() async {
        let callOrder = LockIsolated<[String]>([])
        let capturedAccountUUIDs = LockIsolated<[AccountUUID]>([])
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.debugRescheduleMigrationTransfers = { accountUUID in
                callOrder.withValue { $0.append("reschedule") }
                capturedAccountUUIDs.withValue { $0.append(accountUUID) }
                return 3
            }
            $0.migrationManager.reconcile = { callOrder.withValue { $0.append("reconcile") } }
            $0.migrationBGScheduler.scheduleFirstWindow = { callOrder.withValue { $0.append("scheduleFirstWindow") } }
        }

        await store.send(.debugMigrationRescheduleTapped)
        await store.receive(\.debugMigrationRescheduleFinished) {
            $0.alert = AlertState.debugMigrationRescheduleResult(.rescheduled(count: 3))
        }

        #expect(callOrder.value == ["reschedule", "reconcile", "scheduleFirstWindow"])
        #expect(capturedAccountUUIDs.value == [Self.account.id])
    }

    @MainActor @Test func rescheduleTappedWithPositiveCountShowsSuccessAlert() async {
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.debugRescheduleMigrationTransfers = { _ in 5 }
            $0.migrationManager.reconcile = { }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
        }

        await store.send(.debugMigrationRescheduleTapped)
        await store.receive(\.debugMigrationRescheduleFinished) {
            $0.alert = AlertState.debugMigrationRescheduleResult(.rescheduled(count: 5))
        }
    }

    @MainActor @Test func rescheduleTappedWithZeroCountShowsZeroAlert() async {
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.debugRescheduleMigrationTransfers = { _ in 0 }
            $0.migrationManager.reconcile = { }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
        }

        await store.send(.debugMigrationRescheduleTapped)
        await store.receive(\.debugMigrationRescheduleFinished) {
            $0.alert = AlertState.debugMigrationRescheduleResult(.rescheduled(count: 0))
        }
    }

    /// A thrown error must skip `reconcile`/`scheduleFirstWindow` entirely (nothing to reconcile
    /// or re-arm when the reschedule itself never happened) and surface the error's own text.
    @MainActor @Test func rescheduleTappedWhenThrowsShowsErrorAlertAndSkipsReconcileAndSchedule() async {
        let reconcileCalls = LockIsolated<Int>(0)
        let scheduleCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.debugRescheduleMigrationTransfers = { _ in throw ZcashError.txIdNot32Bytes }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            $0.migrationBGScheduler.scheduleFirstWindow = { scheduleCalls.withValue { $0 += 1 } }
        }

        await store.send(.debugMigrationRescheduleTapped)
        await store.receive(\.debugMigrationRescheduleFinished) {
            $0.alert = AlertState.debugMigrationRescheduleResult(.failed(ZcashError.txIdNot32Bytes.localizedDescription))
        }

        #expect(reconcileCalls.value == 0)
        #expect(scheduleCalls.value == 0)
    }

    /// Defensive edge case, not explicitly spec'd but exercised for robustness: no selected
    /// account must never reach the SDK.
    @MainActor @Test func rescheduleTappedWithNoSelectedAccountShowsErrorAlertWithoutCallingSDK() async {
        noAccountSelected()

        let calls = LockIsolated<Int>(0)
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.debugRescheduleMigrationTransfers = { _ in
                calls.withValue { $0 += 1 }
                return 1
            }
        }

        await store.send(.debugMigrationRescheduleTapped)
        await store.receive(\.debugMigrationRescheduleFinished) {
            $0.alert = AlertState.debugMigrationRescheduleResult(.failed("No wallet account selected"))
        }

        #expect(calls.value == 0)
    }

    // MARK: - Row 2: debugMigrationDeliverTapped

    /// Call-order assertion: `stopSyncBeforeMigrationBroadcast()` fires BEFORE
    /// `executeNextPendingMigrationTransfer`, mirroring every other foreground migration broadcast
    /// lane (`MigrationSendingStore`).
    @MainActor @Test func deliverTappedStopsSyncBeforeExecutingTransfer() async {
        let callOrder = LockIsolated<[String]>([])
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { callOrder.withValue { $0.append("stop") } },
                isSyncing: { true }
            )
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                callOrder.withValue { $0.append("execute") }
                return MigrationTransferResult.success(txId: "tx-order")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
        }

        await store.send(.debugMigrationDeliverTapped)
        await store.receive(\.debugMigrationDeliverFinished) {
            $0.alert = AlertState.debugMigrationDeliverResult(.delivered(txId: "tx-order"))
        }

        #expect(callOrder.value == ["stop", "execute"])
    }

    @MainActor @Test func deliverTappedWithDeliveredResultShowsSuccessAlert() async {
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                MigrationTransferResult.success(txId: "e87f1234567890abcdef6f28bd0011223344")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
        }

        await store.send(.debugMigrationDeliverTapped)
        await store.receive(\.debugMigrationDeliverFinished) {
            $0.alert = AlertState.debugMigrationDeliverResult(.delivered(txId: "e87f1234567890abcdef6f28bd0011223344"))
        }
    }

    @MainActor @Test func deliverTappedWithNilResultShowsNothingDueAlert() async {
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
        }

        await store.send(.debugMigrationDeliverTapped)
        await store.receive(\.debugMigrationDeliverFinished) {
            $0.alert = AlertState.debugMigrationDeliverResult(.nothingDue)
        }
    }

    @MainActor @Test func deliverTappedWhenThrowsShowsErrorAlert() async {
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in throw ZcashError.txIdNot32Bytes }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
        }

        await store.send(.debugMigrationDeliverTapped)
        await store.receive(\.debugMigrationDeliverFinished) {
            $0.alert = AlertState.debugMigrationDeliverResult(.failed(ZcashError.txIdNot32Bytes.localizedDescription))
        }
    }

    /// A returned (not thrown) non-success outcome — e.g. a network error at broadcast time — is
    /// neither "delivered" nor genuinely "nothing due"; routed to the same failed-style alert as a
    /// thrown error rather than mislabeled as nothing-due.
    @MainActor @Test func deliverTappedWithNetworkErrorResultShowsFailedAlertNotNothingDue() async {
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
        }

        await store.send(.debugMigrationDeliverTapped)
        await store.receive(\.debugMigrationDeliverFinished) {
            $0.alert = AlertState.debugMigrationDeliverResult(
                .failed(String(describing: MigrationTransferResult.networkError(retryable: true)))
            )
        }
    }

    /// Defensive edge case, not explicitly spec'd but exercised for robustness: no selected
    /// account must never reach the SDK.
    @MainActor @Test func deliverTappedWithNoSelectedAccountShowsErrorAlertWithoutCallingSDK() async {
        noAccountSelected()

        let calls = LockIsolated<Int>(0)
        let store = TestStore(initialState: AdvancedSettings.State()) {
            AdvancedSettings()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                calls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
        }

        await store.send(.debugMigrationDeliverTapped)
        await store.receive(\.debugMigrationDeliverFinished) {
            $0.alert = AlertState.debugMigrationDeliverResult(.failed("No wallet account selected"))
        }

        #expect(calls.value == 0)
    }
}
