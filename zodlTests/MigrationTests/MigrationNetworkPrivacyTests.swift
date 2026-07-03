//
//  MigrationNetworkPrivacyTests.swift
//  zodlTests
//
//  Covers the MigrationNetworkPrivacy reducer
//  (Features/Migration/MigrationNetworkPrivacy/MigrationNetworkPrivacyStore.swift) for MOB-1460: the
//  `isTorOn` binding and the `nextTapped` delegate contract. No SDK calls, no navigation — chaining
//  lands in MOB-1466. No shared/global state -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

@Suite struct MigrationNetworkPrivacyTests {
    @MainActor @Test func defaultStateHasTorOffAndScheduledVariant() async {
        let state = MigrationNetworkPrivacy.State()

        #expect(state.isTorOn == false)
        #expect(state.variant == .scheduled(transferCount: 5))
    }

    @MainActor @Test func isTorOnBindingTogglesOn() async {
        let store = TestStore(initialState: MigrationNetworkPrivacy.State()) {
            MigrationNetworkPrivacy()
        }

        await store.send(.binding(.set(\.isTorOn, true))) {
            $0.isTorOn = true
        }
    }

    @MainActor @Test func isTorOnBindingTogglesOff() async {
        let store = TestStore(initialState: MigrationNetworkPrivacy.State(isTorOn: true)) {
            MigrationNetworkPrivacy()
        }

        await store.send(.binding(.set(\.isTorOn, false))) {
            $0.isTorOn = false
        }
    }

    @MainActor @Test func nextTappedEmitsDelegateConfirmedWithTorOnAndNilEndpoint() async {
        let store = TestStore(initialState: MigrationNetworkPrivacy.State(isTorOn: true)) {
            MigrationNetworkPrivacy()
        }

        await store.send(.nextTapped)
        await store.receive(.delegate(.confirmed(NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil))))
    }

    @MainActor @Test func nextTappedEmitsDelegateConfirmedWithTorOffAndNilEndpoint() async {
        let store = TestStore(initialState: MigrationNetworkPrivacy.State(isTorOn: false)) {
            MigrationNetworkPrivacy()
        }

        await store.send(.nextTapped)
        await store.receive(.delegate(.confirmed(NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil))))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationNetworkPrivacy.State()) {
            MigrationNetworkPrivacy()
        }

        await store.send(.delegate(.confirmed(NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil))))
    }
}
