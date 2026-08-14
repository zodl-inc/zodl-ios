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

@Suite struct MigrationBannerEntryTests {
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
        advanceStep: @escaping @Sendable (AccountUUID) async throws -> MigrationAdvance? = { _ in nil },
        state: @escaping @Sendable () -> SynchronizerState = { syncedState() }
    ) async -> MigrationBannerVariant? {
        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: state,
                migrationAdvanceStep: advanceStep,
                getAccountsBalances: { [accountUUID: orchardOnly(balance)] }
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
}
