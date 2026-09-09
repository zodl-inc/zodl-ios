//
//  RootTransactionsCoalescingTests.swift
//  zodlTests
//
//  MOB-1856: `.fetchTransactionsForTheSelectedAccount` (`RootTransactions.swift`) is dispatched on
//  every throttled synchronizer event during a sync -- `.observeTransactions` throttles to one
//  event per 0.2s, and every `foundTransactions`/`minedTransaction` re-dispatches this action. On a
//  wallet with a long transaction history, `getAllTransactions` reads the WHOLE history and can
//  easily take longer than that 0.2s window, so every throttled tick started its own concurrent
//  full-history fetch -- they piled up for the whole catch-up sync, each one competing for the same
//  SQLite connection and CPU the sync itself needed.
//
//  The fix is a single-flight coalescing gate: `Root.State.isTransactionsFetchInFlight` lets at
//  most one `getAllTransactions` fetch run at a time; a dispatch that arrives while one is already
//  running just marks `isTransactionsFetchDirty` and returns, and the in-flight fetch's own
//  completion (`.fetchedTransactions` or `.transactionsFetchFailed`) folds every dispatch coalesced
//  during its run into exactly one follow-up fetch, for whichever account is selected at that
//  point.
//
//  A pre-dispatch amendment closes a corollary gap: `accountSwitchedEffect`
//  (`RootCoordinator.swift`) is the only site that `.cancel`s the fetch effect -- TCA drops actions
//  sent from a cancelled effect, so neither completion action ever arrives for a fetch cancelled by
//  a switch. Without its own reset, `isTransactionsFetchInFlight` would stick `true` forever and the
//  fresh fetch `accountSwitchedEffect` sends right after would be coalesced as dirty instead of
//  actually starting -- parking the newly-selected account's fetch forever.
//
//  Mirrors `RootPendingTransactionRefreshTests.swift`/`RootTransactionsEmptyFetchTests.swift`'s
//  established pattern for this directory: a plain `Store` (not `TestStore`) driven with a
//  file-scoped `baseNoOpDependencies` (copied from `RootTransactionsAccountSwitchTests.swift`,
//  since the account-switch test here needs the SAME dependency shape `.home(.walletAccountTapped)`
//  already exercises there). The suspension/counting mechanics instead borrow
//  `TestSupport/TestSignals.swift`'s `ResumableGate`/`SignalledRecords` -- the same event-driven,
//  no-clock primitives `RootRetryStartReentrancyTests.swift` uses to hold a mocked dependency open
//  on a gate and count calls, rather than re-deriving that machinery with ad hoc `LockIsolated`
//  counters and `AsyncStream`s.
//
//  Once a gate opens and a coalesced chain is released, completion is awaited with the relevant
//  dispatch's own `StoreTask.finish()` -- exactly `RootTransactionsAccountSwitchTests.swift`'s
//  documented mechanism (its header explains why: `finish()` awaits the whole effect tree,
//  including every nested action the effect itself sends, so it is deterministic all the way down
//  a coalescing chain, not just for the one dispatch it was called on). The few `Task.sleep`s left
//  in this file each guard a NEGATIVE only -- "no extra call landed" -- where there is deliberately
//  nothing positive left to wait for; none of them gate a positive assertion.
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

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct RootTransactionsCoalescingTests {
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

    /// A distinguishable, non-empty fetch result -- see `coalescesConcurrentDispatchesIntoExactlyOneInFlightFetchAndOneFollowUp`,
    /// which uses it to prove the in-flight fetch's own payload actually reaches `state.transactions`,
    /// not just that call counts add up. Mirrors `RootTransactionsAccountSwitchTests.swift`'s `tx(id:)`.
    private static func tx(id: String) -> TransactionState {
        TransactionState(fee: Zatoshi(10), id: id, status: .received, zecAmount: Zatoshi(100_000))
    }

    private struct FetchStubError: Error { }

    // MARK: - (1) Three dispatches before the first fetch completes coalesce into one call, then one follow-up

    /// The core coalescing behavior: three `.fetchTransactionsForTheSelectedAccount` dispatches
    /// land back-to-back, none awaited, before the first fetch has any chance to complete. The
    /// in-flight/dirty guard is plain state set synchronously inside the reducer -- before the
    /// `.run` effect's own Task is even scheduled -- so by the time dispatch #2 and #3 run their
    /// reducers, dispatch #1 has already flipped `isTransactionsFetchInFlight`; this is
    /// deterministic on any machine, not a timing-dependent race. Only the first dispatch may ever
    /// call `getAllTransactions`; releasing it must fold the two coalesced dispatches into exactly
    /// one follow-up fetch, and that follow-up's own completion must not chase a third.
    @Test func coalescesConcurrentDispatchesIntoExactlyOneInFlightFetchAndOneFollowUp() async {
        let account = Self.walletAccount(idByte: 90)
        let fetchCalls = SignalledRecords<Void>()
        let gate = ResumableGate()
        // A distinguishable, non-empty result every stub in this call returns -- proves the
        // in-flight fetch's own payload actually reaches `state.transactions`, not just that call
        // counts add up. Both the in-flight fetch and its coalesced follow-up return the identical
        // payload, so the final assertion holds regardless of which of the two writes it.
        let inFlightTransactions = IdentifiedArrayOf<TransactionState>(uniqueElements: [Self.tx(id: "in-flight-tx")])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = [] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getAllTransactions: { _ in
                    let ordinal = fetchCalls.recordCall()
                    if ordinal == 1 {
                        await gate.wait()
                    }
                    return inFlightTransactions
                }
            )
        }

        let firstDispatch = store.send(.fetchTransactionsForTheSelectedAccount)
        store.send(.fetchTransactionsForTheSelectedAccount)
        store.send(.fetchTransactionsForTheSelectedAccount)

        // Synchronous: true before any effect Task has had a chance to run at all.
        #expect(store.state.isTransactionsFetchInFlight, "the first dispatch must mark the gate in flight")
        #expect(store.state.isTransactionsFetchDirty, "the two coalesced dispatches must mark the gate dirty")

        await fetchCalls.countReached(1)
        // A moment for a wrongly-started duplicate to land -- if the guard were missing, a second
        // (or third) call would already be sitting here, well before the gate is ever released.
        // Negative-only: the one in-flight call is deliberately still parked on the gate, so there
        // is no positive completion to wait on yet, only the absence of an extra call to prove.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fetchCalls.count == 1, "a dispatch coalesced while a fetch is in flight must never start its own getAllTransactions call")

        // Release the in-flight fetch. `finish()` on the FIRST dispatch's own `StoreTask` awaits
        // its whole effect tree, including every nested action it sends -- its own
        // `.fetchedTransactions`, the coalesced follow-up fetch that spawns from it, and THAT
        // fetch's own `.fetchedTransactions` in turn -- so by the time this returns, the follow-up
        // has both started and fully completed. No wall clock stands between "released" and
        // "settled" (see `RootTransactionsAccountSwitchTests.swift`'s header for why this is safe).
        gate.open()
        await firstDispatch.finish()
        #expect(
            fetchCalls.count == 2,
            "the coalesced dispatches must fold into exactly one follow-up fetch, and that follow-up's own completion must not chase a third"
        )
        #expect(!store.state.isTransactionsFetchInFlight, "the follow-up fetch's completion must clear the in-flight gate")
        #expect(!store.state.isTransactionsFetchDirty)
        #expect(
            store.state.transactions == inFlightTransactions,
            "the in-flight fetch's own payload must reach state.transactions once the coalescing gate settles"
        )
    }

    // MARK: - (2) The same coalescing behavior off the failure path

    /// Identical shape to the success-path test above, but the in-flight fetch THROWS, driving
    /// `.transactionsFetchFailed` instead of `.fetchedTransactions`. The coalescing gate must reset
    /// and chase exactly one follow-up fetch off the failure path too -- a wallet whose fetch keeps
    /// failing must never let dispatches from a busy sync pile up behind it.
    @Test func coalescesConcurrentDispatchesIntoExactlyOneFollowUpAfterAFailingFetch() async {
        let account = Self.walletAccount(idByte: 91)
        let fetchCalls = SignalledRecords<Void>()
        let gate = ResumableGate()

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = [] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getAllTransactions: { _ in
                    let ordinal = fetchCalls.recordCall()
                    if ordinal == 1 {
                        await gate.wait()
                    }
                    throw FetchStubError()
                }
            )
        }

        let firstDispatch = store.send(.fetchTransactionsForTheSelectedAccount)
        store.send(.fetchTransactionsForTheSelectedAccount)
        store.send(.fetchTransactionsForTheSelectedAccount)

        #expect(store.state.isTransactionsFetchInFlight)
        #expect(store.state.isTransactionsFetchDirty, "the two coalesced dispatches must mark the gate dirty even on the failure path")

        await fetchCalls.countReached(1)
        // Negative-only, same as the success-path test: nothing positive to wait on while the one
        // in-flight call is still parked on the gate.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fetchCalls.count == 1, "a dispatch coalesced while a failing fetch is in flight must never start its own call")

        // `finish()` on the first dispatch's own `StoreTask` awaits the whole nested chain -- its
        // own `.transactionsFetchFailed`, the coalesced follow-up fetch it spawns, and that
        // follow-up's own completion -- deterministically, with no wall clock between "released"
        // and "settled".
        gate.open()
        await firstDispatch.finish()
        #expect(
            fetchCalls.count == 2,
            "a failed fetch must still fold its coalesced dispatches into one follow-up fetch, with no third call chased afterward"
        )
        #expect(!store.state.isTransactionsFetchInFlight, "a failed follow-up fetch must still clear the in-flight gate")
        #expect(!store.state.isTransactionsFetchDirty)
    }

    // MARK: - (2b) An account switch while a fetch is in flight starts the new account's fetch immediately

    /// The pre-dispatch amendment's own regression guard. A fetch for account A is parked in
    /// flight (its gate is never released in this test -- that A's completion never has to land is
    /// exactly the point); the user then switches to account B. `accountSwitchedEffect` cancels A's
    /// fetch and, immediately after, sends a fresh fetch for B -- which must actually start (a
    /// second, distinct `getAllTransactions` call for B) rather than being coalesced as "dirty"
    /// behind a gate only A's own cancelled-and-dropped completion could ever have cleared.
    /// Finally, releasing A's stale fetch must change nothing and must not produce a third call.
    @Test func accountSwitchWhileAFetchIsInFlightStartsTheNewAccountsFetchWithoutWaitingForTheStaleOne() async {
        let accountA = Self.walletAccount(idByte: 92)
        let accountB = Self.walletAccount(idByte: 93)
        let fetchCalls = SignalledRecords<AccountUUID>()
        let gate = ResumableGate()

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = accountA }
        initialState.$walletAccounts.withLock { $0 = [accountA, accountB] }
        initialState.$transactions.withLock { $0 = [] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getAllTransactions: { accountUUID in
                    guard let accountUUID else { return [] }
                    let ordinal = fetchCalls.record(accountUUID)
                    if ordinal == 1 {
                        // Never released in this test -- proving the switch's fresh fetch needs no
                        // release of this one is exactly what this test guards.
                        await gate.wait()
                    }
                    return []
                }
            )
        }

        store.send(.fetchTransactionsForTheSelectedAccount)
        await fetchCalls.recorded(where: { $0 == [accountA.id] })
        #expect(store.state.isTransactionsFetchInFlight)

        // The switch: cancels A's in-flight fetch and, after resetting the coalescing gate,
        // immediately sends a fresh fetch for B -- all while A's gate stays closed. `finish()` on
        // this dispatch's own `StoreTask` awaits its whole effect tree, including B's fetch
        // actually running to completion and its `.fetchedTransactions` landing -- deterministic,
        // and it cannot hang on A's still-gated mock: `.cancel(id:)` only flips A's Task's
        // cancelled flag and returns, it never waits for that Task to actually unwind (see
        // `RootTransactionsAccountSwitchTests.swift`'s header for the general mechanism).
        let switchTask = store.send(.home(.walletAccountTapped(accountB)))
        await switchTask.finish()

        #expect(
            fetchCalls.values == [accountA.id, accountB.id],
            "the switch must start B's fetch as an immediate second call, not park it behind A's still-open gate"
        )
        #expect(store.state.selectedWalletAccount == accountB)
        #expect(!store.state.isTransactionsFetchInFlight, "B's own fetch must have completed and cleared the in-flight gate")
        #expect(!store.state.isTransactionsFetchDirty)

        // Release A's stale fetch. `Send.callAsFunction` checks `Task.isCancelled` and silently
        // drops an action sent from a cancelled effect, so A's `.fetchedTransactions` never even
        // reaches the reducer -- there is no positive completion signal left to wait on, only the
        // absence of a third call to prove. A short, clearly-labelled sleep is the right tool for
        // that negative check alone.
        gate.open()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(fetchCalls.count == 2, "the stale, cancelled fetch for A must never produce a third getAllTransactions call")
    }
}

/// Shared no-op dependency baseline for every test in this file. Kept as a private, file-scoped
/// helper rather than something shared globally, the same way the other suites in this directory
/// keep theirs. Copied from `RootTransactionsAccountSwitchTests.swift` rather than the
/// Empty/PendingRefresh files' baseline: this file's account-switch test drives
/// `.home(.walletAccountTapped)`, exactly the action that baseline is already proven to support
/// (`loadContacts`/`resolveMetadataEncryptionKeys`/`loadUserMetadata` all need real no-op
/// dependencies, not just `sdkSynchronizer`'s). `mainQueue = .immediate`: none of the tests here
/// exercise throttle windows or the reconciliation poller, so there is no need for a controllable
/// test scheduler.
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
