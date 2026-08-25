//
//  MigrationResidualStoreTests.swift
//  zodlTests
//
//  MOB-1749: the Remaining Orchard Funds screen's reducer. The lock machine itself is
//  `MigrationLockDecision`'s and is tested there, once, for both adopting screens — what is left
//  here is this screen's own glue: the alert the child's failure delegate asks for, the
//  "Migrate anyway" delegate re-surfaced at screen level so the coordinator keeps listening to the
//  SCREEN, and a "Got it" that only delegates because there is no run to acknowledge.
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

    /// The child owns the return to `.offered`; the screen owns the alert. Starting from `.locking`
    /// makes both halves load-bearing — from `.offered` the reset would assert nothing.
    @Test func aLockFailureDelegateShowsTheAlert() async {
        let store = TestStore(initialState: Self.state(resolution: .locking)) {
            MigrationResidual()
        }

        await store.send(.lock(.lockFailed(ZcashError.synchronizerNotPrepared))) { state in
            state.lock.resolution = .offered
        }
        await store.receive(.lock(.delegate(.lockFailed))) { state in
            state.alert = AlertState.migrationLockFailed()
        }
    }

    @Test func dismissingTheAlertClearsIt() async {
        var initialState = Self.state()
        initialState.alert = AlertState.migrationLockFailed()
        let store = TestStore(initialState: initialState) {
            MigrationResidual()
        }

        await store.send(.alert(.dismiss)) { state in
            state.alert = nil
        }
    }

    /// The coordinator listens for the SCREEN's delegate, not the child's — this hop is what keeps
    /// its `.residual(.delegate(.migrateAnyway))` wiring matching after the extraction.
    @Test func migrateAnywayResurfacesAtScreenLevel() async {
        let store = TestStore(initialState: Self.state()) {
            MigrationResidual()
        }

        await store.send(.lock(.migrateAnywayTapped)) { state in
            state.lock.isMigratingAnyway = true
        }
        await store.receive(.lock(.delegate(.migrateAnyway)))
        await store.receive(.delegate(.migrateAnyway))
    }

    @Test func gotItOnlyDelegatesDone() async {
        let store = TestStore(initialState: Self.state(resolution: .locked)) {
            MigrationResidual()
        }

        await store.send(.gotItTapped)
        await store.receive(.delegate(.done))
    }
}
