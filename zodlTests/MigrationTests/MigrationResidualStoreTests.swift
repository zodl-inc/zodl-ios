//
//  MigrationResidualStoreTests.swift
//  zodlTests
//
//  MOB-1749: the Remaining Orchard Funds screen's reducer — the lock half of Migration Complete
//  (MOB-1487) without a run behind it: lock → locked or back to offered with the failure alert,
//  single-flight "Migrate anyway" re-armed on every arrival, an explainer sheet that never closes
//  the screen, and a "Got it" that only delegates.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite @MainActor struct MigrationResidualStoreTests {
    private static func state(resolution: MigrationLockResolution = .offered) -> MigrationResidual.State {
        MigrationResidual.State(
            orchardBalance: Zatoshi(800_000),
            ironwoodBalance: Zatoshi(1_245_000_000),
            resolution: resolution
        )
    }

    // MARK: - Lock

    @Test func lockingTheBalanceLandsOnLocked() async {
        let store = TestStore(initialState: Self.state()) {
            MigrationResidual()
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

    @Test func aFailedLockReturnsToOfferedWithTheFailureAlert() async {
        let store = TestStore(initialState: Self.state()) {
            MigrationResidual()
        } withDependencies: {
            $0.migrationManager.lockMigrationDust = { _ in throw ZcashError.synchronizerNotPrepared }
        }

        await store.send(.lockBalanceTapped) { state in
            state.resolution = .locking
        }
        await store.receive(\.lockFailed) { state in
            state.resolution = .offered
            state.alert = AlertState.lockFailed()
        }
    }

    @Test func lockIsOnlyActionableWhileOffered() async {
        let lockingStore = TestStore(initialState: Self.state(resolution: .locking)) {
            MigrationResidual()
        }
        await lockingStore.send(.lockBalanceTapped)

        let lockedStore = TestStore(initialState: Self.state(resolution: .locked)) {
            MigrationResidual()
        }
        await lockedStore.send(.lockBalanceTapped)
    }

    // MARK: - Migrate anyway

    @Test func migrateAnywayIsSingleFlight() async {
        let store = TestStore(initialState: Self.state()) {
            MigrationResidual()
        }

        await store.send(.migrateAnywayTapped) { state in
            state.isMigratingAnyway = true
        }
        await store.receive(.delegate(.migrateAnyway))
        await store.send(.migrateAnywayTapped)
    }

    @Test func onAppearReArmsMigrateAnyway() async {
        var initialState = Self.state()
        initialState.isMigratingAnyway = true
        let store = TestStore(initialState: initialState) {
            MigrationResidual()
        }

        await store.send(.onAppear) { state in
            state.isMigratingAnyway = false
        }
    }

    // MARK: - Exits and the explainer

    @Test func gotItOnlyDelegatesDone() async {
        let store = TestStore(initialState: Self.state(resolution: .locked)) {
            MigrationResidual()
        }

        await store.send(.gotItTapped)
        await store.receive(.delegate(.done))
    }

    @Test func theExplainerSheetTogglesWithoutClosingTheScreen() async {
        let store = TestStore(initialState: Self.state()) {
            MigrationResidual()
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

    @Test func dismissingTheAlertClearsIt() async {
        var initialState = Self.state()
        initialState.alert = AlertState.lockFailed()
        let store = TestStore(initialState: initialState) {
            MigrationResidual()
        }

        await store.send(.alert(.dismiss)) { state in
            state.alert = nil
        }
    }
}
