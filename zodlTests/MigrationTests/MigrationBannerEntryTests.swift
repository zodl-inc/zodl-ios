//
//  MigrationBannerEntryTests.swift
//  zodlTests
//
//  Scenario 1.1 as a unit test: a restored wallet with Orchard funds and NO migration run must be
//  OFFERED the migration.
//
//  This exists because 778 passing tests did not catch the feature's entry point being dead. Every
//  pure piece was correct and independently tested — `MigrationState.derive` mapped a nil advance
//  step to `.notStarted`, `MigrationDerivations.bannerVariant` mapped `.notStarted` + a positive
//  Orchard balance to `.required` — and the LIVE GLUE between them threw the nil away:
//
//      guard let advanceStep = try? await sdkSynchronizer.migrationAdvanceStep(accountUUID)
//      else { return nil }   // "the read failed"
//
//  `migrationAdvanceStep` returns `MigrationAdvanceStep?`, and since SE-0230 `try?` FLATTENS a
//  throwing optional call into ONE optional — so "threw" and "no run" arrive as the same `nil` and
//  that guard treats a healthy no-run wallet as a failed read. `bannerVariant` returned nil forever,
//  no banner ever appeared, and since the banner is how a run is STARTED, the feature could not be
//  entered at all. The tests stayed green because they call the pure functions directly, passing the
//  optional themselves — the only caller that ever exercised `derive`'s documented nil arm.
//
//  So this test drives the REAL `MigrationManagerImpl` with mocked dependencies rather than the pure
//  layer, because the pure layer was never wrong. A test that cannot fail on the bug it is named for
//  is decoration.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
import ComposableArchitecture
@testable import zodl_internal

/// Serialized: several tests here write `@Shared(.inMemory(.selectedWalletAccount))`, which is
/// process-global — Swift Testing runs a suite's tests in parallel otherwise, and two of them
/// installing/clearing the same account concurrently is a race, not a test.
@Suite(.serialized) struct MigrationBannerEntryTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))

    /// Testnet NU6.3. The tip sits above it, as it does on any wallet that can see Ironwood at all.
    private static let activationHeight: BlockHeight = 4_134_000
    private static let tip: BlockHeight = 4_200_000

    private static func orchardOnly(_ amount: Zatoshi) -> AccountBalance {
        AccountBalance(
            saplingBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            orchardBalance: PoolBalance(spendableValue: amount, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            ironwoodBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            unshielded: .zero,
            awaitingResolution: .zero
        )
    }

    /// `pending` lands in the Orchard pool's `valuePendingSpendability` — value the wallet holds
    /// but cannot spend yet. It is what separates the two Orchard bases: the OFFER is sized from
    /// `unlockedForMigration` (spendable plus both pending buckets), the RESIDUAL from spendable
    /// alone, and with `pending` at its default of zero the two coincide and no fixture can tell
    /// them apart.
    private static func balances(orchard: Zatoshi, ironwood: Zatoshi, pending: Zatoshi = .zero) -> AccountBalance {
        AccountBalance(
            saplingBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            orchardBalance: PoolBalance(spendableValue: orchard, changePendingConfirmation: .zero, valuePendingSpendability: pending),
            ironwoodBalance: PoolBalance(spendableValue: ironwood, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            unshielded: .zero,
            awaitingResolution: .zero
        )
    }

    /// A wallet that is CAUGHT UP — which now takes saying so.
    ///
    /// This fixture set only the height and inherited `SynchronizerState.zero`'s sync status, so it
    /// was named `syncedState` while describing a wallet mid-sync. Harmless until GOAL 1
    /// (2026-08-02) added the offer gate: a migration is not offered to a wallet that is not caught
    /// up, because a plan sized from a stale balance is worse than no plan. The gate read this
    /// fixture correctly and held the offer — the fixture was the thing that was wrong.
    ///
    /// Caught in the first full-target run after the gate landed; I had been running targeted suites,
    /// which is how a red suite survived a day.
    private static func syncedState() -> SynchronizerState {
        var state = SynchronizerState.zero
        state.latestBlockHeight = tip
        state.syncStatus = .upToDate
        return state
    }

    /// The same wallet, still catching up — the state GOAL 1's gate exists for.
    private static func syncingState() -> SynchronizerState {
        var state = SynchronizerState.zero
        state.latestBlockHeight = tip
        state.syncStatus = .syncing(0.5, false)
        return state
    }

    /// Runs the real manager with a wallet that has `balance` in Orchard and, unless
    /// `advanceStep` says otherwise, no migration run at all.
    private static func bannerVariant(
        balance: Zatoshi,
        ironwood: Zatoshi = .zero,
        pending: Zatoshi = .zero,
        advanceStep: @escaping @Sendable (AccountUUID) async throws -> MigrationAdvance? = { _ in nil },
        state: @escaping @Sendable () -> SynchronizerState = { syncedState() }
    ) async -> MigrationBannerVariant? {
        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: state,
                migrationAdvanceStep: advanceStep,
                getAccountsBalances: { [accountUUID: balances(orchard: balance, ironwood: ironwood, pending: pending)] }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { activationHeight }
        } operation: {
            await MigrationManagerImpl().bannerVariant(accountUUID: accountUUID)
        }
    }

    // MARK: - The entry point

    /// THE regression test. A freshly restored wallet: Ironwood active, 100 TAZ sitting in Orchard,
    /// no run started. The engine answers "no run" — a SUCCESSFUL answer, not a failure — and the
    /// user must be offered the migration.
    @Test func aRestoredWalletWithOrchardFundsIsOfferedTheMigration() async {
        let variant = await Self.bannerVariant(balance: Zatoshi(10_000_000_000))

        #expect(variant == .required)
    }

    /// GOAL 1 (2026-08-02), and the coverage whose absence let the suite sit red for a day: the SAME
    /// wallet, still catching up, is offered NOTHING.
    ///
    /// A migration is sized from the Orchard balance at the moment it is planned. A wallet that has
    /// not finished syncing does not yet know that balance — a six-month-dormant wallet reports its
    /// six-month-old one — and a plan built on it splits and schedules the wrong amount. Holding the
    /// offer costs the user one sync; taking it costs them a wrong plan they have to redo.
    @Test func aWalletStillSyncingIsNotOfferedTheMigration() async {
        let variant = await Self.bannerVariant(
            balance: Zatoshi(10_000_000_000),
            state: { Self.syncingState() }
        )

        #expect(variant == nil, "the offer must be HELD until the balance is trustworthy")
    }

    /// The other half of the same predicate: no Orchard value, nothing to offer. Proves the test
    /// above passes for the right reason — that `.required` tracks the balance rather than falling
    /// out of the fixture unconditionally.
    @Test func aWalletWithNothingInOrchardIsNotOffered() async {
        let variant = await Self.bannerVariant(balance: .zero)

        #expect(variant == nil)
    }

    /// MOB-1749: the restored/self-migrated wallet the residual lane exists for — Orchard dust
    /// below the offer floor, real funds already in Ironwood. The LIVE glue must hand the
    /// Ironwood total to the derivation; the pure table alone cannot prove that.
    @Test func aRestoredWalletWithAnOrchardResidualAndIronwoodFundsSeesTheResidualBanner() async {
        let variant = await Self.bannerVariant(balance: Zatoshi(800_000), ironwood: Zatoshi(1_245_000_000))

        #expect(variant == .residual(amount: Zatoshi(800_000)))
    }

    /// MOB-1749 review fix: WHICH Orchard figure the residual lane reads, pinned end to end.
    ///
    /// Nothing spendable, 0.005 ZEC awaiting spendability, real funds in Ironwood. On the SPENDABLE
    /// basis this is not a residual and the banner stays quiet; on the old `unlockedForMigration`
    /// basis it is squarely in the band and the banner offers to lock it.
    ///
    /// Offering it is the bug the basis change closes. The lock would succeed — and the SDK would
    /// go on reporting the value as PENDING rather than locked, so the next balances read puts the
    /// same figure back in the band and the banner returns exactly as it was. The user locks, the
    /// banner reappears, they lock again. This test fails the moment `init(accountBalance:)` goes
    /// back to `unlockedForMigration`, which is the only thing standing between the lane and that
    /// loop.
    @Test func aPendingOnlyOrchardBalanceIsNotAResidual() async {
        let variant = await Self.bannerVariant(
            balance: .zero,
            ironwood: Zatoshi(1_245_000_000),
            pending: Zatoshi(500_000)
        )

        #expect(variant == nil, "a balance the wallet cannot spend yet is not dust it can be asked to lock")
    }

    /// MOB-1749: the same dust with NOTHING in Ironwood is not a residual — the screen's "You've
    /// moved to Ironwood" framing would be false.
    @Test func anOrchardResidualWithNothingInIronwoodStaysQuiet() async {
        let variant = await Self.bannerVariant(balance: Zatoshi(800_000))

        #expect(variant == nil)
    }

    // MARK: - The distinction the bug erased

    /// A read that genuinely FAILS must not be mistaken for "no run": it yields no banner, but for
    /// the opposite reason — the state is unknown, so callers keep whatever they had rather than
    /// flipping the wallet to `.notStarted` on a transient error.
    ///
    /// Before the fix this expectation and the one above were satisfied by the same code path, which
    /// is precisely why the bug was invisible: the failure case was "working".
    @Test func aFailedReadIsNotTreatedAsNoRun() async {
        let variant = await Self.bannerVariant(
            balance: Zatoshi(10_000_000_000),
            advanceStep: { _ in throw ZcashError.synchronizerNotPrepared }
        )

        #expect(variant == nil, "an unknown state offers nothing — but it must reach here by throwing, not by reading nil")
    }

    /// Pre-activation there is no migration to offer whatever the balance says. Pinned here because
    /// it is the one remaining silent-nil exit in `bannerVariant`, and a tester seeing no banner
    /// needs the logs to distinguish it from the case above.
    @Test func beforeActivationNothingIsOffered() async {
        let variant = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.syncedState() },
                getAccountsBalances: { [Self.accountUUID: Self.orchardOnly(Zatoshi(10_000_000_000))] }
            )
            // Activation still ahead of the tip.
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.tip + 1 }
        } operation: {
            await MigrationManagerImpl().bannerVariant(accountUUID: Self.accountUUID)
        }

        #expect(variant == nil)
    }

    // MARK: - The route behind the residual banner's button

    /// MOB-1749: the LIVE route reads the same balances the banner did — a residual banner's tap
    /// must open the residual screen, not the fork.
    @Test func aRestoredWalletWithAnOrchardResidualRoutesToTheResidualScreen() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock {
            $0 = WalletAccount(
                Account(
                    id: Self.accountUUID,
                    name: "Zodl",
                    keySource: nil,
                    seedFingerprint: nil,
                    hdAccountIndex: Zip32AccountIndex(0),
                    ufvk: nil,
                    uivk: nil
                )
            )
        }

        let route = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.syncedState() },
                getAccountsBalances: { [Self.accountUUID: Self.balances(orchard: Zatoshi(800_000), ironwood: Zatoshi(1_245_000_000))] }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            await MigrationManagerImpl().reentryRoute()
        }

        #expect(
            route == .residual(
                MigrationResidualBalances(
                    residualOrchard: Zatoshi(800_000),
                    unlockedOrchard: Zatoshi(800_000),
                    lockedOrchard: .zero,
                    ironwood: Zatoshi(1_245_000_000)
                )
            )
        )

        // Resets the process-global shared account so this test does not leak state into the rest
        // of the run.
        $selectedWalletAccount.withLock { $0 = nil }
    }

    // MARK: - What actually clears the residual banner after a lock

    /// The same account as the fixtures above, as a `WalletAccount` — `reconcile()` resolves its
    /// candidate accounts from `@Shared(.inMemory(.selectedWalletAccount))`.
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

    /// The post-lock shape of the same wallet: the residual is still THERE, it is just no longer
    /// spendable — `lockedValue` holds it and `spendableValue` (the figure every residual arm
    /// reads) is zero.
    private static func lockedResidual(orchard: Zatoshi, ironwood: Zatoshi) -> AccountBalance {
        AccountBalance(
            saplingBalance: PoolBalance(spendableValue: .zero, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            orchardBalance: PoolBalance(
                spendableValue: .zero,
                changePendingConfirmation: .zero,
                valuePendingSpendability: .zero,
                lockedValue: orchard
            ),
            ironwoodBalance: PoolBalance(spendableValue: ironwood, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            unshielded: .zero,
            awaitingResolution: .zero
        )
    }

    /// Short real-time polling for a condition driven by a concurrently-running `Task` — copied
    /// from `MigrationSnapshotFreshnessTests`, and needed for the same reason: the republish
    /// `reconcile()` schedules runs in a detached `Task`, so the test must wait for it to land
    /// rather than assume it did. Sized generously for parallel test load.
    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// MOB-1749 (fix wave): what the residual screen's "Got it" exit actually depends on.
    ///
    /// `bannerVariant` is a WINDOW onto the published snapshot — it serves
    /// `snapshotSubjects[account]?.value?.banner` and only builds when nothing has been published
    /// yet. A snapshot is rebuilt on a WRITER EDGE, and `reconcile()` is the edge the migration
    /// flow's exits ride. So locking the residual — which changes only the SDK's balances — does
    /// not by itself change one word of what the banner says.
    ///
    /// The three steps are the whole mechanism: (a) the residual banner is published, (b) the
    /// balance goes locked and the banner STILL says residual (the negative control — this is the
    /// staleness the bare `.send(.flowFinished)` exit shipped), (c) `reconcile()` republishes off a
    /// fresh balances read and the banner goes quiet.
    @Test func aLockedResidualClearsTheBannerOnlyOnceAReconcileRepublishes() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }

        let storedBalance = LockIsolated<AccountBalance>(
            Self.balances(orchard: Zatoshi(800_000), ironwood: Zatoshi(1_245_000_000))
        )

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.syncedState() },
                getAccountsBalances: { [Self.accountUUID: storedBalance.value] }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            // Held for the whole test: the republish `reconcile()` schedules captures the manager
            // WEAKLY, so a manager that only lived for the `reconcile()` call would be gone before
            // its own build landed and the poll below would time out on a dead object.
            let manager = MigrationManagerImpl()

            // (a) The unlocked residual — the banner the screen is entered from. This first ask is
            // also what creates the account's snapshot subject, so the writer edge in (c) has
            // something to republish onto.
            let offered = await manager.bannerVariant(accountUUID: Self.accountUUID)
            #expect(offered == .residual(amount: Zatoshi(800_000)))

            // (b) NEGATIVE CONTROL. The lock has happened as far as the SDK is concerned; nothing
            // has told the snapshot pipeline. The banner must still answer `.residual` here — if it
            // ever stops, the published snapshot is no longer what `bannerVariant` serves and step
            // (c), along with the coordinator fix it justifies, needs rereading.
            storedBalance.setValue(Self.lockedResidual(orchard: Zatoshi(800_000), ironwood: Zatoshi(1_245_000_000)))
            let stale = await manager.bannerVariant(accountUUID: Self.accountUUID)
            #expect(
                stale == .residual(amount: Zatoshi(800_000)),
                "a balance change alone is NOT a writer edge — the published snapshot is served unchanged"
            )

            // (c) The writer edge. `reconcile()` pushes state, which republishes the snapshot off a
            // fresh `getAccountsBalances` — now the locked shape, whose unlocked Orchard is zero.
            await manager.reconcile()
            await Self.waitUntil { manager.currentMigrationSnapshot(accountUUID: Self.accountUUID)?.banner == nil }

            let republished = manager.currentMigrationSnapshot(accountUUID: Self.accountUUID)
            #expect(republished != nil, "the republish must land a snapshot, not clear the channel")

            let cleared = await manager.bannerVariant(accountUUID: Self.accountUUID)
            #expect(cleared == nil, "after the republish the banner reads the locked balance and goes quiet")
        }

        $selectedWalletAccount.withLock { $0 = nil }
    }
}
