//
//  MigrationSweepBannerFreshnessTests.swift
//  zodlTests
//
//  MOB-1749 field bug: after "Migrate anyway" broadcasts the immediate sweep, the Home banner kept
//  advertising the residual (`.residual(amount:)`) while a fresh `reentryRoute()` already answered
//  `.entry` — the two surfaces disagreed because `bannerVariant` serves the PUBLISHED snapshot and
//  the sweep's success chain (`recordTransferBroadcast` → `reconcile()`) is the only thing that can
//  republish it on that path. These tests replay that exact chain at the manager level, with the
//  SDK facts the device reported (an immediate run in progress), and pin that the published banner
//  retires.
//
//  Fixture conventions mirror MigrationSnapshotFreshnessTests (fixed-bytes AccountUUID, the tip/
//  activation pair, `withDependencies`, `waitUntil` real-time polling, `.serialized` because the
//  wallet-wide candidate set rides `@Shared(.inMemory(...))`).
//

import Foundation
import Combine
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationSweepBannerFreshnessTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x5A, count: 16))
    private static let activationHeight: BlockHeight = 4_134_000
    private static let tip: BlockHeight = 4_200_000
    private static let suiteName = "MigrationSweepBannerFreshnessTests"

    /// Caught up at the tip — the residual banner requires the offer gate open, and on the device
    /// the pre-broadcast stop no-ops on an idle-at-tip engine, so the status stays `.upToDate`
    /// through the whole sweep.
    private static func caughtUpState() -> SynchronizerState {
        var state = SynchronizerState.zero
        state.latestBlockHeight = tip
        state.syncStatus = SyncStatus.upToDate
        return state
    }

    private static func account() -> WalletAccount {
        WalletAccount(
            Account(
                id: accountUUID,
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private static func installCandidateAccount() {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        $selectedWalletAccount.withLock { $0 = Self.account() }
        $walletAccounts.withLock { $0 = [Self.account()] }
    }

    /// A residual candidate: 0.008 ZEC spendable Orchard, Ironwood funds present.
    private static func candidateBalance() -> AccountBalance {
        AccountBalance(
            saplingBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            orchardBalance: PoolBalance(spendableValue: Zatoshi(800_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            ironwoodBalance: PoolBalance(spendableValue: Zatoshi(1_000_000_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            unshielded: .zero,
            awaitingResolution: .zero
        )
    }

    /// The same wallet right after the sweep broadcast: the Orchard notes are spent by the unmined
    /// transaction, the swept value sits pending in Ironwood.
    private static func sweptBalance() -> AccountBalance {
        AccountBalance(
            saplingBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            orchardBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            ironwoodBalance: PoolBalance(
                spendableValue: Zatoshi(1_000_000_000),
                changePendingConfirmation: .zero,
                valuePendingSpendability: Zatoshi(785_000)
            ),
            unshielded: .zero,
            awaitingResolution: .zero
        )
    }

    /// What `getMigrationProgress` reports while the recorded immediate sweep is unmined — the
    /// SDK's documented `0 of 1, isImmediate` snapshot.
    private static func immediateProgress() -> MigrationProgress {
        MigrationProgress(
            completedTransfers: 0,
            totalTransfers: 1,
            remainingOrchard: Zatoshi.zero,
            nextTransferReadyAtHeight: nil,
            isImmediate: true
        )
    }

    /// A fresh schedule storage over a wiped named suite — no committed schedule (the immediate
    /// lane never stores one), just isolation from the standard defaults.
    private static func makeEmptyScheduleStorage() -> MigrationScheduleStorage {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return MigrationScheduleStorage(userDefaults: defaults)
    }

    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The device's happy path, replayed verbatim: the sweep lands, the SDK flips to "immediate run
    /// in progress, notes spent", and the sending screen's success chain runs
    /// `recordTransferBroadcast` → `reconcile()`. The published snapshot the banner reads must stop
    /// answering `.residual` before the user can leave the flow.
    @Test func theImmediateSweepSuccessChainRetiresThePublishedResidualBanner() async throws {
        Self.installCandidateAccount()

        let isSwept = LockIsolated<Bool>(false)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.caughtUpState() },
                getMigrationProgress: { _ in isSwept.value ? Self.immediateProgress() : nil },
                getAccountsBalances: { [Self.accountUUID: isSwept.value ? Self.sweptBalance() : Self.candidateBalance()] }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = MigrationManagerImpl(scheduleStorage: Self.makeEmptyScheduleStorage())

            let received = LockIsolated<MigrationViewSnapshot?>(nil)
            var cancellables = Set<AnyCancellable>()
            manager.migrationSnapshotEvents(accountUUID: Self.accountUUID)
                .sink { snapshot in received.setValue(snapshot) }
                .store(in: &cancellables)

            manager.refreshMigrationSnapshot(accountUUID: Self.accountUUID)
            await Self.waitUntil { received.value?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)) }
            #expect(
                received.value?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)),
                "precondition: the pre-sweep snapshot advertises the residual"
            )
            await Self.waitUntil { manager.isSnapshotRepublishIdle(for: Self.accountUUID) }

            // The sweep broadcast lands — from here on the SDK reports the immediate run.
            isSwept.setValue(true)

            // MigrationSendingStore's `.transferResult(.success)` chain, verbatim.
            await manager.recordTransferBroadcast(
                accountUUID: Self.accountUUID,
                result: MigrationTransferResult.success(txId: "aa00")
            )
            await manager.reconcile()

            await Self.waitUntil { manager.isSnapshotRepublishIdle(for: Self.accountUUID) }
            #expect(
                manager.isSnapshotRepublishIdle(for: Self.accountUUID),
                "quiescence precondition timed out — raise waitUntil's deadline before suspecting the product"
            )

            let published = manager.currentMigrationSnapshot(accountUUID: Self.accountUUID)
            #expect(
                published?.banner == nil,
                "the sweep's success chain must leave the published snapshot rebuilt — a stale .residual here is the banner that survives its own sweep"
            )
            let reread = await manager.bannerVariant(accountUUID: Self.accountUUID)
            #expect(
                reread == nil,
                "the flow-close re-read (Root's flowFinished poke) must see the sweep, not the pre-sweep snapshot"
            )
        }
    }

    /// The device timeline, deterministically: a snapshot build is several FFI reads (measured
    /// 4.75 s quiet in the field), while `reconcile()`'s republish is scheduled, never awaited —
    /// so the success chain returns, the user closes the flow, and Root's `flowFinished` re-read
    /// races a build that has barely started. The 300 ms delay on the build-only estimate read
    /// stands in for those seconds; the re-read runs immediately after the chain returns, exactly
    /// as the flow-close poke does. The sweep is a WRITER EDGE — by the time its success chain
    /// returns, the published snapshot must already tell the post-sweep truth (the same guarantee
    /// `lockMigrationDust` gives the lock).
    @Test func theSweepSuccessChainOutrunsItsOwnRepublish() async throws {
        Self.installCandidateAccount()

        let isSwept = LockIsolated<Bool>(false)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.caughtUpState() },
                estimateMigrationRunCount: { _ in
                    if isSwept.value {
                        // Only the snapshot BUILD reads this (bannerArm → migrationRoundContext);
                        // reconcile's own reads never do — the delay slows the rebuild alone.
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                    return nil
                },
                getMigrationProgress: { _ in isSwept.value ? Self.immediateProgress() : nil },
                getAccountsBalances: { [Self.accountUUID: isSwept.value ? Self.sweptBalance() : Self.candidateBalance()] }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = MigrationManagerImpl(scheduleStorage: Self.makeEmptyScheduleStorage())

            let received = LockIsolated<MigrationViewSnapshot?>(nil)
            var cancellables = Set<AnyCancellable>()
            manager.migrationSnapshotEvents(accountUUID: Self.accountUUID)
                .sink { snapshot in received.setValue(snapshot) }
                .store(in: &cancellables)

            manager.refreshMigrationSnapshot(accountUUID: Self.accountUUID)
            await Self.waitUntil { received.value?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)) }
            #expect(
                received.value?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)),
                "precondition: the pre-sweep snapshot advertises the residual"
            )
            await Self.waitUntil { manager.isSnapshotRepublishIdle(for: Self.accountUUID) }

            isSwept.setValue(true)

            await manager.recordTransferBroadcast(
                accountUUID: Self.accountUUID,
                result: MigrationTransferResult.success(txId: "aa00")
            )
            await manager.reconcile()

            // NO idle wait — this is the flow-close re-read, which on the device runs the moment
            // the user taps Close on the success screen.
            let reread = await manager.bannerVariant(accountUUID: Self.accountUUID)
            #expect(
                reread == nil,
                "the success chain returned with the published snapshot still pre-sweep — the flow-close re-read re-seats the retired residual banner"
            )

            // Drain the delayed build so it cannot leak into the next test.
            await Self.waitUntil { manager.isSnapshotRepublishIdle(for: Self.accountUUID) }
        }
    }

    /// The transient the device can hit in the post-broadcast window: the engine's advance-step
    /// read fails once while `reconcile()` walks the account. The banner must still retire — a
    /// republish skipped here leaves the stale `.residual` standing for the flow-close re-read,
    /// which is exactly the field bug.
    @Test func aFailedStateReadDuringReconcileStillRetiresTheResidualBanner() async throws {
        Self.installCandidateAccount()

        let isSwept = LockIsolated<Bool>(false)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.caughtUpState() },
                migrationAdvanceStep: { _ in
                    if isSwept.value {
                        throw ZcashError.synchronizerNotPrepared
                    }
                    return nil
                },
                getMigrationProgress: { _ in isSwept.value ? Self.immediateProgress() : nil },
                getAccountsBalances: { [Self.accountUUID: isSwept.value ? Self.sweptBalance() : Self.candidateBalance()] }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = MigrationManagerImpl(scheduleStorage: Self.makeEmptyScheduleStorage())

            let received = LockIsolated<MigrationViewSnapshot?>(nil)
            var cancellables = Set<AnyCancellable>()
            manager.migrationSnapshotEvents(accountUUID: Self.accountUUID)
                .sink { snapshot in received.setValue(snapshot) }
                .store(in: &cancellables)

            manager.refreshMigrationSnapshot(accountUUID: Self.accountUUID)
            await Self.waitUntil { received.value?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)) }
            #expect(
                received.value?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)),
                "precondition: the pre-sweep snapshot advertises the residual"
            )
            await Self.waitUntil { manager.isSnapshotRepublishIdle(for: Self.accountUUID) }

            isSwept.setValue(true)

            await manager.recordTransferBroadcast(
                accountUUID: Self.accountUUID,
                result: MigrationTransferResult.success(txId: "aa00")
            )
            await manager.reconcile()

            await Self.waitUntil { manager.isSnapshotRepublishIdle(for: Self.accountUUID) }

            let reread = await manager.bannerVariant(accountUUID: Self.accountUUID)
            #expect(
                reread != MigrationBannerVariant.residual(amount: Zatoshi(800_000)),
                "a transient advance-step failure during the post-broadcast reconcile must not leave the retired residual banner standing"
            )
        }
    }
}
