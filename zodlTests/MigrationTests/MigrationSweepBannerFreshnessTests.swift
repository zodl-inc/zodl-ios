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
//  activation pair, `withDependencies`, `.serialized` because the wallet-wide candidate set rides
//  `@Shared(.inMemory(...))`) — including its event-driven waits: `firstSnapshot(of:matching:
//  storingIn:afterSubscribing:)` suspends until the expected snapshot is actually published, and
//  `MigrationManagerImpl.awaitSnapshotRepublishIdle(for:)` suspends until the republish coalescer
//  itself clears. An earlier version of THIS suite polled both conditions against a wall-clock
//  deadline (`waitUntil`, 10 s) — the very pattern that sibling had already retired — and CI
//  re-proved why: at the contended tail of a full parallel run a coalesced build that takes 0.07 s
//  uncontended lost the fixed 10 s budget, so the precondition read `banner == nil` while the
//  build was still queued (unit_tests runs 33360721267 and 33367930400, same failure on two
//  branches). The event-driven waits scale with however long the build actually takes under load.
//
//  `.timeLimit` is a hang RECORDER, not a deadline the tests race: the waits themselves have no
//  budget, so a coalescer that genuinely never publishes or never idles is reported as a failure
//  at the limit instead of the run sitting in-progress until the CI job's own timeout. Two minutes
//  where the sibling records at one: the immediate-sweep chain crosses two writer edges plus
//  `reconcile()`, so a starved runner stacks more sequential builds into one test here.
//
//  The one clock that used to sit outside this file's control is now pinned too:
//  `recordTransferBroadcast`'s awaited republish carries the `lockRepublishTimeoutNanoseconds`
//  bound (production default 10 s), and CI re-proved the residual risk this header used to only
//  predict — on a starved runner the mocked build outlasted the bound, the chain returned early by
//  design, and `theSweepSuccessChainOutrunsItsOwnRepublish`'s deliberately-immediate re-read saw
//  the stale residual (unit_tests run 33495197340). Every manager here is therefore constructed
//  with the bound raised past this suite's `.timeLimit` through the init seam, so a genuinely
//  wedged build is recorded by the limit while load alone can no longer expire a writer edge's
//  awaited republish mid-test.
//

import Foundation
import Combine
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(2))) struct MigrationSweepBannerFreshnessTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x5A, count: 16))
    private static let activationHeight: BlockHeight = 4_134_000
    private static let tip: BlockHeight = 4_200_000
    private static let suiteName = "MigrationSweepBannerFreshnessTests"

    /// The writer edges' awaited-republish bound for every manager this suite constructs: raised
    /// far past the suite's `.timeLimit` (2 min) so the limit is what records a genuinely wedged
    /// build, and a merely starved one can never expire the await mid-test the way the 10 s
    /// production default did on CI (see header).
    private static let raisedRepublishBoundNanoseconds: UInt64 = 600_000_000_000

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

    /// Suspends until `publisher` emits a snapshot matching `predicate`, resumed by the emission
    /// itself instead of polled against a wall-clock deadline — the sibling
    /// MigrationSnapshotFreshnessTests' helper, replicated per this file's self-contained fixture
    /// convention; see its header for why the deadline version proved flaky under CI load.
    /// `afterSubscribing` runs the writer edge expected to produce the match from INSIDE the same
    /// synchronous setup `withCheckedContinuation` runs, so the subscription is always live before
    /// that edge's build can possibly publish.
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
            let manager = MigrationManagerImpl(
                scheduleStorage: Self.makeEmptyScheduleStorage(),
                lockRepublishTimeoutNanoseconds: Self.raisedRepublishBoundNanoseconds
            )

            var cancellables = Set<AnyCancellable>()
            let preSweepSnapshot = await Self.firstSnapshot(
                of: manager.migrationSnapshotEvents(accountUUID: Self.accountUUID),
                matching: { $0?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)) },
                storingIn: &cancellables
            ) {
                manager.refreshMigrationSnapshot(accountUUID: Self.accountUUID)
            }
            #expect(
                preSweepSnapshot?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)),
                "precondition: the pre-sweep snapshot advertises the residual"
            )
            // Two builds are queued above (the subscription's, and the refresh's coalesced
            // follow-up); the wait above lands on the first publish, so the second can still be
            // running. Suspend until the coalescer itself clears — the sweep below must start
            // UNCONTENDED, or its awaited republish would coalesce into a pre-sweep build.
            await manager.awaitSnapshotRepublishIdle(for: Self.accountUUID)

            // The sweep broadcast lands — from here on the SDK reports the immediate run.
            isSwept.setValue(true)

            // MigrationSendingStore's `.transferResult(.success)` chain, verbatim.
            await manager.recordTransferBroadcast(
                accountUUID: Self.accountUUID,
                result: MigrationTransferResult.success(txId: "aa00")
            )
            await manager.reconcile()

            // Quiescence before the published-value reads: resumed by the coalescer's own idle
            // transition, so there is no deadline to time out under load.
            await manager.awaitSnapshotRepublishIdle(for: Self.accountUUID)

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
            let manager = MigrationManagerImpl(
                scheduleStorage: Self.makeEmptyScheduleStorage(),
                lockRepublishTimeoutNanoseconds: Self.raisedRepublishBoundNanoseconds
            )

            var cancellables = Set<AnyCancellable>()
            let preSweepSnapshot = await Self.firstSnapshot(
                of: manager.migrationSnapshotEvents(accountUUID: Self.accountUUID),
                matching: { $0?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)) },
                storingIn: &cancellables
            ) {
                manager.refreshMigrationSnapshot(accountUUID: Self.accountUUID)
            }
            #expect(
                preSweepSnapshot?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)),
                "precondition: the pre-sweep snapshot advertises the residual"
            )
            await manager.awaitSnapshotRepublishIdle(for: Self.accountUUID)

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
            await manager.awaitSnapshotRepublishIdle(for: Self.accountUUID)
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
            let manager = MigrationManagerImpl(
                scheduleStorage: Self.makeEmptyScheduleStorage(),
                lockRepublishTimeoutNanoseconds: Self.raisedRepublishBoundNanoseconds
            )

            var cancellables = Set<AnyCancellable>()
            let preSweepSnapshot = await Self.firstSnapshot(
                of: manager.migrationSnapshotEvents(accountUUID: Self.accountUUID),
                matching: { $0?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)) },
                storingIn: &cancellables
            ) {
                manager.refreshMigrationSnapshot(accountUUID: Self.accountUUID)
            }
            #expect(
                preSweepSnapshot?.banner == MigrationBannerVariant.residual(amount: Zatoshi(800_000)),
                "precondition: the pre-sweep snapshot advertises the residual"
            )
            await manager.awaitSnapshotRepublishIdle(for: Self.accountUUID)

            isSwept.setValue(true)

            await manager.recordTransferBroadcast(
                accountUUID: Self.accountUUID,
                result: MigrationTransferResult.success(txId: "aa00")
            )
            await manager.reconcile()

            await manager.awaitSnapshotRepublishIdle(for: Self.accountUUID)

            let reread = await manager.bannerVariant(accountUUID: Self.accountUUID)
            #expect(
                reread != MigrationBannerVariant.residual(amount: Zatoshi(800_000)),
                "a transient advance-step failure during the post-broadcast reconcile must not leave the retired residual banner standing"
            )
        }
    }
}
