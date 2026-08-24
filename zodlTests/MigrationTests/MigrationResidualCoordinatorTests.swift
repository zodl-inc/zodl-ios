//
//  MigrationResidualCoordinatorTests.swift
//  zodlTests
//
//  MOB-1749: the Remaining Orchard Funds screen inside `MigrationCoordFlow` — re-entry lands it
//  hydrated over a hidden root; "Got it" finishes the flow with nothing to acknowledge; "Migrate
//  anyway" hands over to the same immediate-review leg Migration Complete uses but deliberately
//  SKIPS the unlock — the residual leg must never clear a prior output lock, and the send-max
//  sweep covers spendable notes only, so it moves exactly the balance the card names. The only
//  `.migrateAnywayFailed` trigger left on this leg is a missing selected account, which re-arms
//  the button.
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
        #expect(residualState.lock.resolution == .offered)
        #expect(!store.state.isReentryResolved, "a pushed re-entry destination keeps the fork hidden")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    // MARK: - Delegates

    private static func stateWithResidualScreen(resolution: MigrationLockResolution = .offered) -> MigrationCoordFlow.State {
        var state = MigrationCoordFlow.State.initial
        state.path.append(
            .residual(
                MigrationResidual.State(
                    orchardBalance: balances.residualOrchard,
                    lockedOrchardBalance: balances.lockedOrchard,
                    ironwoodBalance: balances.ironwood,
                    resolution: resolution
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
    @Test func gotItFinishesTheFlowWithNothingToAcknowledge() async throws {
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
        let id = try #require(store.state.path.ids.first)

        await store.send(.path(.element(id: id, action: .residual(.gotItTapped))))
        await store.receive(\.flowFinished, timeout: .seconds(5))

        #expect(reconcileCount.value == 1, "the exit republishes the snapshot the banner reads — exactly once, before finishing")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// MOB-1749 review fix: the swipe-back exit must ride the same writer edge as "Got it". A lock
    /// taken on this screen changes the balance the PUBLISHED banner snapshot was built from, and a
    /// bare `.flowFinished` left that snapshot stale — Home kept advertising a residual that was
    /// already locked, and tapping the stale banner opened the fork.
    @Test func aBackSwipeOffTheResidualScreenReconcilesBeforeFinishing() async throws {
        let reconcileCount = LockIsolated<Int>(0)

        let store = TestStore(initialState: Self.stateWithResidualScreen()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            var client = MigrationManagerClient.noOp
            client.reconcile = { reconcileCount.withValue { $0 += 1 } }
            $0.migrationManager = client
        }
        store.exhaustivity = .off
        let id = try #require(store.state.path.ids.first)

        await store.send(.path(.popFrom(id: id)))
        await store.receive(\.flowFinished, timeout: .seconds(5))

        #expect(reconcileCount.value == 1, "the swipe exit republishes the snapshot the banner reads, exactly like Got it")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// MOB-1749 review fix: `unlockMigrationResidual` is an SDK-documented blanket clear of ALL
    /// the account's output locks, and this screen is reachable with an earlier deliberate lock
    /// still in place (locked notes are excluded from the spendable figure that fires the route).
    /// The residual leg therefore must NOT unlock — the immediate sweep is a send-max over
    /// SPENDABLE notes only, so skipping the unlock makes it cover exactly the balance the card
    /// names and leaves the prior lock standing. The `.locked` twin below is the leg that DOES
    /// unlock.
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

        await store.send(.path(.element(id: id, action: .residual(.lock(.migrateAnywayTapped)))))
        await store.receive(\.migrateAnywayUnlocked, timeout: .seconds(5))

        guard case .reviewTransfer(let reviewState)? = store.state.path.last else {
            Issue.record("expected the immediate review on top, got \(String(describing: store.state.path.last))")
            return
        }
        #expect(reviewState.mode == .immediate)

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// Wave 2 — the release path. On a LOCKED residual, "Migrate anyway" means "undo the lock and
    /// move it after all": the leg unlocks exactly once, hands over to the immediate review, and
    /// flips the screen back to `.offered` so backing out of the review lands on a truthful card.
    @Test func migrateAnywayOnALockedResidualUnlocksOnceAndReOffers() async throws {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }
        defer { $selectedWalletAccount.withLock { $0 = nil } }

        let unlockCount = LockIsolated<Int>(0)

        let store = TestStore(initialState: Self.stateWithResidualScreen(resolution: .locked)) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationManager = MigrationManagerClient.noOp
            $0.sdkSynchronizer = .mocked(
                unlockMigrationResidual: { _ in
                    unlockCount.withValue { $0 += 1 }
                    return 0
                }
            )
        }
        store.exhaustivity = .off
        let id = try #require(store.state.path.ids.first)

        await store.send(.path(.element(id: id, action: .residual(.lock(.migrateAnywayTapped)))))
        await store.receive(\.migrateAnywayUnlocked, timeout: .seconds(5))

        #expect(unlockCount.value == 1, "a locked residual's Migrate anyway must clear the lock it is escaping")

        guard case .residual(let residualState)? = store.state.path.first(where: { element in
            if case .residual = element { return true }
            return false
        }) else {
            Issue.record("the residual screen left the stack")
            return
        }
        #expect(residualState.lock.resolution == .offered, "the cleared lock must re-offer, not keep claiming .locked")

        guard case .reviewTransfer(let reviewState)? = store.state.path.last else {
            Issue.record("expected the immediate review on top, got \(String(describing: store.state.path.last))")
            return
        }
        #expect(reviewState.mode == .immediate)

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    @Test func migrateAnywayWithoutASelectedAccountFailsSoftly() async throws {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = nil }
        defer { $selectedWalletAccount.withLock { $0 = nil } }

        let store = TestStore(initialState: Self.stateWithResidualScreen()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationManager = MigrationManagerClient.noOp
        }
        store.exhaustivity = .off
        let id = try #require(store.state.path.ids.first)

        await store.send(.path(.element(id: id, action: .residual(.lock(.migrateAnywayTapped)))))
        await store.receive(\.migrateAnywayFailed, timeout: .seconds(5))

        guard case .residual(let residualState)? = store.state.path.last else {
            Issue.record("expected the residual screen to remain")
            return
        }
        #expect(!residualState.lock.isMigratingAnyway)
    }

    // MARK: - Complete's coordinator leg (MOB-1749 review fix)

    // These mirror the residual pair right above, but drive `.complete(.delegate(.migrateAnyway))`
    // instead of `.residual(...)` — the SIBLING leg through the very same
    // `migrateAnywayEffect(accountUUID:clearsOutputLocks:)`. They live in THIS suite, not a
    // Complete-only file, because what they pin only means something read next to the residual
    // pair above: Wave 2 gives both screens ONE rule — the leg unlocks iff the TAPPING screen's
    // resolution is `.locked`. So Complete's `.offered` leg no longer unlocks either, and each
    // screen's `.locked` leg is the release path that does.

    private static func stateWithCompleteScreen(
        isMigratingAnyway: Bool = false,
        resolution: MigrationLockResolution? = nil
    ) -> MigrationCoordFlow.State {
        var completeState = MigrationComplete.State(dust: Zatoshi(800_000), resolution: resolution)
        completeState.lock.isMigratingAnyway = isMigratingAnyway
        var state = MigrationCoordFlow.State.initial
        state.path.append(.complete(completeState))
        return state
    }

    /// Wave 2 flips this leg: Complete's `.offered` tap used to unlock unconditionally, which was
    /// only ever safe while an already-locked dust hid the button. It no longer does — a prior
    /// lock can now sit alongside this run's own offer — so the blanket clear has to go.
    @Test func completeMigrateAnywayAtOfferedNoLongerUnlocks() async throws {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }
        defer { $selectedWalletAccount.withLock { $0 = nil } }

        let unlockCount = LockIsolated<Int>(0)

        let store = TestStore(initialState: Self.stateWithCompleteScreen()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationManager = MigrationManagerClient.noOp
            $0.sdkSynchronizer = .mocked(
                unlockMigrationResidual: { _ in
                    unlockCount.withValue { $0 += 1 }
                    return 0
                }
            )
        }
        store.exhaustivity = .off
        let id = try #require(store.state.path.ids.first)

        await store.send(.path(.element(id: id, action: .complete(.delegate(.migrateAnyway)))))
        await store.receive(\.migrateAnywayUnlocked, timeout: .seconds(5))

        #expect(
            unlockCount.value == 0,
            """
            at .offered nothing is locked that this tap asked to clear — and with a PRIOR lock \
            present, clearing it here would discard a deliberate earlier decision
            """
        )

        guard case .reviewTransfer(let reviewState)? = store.state.path.last else {
            Issue.record("expected the immediate review on top, got \(String(describing: store.state.path.last))")
            return
        }
        #expect(reviewState.mode == .immediate)

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// Complete's half of the release path — the same rule the locked residual twin above pins:
    /// the tapping screen is `.locked`, so this tap is the user undoing that lock, and the unlock
    /// runs exactly once before the immediate review takes over.
    @Test func completeMigrateAnywayAtLockedUnlocksOnce() async throws {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }
        defer { $selectedWalletAccount.withLock { $0 = nil } }

        let unlockCount = LockIsolated<Int>(0)

        let store = TestStore(initialState: Self.stateWithCompleteScreen(resolution: .locked)) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationManager = MigrationManagerClient.noOp
            $0.sdkSynchronizer = .mocked(
                unlockMigrationResidual: { _ in
                    unlockCount.withValue { $0 += 1 }
                    return 0
                }
            )
        }
        store.exhaustivity = .off
        let id = try #require(store.state.path.ids.first)

        await store.send(.path(.element(id: id, action: .complete(.delegate(.migrateAnyway)))))
        await store.receive(\.migrateAnywayUnlocked, timeout: .seconds(5))

        #expect(unlockCount.value == 1, "a locked Complete screen's Migrate anyway must clear the lock it is escaping")

        guard case .reviewTransfer(let reviewState)? = store.state.path.last else {
            Issue.record("expected the immediate review on top, got \(String(describing: store.state.path.last))")
            return
        }
        #expect(reviewState.mode == .immediate)

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// The failure twin, but the throw comes from the unlock call itself rather than a missing
    /// account (contrast `migrateAnywayWithoutASelectedAccountFailsSoftly` above). Wave 2: the
    /// screen starts `.locked`, because that is the only leg that calls the unlock at all — and so
    /// the only one that can throw here. `isMigratingAnyway` starts TRUE so the re-arm assertion is
    /// load-bearing — an already-`false` flag would pass even if `.migrateAnywayFailed`'s fixup
    /// never ran.
    @Test func completeMigrateAnywayFailureReArmsTheButton() async throws {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }
        defer { $selectedWalletAccount.withLock { $0 = nil } }

        let store = TestStore(initialState: Self.stateWithCompleteScreen(isMigratingAnyway: true, resolution: .locked)) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationManager = MigrationManagerClient.noOp
            $0.sdkSynchronizer = .mocked(
                unlockMigrationResidual: { _ in throw ZcashError.synchronizerNotPrepared }
            )
        }
        store.exhaustivity = .off
        let id = try #require(store.state.path.ids.first)
        let pathCountBefore = store.state.path.count

        await store.send(.path(.element(id: id, action: .complete(.delegate(.migrateAnyway)))))
        await store.receive(\.migrateAnywayFailed, timeout: .seconds(5))

        #expect(store.state.path.count == pathCountBefore, "a failed unlock must not push the review screen")

        guard case .complete(let resultState)? = store.state.path.last else {
            Issue.record("expected the complete screen to remain, got \(String(describing: store.state.path.last))")
            return
        }
        #expect(!resultState.lock.isMigratingAnyway, "the failure fixup must re-arm the button")
        #expect(resultState.lock.resolution == .locked, "a FAILED unlock leaves the lock standing — the card must keep saying so")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }
}
