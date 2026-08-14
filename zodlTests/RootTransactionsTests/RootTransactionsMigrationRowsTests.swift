//
//  RootTransactionsMigrationRowsTests.swift
//  zodlTests
//
//  ZIP 318 labels: Activity PRESENTS migration transactions instead of hiding them. The engine
//  stores a migration transaction into the wallet's own tables at PROVE time — hours or days
//  before its scheduled broadcast — and the approved design (Figma "Transaction Statuses/Labels —
//  Final Designs") renders that in-flight story right on the list ("Migrating…", "Splitting
//  Balance…", failed states) rather than filtering it. This supersedes the M3 Part A filter.
//  What this file pins now: `.fetchedTransactions` — the one canonical build every consumer of
//  the shared `$transactions` reads — RETAINS every row, and still publishes the unmined
//  migration rows' received value for the balance-breakdown sheet's Pending correction (M3 B2),
//  which is a balance concern and outlived the filter.
//
//  Mirrors `RootTransactionsAccountSwitchTests`' established pattern for Root-level tests: a plain
//  `Store` (not `TestStore`) — Root's init effects are too heavy for exhaustive assertion — with a
//  file-scoped `baseNoOpDependencies` baseline, kept private to this file per that file's own
//  convention. `.serialized` for the same reason as its sibling: `Root.State` touches the
//  process-global `@Shared(.inMemory(...))` keys.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct RootTransactionsMigrationRowsTests {
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

    private func row(
        id: String,
        kind: ZcashTransaction.Overview.ZIP318Kind,
        minedHeight: BlockHeight?,
        totalReceived: Zatoshi? = nil
    ) -> TransactionState {
        var row = TransactionState(fee: Zatoshi(10), id: id, status: .sending, zecAmount: Zatoshi(100))
        row.minedHeight = minedHeight
        row.zip318Kind = kind
        row.timestamp = 1_000
        row.totalReceived = totalReceived
        return row
    }

    /// The canonical list build keeps EVERY row — stored-but-unmined migration rows included —
    /// and still publishes their received value for the breakdown sheet's Pending correction.
    @Test func fetchedTransactionsRetainsMigrationRowsAndPublishesPendingValue() async {
        let account = Self.walletAccount(idByte: 7)
        let scheduler = DispatchQueue.test
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        let sharedTransactions = initialState.$transactions
        sharedTransactions.withLock { $0 = [] }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            // The pending-transactions poller arms on this payload's unmined rows. On the file's
            // `.immediate` queue its 30 s sleep would elapse instantly and the tick's no-op fetch
            // (`getAllTransactions` -> []) would wipe the very rows this test pins. A test clock
            // that is never advanced keeps the poller armed but dormant — which is also why the
            // sends below must not `.finish()`: the dormant poller never completes.
            $0.mainQueue = scheduler.eraseToAnyScheduler()
        }

        let payload = IdentifiedArrayOf<TransactionState>(uniqueElements: [
            row(id: "prep-unmined", kind: .preparation, minedHeight: nil, totalReceived: Zatoshi(600)),
            row(id: "transfer-unmined", kind: .transfer, minedHeight: nil, totalReceived: Zatoshi(400)),
            row(id: "transfer-mined", kind: .transfer, minedHeight: BlockHeight(100), totalReceived: Zatoshi(9_999)),
            row(id: "regular-unmined", kind: .notClassified, minedHeight: nil, totalReceived: Zatoshi(7_777))
        ])

        store.send(.fetchedTransactions(account.id, payload))

        let ids = Set(sharedTransactions.wrappedValue.map(\.id))
        #expect(ids == Set(["prep-unmined", "transfer-unmined", "transfer-mined", "regular-unmined"]))

        // M3 B2: only the unmined migration rows contribute (600 + 400) — never the mined
        // migration row or the regular unmined send.
        #expect(initialState.unminedMigrationPendingValue == Zatoshi(1_000))

        // A later fetch with no in-flight migration rows resets the figure — it must never
        // linger from a previous pass.
        let cleanPayload = IdentifiedArrayOf<TransactionState>(uniqueElements: [
            row(id: "regular-unmined", kind: .notClassified, minedHeight: nil, totalReceived: Zatoshi(7_777))
        ])
        store.send(.fetchedTransactions(account.id, cleanPayload))
        #expect(initialState.unminedMigrationPendingValue == .zero)
    }
}

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
