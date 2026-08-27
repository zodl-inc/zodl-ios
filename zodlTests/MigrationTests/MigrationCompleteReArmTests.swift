//
//  MigrationCompleteReArmTests.swift
//  zodlTests
//
//  Audit 2026-08-03 (#11): `isMigratingAnyway` used to be cleared only on FAILURE — a successful
//  unlock pushed Review Transfer ON TOP of Complete, and backing off it landed on a Complete
//  screen whose "Migrate anyway" was permanently disabled, with "Got it" (which wipes the run)
//  as the only live control and the residual already unlocked on chain. `.onAppear` now re-arms
//  the button on every arrival, mirroring `MigrationRecovery`'s reset of its twin flag.
//
//  MOB-1749 review fix: the flag and its re-arm live in the shared `MigrationLockDecision` child
//  now (covered directly by `MigrationLockDecisionTests`); this suite stays because the arrival it
//  guards is THIS screen's — Complete's own `.onAppear` has to reach the child for the fix to hold
//  on the path this audit finding was actually found on.
//

import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

@Suite @MainActor struct MigrationCompleteReArmTests {
    @Test func onAppearReArmsTheMigrateAnywayButton() async {
        var initialState = MigrationComplete.State()
        initialState.lock.isMigratingAnyway = true

        let store = TestStore(initialState: initialState) {
            MigrationComplete()
        }
        store.exhaustivity = .off

        await store.send(.lock(.onAppear)) { state in
            state.lock.isMigratingAnyway = false
        }
    }
}
