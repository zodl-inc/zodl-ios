//
//  RestoreSeedGuardTests.swift
//  zodlTests
//
//  Preventive guard ([#1024]): when a wallet DB is already on disk, restoring a seed that doesn't match
//  it must warn instead of silently importing the foreign seed over that DB. That silent import is the
//  desync that left the keychain seed and data.db pointing at different wallets and broke every send
//  ("Wallet does not contain an account corresponding to the provided spending key"). The original guard
//  was deleted in a 2025 "code cleanup" and never re-homed into the CoordFlow nav; these tests lock the
//  re-homed version in so it can't silently regress again.
//

import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@MainActor
@Suite struct RestoreSeedGuardTests {
    private func makeStore(
        dbPresent: Bool,
        seedRelevant: Bool
    ) -> TestStore<RestoreWalletCoordFlow.State, RestoreWalletCoordFlow.Action> {
        var initialState = RestoreWalletCoordFlow.State()
        initialState.birthday = 2_700_000
        initialState.words = Array(repeating: "abandon", count: 24)

        let store = TestStore(initialState: initialState) {
            RestoreWalletCoordFlow()
        }
        store.exhaustivity = .off

        store.dependencies.mainQueue = .immediate
        store.dependencies.zcashSDKEnvironment = .testnet
        store.dependencies.walletStorage = .noOp
        var databaseFiles = DatabaseFilesClient.noOp
        databaseFiles.areDbFilesPresentFor = { _ in dbPresent }
        store.dependencies.databaseFiles = databaseFiles
        store.dependencies.mnemonic = .liveValue
        store.dependencies.mnemonic.isValid = { _ in }
        store.dependencies.mnemonic.toSeed = { _ in [UInt8](repeating: 0, count: 32) }
        store.dependencies.sdkSynchronizer.isSeedRelevantToAnyDerivedAccount = { _ in seedRelevant }

        return store
    }

    /// A different wallet's seed restored over an existing DB routes to the mismatch warning and is NEVER
    /// written to the keychain.
    @Test func mismatchedSeedOverExistingDBWarnsAndDoesNotImport() async {
        let store = makeStore(dbPresent: true, seedRelevant: false)
        store.dependencies.walletStorage.importWallet = { _, _, _, _ in
            Issue.record("importWallet must not be called when the seed doesn't match the existing DB")
        }

        await store.send(.resolveRestore)
        await store.receive(\.seedRelevanceChecked)
        await store.receive(\.seedNotRelevantToExistingDB)
    }

    /// The same wallet's seed (relevant to the DB) imports silently, keeping the already-synced DB.
    @Test func relevantSeedOverExistingDBImportsSilently() async {
        let store = makeStore(dbPresent: true, seedRelevant: true)

        await store.send(.resolveRestore)
        await store.receive(\.seedRelevanceChecked)
        await store.receive(\.commitRestore)
        await store.receive(\.successfullyRecovered)
    }

    /// A fresh restore with no DB on disk skips the relevance check and imports directly (unchanged path).
    @Test func freshRestoreWithoutExistingDBImportsDirectly() async {
        let store = makeStore(dbPresent: false, seedRelevant: false)

        await store.send(.resolveRestore)
        await store.receive(\.commitRestore)
        await store.receive(\.successfullyRecovered)
    }
}
