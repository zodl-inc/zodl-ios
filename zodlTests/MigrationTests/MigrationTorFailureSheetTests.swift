//
//  MigrationTorFailureSheetTests.swift
//  zodlTests
//
//  Covers the MigrationTorFailureSheet reducer
//  (Features/Migration/MigrationTorFailureSheet/MigrationTorFailureSheetStore.swift) for MOB-1497
//  (T6): the "Couldn't Connect to Tor" sheet. The store itself is intentionally minimal — each
//  button tap emits its `.delegate` case and nothing else; every side effect (dismiss, clear the
//  latch, `overrideTorForRun`, the foreground broadcast attempt, re-arm/re-present) is `Root`'s job
//  and is covered in `RootTorFailurePromptTests`. No shared/global state -> no `.serialized`.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite struct MigrationTorFailureSheetTests {
    @MainActor @Test func continueWithoutTorTappedEmitsContinueWithoutTorDelegate() async {
        let store = TestStore(initialState: MigrationTorFailureSheet.State()) {
            MigrationTorFailureSheet()
        }

        await store.send(.continueWithoutTorTapped)
        await store.receive(.delegate(.continueWithoutTor))
    }

    @MainActor @Test func tryAgainTappedEmitsTryAgainDelegate() async {
        let store = TestStore(initialState: MigrationTorFailureSheet.State()) {
            MigrationTorFailureSheet()
        }

        await store.send(.tryAgainTapped)
        await store.receive(.delegate(.tryAgain))
    }
}
