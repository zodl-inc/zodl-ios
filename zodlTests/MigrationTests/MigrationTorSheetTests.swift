//
//  MigrationTorSheetTests.swift
//  zodlTests
//
//  Covers the MigrationTorSheet reducer
//  (Features/Migration/MigrationTorSheet/MigrationTorSheetStore.swift) for MOB-1478 (W2) +
//  MOB-1494 (round 4): the `isTorOn` binding (defaults ON per the round-4 canvas), the per-path
//  body-copy flag (`usesFullBalanceCopy`), and the `gotItTapped` delegate contract. Persisting the
//  choice into `NetworkPrivacyOptions` and resuming the stashed destination is
//  `MigrationCoordFlowCoordinator`'s job — covered in `MigrationCoordFlowTests`. No shared/global
//  state -> no `.serialized`.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite struct MigrationTorSheetTests {
    @MainActor @Test func defaultStateHasTorOnAndScheduledBodyCopy() async {
        // MOB-1494 (round 4): the canvas draws the toggle ON in every frame — default-on
        // supersedes the earlier no-pre-selection rule. The body copy defaults to the scheduled
        // ("your balance") variant.
        let state = MigrationTorSheet.State()

        #expect(state.isTorOn == true)
        #expect(state.usesFullBalanceCopy == false)
    }

    @MainActor @Test func initCanOverrideToggleAndBodyCopyVariant() async {
        let state = MigrationTorSheet.State(isTorOn: false, usesFullBalanceCopy: true)

        #expect(state.isTorOn == false)
        #expect(state.usesFullBalanceCopy == true)
    }

    @MainActor @Test func isTorOnBindingTogglesOff() async {
        let store = TestStore(initialState: MigrationTorSheet.State()) {
            MigrationTorSheet()
        }

        await store.send(.binding(.set(\.isTorOn, false))) {
            $0.isTorOn = false
        }
    }

    @MainActor @Test func isTorOnBindingTogglesOn() async {
        let store = TestStore(initialState: MigrationTorSheet.State(isTorOn: false)) {
            MigrationTorSheet()
        }

        await store.send(.binding(.set(\.isTorOn, true))) {
            $0.isTorOn = true
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
