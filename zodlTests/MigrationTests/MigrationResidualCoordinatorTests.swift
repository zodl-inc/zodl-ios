//
//  MigrationResidualCoordinatorTests.swift
//  zodlTests
//
//  MOB-1749: the Remaining Orchard Funds screen inside `MigrationCoordFlow` — re-entry lands it
//  hydrated over a hidden root; "Got it" finishes the flow with nothing to acknowledge; "Migrate
//  anyway" rides the exact unlock → immediate-review leg Migration Complete uses, and a failed
//  unlock re-arms the button.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationResidualCoordinatorTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x0D, count: 16))
    /// A non-zero `lockedOrchard`: a residual the user locked on an earlier visit, still sitting in
    /// the pool. It has to be non-zero for the hydration assertion below to be load-bearing — with
    /// `.zero` the "Locked in Orchard" wiring would pass by doing nothing at all.
    private static let balances = MigrationResidualBalances(
        residualOrchard: Zatoshi(800_000),
        unlockedOrchard: Zatoshi(800_000),
        lockedOrchard: Zatoshi(300_000),
        ironwood: Zatoshi(1_245_000_000)
    )

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

    // MARK: - Re-entry

    @Test func aResidualRouteLandsTheHydratedScreenOverAHiddenRoot() async {
        let store = TestStore(initialState: MigrationCoordFlow.State.initial) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            var client = MigrationManagerClient.noOp
            client.reentryRoute = { .residual(await Self.balances) }
            $0.migrationManager = client
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushHydratedPathState, timeout: .seconds(5))

        #expect(store.state.path.count == 1, "a resolved push destination must land exactly one path element")
        guard case .residual(let residualState)? = store.state.path.last else {
            Issue.record("expected a .residual element, got \(String(describing: store.state.path.last))")
            return
        }
        #expect(residualState.orchardBalance == Zatoshi(800_000))
        #expect(residualState.lockedOrchardBalance == Zatoshi(300_000))
        #expect(residualState.ironwoodBalance == Zatoshi(1_245_000_000))
        #expect(residualState.resolution == .offered)
        #expect(!store.state.isReentryResolved, "a pushed re-entry destination keeps the fork hidden")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    // MARK: - Delegates

    private static func stateWithResidualScreen() -> MigrationCoordFlow.State {
        var state = MigrationCoordFlow.State.initial
        state.path.append(
            .residual(
                MigrationResidual.State(
                    orchardBalance: balances.residualOrchard,
                    lockedOrchardBalance: balances.lockedOrchard,
                    ironwoodBalance: balances.ironwood
                )
            )
        )
        return state
    }

    /// "Got it" acknowledges NOTHING — there is no run behind this screen — but it must still
    /// reconcile before finishing, and that half is not cosmetic.
    ///
    /// `MigrationManagerImpl.bannerVariant` serves the PUBLISHED snapshot; a snapshot is rebuilt
    /// only on a writer edge, and `reconcile()` is the edge this exit owns. Without it the lock
    /// that just emptied the unlocked Orchard balance changes nothing the banner can see, so
    /// Root's `flowFinished` re-evaluation reads the stale `.residual(amount:)` and the banner
    /// keeps offering a residual that no longer exists. Counting the call is therefore the
    /// assertion — receiving `.flowFinished` alone passed on the broken code.
    @Test func gotItFinishesTheFlowWithNothingToAcknowledge() async {
        let reconcileCount = LockIsolated<Int>(0)

        let store = TestStore(initialState: Self.stateWithResidualScreen()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            // `.noOp` leaves `acknowledgeComplete` at its inert default; the residual exit must
            // never reach it — `testValue`'s unimplemented stub would fail the test if it did.
            var client = MigrationManagerClient.noOp
            client.acknowledgeComplete = { _ in Issue.record("the residual screen has no run to acknowledge") }
            client.reconcile = { reconcileCount.withValue { $0 += 1 } }
            $0.migrationManager = client
        }
        store.exhaustivity = .off
        let id = try! #require(store.state.path.ids.first)

        await store.send(.path(.element(id: id, action: .residual(.gotItTapped))))
        await store.receive(\.flowFinished, timeout: .seconds(5))

        #expect(reconcileCount.value == 1, "the exit republishes the snapshot the banner reads — exactly once, before finishing")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// MOB-1749 review fix: `unlockMigrationResidual` is an SDK-documented blanket clear of ALL
    /// the account's output locks, and this screen is reachable with an earlier deliberate lock
    /// still in place (locked notes are excluded from the spendable figure that fires the route).
    /// The residual leg therefore must NOT unlock — the immediate sweep is a send-max over
    /// SPENDABLE notes only, so skipping the unlock makes it cover exactly the balance the card
    /// names and leaves the prior lock standing.
    @Test func migrateAnywayHandsOverToTheImmediateReviewWithoutClearingLocks() async throws {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }
        defer { $selectedWalletAccount.withLock { $0 = nil } }

        let store = TestStore(initialState: Self.stateWithResidualScreen()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationManager = MigrationManagerClient.noOp
            $0.sdkSynchronizer = .mocked(
                unlockMigrationResidual: { _ in
                    Issue.record("the residual leg must never clear the account's output locks")
                    return 0
                }
            )
        }
        store.exhaustivity = .off
        let id = try #require(store.state.path.ids.first)

        await store.send(.path(.element(id: id, action: .residual(.migrateAnywayTapped))))
        await store.receive(\.migrateAnywayUnlocked, timeout: .seconds(5))

        guard case .reviewTransfer(let reviewState)? = store.state.path.last else {
            Issue.record("expected the immediate review on top, got \(String(describing: store.state.path.last))")
            return
        }
        #expect(reviewState.mode == .immediate)

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    @Test func migrateAnywayWithoutASelectedAccountFailsSoftly() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = nil }

        let store = TestStore(initialState: Self.stateWithResidualScreen()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationManager = MigrationManagerClient.noOp
        }
        store.exhaustivity = .off
        let id = try! #require(store.state.path.ids.first)

        await store.send(.path(.element(id: id, action: .residual(.migrateAnywayTapped))))
        await store.receive(\.migrateAnywayFailed, timeout: .seconds(5))

        guard case .residual(let residualState)? = store.state.path.last else {
            Issue.record("expected the residual screen to remain")
            return
        }
        #expect(!residualState.isMigratingAnyway)
    }
}
