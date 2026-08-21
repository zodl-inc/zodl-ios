//
//  MigrationResidualCoordinatorTests.swift
//  zodlTests
//
//  MOB-1749: the Remaining Orchard Funds screen inside `MigrationCoordFlow` — re-entry lands it
//  hydrated over a hidden root; "Got it" finishes the flow with nothing to acknowledge; "Migrate
//  anyway" rides the exact unlock → immediate-review leg Migration Complete uses, and a failed
//  unlock re-arms the button.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationResidualCoordinatorTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x0D, count: 16))
    private static let balances = MigrationResidualBalances(unlockedOrchard: Zatoshi(800_000), ironwood: Zatoshi(1_245_000_000))

    private static func account() -> WalletAccount {
        WalletAccount(
            Account(
                id: accountUUID,
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    // MARK: - Re-entry

    @Test func aResidualRouteLandsTheHydratedScreenOverAHiddenRoot() async {
        let store = TestStore(initialState: MigrationCoordFlow.State.initial) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            var client = MigrationManagerClient.noOp
            client.reentryRoute = { .residual }
            client.residualBalances = { _ in await Self.balances }
            $0.migrationManager = client
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushHydratedPathState, timeout: .seconds(5))

        #expect(store.state.path.count == 1, "a resolved push destination must land exactly one path element")
        guard case .residual(let residualState)? = store.state.path.last else {
            Issue.record("expected a .residual element, got \(String(describing: store.state.path.last))")
            return
        }
        #expect(residualState.orchardBalance == Zatoshi(800_000))
        #expect(residualState.ironwoodBalance == Zatoshi(1_245_000_000))
        #expect(residualState.resolution == .offered)
        #expect(!store.state.isReentryResolved, "a pushed re-entry destination keeps the fork hidden")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }
}
