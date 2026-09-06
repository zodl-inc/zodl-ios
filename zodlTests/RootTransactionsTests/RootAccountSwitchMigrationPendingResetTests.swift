//
//  RootAccountSwitchMigrationPendingResetTests.swift
//  zodlTests
//
//  MOB-1862: `accountSwitchedEffect` (`RootCoordinator.swift`) clears the shared `transactions`
//  array and its account marker the moment the selected account changes, but left
//  `unminedMigrationPendingValue` untouched. That figure is derived FROM those same rows
//  (`RootTransactions.swift`'s `.fetchedTransactions` handler) and read straight into the balance
//  breakdown's "Pending" row (`Balances.State.displayedPendingBalance`), so a switch could leave
//  the PREVIOUS account's in-flight-migration figure subtracted from the NEWLY selected account's
//  pending lanes for however long it takes that account's own transaction fetch to land and
//  correct it.
//
//  Mirrors `RootTransactionsAccountProvenanceTests.swift`'s established pattern: a plain `Store`
//  (not `TestStore`) driven with a file-scoped `baseNoOpDependencies` baseline. Unlike that file,
//  the value under test is set directly rather than produced by a real `.fetchedTransactions`
//  completion -- what is being verified here is the reset itself, not how the figure is derived in
//  the first place (that is `RootTransactionsMigrationRowsTests.swift`'s job).
//
//  `.serialized`: constructing/driving `Root.State` touches the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` / `.inMemory(.walletAccounts)` /
//  `.inMemory(.unminedMigrationPendingValue)` keys, same precedent as every other Root-level suite
//  in this directory.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct RootAccountSwitchMigrationPendingResetTests {
    private static func walletAccount(idByte: UInt8) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// The exact regression: A leaves a non-zero pending-migration figure behind. B's own
    /// transaction fetch -- which would eventually recompute the figure from scratch anyway, since
    /// it lands on the shared `transactions` array `accountSwitchedEffect` already empties -- is
    /// held on a gate, so this checks the window BEFORE that fetch has any chance to land: the
    /// figure must already read zero from `accountSwitchedEffect`'s own synchronous reset, not
    /// however long it takes B's fetch to complete and correct it as a side effect.
    @Test func accountSwitchResetsUnminedMigrationPendingValueBeforeTheNewFetchLands() async {
        let accountA = Self.walletAccount(idByte: 140)
        let accountB = Self.walletAccount(idByte: 141)
        let gate = ResumableGate()

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountA }
        initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
        initialState.$unminedMigrationPendingValue.withLock { $0 = Zatoshi(12_345) }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { _ in
                await gate.wait()
                return []
            }
        }

        #expect(store.state.unminedMigrationPendingValue == Zatoshi(12_345), "setup must land A's non-zero figure before the switch")

        // `Store.send` (unlike `TestStore.send`) runs the reducer's synchronous body immediately
        // and returns once any effects it starts are merely spawned -- so by the time this call
        // returns, `accountSwitchedEffect`'s own state mutations have already applied, while B's
        // gated fetch has not.
        let switchTask = store.send(.home(.walletAccountTapped(accountB)))

        #expect(
            store.state.unminedMigrationPendingValue == .zero,
            "the previous account's figure must not survive an account switch, even before B's own fetch lands"
        )

        gate.open()
        await switchTask.finish()

        #expect(store.state.unminedMigrationPendingValue == .zero)
        #expect(store.state.selectedWalletAccount == accountB)
    }
}

/// Shared no-op dependency baseline for this file. Copied from
/// `RootTransactionsAccountProvenanceTests.swift` per this directory's established convention of
/// not sharing test helpers across files -- this test drives the same real
/// `.home(.walletAccountTapped)` action, which also merges in `.loadContacts`/
/// `.resolveMetadataEncryptionKeys`/`.loadUserMetadata`, and that baseline is already proven to
/// carry those to completion.
@MainActor
private func baseNoOpDependencies(_ values: inout DependencyValues) {
    values.databaseFiles = .noOp
    values.derivationTool = .liveValue
    values.diskSpaceChecker = .mockFullDisk
    values.flexaHandler = .noOp
    values.localAuthentication = .mockAuthenticationSucceeded
    values.mainQueue = .immediate
    values.mnemonic = .mock
    values.readTransactionsStorage.resetZashi = { }
    values.sdkSynchronizer = .noOp
    values.userMetadataProvider.load = { _ in }
    values.walletStorage = .noOp
    values.zcashSDKEnvironment = .testnet
}
