//
//  RootShieldingAlertTests.swift
//  zodlTests
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized: constructing `Root.State` touches process-global `@Shared(.inMemory(...))` keys.
@Suite(.serialized) @MainActor struct RootShieldingAlertTests {
    /// `.nothingToShield` is a plain outcome, not a failure: it must show its own titled alert
    /// (no error code, no "send report" button — compare `shieldFundsFailure`).
    @Test func nothingToShieldShowsThePlainAlert() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let initialState = Root.State(
                destinationState: Root.DestinationState(internalDestination: .welcome),
                exportLogsState: ExportLogs.State(),
                onboardingState: RestoreWalletCoordFlow.State(),
                phraseDisplayState: RecoveryPhraseDisplay.State(),
                walletConfig: .initial,
                welcomeState: Welcome.State()
            )
            let store = TestStore(initialState: initialState) { Root() }
            store.exhaustivity = .off

            await store.send(.shieldingProcessorStateChanged(.nothingToShield)) {
                $0.alert = AlertState.shieldFundsNothingToShield()
            }
        }
    }
}
