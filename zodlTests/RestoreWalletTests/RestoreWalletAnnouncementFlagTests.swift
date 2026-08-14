//
//  RestoreWalletAnnouncementFlagTests.swift
//  zodlTests
//
//  Ironwood announcement — neither wallet-creation nor wallet-restore
//  (Features/CoordFlows/RestoreWalletCoordFlowCoordinator.swift) may touch the
//  Ironwood-announcement keychain flag. Ironwood is news about the network, not about a
//  particular wallet, so both paths must leave the flag untouched and let Root's normal
//  activation gate decide. An earlier revision pre-acknowledged the flag on creation; that made
//  "fresh install, create a wallet" the one path on which the screen could never appear, which
//  is also the most obvious way to test the feature by hand. These tests are what stop it
//  coming back.
//
//  RestoreWalletCoordFlow.State is not Equatable (it holds a non-Equatable StackState, and its
//  Action type — referenced via Action-typed AlertState — isn't Equatable either), so TestStore
//  will not compile against it. These tests instead drive a plain Store and read/record state
//  directly after sending actions — the same approach used by AddKeystoneHWWalletCoordFlowTests
//  (see its header comment) and ScanCoordFlowZip321Tests. Initial state is set up before Store
//  creation, never via store.state mutation (get-only on a plain Store).
//
//  Both cases under test perform their walletStorage calls synchronously inside the reducer body,
//  before any returned effect runs, so no polling/waiting is needed after `send`.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RestoreWalletAnnouncementFlagTests {
    @Test func createNewWalletRequestedNeverWritesIronwoodAnnouncementFlag() async {
        let calls = LockIsolated<[Bool]>([])
        let store = makeStore(initialState: RestoreWalletCoordFlow.State(), flagCalls: calls)

        store.send(.createNewWalletRequested)

        // Creating a wallet must leave the flag completely untouched — not even written `true`.
        // Writing it here would permanently suppress the announcement for every user who starts
        // with a fresh wallet, and would make the feature untestable by hand without the debug
        // reset row. Asserting an empty call list is what catches a reintroduction.
        #expect(calls.value.isEmpty)
    }

    @Test func resolveRestoreNeverWritesIronwoodAnnouncementFlag() async {
        var initialState = RestoreWalletCoordFlow.State()
        initialState.birthday = 1_000_000
        let calls = LockIsolated<[Bool]>([])
        let store = makeStore(initialState: initialState, flagCalls: calls)

        store.send(.resolveRestore)

        // Restoring a seed likewise leaves the flag untouched, so the one-time announcement
        // screen remains eligible to show for a returning user.
        #expect(calls.value.isEmpty)
    }

    // MARK: - Helpers

    private func makeStore(
        initialState: RestoreWalletCoordFlow.State,
        flagCalls: LockIsolated<[Bool]>
    ) -> StoreOf<RestoreWalletCoordFlow> {
        Store(initialState: initialState) {
            RestoreWalletCoordFlow()
        } withDependencies: {
            $0.mnemonic = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.importIronwoodAnnouncementFlag = { value in
                flagCalls.withValue { $0.append(value) }
            }
            // [#1024] seed/DB integrity guard (RestoreSeedGuardTests): `.resolveRestore` checks
            // `databaseFiles.areDbFilesPresentFor` before importing. Not part of what this suite
            // covers (the Ironwood flag), so stub the no-DB-on-disk case -- same value as
            // `DatabaseFilesClient`'s own default -- to reach `.commitRestore` without an
            // unimplemented-dependency issue.
            $0.databaseFiles = .noOp
        }
    }
}
