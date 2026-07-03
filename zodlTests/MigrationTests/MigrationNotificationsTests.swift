//
//  MigrationNotificationsTests.swift
//  zodlTests
//
//  Covers the MigrationNotifications reducer
//  (Features/Migration/MigrationNotifications/MigrationNotificationsStore.swift) for MOB-1462/1466:
//  the default `variant`, the `skipTapped` delegate contract, and (MOB-1466) `allowTapped`
//  requesting `UserNotificationsClient` authorization and `authorizationResult` emitting
//  `.delegate(.continued)` regardless of outcome. No shared/global state -> no `.serialized`.
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

    @MainActor @Test func allowTappedRequestsAuthorizationAndEmitsResultTrue() async {
        let store = TestStore(initialState: MigrationNotifications.State()) {
            MigrationNotifications()
        } withDependencies: {
            $0.userNotifications.requestAuthorization = { true }
        }

        await store.send(.allowTapped)
        await store.receive(.authorizationResult(true))
        await store.receive(.delegate(.continued))
    }

    @MainActor @Test func allowTappedRequestsAuthorizationAndEmitsResultFalse() async {
        let store = TestStore(initialState: MigrationNotifications.State()) {
            MigrationNotifications()
        } withDependencies: {
            $0.userNotifications.requestAuthorization = { false }
        }

        await store.send(.allowTapped)
        await store.receive(.authorizationResult(false))
        await store.receive(.delegate(.continued))
    }

    @MainActor @Test func authorizationResultTrueEmitsDelegateContinued() async {
        let store = TestStore(initialState: MigrationNotifications.State()) {
            MigrationNotifications()
        }

        await store.send(.authorizationResult(true))
        await store.receive(.delegate(.continued))
    }

    @MainActor @Test func authorizationResultFalseEmitsDelegateContinued() async {
        let store = TestStore(initialState: MigrationNotifications.State()) {
            MigrationNotifications()
        }

        await store.send(.authorizationResult(false))
        await store.receive(.delegate(.continued))
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
