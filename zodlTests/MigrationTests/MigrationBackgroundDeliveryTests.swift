//
//  MigrationBackgroundDeliveryTests.swift
//  zodlTests
//
//  Covers the MigrationBackgroundDelivery reducer
//  (Features/Migration/MigrationBackgroundDelivery/MigrationBackgroundDeliveryStore.swift) for
//  MOB-1462/1466: the `skipTapped` delegate contract, that `allowTapped` produces no state/effects
//  (the Settings deep-link opens from the view via `@Environment(\.openURL)`), and (MOB-1466)
//  `scenePhaseActive` re-checking `MigrationBGSchedulerClient.backgroundRefreshStatus()` and
//  auto-advancing via `.continued(backgroundAllowed: true)` once it becomes `.available`. No
//  shared/global state -> no `.serialized`.
//

import Testing
import Foundation
import UIKit
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

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationBackgroundDelivery.State()) {
            MigrationBackgroundDelivery()
        }

        await store.send(.delegate(.continued(backgroundAllowed: false)))
    }

    @MainActor @Test func scenePhaseActiveWithAvailableStatusEmitsDelegateContinuedAllowed() async {
        let store = TestStore(initialState: MigrationBackgroundDelivery.State()) {
            MigrationBackgroundDelivery()
        } withDependencies: {
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
        }

        await store.send(.scenePhaseActive)
        await store.receive(.delegate(.continued(backgroundAllowed: true)))
    }

    @MainActor @Test func scenePhaseActiveWithDeniedStatusProducesNoDelegate() async {
        let store = TestStore(initialState: MigrationBackgroundDelivery.State()) {
            MigrationBackgroundDelivery()
        } withDependencies: {
            $0.migrationBGScheduler.backgroundRefreshStatus = { .denied }
        }

        await store.send(.scenePhaseActive)
    }

    @MainActor @Test func scenePhaseActiveWithRestrictedStatusProducesNoDelegate() async {
        let store = TestStore(initialState: MigrationBackgroundDelivery.State()) {
            MigrationBackgroundDelivery()
        } withDependencies: {
            $0.migrationBGScheduler.backgroundRefreshStatus = { .restricted }
        }

        await store.send(.scenePhaseActive)
    }
}
