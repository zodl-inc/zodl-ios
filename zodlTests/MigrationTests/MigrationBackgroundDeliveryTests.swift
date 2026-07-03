//
//  MigrationBackgroundDeliveryTests.swift
//  zodlTests
//
//  Covers the MigrationBackgroundDelivery reducer
//  (Features/Migration/MigrationBackgroundDelivery/MigrationBackgroundDeliveryStore.swift) for
//  MOB-1462: the `skipTapped` delegate contract, and that `allowTapped` / `scenePhaseActive` are
//  no-ops for now — the Settings deep-link and BAR re-check land in MOB-1466. No shared/global
//  state -> no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

@Suite struct MigrationBackgroundDeliveryTests {
    @MainActor @Test func skipTappedEmitsDelegateContinuedWithBackgroundNotAllowed() async {
        let store = TestStore(initialState: MigrationBackgroundDelivery.State()) {
            MigrationBackgroundDelivery()
        }

        await store.send(.skipTapped)
        await store.receive(.delegate(.continued(backgroundAllowed: false)))
    }

    @MainActor @Test func allowTappedProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationBackgroundDelivery.State()) {
            MigrationBackgroundDelivery()
        }

        await store.send(.allowTapped)
    }

    @MainActor @Test func scenePhaseActiveProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationBackgroundDelivery.State()) {
            MigrationBackgroundDelivery()
        }

        await store.send(.scenePhaseActive)
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationBackgroundDelivery.State()) {
            MigrationBackgroundDelivery()
        }

        await store.send(.delegate(.continued(backgroundAllowed: false)))
    }
}
