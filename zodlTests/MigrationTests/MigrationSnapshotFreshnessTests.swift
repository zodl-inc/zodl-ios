//
//  MigrationSnapshotFreshnessTests.swift
//  zodlTests
//
//  Q2-1 (read-only SDK reads): the snapshot pipeline no longer serves stale caches or drops
//  rebuild requests while migration work is in flight — reads are cheap now, so every request
//  builds. These pin the three behaviors the cache retirement changes.
//
//  Fixture conventions mirror the retired warm-up suite's idiom (fixed-bytes AccountUUID, the tip/
//  activation-height pair, `withDependencies`) and MigrationSentRecordAttributionTests (the
//  committed-schedule builder, a named `UserDefaults` suite for `MigrationScheduleStorage`).
//  Serialized: installs the same wallet-wide candidate account set
//  (`@Shared(.inMemory(.selectedWalletAccount))` / `.walletAccounts`) those suites serialize their
//  own runs over.
//
//  A concurrently-running derivation (the coalesced republish `Task` `refreshMigrationSnapshot`
//  fires) is awaited event-driven, never polled:
//  `firstSnapshot(of:matching:storingIn:afterSubscribing:)` bridges Combine's `first(where:)` to a
//  continuation for "a specific published snapshot landed", and
//  `MigrationManagerImpl.awaitSnapshotRepublishIdle(for:)` (a test-support hook, its awaitable
//  sibling to the synchronous `isSnapshotRepublishIdle(for:)`) is suspended on directly for "the
//  coalescer went idle". An earlier version polled both against a wall-clock deadline (`waitUntil`,
//  10 s) — correct in kind (a real condition, not a blind sleep) but still a fixed budget racing
//  work whose actual duration scales with CI load, so a busier-than-tested runner could always
//  make the deadline lose even though nothing was wrong.
//
//  `.timeLimit` below is NOT the only clock left in this suite's path.
//  `lockingRepublishesTheSnapshotBeforeReturning` still calls `lockMigrationDust`, which separately
//  wraps its own awaited republish in the PRODUCTION `lockRepublishTimeoutNanoseconds` bound (10 s,
//  `awaitBounded`, in MigrationManagerLiveKey.swift) — under starvation extreme enough, that budget
//  can still lose to the mocked build, in which case `lockMigrationDust` returns early by design
//  (its documented heal path) and this test's final `#expect(published.banner == nil)` would see
//  the stale residual. A recurrence there is that production-side bound doing its job under an
//  even worse runner, not a gap in the waits this file controls.
//
//  `.timeLimit` is also not a hang-preventer: both new awaits above are plain
//  `withCheckedContinuation`s with no cancellation handler, so a coalescer that genuinely never
//  goes idle leaves the suspended `Task` running regardless of the trait. What `.timeLimit` does is
//  RECORD the test as failed at 60 s instead of the run showing it as still in progress forever —
//  an actual hang is bounded only by the CI job's own timeout, outside this file's control.
//

import Foundation
import Combine
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(1))) struct MigrationSnapshotFreshnessTests {
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

    /// The same wallet, CAUGHT UP — `atTipState()` above sets only the height and inherits
    /// `SynchronizerState.zero`'s sync status, which the residual lane's offer gate reads as "not
    /// caught up". Mirrors `MigrationBannerEntryTests.syncedState()`, the pinned caught-up fixture.
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

    /// Suspends until `publisher` emits a snapshot matching `predicate`, resumed by the emission
    /// itself (`Combine.Publisher.first(where:)` cancels upstream after its one match, bridged to
    /// `async`/`await` by a continuation) instead of polled — see the file header for why a
    /// wall-clock deadline over this coalescer proved flaky under CI load. `cancellables` is the
    /// caller's own store (mirrors the existing `Set<AnyCancellable>` idiom): Combine drops a
    /// subscription nobody retains. `afterSubscribing` runs the writer edge that is expected to
    /// produce the match (a refresh, a lock) — called from INSIDE the same synchronous setup
    /// `withCheckedContinuation` runs, so the subscription is always live before that edge's build
    /// can possibly publish, the same ordering a plain `.sink` before the write already required.
    private static func firstSnapshot(
        of publisher: AnyPublisher<MigrationViewSnapshot?, Never>,
        matching predicate: @escaping @Sendable (MigrationViewSnapshot?) -> Bool,
        storingIn cancellables: inout Set<AnyCancellable>,
        afterSubscribing trigger: () -> Void
    ) async -> MigrationViewSnapshot? {
        await withCheckedContinuation { (continuation: CheckedContinuation<MigrationViewSnapshot?, Never>) in
            publisher
                .first(where: predicate)
                .sink { snapshot in continuation.resume(returning: snapshot) }
                .store(in: &cancellables)
            trigger()
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

            var cancellables = Set<AnyCancellable>()
            let published = await Self.firstSnapshot(
                of: manager.migrationSnapshotEvents(accountUUID: Self.accountUUID),
                matching: { $0 != nil },
                storingIn: &cancellables
            ) {
                manager.refreshMigrationSnapshot(accountUUID: Self.accountUUID)
            }

            // `refreshMigrationSnapshot` fires the build on `Task { [weak self] in ... }` — with no
            // further use of `manager` in this scope, ARC is free to release it the instant this
            // scope stops needing it, which under parallel test load can land BEFORE that detached
            // task body ever runs, silently no-op'ing the very build the await above is waiting on.
            // Reading `manager` again here keeps it alive across the whole wait, and doubles as its
            // own pin: the channel's synchronous snapshot read must agree with the async emission
            // already awaited above.
            #expect(manager.currentMigrationSnapshot(accountUUID: Self.accountUUID) != nil)

            #expect(
                published != nil,
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

    /// Wave 2: the lock is a WRITER EDGE — it changes the balance the published snapshot was built
    /// from, so it republishes before returning. This is what lets every flow exit (the back-swipe
    /// included) leave immediately: freshness no longer depends on an exit-path reconcile.
    @Test func lockingRepublishesTheSnapshotBeforeReturning() async throws {
        Self.installCandidateAccount()

        let isLocked = LockIsolated<Bool>(false)
        let candidateBalance = AccountBalance(
            saplingBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            orchardBalance: PoolBalance(spendableValue: Zatoshi(800_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            ironwoodBalance: PoolBalance(spendableValue: Zatoshi(1_000_000_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            unshielded: .zero,
            awaitingResolution: .zero
        )
        let lockedBalance = AccountBalance(
            saplingBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            orchardBalance: PoolBalance(
                spendableValue: .zero,
                changePendingConfirmation: .zero,
                valuePendingSpendability: .zero,
                lockedValue: Zatoshi(800_000)
            ),
            ironwoodBalance: PoolBalance(spendableValue: Zatoshi(1_000_000_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            unshielded: .zero,
            awaitingResolution: .zero
        )

        try await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.caughtUpState() },
                lockMigrationResidual: { _ in
                    isLocked.setValue(true)
                    return Zatoshi(800_000)
                },
                getAccountsBalances: { [Self.accountUUID: isLocked.value ? lockedBalance : candidateBalance] }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = MigrationManagerImpl()

            var cancellables = Set<AnyCancellable>()
            let preLockSnapshot = await Self.firstSnapshot(
                of: manager.migrationSnapshotEvents(accountUUID: Self.accountUUID),
                matching: { $0?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)) },
                storingIn: &cancellables
            ) {
                manager.refreshMigrationSnapshot(accountUUID: Self.accountUUID)
            }
            #expect(
                preLockSnapshot?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)),
                "precondition: the pre-lock snapshot advertises the residual"
            )
            // Second precondition — the AWAITED republish is the uncontended path: a build already
            // in flight makes `republishSnapshotNow` mark dirty and return, leaving the post-lock
            // truth to that build's follow-up. Two builds are queued above (the subscription's, and
            // the refresh's coalesced follow-up) and the wait above lands on the FIRST one's
            // publish, so the second can still be running. `awaitSnapshotRepublishIdle` asks the
            // coalescer itself and suspends until it actually clears, instead of polling either its
            // side effects or `isSnapshotRepublishIdle` against a deadline that has to outrun it.
            await manager.awaitSnapshotRepublishIdle(for: Self.accountUUID)

            try await manager.lockMigrationDust(accountUUID: Self.accountUUID)

            let published = try #require(manager.currentMigrationSnapshot(accountUUID: Self.accountUUID))
            #expect(
                published.banner == nil,
                "the lock must return with the published snapshot already rebuilt — a stale .residual here is the banner that survives its own lock"
            )
        }
    }

    // (`viewFreshnessStampsOnPublish` — the pin for `isMigrationViewFresh` — was REMOVED
    // 2026-08-07 with the probe itself. Its only production consumers were the migration
    // screen's `isUpdating` writes, and that label was never in any design — nor was the
    // `asOfSyncedAt` age line that went with it on the same day.)
}
