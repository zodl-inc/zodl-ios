//
//  MigrationNotificationsTests.swift
//  zodlTests
//
//  Covers the MigrationNotifications reducer
//  (Features/Migration/MigrationNotifications/MigrationNotificationsStore.swift) for MOB-1462: the
//  default `variant`, the `skipTapped` delegate contract, and that `allowTapped` /
//  `authorizationResult` are no-ops for now — the `UNUserNotificationCenter` request lands in
//  MOB-1466. No shared/global state -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

@Suite struct MigrationNotificationsTests {
    @MainActor @Test func defaultStateHasScheduledVariant() async {
        let state = MigrationNotifications.State()

        #expect(state.variant == .scheduled)
    }

    @MainActor @Test func skipTappedEmitsDelegateContinued() async {
        let store = TestStore(initialState: MigrationNotifications.State()) {
            MigrationNotifications()
        }

        await store.send(.skipTapped)
        await store.receive(.delegate(.continued))
    }

    @MainActor @Test func allowTappedProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationNotifications.State()) {
            MigrationNotifications()
        }

        await store.send(.allowTapped)
    }

    @MainActor @Test func authorizationResultTrueProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationNotifications.State()) {
            MigrationNotifications()
        }

        await store.send(.authorizationResult(true))
    }

    @MainActor @Test func authorizationResultFalseProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationNotifications.State()) {
            MigrationNotifications()
        }

        await store.send(.authorizationResult(false))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationNotifications.State()) {
            MigrationNotifications()
        }

        await store.send(.delegate(.continued))
    }

    @MainActor @Test func manualVariantIsPreservedInState() async {
        let state = MigrationNotifications.State(variant: .manual)

        #expect(state.variant == .manual)
    }
}
