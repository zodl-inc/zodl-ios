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

import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

@Suite @MainActor struct MigrationCompleteReArmTests {
    @Test func onAppearReArmsTheMigrateAnywayButton() async {
        var initialState = MigrationComplete.State()
        initialState.isMigratingAnyway = true

        let store = TestStore(initialState: initialState) {
            MigrationComplete()
        }
        store.exhaustivity = .off

        await store.send(.onAppear) { state in
            state.isMigratingAnyway = false
        }
    }
}
