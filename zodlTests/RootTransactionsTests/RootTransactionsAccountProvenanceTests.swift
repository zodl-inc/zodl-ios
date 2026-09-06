//
//  RootTransactionsAccountProvenanceTests.swift
//  zodlTests
//
//  The shared `transactions` array used to carry no record of which account's fetch actually
//  produced it. `accountSwitchedEffect` (`RootCoordinator.swift`) invalidated both transaction
//  lists on a switch but left the array itself untouched, so if the NEWLY selected account's first
//  fetch then FAILED, the failure path's own guard (`accountUUID == state.selectedWalletAccount?.id`)
//  passed -- correctly, the failure genuinely is for the current account -- and went on to notify
//  both lists and re-arm the reconciliation poller from whatever was still sitting in
//  `state.transactions`: the PREVIOUS account's rows. Both lists cleared their loading placeholder
//  and rendered the old account's history as if it were the new account's, with no error surfaced
//  anywhere.
//
//  The fix is two-layered: `accountSwitchedEffect` now empties the shared array (and the new
//  `transactionsAccountId` alongside it) the moment it invalidates both lists, so nothing
//  renderable survives a switch until the new account's own fetch actually lands; and
//  `transactionsAccountId` (`RootStore.swift`) records which account's rows are CURRENTLY in the
//  array, read by both the pre-existing empty-fetch keep-guard and a new defensive check on the
//  failure path, so neither can ever treat a foreign account's leftover rows as a confirmed answer
//  for the account a fetch just completed -- or failed -- for.
//
//  Mirrors `RootTransactionsAccountSwitchTests.swift`'s established pattern: a plain `Store` (not
//  `TestStore`) driven with a file-scoped `baseNoOpDependencies` baseline (copied from that file,
//  since these tests drive the SAME real switch action, `.home(.walletAccountTapped)`, and need the
//  same dependency shape for `loadContacts`/`resolveMetadataEncryptionKeys`/`loadUserMetadata` to
//  settle). Every account's rows are seeded via a REAL `.fetchedTransactions` completion rather than
//  a hand-built `$transactions`/`transactionsAccountId` fixture, so `transactionsAccountId` ends up
//  set exactly the way production sets it. The one late-arriving completion each test needs (a
//  stale failure, or a still-parked fetch for the newly-selected account) is driven with
//  `TestSupport/TestSignals.swift`'s `ResumableGate` -- the same event-driven, no-clock primitive
//  `RootTransactionsCoalescingTests.swift` uses to hold a mocked dependency open on a gate.
//
//  `.serialized`: constructing/driving `Root.State` touches the process-global
//  `@Shared(.inMemory(.selectedWalletAccount))` / `.inMemory(.transactions)` /
//  `.inMemory(.walletAccounts)` keys, same precedent as every other Root-level suite in this
//  directory.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct RootTransactionsAccountProvenanceTests {
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

    private func tx(id: String, status: TransactionState.Status = .received) -> TransactionState {
        TransactionState(fee: Zatoshi(10), id: id, status: status, zecAmount: Zatoshi(100_000))
    }

    private struct FetchStubError: Error { }

    // MARK: - (1) A failed fetch for the NEW account must never leave the OLD account's rows on screen

    /// The exact regression: A has rows, the user switches to B, and B's very first fetch fails.
    /// Before the fix, the failure path's provenance guard alone let this through -- the failure IS
    /// for the currently-selected account -- and re-validated whatever was left in
    /// `state.transactions`, which was still A's rows because nothing had cleared them on the
    /// switch. Both lists then cleared their placeholder over A's stale history.
    @Test func failedFetchForTheNewAccountNeverRevealsThePreviousAccountsRows() async {
        let accountA = Self.walletAccount(idByte: 120)
        let accountB = Self.walletAccount(idByte: 121)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountA }
        initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                if accountUUID == accountB.id {
                    throw FetchStubError()
                }
                return []
            }
        }

        // Seed A's rows via a REAL `.fetchedTransactions` completion, establishing
        // `transactionsAccountId == accountA.id` exactly the way `accountSwitchedEffect`'s own
        // fetch would have.
        let aRows = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "a-tx-1"), tx(id: "a-tx-2")])
        store.send(.fetchedTransactions(accountA.id, aRows))
        #expect(store.state.transactions == aRows, "setup must land A's rows before the switch")

        // The real switch action -- reaches `accountSwitchedEffect`, which must clear the shared
        // array up front, then immediately fires a fresh fetch for B, which the mock above fails.
        // `finish()` awaits that whole chain, including B's own `.transactionsFetchFailed`.
        await store.send(.home(.walletAccountTapped(accountB))).finish()

        #expect(
            store.state.transactions.isEmpty,
            "B's failed fetch must never leave A's rows in the shared array as if they were B's history"
        )
        #expect(store.state.homeState.transactionListState.isInvalidated == false, "Home must still clear its placeholder")
        #expect(
            store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated == false,
            "See All must still clear its placeholder"
        )
        #expect(store.state.selectedWalletAccount == accountB)
    }

    /// The defensive foreign-rows branch above clears `state.transactions`, but
    /// `unminedMigrationPendingValue` (`RootStore.swift`) is derived from those same rows
    /// (`.fetchedTransactions`, above) and read straight into the balance breakdown's "Pending"
    /// row -- so it must be cleared alongside them, not left reading the account just left's
    /// figure until the newly-selected account's own fetch eventually corrects it as a side
    /// effect. Reaches the branch with a hand-built fixture rather than the real switch action --
    /// `accountSwitchedEffect` (`RootCoordinator.swift`) already empties `transactions` on every
    /// switch, so this defensive branch is only reachable at all with a fixture that deliberately
    /// disagrees with that invariant, exactly as the surrounding code comment describes.
    @Test func transactionsFetchFailedClearsUnminedMigrationPendingValueWithForeignRows() async {
        let accountA = Self.walletAccount(idByte: 128)
        let accountB = Self.walletAccount(idByte: 129)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountB }
        initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
        let aRows = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "a-tx-1")])
        initialState.$transactions.withLock { $0 = aRows }
        initialState.transactionsAccountId = accountA.id
        let previousUnminedMigrationPendingValue = initialState.unminedMigrationPendingValue
        initialState.$unminedMigrationPendingValue.withLock { $0 = Zatoshi(12_345) }
        defer { initialState.$unminedMigrationPendingValue.withLock { $0 = previousUnminedMigrationPendingValue } }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
        }

        // `Store.send` (unlike `TestStore.send`) runs the reducer's synchronous body immediately,
        // so both assertions below hold as soon as this call returns, with no need to await
        // whatever effects it also spawns.
        store.send(.transactionsFetchFailed(accountUUID: accountB.id))

        #expect(store.state.transactions.isEmpty, "the foreign rows must still be cleared")
        #expect(
            store.state.unminedMigrationPendingValue == .zero,
            "the pending-migration figure derived from those same foreign rows must not outlive them"
        )
        #expect(
            store.state.transactionsAccountId == nil,
            "transactionsAccountId's own invariant (RootStore.swift) is that it names the account whose rows $transactions holds -- with the array just cleared to empty, it must follow back to nil"
        )
    }

    // MARK: - (2) An empty result for the NEW account while syncing must leave it empty, not resurrect the old rows

    /// The non-failure sibling of the test above: B's fetch does not throw, it legitimately answers
    /// empty while still syncing. The array must stay empty -- both because the switch already
    /// cleared it, and because the empty-fetch keep-guard's own account check
    /// (`state.transactionsAccountId == accountUUID`) would refuse to treat A's old rows as B's
    /// answer even if something else had left them behind.
    @Test func emptyResultForTheNewAccountWhileSyncingLeavesItEmpty() async {
        let accountA = Self.walletAccount(idByte: 122)
        let accountB = Self.walletAccount(idByte: 123)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountA }
        initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false
        initialState.lastKnownSyncStatus = .syncing(0.4, false)

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { _ in [] }
        }

        let aRows = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "a-tx-1")])
        store.send(.fetchedTransactions(accountA.id, aRows))
        #expect(store.state.transactions == aRows, "setup must land A's rows before the switch")

        // B's own post-switch fetch (mocked above) answers empty while still mid-sync.
        await store.send(.home(.walletAccountTapped(accountB))).finish()

        #expect(
            store.state.transactions.isEmpty,
            "a legitimate empty result for the new account must never resurrect the previous account's rows"
        )
        #expect(store.state.selectedWalletAccount == accountB)
    }

    // MARK: - (3) A stale failure for the account just LEFT must change nothing after the switch

    /// Mirrors `RootTransactionsEmptyFetchTests.swift`'s `fetchFailureForANonSelectedAccountChangesNothing`,
    /// but reaches the post-switch shape via the REAL switch action instead of a hand-built fixture.
    /// B's own fetch is deliberately held open on a gate for the whole test -- its eventual
    /// resolution (either way) is not what this test is about, and letting it complete would let
    /// its OWN legitimate `transactionsUpdated` clear the invalidation flags this test checks,
    /// masking whether the STALE failure wrongly did so instead.
    @Test func staleFailureForThePreviousAccountChangesNothingAfterTheSwitch() async {
        let accountA = Self.walletAccount(idByte: 124)
        let accountB = Self.walletAccount(idByte: 125)
        let gate = ResumableGate()

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountA }
        initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
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

        let aRows = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "a-tx-1")])
        store.send(.fetchedTransactions(accountA.id, aRows))
        #expect(store.state.transactions == aRows, "setup must land A's rows before the switch")

        // The switch's own state mutations (clearing the array, invalidating both lists) happen
        // synchronously in the reducer, before the fresh fetch it dispatches for B has any chance
        // to run -- true regardless of the gate above, which only matters once that fetch actually
        // starts.
        store.send(.home(.walletAccountTapped(accountB)))

        #expect(store.state.selectedWalletAccount == accountB)
        #expect(store.state.transactions.isEmpty, "the switch must clear A's rows up front")
        #expect(store.state.homeState.transactionListState.isInvalidated)
        #expect(store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated)

        // A stale failure for A, arriving after the switch -- the provenance guard
        // (`accountUUID == state.selectedWalletAccount?.id`) must drop it before it can touch B's
        // still-loading lists, regardless of what `transactionsAccountId` says.
        store.send(.transactionsFetchFailed(accountUUID: accountA.id))

        #expect(store.state.transactions.isEmpty, "a stale failure for the previous account must not resurrect its rows")
        #expect(
            store.state.homeState.transactionListState.isInvalidated,
            "a stale failure must not clear the CURRENTLY selected account's Home invalidation"
        )
        #expect(
            store.state.transactionsCoordFlowState.transactionsManagerState.isInvalidated,
            "a stale failure must not clear the CURRENTLY selected account's See All invalidation"
        )

        gate.open()
    }

    // MARK: - (4) A same-account failure must still keep its own rows and re-arm the poller

    /// The non-regression guard alongside the three above: a failure for the account that is ALREADY
    /// selected -- no switch involved at all -- must never trip the new defensive foreign-rows
    /// check. `transactionsAccountId` already matches, so the rows are kept exactly as before this
    /// change, and the reconciliation poller still re-arms from them.
    @Test func sameAccountFailureKeepsRowsAndPoller() async {
        let account = Self.walletAccount(idByte: 126)
        let scheduler = DispatchQueue.test
        let fetchCalls = LockIsolated<Int>(0)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

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

        // Seed the account's own rows via a REAL `.fetchedTransactions` completion -- a pending row
        // so the reconciliation poller below has something to arm on -- establishing
        // `transactionsAccountId == account.id` exactly the way production does.
        let ownRows = IdentifiedArrayOf<TransactionState>(uniqueElements: [tx(id: "own-pending-tx", status: .sending)])
        store.send(.fetchedTransactions(account.id, ownRows))
        #expect(store.state.transactions == ownRows, "setup must land the account's own rows")

        // The SAME account's own fetch fails -- `transactionsAccountId` already matches, so the
        // defensive foreign-rows check must not fire.
        store.send(.transactionsFetchFailed(accountUUID: account.id))

        #expect(store.state.transactions == ownRows, "a same-account failure must never clear its own kept rows")

        while fetchCalls.value < 1 {
            await scheduler.advance(by: .seconds(1))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fetchCalls.value >= 1, "the reconciliation poller was not armed from the kept rows after a same-account failure")
    }
}

/// Shared no-op dependency baseline for every test in this file. Copied from
/// `RootTransactionsAccountSwitchTests.swift` rather than the Empty/PendingRefresh files' baseline:
/// every test here drives the REAL `.home(.walletAccountTapped)` action at least once (to reach
/// `accountSwitchedEffect`), which also merges in `.loadContacts`/`.resolveMetadataEncryptionKeys`/
/// `.loadUserMetadata` -- that baseline is already proven to carry those to completion. Kept as its
/// own private, file-scoped copy per this directory's established convention of not sharing test
/// helpers across files.
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
