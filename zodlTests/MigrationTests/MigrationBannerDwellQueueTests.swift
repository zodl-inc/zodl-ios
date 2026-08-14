//
//  MigrationBannerDwellQueueTests.swift
//  zodlTests
//
//  SB-D1 (Lukas, 2026-08-07): "always render any banner's state for at least 0.5s". He had watched
//  evaluating → sending Tx → we'll notify go past inside a blink and could not read what had been
//  shown. He also named the cost and accepted it: "adding extra times can slip the reality but
//  improves UX.. I see only tradeoffs in any solution we pick."
//
//  So these pins are as much about the BOUND as about the delay. An unbounded queue would trade a
//  flicker for a banner drifting arbitrarily behind the wallet, which is the worse lie.
//
//  Every test starts from `.checkingStatus`: it is the one predecessor `resolvingIdleTermination`
//  passes through untouched, so the queue's own behaviour is what is under test rather than THE
//  BANNER MAP's idle1 conversion. `queueingPreservesIdleTermination` covers the interaction on
//  purpose, at the end.
//

import Foundation
import Testing
import ComposableArchitecture
import ZcashLightClientKit
@testable import zodl_internal

@MainActor
@Suite struct MigrationBannerDwellQueueTests {
    private static func store(queue: TestSchedulerOf<DispatchQueue>) -> TestStoreOf<SmartBanner> {
        var state = SmartBanner.State()
        state.priorityContent = .priorityMigration
        state.migrationBannerVariant = .checkingStatus
        let store = TestStore(initialState: state) { SmartBanner() } withDependencies: {
            $0.mainQueue = queue.eraseToAnyScheduler()
            $0.migrationManager.isMigrationSessionVerdictKnown = { true }
        }
        store.exhaustivity = .off
        return store
    }

    /// Serve the current state's floor, then let the next one through.
    private static func tick(_ store: TestStoreOf<SmartBanner>, _ queue: TestSchedulerOf<DispatchQueue>) async {
        await queue.advance(by: .seconds(0.5))
        await store.receive(\.migrationVariantDwellElapsed)
    }

    /// The floor itself: a second state arriving inside it does NOT replace what is on screen.
    @Test func aSecondStateInsideTheFloorDoesNotReplaceTheFirst() async {
        let queue = DispatchQueue.test
        let store = Self.store(queue: queue)

        await store.send(.migrationVariantUpdated(.preparing(done: 0, total: 6)))
        #expect(store.state.migrationBannerVariant == .preparing(done: 0, total: 6))

        await store.send(.migrationVariantUpdated(.transferSending(number: 1)))
        #expect(store.state.migrationBannerVariant == .preparing(done: 0, total: 6))
        #expect(store.state.migrationVariantQueue == [.transferSending(number: 1)])

        await Self.tick(store, queue)
        #expect(store.state.migrationBannerVariant == .transferSending(number: 1))
    }

    /// A → B → C: each gets its turn, in order. The blink Lukas reported becomes three readable
    /// states.
    @Test func aThreeStateRunIsShownInOrder() async {
        let queue = DispatchQueue.test
        let store = Self.store(queue: queue)

        await store.send(.migrationVariantUpdated(.preparing(done: 0, total: 6)))
        await store.send(.migrationVariantUpdated(.transferSending(number: 1)))
        await store.send(.migrationVariantUpdated(.updatePlan))

        #expect(store.state.migrationBannerVariant == .preparing(done: 0, total: 6))
        await Self.tick(store, queue)
        #expect(store.state.migrationBannerVariant == .transferSending(number: 1))
        await Self.tick(store, queue)
        #expect(store.state.migrationBannerVariant == .updatePlan)
        await Self.tick(store, queue)
        #expect(store.state.migrationVariantQueue.isEmpty)
        #expect(!store.state.isMigrationVariantDwelling)
    }

    /// Same-case updates COALESCE: a run of count ticks is ONE state, not five half-seconds of
    /// queue. Lukas asked to see state changes, not every number.
    @Test func countTicksCoalesceInsteadOfQueueing() async {
        let queue = DispatchQueue.test
        let store = Self.store(queue: queue)

        await store.send(.migrationVariantUpdated(.preparing(done: 0, total: 6)))
        for done in 1...5 {
            await store.send(.migrationVariantUpdated(.idleCounts(done: done, total: 6)))
        }

        // One entry, carrying the NEWEST number — coalescing must never show a stale count.
        #expect(store.state.migrationVariantQueue == [.idleCounts(done: 5, total: 6)])
    }

    /// A same-case update to the state ALREADY on screen lands directly: the numbers stay live
    /// without buying another half second of delay for a state the reader is already looking at.
    @Test func aSameCaseUpdateToTheVisibleStateLandsImmediately() async {
        let queue = DispatchQueue.test
        let store = Self.store(queue: queue)

        await store.send(.migrationVariantUpdated(.idleCounts(done: 1, total: 6)))
        #expect(store.state.migrationBannerVariant == .idleCounts(done: 1, total: 6))

        await store.send(.migrationVariantUpdated(.idleCounts(done: 2, total: 6)))
        #expect(store.state.migrationBannerVariant == .idleCounts(done: 2, total: 6))
        #expect(store.state.migrationVariantQueue.isEmpty)
    }

    /// THE BOUND. Churn must not push the banner arbitrarily far behind reality: past the cap the
    /// TAIL is replaced, so the newest truth always survives and worst-case lag stays fixed at
    /// cap × 0.5 s rather than growing with the churn.
    @Test func theQueueIsBoundedAndKeepsTheNewestTruth() async {
        let queue = DispatchQueue.test
        let store = Self.store(queue: queue)

        await store.send(.migrationVariantUpdated(.preparing(done: 0, total: 6)))
        let churn: [MigrationBannerVariant] = [
            .transferSending(number: 1), .updatePlan, .transfersExpired(first: 1, last: 2),
            .required, .nextRoundRequired(round: 2, totalRounds: 3), .complete
        ]
        for variant in churn {
            await store.send(.migrationVariantUpdated(variant))
        }

        #expect(store.state.migrationVariantQueue.count <= 4)
        // Whatever got dropped, it was never the latest answer.
        #expect(store.state.migrationVariantQueue.last == .complete)
    }

    /// The queue must not smuggle a state past THE BANNER MAP's idle1 rule (as amended 2026-08-08,
    /// Andrea via Lukas). A quiet counts answer arriving behind a finished PREPARING still converts
    /// to `.idle` (the termination notify line) when it finally paints — the conversion reads the
    /// variant it actually follows on screen, which is exactly what queueing preserves. And the
    /// amendment survives the queue in the other direction too: a counts answer behind a finished
    /// SENDING stays the generic counts.
    @Test func queueingPreservesIdleTermination() async {
        let queue = DispatchQueue.test
        let store = Self.store(queue: queue)

        await store.send(.migrationVariantUpdated(.preparing(done: 1, total: 6)))
        await store.send(.migrationVariantUpdated(.idleCounts(done: 6, total: 6)))

        await Self.tick(store, queue)
        #expect(store.state.migrationBannerVariant == .idle)
    }

    /// The amendment's other half, through the same queue: a finished SENDING settles on the
    /// generic counts — the notify promise never paints off the back of a completed send.
    @Test func queueingKeepsASendingFinishOnCounts() async {
        let queue = DispatchQueue.test
        let store = Self.store(queue: queue)

        await store.send(.migrationVariantUpdated(.transferSending(number: 1)))
        await store.send(.migrationVariantUpdated(.idleCounts(done: 6, total: 6)))

        await Self.tick(store, queue)
        #expect(store.state.migrationBannerVariant == .idleCounts(done: 6, total: 6))
    }
}
