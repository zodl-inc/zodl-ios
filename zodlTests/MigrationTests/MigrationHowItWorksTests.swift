//
//  MigrationHowItWorksTests.swift
//  zodlTests
//
//  Covers the MigrationHowItWorks reducer
//  (Features/Migration/MigrationHowItWorks/MigrationHowItWorksStore.swift) for MOB-1478 (W3): the
//  `continueTapped` delegate contract. Pure explainer — no dependencies, no state beyond `init()`.
//  No shared/global state -> no `.serialized`.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite struct MigrationHowItWorksTests {
    @MainActor @Test func continueTappedEmitsDelegateContinueTapped() async {
        let store = TestStore(initialState: MigrationHowItWorks.State()) {
            MigrationHowItWorks()
        }

        await store.send(.continueTapped)
        await store.receive(.delegate(.continueTapped))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationHowItWorks.State()) {
            MigrationHowItWorks()
        }

        await store.send(.delegate(.continueTapped))
    }
}
