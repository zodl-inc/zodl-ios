//
//  RootTransactionsUpToDateEdgeTests.swift
//  zodlTests
//
//  MOB-1954: `.observeTransactions` (`RootTransactions.swift`) used to map EVERY synchronizer
//  state whose status is `.upToDate` to a full-history fetch. The Slipstream poll loop publishes a
//  state every 2 s and never deduplicates, so on a synced wallet the app requested the whole
//  history every 2 s, and the MOB-1856 coalescing gate turned that into back-to-back
//  `getAllTransactions` reads for as long as the app stayed open -- on a 1,255-transaction wallet
//  each one a 25 s read, with up to nine reads in flight together with the migration ones (field,
//  2026-09-14). The fetch is now EDGE-triggered: it fires when the status BECOMES `.upToDate`; the
//  transaction events, the initial one-shot fetch and the 30 s pending-transaction poller cover
//  everything else, and these tests pin all three.
//
//  Mirrors `RootPendingTransactionRefreshTests.swift`: a plain `Store`, a file-scoped
//  `baseNoOpDependencies`, a `DispatchQueue.test` scheduler injected as `mainQueue` so the 0.2 s
//  throttle is advanced by hand, `LockIsolated` counters, and event-driven waits (the fetch count,
//  the in-flight flag) wherever there is something positive to wait for. The short sleeps guard
//  NEGATIVES only ("no extra fetch landed"). The first `.upToDate` push is retried until a fetch
//  lands because the publisher subscription races the first push; a duplicate `.upToDate` pushed
//  before the subscription is live cannot be told from one pushed after it, so re-pushing is
//  harmless and keeps the test free of wall-clock deadlines.
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

@Suite(.serialized, .timeLimit(.minutes(3))) @MainActor struct RootTransactionsUpToDateEdgeTests {
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

    private static func state(_ status: SyncStatus) -> SynchronizerState {
        var state = SynchronizerState.zero
        state.latestBlockHeight = 4_200_000
        state.syncStatus = status
        return state
    }

    /// One store observing a hand-driven state stream and event stream, counting history fetches.
    @MainActor private final class Harness {
        let scheduler = DispatchQueue.test
        let states = PassthroughSubject<SynchronizerState, Never>()
        let events = PassthroughSubject<SynchronizerEvent, Never>()
        let fetchCalls = LockIsolated<Int>(0)
        let store: StoreOf<Root>

        init(idByte: UInt8) {
            var initialState = Root.State.initial
            initialState.$selectedWalletAccount.withLock { $0 = RootTransactionsUpToDateEdgeTests.walletAccount(idByte: idByte) }
            initialState.$transactions.withLock { $0 = [] }
            initialState.homeState.transactionListState.isInvalidated = false
            initialState.transactionsCoordFlowState.transactionsManagerState.isInvalidated = false

            let scheduler = self.scheduler
            let states = self.states
            let events = self.events
            let fetchCalls = self.fetchCalls
            store = Store(initialState: initialState) {
                Root()
            } withDependencies: {
                baseNoOpDependencies(&$0)
                $0.mainQueue = scheduler.eraseToAnyScheduler()
                // `stateStream`/`eventStream` are `let`s on the client, so the whole client is
                // replaced via `.mocked(...)`; `getAllTransactions` is a `var` and is re-mocked in
                // place.
                $0.sdkSynchronizer = .mocked(
                    stateStream: { states.eraseToAnyPublisher() },
                    eventStream: { events.eraseToAnyPublisher() }
                )
                $0.sdkSynchronizer.getAllTransactions = { _ in
                    fetchCalls.withValue { $0 += 1 }
                    return []
                }
            }
        }

        /// Starts observing and waits for the trailing one-shot fetch inside `.observeTransactions`
        /// to start AND settle, so every later count is the edge logic's alone.
        func startObserving() async {
            store.send(.observeTransactions)
            await settled(expectingFetches: 1)
        }

        /// Pushes one state and advances the throttle window past it.
        func push(_ status: SyncStatus) async {
            states.send(RootTransactionsUpToDateEdgeTests.state(status))
            await scheduler.advance(by: .seconds(0.3))
            await Task.yield()
        }

        /// Pushes `.upToDate` until the first edge fetch has landed (the subscription may not be
        /// live for the very first push -- see the header), then waits for it to settle.
        func pushUpToDateUntilTheFirstEdgeFetchLands() async {
            while fetchCalls.value < 2 {
                await push(.upToDate)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            await settled(expectingFetches: 2)
        }

        /// Event-driven positive wait: the fetch count has reached `count` and the MOB-1856
        /// coalescing gate is closed again, so the next push cannot be folded into an in-flight
        /// fetch and counted as a follow-up.
        func settled(expectingFetches count: Int) async {
            while fetchCalls.value < count || store.state.isTransactionsFetchInFlight {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        /// Negative-only wait: gives a wrongly triggered fetch time to land before a count is read.
        func giveAWrongFetchTimeToLand() async {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - (1) Identical `.upToDate` ticks fetch once, not once per tick

    @Test func repeatedUpToDateStatesFetchOnceNotOncePerTick() async {
        let harness = Harness(idByte: 60)
        await harness.startObserving()
        await harness.pushUpToDateUntilTheFirstEdgeFetchLands()

        // Five more identical ticks, as the 2 s poll loop produces on a synced wallet.
        for _ in 0..<5 {
            await harness.push(.upToDate)
        }
        await harness.giveAWrongFetchTimeToLand()
        #expect(
            harness.fetchCalls.value == 2,
            "an unchanged .upToDate status must not refetch the whole history on every poll tick"
        )
    }

    // MARK: - (2) Every transition INTO `.upToDate` fetches again; `.syncing` never does

    @Test func everyTransitionIntoUpToDateFetchesAgain() async {
        let harness = Harness(idByte: 61)
        await harness.startObserving()
        await harness.pushUpToDateUntilTheFirstEdgeFetchLands()

        await harness.push(.syncing(0.5, false))
        await harness.giveAWrongFetchTimeToLand()
        #expect(harness.fetchCalls.value == 2, "a .syncing state must not fetch")

        await harness.push(.upToDate)
        await harness.settled(expectingFetches: 3)
        #expect(harness.fetchCalls.value == 3, "the next pass completing must refresh the list once")
    }

    // MARK: - (3) A transaction event between identical `.upToDate` ticks still fetches

    @Test func aTransactionEventBetweenIdenticalUpToDateStatesStillFetches() async {
        let harness = Harness(idByte: 62)
        await harness.startObserving()
        await harness.pushUpToDateUntilTheFirstEdgeFetchLands()

        await harness.push(.upToDate)
        harness.events.send(.foundTransactions([], nil))
        await harness.scheduler.advance(by: .seconds(0.3))
        await harness.settled(expectingFetches: 3)
        #expect(
            harness.fetchCalls.value == 3,
            "foundTransactions must keep triggering a fetch while the status stays .upToDate"
        )
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
