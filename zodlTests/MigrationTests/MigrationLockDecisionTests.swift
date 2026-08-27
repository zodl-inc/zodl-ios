//
//  MigrationLockDecisionTests.swift
//  zodlTests
//
//  MOB-1749 review fix: the ONE lock-decision state machine, tested once. Migration Complete's
//  lock half and the Remaining Orchard Funds screen used to carry byte-identical rename-copies of
//  it, which meant two copies of these assertions too — and a fix landing in only one of them was
//  exactly the drift the extraction ends. These tests drive the child directly, with no screen
//  around it: the adopters' own suites now cover only their glue (their alert, their exit, their
//  re-surfaced delegate).
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite @MainActor struct MigrationLockDecisionTests {
    // MARK: - Lock

    @Test func lockingTheBalanceLandsOnLocked() async {
        let store = TestStore(initialState: MigrationLockDecision.State()) {
            MigrationLockDecision()
        } withDependencies: {
            $0.migrationManager.lockMigrationDust = { _ in }
        }

        await store.send(.lockBalanceTapped) { state in
            state.resolution = .locking
        }
        await store.receive(\.lockSucceeded) { state in
            state.resolution = .locked
        }
    }

    /// The failure returns to `.offered` and says so OUT LOUD: the child owns the state machine but
    /// not the alert, so the enclosing screen only learns about it through this delegate.
    @Test func aFailedLockReturnsToOfferedAndDelegatesTheFailure() async {
        let store = TestStore(initialState: MigrationLockDecision.State()) {
            MigrationLockDecision()
        } withDependencies: {
            $0.migrationManager.lockMigrationDust = { _ in throw ZcashError.synchronizerNotPrepared }
        }

        await store.send(.lockBalanceTapped) { state in
            state.resolution = .locking
        }
        await store.receive(\.lockFailed) { state in
            state.resolution = .offered
        }
        await store.receive(.delegate(.lockFailed))
    }

    /// The guard protects a real SDK side effect: a second tap arriving while the lock is in flight,
    /// or after it landed, must never start another `lockMigrationDust`. The unimplemented default
    /// dependency is the assertion — reaching it would fail the test.
    @Test func lockIsOnlyActionableWhileOffered() async {
        let lockingStore = TestStore(initialState: MigrationLockDecision.State(resolution: .locking)) {
            MigrationLockDecision()
        }
        await lockingStore.send(.lockBalanceTapped)

        let lockedStore = TestStore(initialState: MigrationLockDecision.State(resolution: .locked)) {
            MigrationLockDecision()
        }
        await lockedStore.send(.lockBalanceTapped)
    }

    // MARK: - Migrate anyway

    @Test func migrateAnywayIsSingleFlight() async {
        let store = TestStore(initialState: MigrationLockDecision.State()) {
            MigrationLockDecision()
        }

        await store.send(.migrateAnywayTapped) { state in
            state.isMigratingAnyway = true
        }
        await store.receive(.delegate(.migrateAnyway))
        await store.send(.migrateAnywayTapped)
    }

    /// Wave 2: `.locked` is no longer a dead end — "Migrate anyway" on a locked balance is the
    /// release path (the coordinator's leg unlocks first when the tapping screen is `.locked`).
    /// Only the in-flight `.locking` state refuses the tap: the lock and the sweep must never race.
    @Test func migrateAnywayDelegatesOnceLocked() async {
        let store = TestStore(initialState: MigrationLockDecision.State(resolution: .locked)) {
            MigrationLockDecision()
        }

        await store.send(.migrateAnywayTapped) { state in
            state.isMigratingAnyway = true
        }
        await store.receive(.delegate(.migrateAnyway))
    }

    @Test func migrateAnywayIsInertWhileLocking() async {
        let store = TestStore(initialState: MigrationLockDecision.State(resolution: .locking)) {
            MigrationLockDecision()
        }

        await store.send(.migrateAnywayTapped)
    }

    /// The reverse race: while a sweep hand-over is in flight, the primary CTA must not start a
    /// lock — the sweep sizes its send-max from the notes a concurrent lock would remove.
    @Test func lockIsInertWhileMigratingAnyway() async {
        var initialState = MigrationLockDecision.State()
        initialState.isMigratingAnyway = true

        let store = TestStore(initialState: initialState) {
            MigrationLockDecision()
        }

        await store.send(.lockBalanceTapped)
    }

    /// Audit 2026-08-03 (#11)'s fix, now living in one place so it cannot need re-fixing twice: the
    /// flag used to clear only on FAILURE, so a successful hand-over followed by a back-swipe landed
    /// on a screen whose "Migrate anyway" was permanently disabled.
    @Test func onAppearReArmsMigrateAnyway() async {
        var initialState = MigrationLockDecision.State()
        initialState.isMigratingAnyway = true

        let store = TestStore(initialState: initialState) {
            MigrationLockDecision()
        }

        await store.send(.onAppear) { state in
            state.isMigratingAnyway = false
        }
    }

    /// `.onAppear` re-arms "Migrate anyway" and NOTHING else — a return to a screen whose balance is
    /// already locked must not offer the lock again.
    @Test func onAppearLeavesTheResolutionAlone() async {
        let store = TestStore(initialState: MigrationLockDecision.State(resolution: .locked)) {
            MigrationLockDecision()
        }

        await store.send(.onAppear)
        #expect(store.state.resolution == .locked)
    }

    // MARK: - The explainer sheet

    /// Present, dismiss, and the sheet binding's own two writes — the drag-dismiss path lands on the
    /// same flag as the sheet's "Got it", differing only in who sends it.
    @Test func theExplainerSheetTogglesFromBothSenders() async {
        let store = TestStore(initialState: MigrationLockDecision.State()) {
            MigrationLockDecision()
        }

        await store.send(.lockExplainerHelpTapped) { state in
            state.isLockExplainerPresented = true
        }
        await store.send(.lockExplainerDismissed) { state in
            state.isLockExplainerPresented = false
        }
        await store.send(.lockExplainerPresentedChanged(true)) { state in
            state.isLockExplainerPresented = true
        }
        await store.send(.lockExplainerPresentedChanged(false)) { state in
            state.isLockExplainerPresented = false
        }
    }
}
