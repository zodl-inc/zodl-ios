//
//  RootTransactionsFailedFetchRetryTests.swift
//  zodlTests
//
//  MOB-1954 review follow-up: the edge-triggered Activity refresh (`RootTransactions.swift`) took
//  away the silent retry every 2 s up-to-date tick used to give a FAILED `getAllTransactions`
//  read. After the edge trigger, `.transactionsFetchFailed` could only run an already-coalesced
//  follow-up or re-arm the pending-row reconciler -- which cancels itself when nothing is pending
//  -- so a read that threw right after an account switch left the new account empty, and one that
//  threw after a `foundTransactions` event on a fully mined history left the new transaction
//  absent, until some unrelated trigger. A failed read now schedules its own bounded retry with a
//  growing delay (`Root.State.transactionsFetchRetryDelaysInSeconds`), provenance-checked and
//  cancelled on an account switch, at backgrounding and whenever another fetch starts.
//
//  Mirrors `RootTransactionsUpToDateEdgeTests.swift`: a plain `Store`, a file-scoped
//  `baseNoOpDependencies`, `DispatchQueue.test` as `mainQueue` so both the 0.2 s throttle and the
//  retry delays are advanced by hand, scripted `getAllTransactions` outcomes per account, and
//  event-driven positive waits (a fetch count reached with the coalescing gate closed; a retry's
//  sleep parked on the scheduler, see `retryArmed(count:)`). The short sleeps guard NEGATIVES
//  only. Every account switch goes through `.home(.walletAccountTapped)`, the same path
//  `RootTransactionsAccountSwitchTests.swift` drives.
//
//  `.serialized`: constructing/driving `Root.State` touches the process-global
//  `@Shared(.inMemory(...))` keys, same precedent as the other Root-level suites here.
//

@preconcurrency import Combine
import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct RootTransactionsFailedFetchRetryTests {
    private struct FetchStubError: Error { }
    /// One scripted answer of the mocked `getAllTransactions`.
    private typealias Outcome = Result<IdentifiedArrayOf<TransactionState>, FetchStubError>

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

    /// A mined, non-pending row (`minedHeight` set), so the pending-row reconciler has nothing to poll for.
    private static func minedTx(id: String) -> TransactionState {
        var transaction = TransactionState(fee: Zatoshi(10), id: id, status: .received, zecAmount: Zatoshi(100_000))
        transaction.minedHeight = BlockHeight(4_100_000)
        return transaction
    }

    private static func state(_ status: SyncStatus) -> SynchronizerState {
        var state = SynchronizerState.zero
        state.latestBlockHeight = 4_200_000
        state.syncStatus = status
        return state
    }

    /// One store over a hand-driven state stream, with per-account scripted fetch outcomes.
    @MainActor private final class Harness {
        let scheduler = DispatchQueue.test
        let states = PassthroughSubject<SynchronizerState, Never>()
        let events = PassthroughSubject<SynchronizerEvent, Never>()
        /// Consumed front to back by each fetch for that account; once empty, `fallback` answers.
        let scripts = LockIsolated<[AccountUUID: [Outcome]]>([:])
        let fallback = LockIsolated<[AccountUUID: IdentifiedArrayOf<TransactionState>]>([:])
        let fetches = LockIsolated<[AccountUUID]>([])
        /// Delayed-retry sleeps parked on `scheduler` so far. `.transactionsFetchFailed` returns its
        /// retry as a `.run` effect whose first act is `mainQueue.sleep(for: <retry delay>)`; that
        /// sleep reaches the scheduler only once the effect is actually running -- which is also the
        /// earliest moment TCA's `.cancel(id:)` can reach it. Counted by the `mainQueue` tap in
        /// `init`, waited on by `retryArmed(count:)`.
        let retrySleepsScheduled = LockIsolated(0)
        let store: StoreOf<Root>

        init(selected: WalletAccount, accounts: [WalletAccount]) {
            var initialState = Root.State.initial
            initialState.$selectedWalletAccount.withLock { $0 = selected }
            initialState.$walletAccounts.withLock { $0 = accounts }
            initialState.$transactions.withLock { $0 = [] }
            initialState.homeState.transactionListState.isInvalidated = false
            initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

            let scheduler = self.scheduler
            let states = self.states
            let events = self.events
            let scripts = self.scripts
            let fallback = self.fallback
            let fetches = self.fetches
            let retrySleepsScheduled = self.retrySleepsScheduled
            let retryDelaysInSeconds = Root.State.transactionsFetchRetryDelaysInSeconds
            store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                // `scheduler.eraseToAnyScheduler()`, plus a tap on the one entry point
                // `Scheduler.sleep(for:)` goes through (`schedule(after:interval:)`, via
                // `timer(interval:)`): an interval equal to a retry delay is the delayed retry
                // parking its sleep. Nothing else driven here sleeps for 2, 4, 8, 16 or 32 s -- the
                // throttles are 0.2 s, the smart banner's account-switch dwell 1 s and its seat
                // delay 1-1.5 s, the pending-row poller 30 s.
                $0.mainQueue = AnyScheduler(
                    minimumTolerance: { @Sendable in scheduler.minimumTolerance },
                    now: { @Sendable in scheduler.now },
                    scheduleImmediately: { @Sendable options, action in
                        scheduler.schedule(options: options, action)
                    },
                    delayed: { @Sendable date, tolerance, options, action in
                        scheduler.schedule(after: date, tolerance: tolerance, options: options, action)
                    },
                    interval: { @Sendable date, interval, tolerance, options, action in
                        if retryDelaysInSeconds.contains(where: { interval == .seconds($0) }) {
                            retrySleepsScheduled.withValue { $0 += 1 }
                        }
                        return scheduler.schedule(
                            after: date, interval: interval, tolerance: tolerance, options: options, action
                        )
                    }
                )
                $0.sdkSynchronizer = .mocked(
                    stateStream: { states.eraseToAnyPublisher() },
                    eventStream: { events.eraseToAnyPublisher() }
                )
                $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                    guard let accountUUID else { return [] }
                    fetches.withValue { $0.append(accountUUID) }
                    let scripted: Outcome? = scripts.withValue { all in
                        guard var queue = all[accountUUID], !queue.isEmpty else { return nil }
                        let next = queue.removeFirst()
                        all[accountUUID] = queue
                        return next
                    }
                    if let scripted {
                        return try scripted.get()
                    }
                    return fallback.withValue { $0[accountUUID] ?? [] }
                }
            }
        }

        func script(_ account: WalletAccount, _ outcomes: [Outcome]) {
            scripts.withValue { $0[account.id] = outcomes }
        }

        func answer(_ account: WalletAccount, with rows: IdentifiedArrayOf<TransactionState>) {
            fallback.withValue { $0[account.id] = rows }
        }

        func fetchCount(for account: WalletAccount) -> Int {
            fetches.value.filter { $0 == account.id }.count
        }

        var fetchCount: Int { fetches.value.count }

        /// Starts observing, waits for the trailing one-shot fetch to settle, then pushes
        /// `.upToDate` until the first edge fetch has landed and settled (the subscription races
        /// the first push; re-pushing a duplicate is harmless). Leaves the store settled at
        /// `.upToDate` with no in-flight or dirty fetch.
        func startObservingAndSettleAtUpToDate() async {
            store.send(.observeTransactions)
            await settled(expectingFetches: 1)
            while fetchCount < 2 {
                await push(.upToDate)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            await settled(expectingFetches: 2)
        }

        func push(_ status: SyncStatus) async {
            states.send(RootTransactionsFailedFetchRetryTests.state(status))
            await scheduler.advance(by: .seconds(0.3))
            await Task.yield()
        }

        /// Event-driven positive wait: `count` fetches have been requested and the coalescing gate
        /// is closed again.
        func settled(expectingFetches count: Int) async {
            while fetchCount < count || store.state.isTransactionsFetchInFlight {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        /// Event-driven positive wait: the `count`-th delayed retry is in flight, i.e. its sleep is
        /// parked on the scheduler. `settled(expectingFetches:)` only says the reducer has SCHEDULED
        /// a retry -- `transactionsFetchRetryAttempt` is bumped in the very reduce that returns the
        /// effect -- but the effect starts on a later main-actor turn, and TCA's `.cancel(id:)`
        /// reaches only an effect that has started. A test that cancels a pending retry must wait
        /// for this first: sent in the same turn that observed `settled`, the cancel finds nothing
        /// and the retry fires anyway. On CI's shared main actor that turn order was the rule, not
        /// the exception (`backgroundingWhileARetryIsPendingDropsThatRetry` failed on every run);
        /// on an idle machine the effect's task wins the turn, which is why it passed locally.
        func retryArmed(count: Int) async {
            while retrySleepsScheduled.value < count {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        /// Negative-only wait.
        func giveAWrongFetchTimeToLand() async {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        func switchTo(_ account: WalletAccount) {
            store.send(.home(.walletAccountTapped(account)))
        }
    }

    // MARK: - (1) A failed read after an account switch is retried, then no refetch on identical states

    @Test func aFailedReadAfterAnAccountSwitchIsRetriedAndThenSettles() async {
        let accountA = Self.walletAccount(idByte: 70)
        let accountB = Self.walletAccount(idByte: 71)
        let rowsB = IdentifiedArrayOf<TransactionState>(uniqueElements: [Self.minedTx(id: "b-1")])
        let harness = Harness(selected: accountA, accounts: [accountA, accountB])
        harness.answer(accountA, with: IdentifiedArrayOf<TransactionState>(uniqueElements: [Self.minedTx(id: "a-1")]))
        await harness.startObservingAndSettleAtUpToDate()
        let settledCount = harness.fetchCount

        harness.script(accountB, [Outcome.failure(FetchStubError()), Outcome.success(rowsB)])
        harness.switchTo(accountB)
        await harness.settled(expectingFetches: settledCount + 1)
        #expect(harness.store.state.transactions.isEmpty, "the failed read leaves the switched-to account empty")

        // The first retry delay elapses; the retry must be the ONLY new read and must succeed.
        await harness.scheduler.advance(by: .seconds(Root.State.transactionsFetchRetryDelaysInSeconds[0]))
        await harness.settled(expectingFetches: settledCount + 2)
        #expect(harness.store.state.transactions == rowsB, "the retried read must deliver the account's rows")
        #expect(harness.store.state.transactionsAccountId == accountB.id, "provenance names the account whose retry landed")
        #expect(harness.store.state.transactionsFetchRetryAttempt == 0, "a successful fetch resets the retry streak")

        // Settled again: more time and many identical up-to-date states change nothing.
        await harness.scheduler.advance(by: .seconds(120))
        for _ in 0..<5 {
            await harness.push(.upToDate)
        }
        await harness.giveAWrongFetchTimeToLand()
        #expect(harness.fetchCount == settledCount + 2, "no further read after the retry succeeded")
    }

    // MARK: - (2) A failed event-triggered read on a fully mined history is retried

    @Test func aFailedEventTriggeredReadOnAMinedHistoryIsRetried() async {
        let accountA = Self.walletAccount(idByte: 72)
        let mined = Self.minedTx(id: "a-mined")
        let arrived = Self.minedTx(id: "a-new")
        let harness = Harness(selected: accountA, accounts: [accountA])
        harness.answer(accountA, with: IdentifiedArrayOf<TransactionState>(uniqueElements: [mined]))
        await harness.startObservingAndSettleAtUpToDate()
        let settledCount = harness.fetchCount
        #expect(harness.store.state.transactions.map(\.id) == ["a-mined"])

        harness.script(accountA, [
            Outcome.failure(FetchStubError()),
            Outcome.success(IdentifiedArrayOf<TransactionState>(uniqueElements: [mined, arrived]))
        ])
        harness.events.send(.foundTransactions([], nil))
        await harness.scheduler.advance(by: .seconds(0.3))
        await harness.settled(expectingFetches: settledCount + 1)
        #expect(harness.store.state.transactions.map(\.id) == ["a-mined"], "the failed read keeps the previous rows")

        await harness.scheduler.advance(by: .seconds(Root.State.transactionsFetchRetryDelaysInSeconds[0]))
        await harness.settled(expectingFetches: settledCount + 2)
        #expect(harness.store.state.transactions.map(\.id).contains("a-new"), "the retry must pick up the new transaction")
    }

    // MARK: - (3) A pending retry never outlives its account or the foreground

    @Test func switchingAccountsWhileARetryIsPendingDropsThatRetry() async {
        let accountA = Self.walletAccount(idByte: 73)
        let accountB = Self.walletAccount(idByte: 74)
        let accountC = Self.walletAccount(idByte: 75)
        let rowsC = IdentifiedArrayOf<TransactionState>(uniqueElements: [Self.minedTx(id: "c-1")])
        let harness = Harness(selected: accountA, accounts: [accountA, accountB, accountC])
        await harness.startObservingAndSettleAtUpToDate()
        let settledCount = harness.fetchCount

        harness.script(accountB, [Outcome.failure(FetchStubError())])
        harness.switchTo(accountB)
        await harness.settled(expectingFetches: settledCount + 1)

        harness.answer(accountC, with: rowsC)
        harness.switchTo(accountC)
        await harness.settled(expectingFetches: settledCount + 2)
        #expect(harness.store.state.transactions == rowsC)

        // B's retry would have fired inside this window; it must not, and C's rows must stand.
        await harness.scheduler.advance(by: .seconds(120))
        await harness.giveAWrongFetchTimeToLand()
        #expect(harness.fetchCount(for: accountB) == 1, "no delayed retry for the account that was left")
        #expect(harness.fetchCount == settledCount + 2)
        #expect(harness.store.state.transactions == rowsC)
        #expect(harness.store.state.transactionsAccountId == accountC.id)
    }

    @Test func backgroundingWhileARetryIsPendingDropsThatRetry() async {
        let accountA = Self.walletAccount(idByte: 76)
        let accountB = Self.walletAccount(idByte: 77)
        let harness = Harness(selected: accountA, accounts: [accountA, accountB])
        await harness.startObservingAndSettleAtUpToDate()
        let settledCount = harness.fetchCount

        harness.script(accountB, [Outcome.failure(FetchStubError())])
        harness.switchTo(accountB)
        await harness.settled(expectingFetches: settledCount + 1)
        #expect(harness.store.state.transactionsFetchRetryAttempt == 1, "the failed read must have scheduled a retry")
        // The retry must be in flight before backgrounding cancels it -- see `retryArmed(count:)`.
        await harness.retryArmed(count: 1)

        harness.store.send(.initialization(.appDelegate(.didEnterBackground)))
        await harness.scheduler.advance(by: .seconds(120))
        await harness.giveAWrongFetchTimeToLand()
        #expect(harness.fetchCount == settledCount + 1, "no retry may fire after backgrounding")
        #expect(harness.store.state.transactionsFetchRetryAttempt == 0)
    }

    /// The start-cancel in `.fetchTransactionsForTheSelectedAccount` (`RootTransactions.swift`).
    /// A retry is pending at t+2 when an unrelated trigger -- here a `foundTransactions` event --
    /// starts and completes its own read at t+1. That read is the refresh the pending retry existed
    /// to obtain, so the retry must be cancelled as the read starts rather than firing a redundant
    /// second full-history read a second later. Deleting that `.cancel` leaves every other test in
    /// this suite green and only this one red.
    @Test func aFetchStartedBeforeTheRetryDelayCancelsThePendingRetry() async {
        let accountA = Self.walletAccount(idByte: 80)
        let accountB = Self.walletAccount(idByte: 81)
        let rowsB = IdentifiedArrayOf<TransactionState>(uniqueElements: [Self.minedTx(id: "b-1")])
        let harness = Harness(selected: accountA, accounts: [accountA, accountB])
        await harness.startObservingAndSettleAtUpToDate()
        let settledCount = harness.fetchCount

        // B's first read throws, opening the retry lane; everything after it answers with B's rows.
        harness.script(accountB, [Outcome.failure(FetchStubError())])
        harness.answer(accountB, with: rowsB)
        harness.switchTo(accountB)
        await harness.settled(expectingFetches: settledCount + 1)
        #expect(harness.store.state.transactionsFetchRetryAttempt == 1, "the failed read must have scheduled a retry")

        // t+1: still inside the first retry delay, so nothing has retried yet. An unrelated trigger
        // now starts its own read, which succeeds.
        await harness.scheduler.advance(by: .seconds(1))
        await harness.giveAWrongFetchTimeToLand()
        #expect(harness.fetchCount == settledCount + 1, "the retry delay has not elapsed yet")
        harness.events.send(.foundTransactions([], nil))
        await harness.scheduler.advance(by: .seconds(0.3))
        await harness.settled(expectingFetches: settledCount + 2)
        #expect(harness.store.state.transactions == rowsB, "the event-triggered read must deliver the account's rows")
        #expect(harness.store.state.transactionsFetchRetryAttempt == 0, "a read that landed ends the failure streak")

        // Past t+2 and far beyond: the retry the failure had scheduled must never fire.
        await harness.scheduler.advance(by: .seconds(120))
        await harness.giveAWrongFetchTimeToLand()
        #expect(harness.fetchCount == settledCount + 2, "a fetch that started must cancel the retry still waiting on the last failure")
    }

    // MARK: - (4) Repeated failures respect the budget and stay coalesced

    @Test func repeatedFailuresStopAfterTheRetryBudget() async {
        let accountA = Self.walletAccount(idByte: 78)
        let accountB = Self.walletAccount(idByte: 79)
        let harness = Harness(selected: accountA, accounts: [accountA, accountB])
        await harness.startObservingAndSettleAtUpToDate()
        let settledCount = harness.fetchCount

        let delays = Root.State.transactionsFetchRetryDelaysInSeconds
        harness.script(accountB, Array(repeating: Outcome.failure(FetchStubError()), count: delays.count + 3))
        harness.switchTo(accountB)
        await harness.settled(expectingFetches: settledCount + 1)

        #expect(delays.allSatisfy { $0 >= 2 }, "the just-before probe below needs at least a one-second gap")
        for (index, delay) in delays.enumerated() {
            // Just short of the delay: nothing yet; then the delay itself: exactly one more read.
            await harness.scheduler.advance(by: .seconds(delay - 1))
            await harness.giveAWrongFetchTimeToLand()
            #expect(harness.fetchCount == settledCount + 1 + index, "retry \(index + 1) fired early")
            await harness.scheduler.advance(by: .seconds(1))
            await harness.settled(expectingFetches: settledCount + 2 + index)
        }
        #expect(harness.store.state.transactionsFetchRetryAttempt == delays.count)

        await harness.scheduler.advance(by: .seconds(600))
        await harness.giveAWrongFetchTimeToLand()
        #expect(harness.fetchCount == settledCount + 1 + delays.count, "the budget is spent: no further retry")
        #expect(!harness.store.state.isTransactionsFetchInFlight)
        #expect(!harness.store.state.isTransactionsFetchDirty)
    }
}

// MARK: - Dependencies

/// Copied from `RootPendingTransactionRefreshTests.swift`, this directory's established shape for
/// driving `Root` without touching the network, disk or keychain.
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
