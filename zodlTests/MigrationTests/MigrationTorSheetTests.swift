//
//  MigrationTorSheetTests.swift
//  zodlTests
//
//  Covers the MigrationTorSheet reducer
//  (Features/Migration/MigrationTorSheet/MigrationTorSheetStore.swift) for MOB-1478 (W2): the
//  `isTorOn` binding (default off, no pre-selection bias) and the `gotItTapped` delegate contract.
//  Persisting the choice into `NetworkPrivacyOptions` and resuming the stashed destination is
//  `MigrationCoordFlowCoordinator`'s job — covered in `MigrationCoordFlowTests`. No shared/global
//  state -> no `.serialized`.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite struct MigrationTorSheetTests {
    @MainActor @Test func defaultStateHasTorOff() async {
        let state = MigrationTorSheet.State()

        #expect(state.isTorOn == false)
    }

    @MainActor @Test func isTorOnBindingTogglesOn() async {
        let store = TestStore(initialState: MigrationTorSheet.State()) {
            MigrationTorSheet()
        }

        await store.send(.binding(.set(\.isTorOn, true))) {
            $0.isTorOn = true
        }
    }

    @MainActor @Test func isTorOnBindingTogglesOff() async {
        let store = TestStore(initialState: MigrationTorSheet.State(isTorOn: true)) {
            MigrationTorSheet()
        }

        await store.send(.binding(.set(\.isTorOn, false))) {
            $0.isTorOn = false
        }
    }

    @MainActor @Test func gotItTappedEmitsDelegateGotIt() async {
        let store = TestStore(initialState: MigrationTorSheet.State()) {
            MigrationTorSheet()
        }

        await store.send(.gotItTapped)
        await store.receive(.delegate(.gotIt))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationTorSheet.State()) {
            MigrationTorSheet()
        }

        await store.send(.delegate(.gotIt))
    }
}
