//
//  MigrationSnapshotFreshnessTests.swift
//  zodlTests
//
//  Q2-1 (read-only SDK reads): the snapshot pipeline no longer serves stale caches or drops
//  rebuild requests while migration work is in flight — reads are cheap now, so every request
//  builds. These pin the three behaviors the cache retirement changes.
//
//  Fixture conventions mirror the retired warm-up suite's idiom (fixed-bytes AccountUUID, the tip/
//  activation-height pair, `withDependencies`, the `waitUntil` real-time poll for a concurrently
//  running derivation) and MigrationSentRecordAttributionTests (the committed-schedule builder, a
//  named `UserDefaults` suite for `MigrationScheduleStorage`). Serialized: installs the same
//  wallet-wide candidate account set (`@Shared(.inMemory(.selectedWalletAccount))` /
//  `.walletAccounts`) those suites serialize their own runs over.
//

import Foundation
import Combine
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationSnapshotFreshnessTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x59, count: 16))
    /// Testnet NU6.3, mirroring the retired warm-up suite's fixture — the tip sits above it.
    private static let activationHeight: BlockHeight = 4_134_000
    private static let tip: BlockHeight = 4_200_000
    private static let suiteName = "MigrationSnapshotFreshnessTests"

    private static func atTipState() -> SynchronizerState {
        var state = SynchronizerState.zero
        state.latestBlockHeight = tip
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

    /// Installs `accountUUID` as the sole candidate — selected AND the whole wallet-account list —
    /// mirrors the retired warm-up suite's `installCandidateAccount()`.
    private static func installCandidateAccount() {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        $selectedWalletAccount.withLock { $0 = Self.account() }
        $walletAccounts.withLock { $0 = [Self.account()] }
    }

    /// One ready-to-prove transfer status — see the doc on the retired warm-up suite's
    /// `oneTransferStatus`: enough for the W1 fallback (no committed schedule) to resolve a
    /// non-empty row list.
    private static func oneTransferStatus() -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: 1,
            kind: MigrationTransactionStatus.Kind.transfer(crossing: 0),
            state: MigrationTransactionStatus.State.proved,
            scheduledHeight: Self.tip,
            expiryHeight: nil,
            isReady: true,
            nextAction: MigrationTransactionStatus.NextAction.prove,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    private static func someProgress() -> MigrationProgress {
        MigrationProgress(completedTransfers: 0, totalTransfers: 1, remainingOrchard: Zatoshi.zero, nextTransferReadyAtHeight: nil)
    }

    /// A single committed-schedule transfer — enough for `scheduleStorage.committedSchedule(for:)`
    /// to answer non-nil, which is all the route short-circuit needs (it is epoch- and
    /// content-blind: existence is the whole question).
    private static func schedule() -> MigrationSchedule {
        MigrationSchedule(
            transfers: [
                MigrationTransferProposal(
                    id: 0,
                    amount: Zatoshi(100_000_000),
                    anchorHeight: BlockHeight(3_000_000),
                    nextExecutableAfterHeight: BlockHeight(3_000_100),
                    expiryHeight: BlockHeight(3_000_140)
                )
            ],
            estimatedDurationHours: 0,
            proposalHandle: 0,
            preparations: []
        )
    }

    /// A fresh storage over a wiped named suite, pre-seeded with the committed schedule — mirrors
    /// `MigrationSentRecordAttributionTests.makeStorage()`.
    private static func makeCommittedScheduleStorage() -> MigrationScheduleStorage {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let storage = MigrationScheduleStorage(userDefaults: defaults)
        storage.recordCommittedSchedule(schedule(), for: accountUUID, now: Date())
        return storage
    }

    /// Short, repeated real-time polling for a condition driven by a concurrently-running `Task` —
    /// mirrors the retired warm-up suite's `waitUntil`, needed here to know a coalesced republish
    /// Task has actually landed its build before the test inspects the result. Sized generously
    /// (mirroring `MigrationSyncCompleteEdgeTests`'s bound) — under parallel test load the
    /// concurrently-running `Task` this polls for can be scheduled well behind a tighter deadline.
    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// A refresh requested WHILE work is in flight still lands a publish — the old pipeline
    /// dropped it (`guard !isMigrationWorkInFlight`), leaving the screen on the last value
    /// until some later edge.
    @Test func aRefreshDuringInFlightWorkStillPublishes() async throws {
        Self.installCandidateAccount()

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                migrationTransactionStatuses: { _ in [Self.oneTransferStatus()] },
                getMigrationProgress: { _ in Self.someProgress() }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = MigrationManagerImpl()
            manager.setMigrationWorkInFlight(true)

            let received = LockIsolated<MigrationViewSnapshot?>(nil)
            var cancellables = Set<AnyCancellable>()
            manager.migrationSnapshotEvents(accountUUID: Self.accountUUID)
                .sink { snapshot in received.setValue(snapshot) }
                .store(in: &cancellables)

            manager.refreshMigrationSnapshot(accountUUID: Self.accountUUID)

            await Self.waitUntil { received.value != nil }

            // `refreshMigrationSnapshot` fires the build on `Task { [weak self] in ... }` — with no
            // further use of `manager` in this scope, ARC is free to release it the instant this
            // scope stops needing it, which under parallel test load can land BEFORE that detached
            // task body ever runs, silently no-op'ing the very build the wait above is waiting on.
            // Reading `manager` again here keeps it alive across the whole wait, and doubles as its
            // own pin: the channel's synchronous snapshot read must agree with the async emission
            // the sink above already saw.
            #expect(manager.currentMigrationSnapshot(accountUUID: Self.accountUUID) != nil)

            #expect(
                received.value != nil,
                "a refresh requested while migration work is in flight must still publish — the old drop-guard left the screen on its last value forever"
            )
        }
    }

    /// The route short-circuit survives the cache retirement: work in flight + a COMMITTED
    /// SCHEDULE (not a warmed cache) short-circuits to statusProgress.
    @Test func theRouteShortCircuitKeysOffTheCommittedSchedule() async throws {
        Self.installCandidateAccount()
        let storage = Self.makeCommittedScheduleStorage()

        await withDependencies {
            $0.sdkSynchronizer = .mocked(latestState: { Self.atTipState() })
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = MigrationManagerImpl(scheduleStorage: storage)
            manager.setMigrationWorkInFlight(true)

            let route = await manager.reentryRoute()

            #expect(route == MigrationReentryRoute.statusProgress)
        }
    }

    // (`viewFreshnessStampsOnPublish` — the pin for `isMigrationViewFresh` — was REMOVED
    // 2026-08-07 with the probe itself. Its only production consumers were the migration
    // screen's `isUpdating` writes, and that label was never in any design — nor was the
    // `asOfSyncedAt` age line that went with it on the same day.)
}
