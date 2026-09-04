//
//  RootTransactionsEmptyFetchTests.swift
//  zodlTests
//
//  `.fetchedTransactions` (`RootTransactions.swift`) used to trust every fetch result
//  unconditionally: whenever the freshly fetched array differed from `state.transactions`, it
//  overwrote the shared list, even with an EMPTY array. `getAllTransactions` can legitimately race
//  a reorg/rescan window mid-sync and answer with zero rows for an account that plainly has
//  transactions -- that raced empty answer blanked a list that was correct a moment before, or
//  left it stuck showing placeholders, with nothing to tell it to trust its own kept rows over a
//  transient miss. A parallel gap sat in the failure path: a THROWN `getAllTransactions` only
//  logged, so a list already showing its loading placeholder (freshly invalidated by an account
//  switch, say) never got the completion signal it needed to clear that placeholder, even though
//  the kept rows underneath were perfectly fine.
//
//  Covers both: an empty fetch is now trusted only once the synchronizer itself reports
//  `.upToDate`, or once a list is already invalidated and therefore has nothing correct left to
//  lose; a failed fetch still notifies both lists and re-arms the reconciliation poller from the
//  rows that were kept, exactly as an ignored empty fetch does.
//
//  Mirrors `RootPendingTransactionRefreshTests.swift`'s established pattern: a plain `Store` (not
//  `TestStore`) driven with `LockIsolated` spies, with time-dependent behavior (the 30 s
//  reconciliation poller) run on a `DispatchQueue.test` scheduler injected as `mainQueue`,
//  advanced in small steps interleaved with real-time yields so the poller's effect Task gets a
//  chance to register its sleep on the scheduler before the clock advances past it.
//
//  `.serialized`: constructing/driving `Root.State` touches the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` / `.inMemory(.transactions)` keys, same precedent
//  as the other Root-level suites in this directory.
//

@preconcurrency import Combine
import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct RootTransactionsEmptyFetchTests {
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

    private func tx(id: String, status: TransactionState.Status) -> TransactionState {
        TransactionState(fee: Zatoshi(10), id: id, status: status, zecAmount: Zatoshi(100_000))
    }

    private struct FetchStubError: Error { }

    // MARK: - (1) A spurious empty fetch mid-sync, with neither list invalidated, must be ignored

    /// The core guard: sync still in progress (not `.upToDate`), neither Home's nor See All's
    /// transaction list already invalidated, and the fetch came back empty while the kept list is
    /// not -- the fetch must be treated as spurious. The list is kept untouched, but both lists
    /// still get their own `transactionsUpdated` so a list that WAS mid-load has something to
    /// clear its placeholder with, and the 30 s reconciliation poller stays armed from the KEPT
    /// pending row, never from the empty fetch result.
    @Test func emptyFetchMidSyncWithValidListsKeepsTheListAndStillNotifiesBothLists() async {
        let account = Self.walletAccount(idByte: 100)
        let scheduler = DispatchQueue.test
        let fetchCalls = LockIsolated<Int>(0)
        let keptTransaction = tx(id: "kept-pending-tx", status: .sending)
        let keptTransactions = IdentifiedArrayOf<TransactionState>(uniqueElements: [keptTransaction])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = keptTransactions }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false
        initialState.lastKnownSyncStatus = .syncing(0.3, false)

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.mainQueue = scheduler.eraseToAnyScheduler()
            $0.sdkSynchronizer.getAllTransactions = { _ in
                fetchCalls.withValue { $0 += 1 }
                return []
            }
        }

        store.send(.fetchedTransactions(account.id, []))

        // The ignore path's early return never touches `state.transactions` -- true synchronously,
        // before any of the returned effects below have had a chance to run.
        #expect(store.state.transactions == keptTransactions, "a spurious empty fetch mid-sync must never blank a non-empty list")

        // `transactionsUpdated` reaches each list via a returned `.send` effect, not a synchronous
        // mutation -- give it a moment to land before reading each list's own derived state.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(
            store.state.homeState.transactionListState.latestTransactionId == "kept-pending-tx",
            "Home's transactionsUpdated was not received on the ignored-empty-fetch path"
        )
        #expect(
            store.state.transactionsCoordFlowState.transactionsManagerState.searchedTransactionsList == keptTransactions,
            "See All's transactionsUpdated was not received on the ignored-empty-fetch path"
        )

        // The reconciliation poller must still be armed from the KEPT rows. Advance in small steps
        // interleaved with real-time yields so the poller's sleep registers on the scheduler before
        // the clock advances past its deadline -- unbounded on purpose, the suite's `.timeLimit`
        // backstops a poller that genuinely never ticks.
        while fetchCalls.value < 1 {
            await scheduler.advance(by: .seconds(1))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fetchCalls.value >= 1, "the reconciliation poller was not scheduled for the kept pending row")
    }

    // MARK: - (2) The same empty fetch, once the synchronizer is up to date, must be trusted

    /// Once `.synchronizerStateChanged` has reported `.upToDate`, an empty result is no longer a
    /// transient sync artifact -- it is the wallet's settled answer, and must be applied exactly
    /// like the pre-existing behavior for every other differing fetch result.
    @Test func emptyFetchOnceUpToDateEmptiesTheList() async {
        let account = Self.walletAccount(idByte: 101)
        let keptTransaction = tx(id: "kept-pending-tx", status: .sending)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = IdentifiedArrayOf<TransactionState>(uniqueElements: [keptTransaction]) }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false
        initialState.lastKnownSyncStatus = .upToDate

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
        }

        store.send(.fetchedTransactions(account.id, []))

        #expect(store.state.transactions.isEmpty, "an empty fetch once the synchronizer is up to date must be trusted and applied")
    }

    // MARK: - (3) The same empty fetch, with ONE list already invalidated, must be trusted (OR boundary)

    /// A list already invalidated (an account switch just happened, say) is already showing its
    /// loading placeholder and has nothing correct left to lose -- the guard must not hold an empty
    /// fetch back in that case, or the placeholder would never clear. Deliberately invalidates only
    /// Home's list, not See All's: `listsAreInvalidated` in the guard is an OR of the two, so this
    /// exercises that either flag alone is enough to bypass the guard. `accountSwitchedEffect`
    /// (`RootCoordinator.swift`) itself invalidates BOTH lists on a real account switch -- this test
    /// does not reproduce that combination, only the OR boundary the guard actually branches on.
    @Test func emptyFetchWithAnInvalidatedListEmptiesTheList() async {
        let account = Self.walletAccount(idByte: 102)
        let keptTransaction = tx(id: "kept-pending-tx", status: .sending)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = IdentifiedArrayOf<TransactionState>(uniqueElements: [keptTransaction]) }
        // Only Home is invalidated here (see the doc comment above) -- deliberately narrower than
        // what `accountSwitchedEffect` (`RootCoordinator.swift`) does on a real account switch.
        initialState.homeState.transactionListState.isInvalidated = true
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false
        initialState.lastKnownSyncStatus = .syncing(0.3, false)

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
        }

        store.send(.fetchedTransactions(account.id, []))

        #expect(store.state.transactions.isEmpty, "an empty fetch for an already-invalidated list has nothing correct to lose, and must apply")
    }

    // MARK: - (4) A failed fetch must still notify both lists and re-arm the poller

    /// A thrown `getAllTransactions` must never leave a list stranded on its loading placeholder:
    /// both lists still receive `transactionsUpdated` (clearing `isInvalidated`), and the
    /// reconciliation poller is armed from whatever `state.transactions` still holds, so a pending
    /// row that was kept through the failure keeps its 30 s reconciler.
    @Test func fetchFailureClearsInvalidationAndReArmsThePollerFromTheKeptList() async {
        let account = Self.walletAccount(idByte: 103)
        let scheduler = DispatchQueue.test
        let fetchCalls = LockIsolated<Int>(0)
        let keptTransaction = tx(id: "kept-pending-tx", status: .sending)
        let keptTransactions = IdentifiedArrayOf<TransactionState>(uniqueElements: [keptTransaction])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = keptTransactions }
        initialState.homeState.transactionListState.isInvalidated = true
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = true

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.mainQueue = scheduler.eraseToAnyScheduler()
            $0.sdkSynchronizer.getAllTransactions = { _ in
                fetchCalls.withValue { $0 += 1 }
                throw FetchStubError()
            }
        }

        store.send(.fetchTransactionsForTheSelectedAccount)
        while fetchCalls.value < 1 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // The failure's own completion signal reaches both lists via returned `.send` effects --
        // give them a moment to land.
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(store.state.transactions == keptTransactions, "a failed fetch must never clear the kept list")
        #expect(!store.state.homeState.transactionListState.isInvalidated, "a failed fetch must still clear Home's invalidation")
        #expect(
            !store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated,
            "a failed fetch must still clear See All's invalidation"
        )

        let fetchesBeforePoll = fetchCalls.value
        while fetchCalls.value < fetchesBeforePoll + 1 {
            await scheduler.advance(by: .seconds(1))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fetchCalls.value > fetchesBeforePoll, "the reconciliation poller was not re-armed from the kept list after a failed fetch")
    }

    // MARK: - (5) A failed fetch for a NON-selected account must change nothing

    /// `.transactionsFetchFailed` must apply the same provenance guard as `.fetchedTransactions`:
    /// a failure for an account the user has since switched away from must never touch the
    /// CURRENTLY selected account's lists. Without the guard, this stale failure would clear the
    /// newly-selected account's `isInvalidated` flags and re-arm the reconciliation poller from ITS
    /// `state.transactions` -- which at that point may still be the previous account's leftover
    /// rows -- marking the new account "loaded" while the wrong rows are still on screen.
    @Test func fetchFailureForANonSelectedAccountChangesNothing() async {
        let selectedAccount = Self.walletAccount(idByte: 104)
        let staleAccount = Self.walletAccount(idByte: 105)
        let scheduler = DispatchQueue.test
        let fetchCalls = LockIsolated<Int>(0)
        let keptTransaction = tx(id: "kept-pending-tx", status: .sending)
        let keptTransactions = IdentifiedArrayOf<TransactionState>(uniqueElements: [keptTransaction])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = selectedAccount }
        initialState.$transactions.withLock { $0 = keptTransactions }
        // Mirrors `accountSwitchedEffect` (`RootCoordinator.swift`): the newly-selected account's
        // lists stay invalidated until ITS OWN fetch completes -- a stale failure for the account
        // just switched away from must not be what clears them.
        initialState.homeState.transactionListState.isInvalidated = true
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = true

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.mainQueue = scheduler.eraseToAnyScheduler()
            $0.sdkSynchronizer.getAllTransactions = { _ in
                fetchCalls.withValue { $0 += 1 }
                throw FetchStubError()
            }
        }

        store.send(.transactionsFetchFailed(accountUUID: staleAccount.id))

        // The guard's early return is synchronous -- true before any wrongly-returned effect could
        // possibly land.
        #expect(store.state.transactions == keptTransactions, "a stale failure must never touch the kept list")
        #expect(
            store.state.homeState.transactionListState.isInvalidated,
            "a stale failure must not clear the CURRENTLY selected account's Home invalidation"
        )
        #expect(
            store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated,
            "a stale failure must not clear the CURRENTLY selected account's See All invalidation"
        )

        // Confirm no reconciliation poller was armed either -- if the guard had NOT fired, this
        // poller WOULD tick, because `keptTransactions` holds a pending row.
        try? await Task.sleep(nanoseconds: 100_000_000)
        await scheduler.advance(by: .seconds(30))
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(fetchCalls.value == 0, "a stale failure must not re-arm the reconciliation poller")
    }

    // MARK: - (6) An empty on-chain fetch with an in-flight swap-to-ZEC must still keep the on-chain rows

    /// The emptiness check in the guard must test the RAW fetched `transactions`, not the
    /// `identifiedArray` built after `mixedTransactions` appends one synthetic row per in-flight
    /// swap-to-ZEC. Otherwise a genuinely empty on-chain fetch, for a user with such a swap
    /// pending, would still produce a non-empty `identifiedArray` (the synthetic row alone),
    /// defeating the guard and overwriting the kept on-chain rows with a list containing only that
    /// synthetic row.
    @Test func emptyOnChainFetchWithInFlightSwapToZecKeepsTheOnChainRows() async {
        let account = Self.walletAccount(idByte: 106)
        let keptTransaction = tx(id: "kept-pending-tx", status: .sending)
        let keptTransactions = IdentifiedArrayOf<TransactionState>(uniqueElements: [keptTransaction])

        // An in-flight swap TO Zec -- `mixedTransactions` (`RootTransactions.swift`) appends a
        // synthetic `TransactionState` for exactly this, regardless of how many on-chain rows the
        // fetch itself returned.
        let swapToZec = UMSwapId(
            depositAddress: "swap-to-zec-deposit-address",
            provider: "near",
            totalFees: 0,
            totalUSDFees: "0",
            lastUpdated: 0,
            fromAsset: "near.usdc.usdc",
            toAsset: SwapConstants.zecAssetIdOnNear,
            exactInput: true,
            status: SwapConstants.processing,
            amountOutFormatted: "0.1"
        )

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = keptTransactions }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false
        initialState.lastKnownSyncStatus = .syncing(0.3, false)

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.userMetadataProvider.allSwaps = { [swapToZec] }
        }

        store.send(.fetchedTransactions(account.id, []))

        #expect(
            store.state.transactions == keptTransactions,
            "an empty on-chain fetch must keep the on-chain rows even with an in-flight swap-to-ZEC synthetic row in play"
        )
    }
}

/// Shared no-op dependency baseline for every test in this file. Kept as a private, file-scoped
/// helper rather than something shared globally, the same way the other suites in this directory
/// keep theirs. `mainQueue` is deliberately NOT set here -- only the tests that exercise the
/// reconciliation poller inject their own `DispatchQueue.test` scheduler.
@MainActor
private func baseNoOpDependencies(_ values: inout DependencyValues) {
    values.autoServerSelection.findBestServer = { nil }
    values.databaseFiles = .noOp
    values.derivationTool = .liveValue
    values.diskSpaceChecker = .mockFullDisk
    values.flexaHandler = .noOp
    values.localAuthentication = .mockAuthenticationSucceeded
    values.mnemonic = .mock
    values.readTransactionsStorage.resetZashi = { }
    values.sdkSynchronizer = .noOp
    values.userMetadataProvider.allSwaps = { [] }
    values.userMetadataProvider.load = { _ in }
    values.walletStorage = .noOp
    values.zcashSDKEnvironment = .testnet
}
