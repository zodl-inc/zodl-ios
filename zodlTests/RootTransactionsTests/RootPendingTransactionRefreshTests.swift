//
//  RootPendingTransactionRefreshTests.swift
//  zodlTests
//
//  A sent transaction could stay rendered as "Sending…" forever even though it had long been
//  mined. The transaction list's pending state resolves ONLY by re-reading the SDK database
//  (`minedHeight` flipping non-nil), and every one of its refresh triggers could be lost:
//
//  1. `.observeTransactions` (`RootTransactions.swift`) throttled the RAW synchronizer event
//     stream (`latest: true`) and only then filtered for `foundTransactions`/`minedTransaction`
//     -- an unrelated `.connectionStateChanged`/`.storedUTXOs` landing in the same 200 ms window
//     replaced the transaction event as "latest" and the refresh silently never fired.
//  2. `didEnterBackground` (`RootInitialization.swift`) cancelled the transaction subscriptions,
//     but the foreground `.retryStart` path only re-registered the synchronizer STATE stream --
//     `.observeTransactions` was dispatched exactly once per process, at app start, so after one
//     background/foreground cycle the list refreshed only by chance one-shot fetches.
//  3. Nothing pull-based backstopped a lost push: once an event was dropped, nothing ever re-read
//     the database again. A 30-second reconciliation poller now runs while any transaction is
//     pending and stops when none is.
//
//  Mirrors `RootTransactionsAccountSwitchTests.swift`'s established pattern: a plain `Store`
//  (not `TestStore`) driven with `LockIsolated` spies and polling, with file-scoped private
//  helpers. Time-dependent behavior (throttle windows, the 30 s poller) runs on a
//  `DispatchQueue.test` scheduler injected as `mainQueue`, advanced in small steps interleaved
//  with real-time yields so effect Tasks get to register their sleeps/timers on the scheduler
//  before it advances past them.
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

@Suite(.serialized) @MainActor struct RootPendingTransactionRefreshTests {
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

    // MARK: - (1) Filter-before-throttle: a sandwiched transaction event must still trigger a fetch

    /// The exact loss mode: `.foundTransactions` arrives BETWEEN two unrelated events inside one
    /// throttle window. Under the old stream shape (throttle the raw stream, filter after), the
    /// window's "latest" element is the trailing `.connectionStateChanged`, the `compactMap` maps
    /// it to nil, and no fetch ever fires -- re-sending the same sandwich in later windows never
    /// helps, because a window that OPENS with an unrelated event also ENDS with one. Under the
    /// fix (filter first) the transaction event is the only element the throttle ever sees.
    ///
    /// The push+advance loop retries the sandwich, which keeps the test robust against the
    /// subscription racing the first push while preserving the discriminating property above:
    /// under the old shape NO amount of retries can produce a fetch, so the loop distinguishes
    /// "never" from "eventually" rather than "fast" from "slow".
    @Test func foundTransactionsSurvivesUnrelatedEventsInTheSameThrottleWindow() async {
        let account = Self.walletAccount(idByte: 80)
        let scheduler = DispatchQueue.test
        let events = PassthroughSubject<SynchronizerEvent, Never>()
        let fetchCalls = LockIsolated<Int>(0)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = [] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.mainQueue = scheduler.eraseToAnyScheduler()
            // `eventStream` is a `let` on the client, so the whole client is replaced via
            // `.mocked(...)`; `getAllTransactions` is a `var` and can be re-mocked in place.
            $0.sdkSynchronizer = .mocked(eventStream: { events.eraseToAnyPublisher() })
            $0.sdkSynchronizer.getAllTransactions = { _ in
                fetchCalls.withValue { $0 += 1 }
                return []
            }
        }

        store.send(.observeTransactions)
        // The trailing one-shot fetch inside `.observeTransactions` is not scheduler-gated, so it
        // doubles as the signal that the action's merged effects have started.
        await waitForRootStore { fetchCalls.value >= 1 }

        for _ in 0..<50 where fetchCalls.value < 2 {
            events.send(.connectionStateChanged(.online))
            events.send(.foundTransactions([], nil))
            events.send(.connectionStateChanged(.online))
            await scheduler.advance(by: .seconds(0.5))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(fetchCalls.value >= 2, "a foundTransactions event sandwiched between unrelated events never triggered a fetch")
    }

    // MARK: - (2) Background/foreground: `.retryStart` must re-establish the transaction observation

    /// Backgrounding tears the transaction subscriptions down (that part always worked); the bug
    /// was that no foreground path ever rebuilt them. Proven end-to-end: a transaction event
    /// triggers a fetch before backgrounding, triggers NOTHING while backgrounded, and triggers a
    /// fetch again after `.retryStart` -- which also re-dispatches `.observeTransactions`' trailing
    /// one-shot fetch, itself the catch-up for anything mined while backgrounded.
    @Test func retryStartAfterBackgroundingReestablishesTransactionObservation() async {
        let account = Self.walletAccount(idByte: 81)
        let scheduler = DispatchQueue.test
        let events = PassthroughSubject<SynchronizerEvent, Never>()
        let fetchCalls = LockIsolated<Int>(0)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = [] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.mainQueue = scheduler.eraseToAnyScheduler()
            // `.retryStart` proceeds only for a prepared synchronizer and enough disk space.
            $0.diskSpaceChecker = .mockEmptyDisk
            // `eventStream`/`latestState` are `let`s on the client, so the whole client is
            // replaced via `.mocked(...)`; `getAllTransactions` is a `var`.
            $0.sdkSynchronizer = .mocked(
                eventStream: { events.eraseToAnyPublisher() },
                latestState: {
                    var latestState = SynchronizerState.zero
                    latestState.syncStatus = .upToDate
                    return latestState
                }
            )
            $0.sdkSynchronizer.getAllTransactions = { _ in
                fetchCalls.withValue { $0 += 1 }
                return []
            }
        }

        store.send(.observeTransactions)
        await waitForRootStore { fetchCalls.value >= 1 }

        // Live subscription: an event-driven fetch lands.
        for _ in 0..<50 where fetchCalls.value < 2 {
            events.send(.foundTransactions([], nil))
            await scheduler.advance(by: .seconds(0.5))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await waitForRootStore { fetchCalls.value >= 2 }

        store.send(.initialization(.appDelegate(.didEnterBackground)))
        // Give the cancellations a moment to land before probing the dead window.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let fetchesBeforeBackgroundProbe = fetchCalls.value

        // Backgrounded: events must NOT trigger fetches. Bounded probe -- five windows is enough
        // to catch an un-cancelled subscription without turning load into a false failure.
        for _ in 0..<5 {
            events.send(.foundTransactions([], nil))
            await scheduler.advance(by: .seconds(0.5))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(fetchCalls.value == fetchesBeforeBackgroundProbe, "the event subscription survived backgrounding")

        // Foreground restart: `.retryStart` re-dispatches `.observeTransactions`, whose trailing
        // one-shot fetch is the first observable proof of the re-established observation.
        let fetchesBeforeRetryStart = fetchCalls.value
        store.send(.initialization(.retryStart))
        await waitForRootStore { fetchCalls.value >= fetchesBeforeRetryStart + 1 }

        // And the event stream is live again.
        let fetchesBeforeEventProbe = fetchCalls.value
        for _ in 0..<50 where fetchCalls.value < fetchesBeforeEventProbe + 1 {
            events.send(.foundTransactions([], nil))
            await scheduler.advance(by: .seconds(0.5))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(fetchCalls.value >= fetchesBeforeEventProbe + 1, "no event-driven fetch after foreground retryStart")
    }

    // MARK: - (3) Reconciliation poller: refetch while pending, stop when resolved

    /// A swap parked in `.pending` must NOT keep the poller alive. `TransactionState.isPending`
    /// reports the SWAP status for every non-`.zcash` type, and that status is owned by the swap
    /// provider's metadata (refreshed by `.autoUpdateCandidatesSwapDetails` in `RootSwaps`), not by
    /// the SDK database this poller re-reads. An abandoned or stalled swap never has to resolve, so
    /// arming the poller on one would poll every 30 seconds for the rest of the session against
    /// state it cannot possibly settle.
    @Test func swapPendingAloneDoesNotArmThePoller() async {
        let account = Self.walletAccount(idByte: 83)
        let scheduler = DispatchQueue.test
        let fetchCalls = LockIsolated<Int>(0)

        // A swap-to-ZEC row: type != .zcash, and `isPending` true purely from its swap status.
        let pendingSwap = TransactionState(
            depositAddress: "deposit-address",
            timestamp: 1,
            zecAmount: "1",
            swapStatus: .pending
        )
        #expect(pendingSwap.isPending, "fixture must be pending, else the test proves nothing")
        #expect(pendingSwap.type != .zcash)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = [] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.mainQueue = scheduler.eraseToAnyScheduler()
            $0.sdkSynchronizer.getAllTransactions = { _ in
                fetchCalls.withValue { $0 += 1 }
                return IdentifiedArrayOf(uniqueElements: [pendingSwap])
            }
        }

        store.send(.fetchedTransactions(account.id, [pendingSwap]))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Far past several poll intervals: a poller armed on the swap would have ticked by now.
        for _ in 0..<5 {
            await scheduler.advance(by: .seconds(30))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(fetchCalls.value == 0, "a swap-only pending list must not arm the local-database poller")
    }

    /// Cancelling the poller must stop it dead: no fetch may be dispatched from a sleep that was
    /// already in flight when the cancellation landed. Reviewed concern -- if the scheduler's
    /// `sleep` did not observe cancellation, a tick could still fire up to one full interval after
    /// the poller was torn down (here, after backgrounding).
    @Test func cancellingThePollerPreventsAnyLaterTick() async {
        let account = Self.walletAccount(idByte: 84)
        let scheduler = DispatchQueue.test
        let fetchCalls = LockIsolated<Int>(0)
        let pendingTransaction = tx(id: "pending-tx", status: .sending)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = [] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.mainQueue = scheduler.eraseToAnyScheduler()
            $0.sdkSynchronizer.getAllTransactions = { _ in
                fetchCalls.withValue { $0 += 1 }
                return IdentifiedArrayOf(uniqueElements: [pendingTransaction])
            }
        }

        // Arm the poller and let it tick once, so the effect is provably running.
        store.send(.fetchedTransactions(account.id, [pendingTransaction]))
        for _ in 0..<40 where fetchCalls.value < 1 {
            await scheduler.advance(by: .seconds(1))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fetchCalls.value >= 1, "poller never armed, so cancellation proves nothing")

        // Cancel mid-interval: advance part of the way, then tear the poller down.
        await scheduler.advance(by: .seconds(10))
        store.send(.initialization(.appDelegate(.didEnterBackground)))
        try? await Task.sleep(nanoseconds: 200_000_000)
        let fetchesAtCancellation = fetchCalls.value

        // Push well past the interval the in-flight sleep would have completed in.
        for _ in 0..<5 {
            await scheduler.advance(by: .seconds(30))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(
            fetchCalls.value == fetchesAtCancellation,
            "a sleep in flight at cancellation still dispatched a fetch afterwards"
        )
    }

    /// While any transaction is pending, a lost push signal must not be able to strand the list --
    /// the poller re-reads the database every 30 seconds. Once nothing is pending it must stop:
    /// polling is a pending-state backstop, not a steady-state loop.
    @Test func pollerRefetchesWhilePendingAndStopsWhenResolved() async {
        let account = Self.walletAccount(idByte: 82)
        let scheduler = DispatchQueue.test
        let fetchCalls = LockIsolated<Int>(0)
        let pendingTransaction = tx(id: "pending-tx", status: .sending)

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.$transactions.withLock { $0 = [] }
        initialState.homeState.transactionListState.isInvalidated = false
        initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.mainQueue = scheduler.eraseToAnyScheduler()
            $0.sdkSynchronizer.getAllTransactions = { _ in
                fetchCalls.withValue { $0 += 1 }
                return IdentifiedArrayOf(uniqueElements: [pendingTransaction])
            }
        }

        // A completed fetch whose payload contains a pending transaction arms the poller.
        store.send(.fetchedTransactions(account.id, [pendingTransaction]))

        // First tick. Advancing in 1 s steps with real-time yields lets the poller's sleep
        // register on the test scheduler before the clock passes its deadline.
        for _ in 0..<40 where fetchCalls.value < 1 {
            await scheduler.advance(by: .seconds(1))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fetchCalls.value >= 1, "the poller never ticked while a transaction was pending")

        // The tick's own fetch returned the same still-pending payload (an UNCHANGED list -- the
        // state-equality short-circuit must not skip poller management), so the poller stays armed.
        for _ in 0..<40 where fetchCalls.value < 2 {
            await scheduler.advance(by: .seconds(1))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fetchCalls.value >= 2, "the poller did not survive an unchanged still-pending fetch result")

        // Resolution: a payload with nothing pending cancels the poller.
        store.send(.fetchedTransactions(account.id, [tx(id: "pending-tx", status: .paid)]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let fetchesAfterResolution = fetchCalls.value

        for _ in 0..<5 {
            await scheduler.advance(by: .seconds(60))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(fetchCalls.value == fetchesAfterResolution, "the poller kept ticking after the last pending transaction resolved")
    }
}

/// Shared no-op dependency baseline for every test in this file. Kept as a private, file-scoped
/// helper rather than something shared globally, the same way the other suites in this directory
/// keep theirs. `mainQueue` is deliberately NOT set here -- every test injects its own
/// `DispatchQueue.test` scheduler to control throttle windows and the 30 s poller.
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

@MainActor
private func waitForRootStore(
    timeoutNanoseconds: UInt64 = 15_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for Root pending-transaction-refresh store state", sourceLocation: sourceLocation)
}
