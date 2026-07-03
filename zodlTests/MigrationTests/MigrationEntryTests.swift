//
//  MigrationEntryTests.swift
//  zodlTests
//
//  Covers the MigrationEntry reducer (Features/Migration/MigrationEntry/MigrationEntryStore.swift)
//  for MOB-1460: mode selection, the disclaimer-visibility derivation, and the `nextTapped` delegate
//  contract. No SDK calls, no navigation — chaining lands in MOB-1466. No shared/global state ->
//  no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

@Suite struct MigrationEntryTests {
    @MainActor @Test func defaultStateIsPrivateScheduledWithNoDisclaimer() async {
        let state = MigrationEntry.State()

        #expect(state.selectedMode == MigrationMode.privateScheduled)
        #expect(state.isDisclaimerVisible == false)
    }

    @MainActor @Test func modeTappedImmediateSelectsModeAndRevealsDisclaimer() async {
        let store = TestStore(initialState: MigrationEntry.State()) {
            MigrationEntry()
        }

        await store.send(.modeTapped(.immediate)) {
            $0.selectedMode = .immediate
        }

        #expect(store.state.isDisclaimerVisible)
    }

    @MainActor @Test func modeTappedPrivateScheduledSelectsModeAndHidesDisclaimer() async {
        let store = TestStore(initialState: MigrationEntry.State(selectedMode: .immediate)) {
            MigrationEntry()
        }

        await store.send(.modeTapped(.privateScheduled)) {
            $0.selectedMode = .privateScheduled
        }

        #expect(store.state.isDisclaimerVisible == false)
    }

    @MainActor @Test func modeTappedWithAlreadySelectedModeIsANoOp() async {
        let store = TestStore(initialState: MigrationEntry.State()) {
            MigrationEntry()
        }

        await store.send(.modeTapped(.privateScheduled))
    }

    @MainActor @Test func nextTappedEmitsDelegateChoseWithPrivateScheduledMode() async {
        let store = TestStore(initialState: MigrationEntry.State()) {
            MigrationEntry()
        }

        await store.send(.nextTapped)
        await store.receive(.delegate(.chose(.privateScheduled)))
    }

    @MainActor @Test func nextTappedEmitsDelegateChoseWithImmediateMode() async {
        let store = TestStore(initialState: MigrationEntry.State(selectedMode: .immediate)) {
            MigrationEntry()
        }

        await store.send(.nextTapped)
        await store.receive(.delegate(.chose(.immediate)))
    }

    @MainActor @Test func findOutMoreTappedProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationEntry.State()) {
            MigrationEntry()
        }

        await store.send(.findOutMoreTapped)
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationEntry.State()) {
            MigrationEntry()
        }

        await store.send(.delegate(.chose(.immediate)))
    }
}
