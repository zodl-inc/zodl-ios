#if VOTING_ENABLED
//
//  VotingBatchSubmissionOverlapTests.swift
//  zodlTests
//
//  MOB-1928. Submitting a ballot used to stop dead between questions: after a vote was proved,
//  broadcast and confirmed on-chain, the loop sat waiting for that question's 16 tally shares to
//  reach the helper servers before it would start proving the next one. These tests pin the
//  replacement — deliveries run in a window of two while the loop moves on, and a question is
//  reported submitted only once its own shares are accepted.
//

import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

// Serialized for the same reason as `VotingCoordFlowCoordinatorTests`: the coordinator's State
// touches process-global `@Shared` storage (`selectedWalletAccount`). The time limit is the
// backstop for the deadline-free waits these tests use — a wait that never fires is recorded as
// a failure rather than running until the CI job's own timeout.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct VotingBatchSubmissionOverlapTests {
    private let roundId = VotingBatchSubmissionFixture.roundId

    /// The point of the change: the next question's proof starts while the previous question's
    /// shares are still travelling, and that previous question is not yet reported submitted.
    @Test func nextProposalProvesWhileTheFirstDeliveryIsStillRunning() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 3)
        let firstDelivery = fixture.gate(forProposal: 1)
        // Held so the interleaving is pinned rather than left to the scheduler: proposal 2 may
        // only prove once proposal 1's delivery is provably in flight.
        let secondProof = fixture.commitGate(forBundle: 0, proposal: 2)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        await fixture.recorder.awaitEvent("deliver:1")
        secondProof.open()
        await fixture.recorder.awaitEvent("commit:0:2")

        let events = fixture.recorder.events()
        let deliveryIndex = try #require(events.firstIndex(of: "deliver:1"))
        let proofIndex = try #require(events.firstIndex(of: "commit:0:2"))
        #expect(deliveryIndex < proofIndex)
        // Nothing has opened `firstDelivery`, so proposal 1's shares are demonstrably still in
        // flight here — and the proposal has not been reported submitted.
        #expect(store.state.roundCache[roundId]?.votes[1] == nil)

        firstDelivery.open()
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus == .completed(successCount: 3)
        }
    }

    /// The window is bounded at two: a third delivery is admitted only when the oldest settles,
    /// so a stalled helper server cannot let deliveries pile up without limit.
    @Test func thirdDeliveryWaitsUntilTheOldestSettles() async {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 3)
        let firstDelivery = fixture.gate(forProposal: 1)
        let secondDelivery = fixture.gate(forProposal: 2)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        // Proposal 3 proves and confirms even though both earlier deliveries are parked...
        await fixture.recorder.awaitEvent("commit:0:3")
        // ...but its own delivery is fenced out until a slot frees up.
        #expect(!fixture.recorder.events().contains("deliver:3"))

        firstDelivery.open()
        await fixture.recorder.awaitEvent("deliver:3")

        secondDelivery.open()
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus == .completed(successCount: 3)
        }
    }

    /// A delivery that the helper servers reject fails its own question and nothing else: the
    /// other questions still count as submitted, and every share the servers did accept is still
    /// recorded locally (the 8P rule, now enforced from inside the window).
    @Test func aFailedDeliveryFailsOnlyItsProposalAndKeepsRecordedShares() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 3)
        fixture.failDelivery(forProposal: 2)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus.isFailureState == true
        }

        let session = try #require(store.state.roundCache[roundId])
        #expect(Set(session.batchVoteErrors.keys) == [2])
        #expect(Set(session.votes.keys) == [1, 3])

        let events = fixture.recorder.events()
        #expect(events.contains("record:0:1:0"))
        #expect(events.contains("record:0:1:15"))
        #expect(events.contains("record:0:3:0"))
        #expect(events.contains("record:0:3:15"))
        // The rejected delivery never reached the recording step.
        #expect(!events.contains { $0.hasPrefix("record:0:2:") })
    }

    /// The batch is not complete while a delivery is outstanding — and no question is reported
    /// submitted early just because its on-chain vote landed first.
    @Test func completionWaitsForEveryDelivery() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 3)
        let lastDelivery = fixture.gate(forProposal: 3)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        await fixture.recorder.awaitEvent("deliver:3")

        let session = try #require(store.state.roundCache[roundId])
        #expect(Self.isSubmitting(session.batchSubmissionStatus))
        #expect(session.votes.isEmpty)

        lastDelivery.open()
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus == .completed(successCount: 3)
        }
    }

    /// Once every helper server has proved unreachable there is nowhere left to send shares, so
    /// the batch stops instead of proving votes it cannot deliver.
    ///
    /// The pool empties when the failed delivery gives up — `delegateSharesWithFallback` retries
    /// an exhaustion twice, two seconds apart, before `deliverShares` prunes the pool — and a lane
    /// only learns of it at a task boundary. Question-major, three bundles, two lanes: bundles 0
    /// and 1 cast question 1 and park their deliveries in the window of two; the lanes then take
    /// bundle 2's question 1 and bundle 0's question 2, and each of those ends by enqueueing a
    /// delivery the full window admits only once the oldest one has settled — after it emptied
    /// the pool. So both lanes reach their next boundary with the pool empty: the queue is
    /// drained, question 3 is never proved and stays a draft, question 1 fails when its deliveries
    /// are settled, and question 2 fails on its own merits — its proof was already under way,
    /// and its shares find the pool empty.
    @Test func exhaustedServersStopTheBatch() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 3, bundleCount: 3)
        fixture.failDelivery(forProposal: 1, with: .serversExhausted)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus.isFailureState == true
        }

        // No bundle proved question 3: by then every lane had seen the empty pool.
        let events = fixture.recorder.events()
        for bundleIndex in UInt32(0)...2 {
            #expect(!events.contains("commit:\(bundleIndex):3"))
        }
        let session = try #require(store.state.roundCache[roundId])
        #expect(Set(session.batchVoteErrors.keys) == [1, 2])
        #expect(session.votes.isEmpty)
    }

    /// Leaving the flow cancels the batch. The walk has to stop there — every further proposal
    /// would be a proof and an on-chain broadcast for a screen the user has left — and the
    /// deliveries the window still owns are cancelled and joined instead of outliving the effect.
    @Test func cancellingTheBatchStopsTheLoopAndJoinsInFlightDeliveries() async {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 3)
        fixture.gate(forProposal: 1)
        // Parks the walk part-way through proposal 2, so the cancellation below lands while the
        // walk is provably still inside the ballot rather than racing its last iteration.
        let secondConfirmation = fixture.confirmationGate(forBundle: 0, proposal: 2)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))
        await fixture.recorder.awaitEvent("commit:0:2")

        // The cancel site a user reaches by leaving the poll: `.dismissFlow` cancels
        // `cancelSubmissionId` among others.
        store.send(.dismissFlow)
        secondConfirmation.open()

        // Proposal 1's delivery is parked on a gate this test never opens, so the only thing that
        // can release it is the window cancelling it — which is what this wait proves.
        await fixture.recorder.awaitEvent("deliver-cancelled:1")
        #expect(!fixture.recorder.events().contains("commit:0:3"))
    }

    /// A proposal that fails on a later bundle has already handed an earlier bundle's shares to
    /// the window. Those are still the effect's to join: the batch cannot report itself complete
    /// while one is running, or it would leave a delivery writing share records beside a retry's.
    @Test func aProposalThatFailsAfterEnqueueingStillWaitsForItsDelivery() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 1, bundleCount: 2)
        let firstDelivery = fixture.gate(forProposal: 1)
        fixture.failCommit(forBundle: 1, proposal: 1)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        // Bundle 0's shares are in the window; bundle 1's proof then fails the whole proposal, so
        // it never joins the awaiting list — and with one proposal in the ballot, the walk is over.
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchVoteErrors[1] != nil
        }
        await fixture.recorder.awaitEvent("deliver:1")
        let pending = try #require(store.state.roundCache[roundId])
        #expect(Self.isSubmitting(pending.batchSubmissionStatus))

        firstDelivery.open()
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus.isFailureState == true
        }
        let session = try #require(store.state.roundCache[roundId])
        #expect(Set(session.batchVoteErrors.keys) == [1])
        #expect(session.votes.isEmpty)
        // The delivery that outlived its proposal still finished its own bookkeeping.
        #expect(fixture.recorder.events().contains("record:0:1:15"))
    }

    // MARK: - Helpers

    private func makeStore(_ fixture: VotingBatchSubmissionFixture) -> StoreOf<VotingCoordFlow> {
        Store(initialState: fixture.makeState()) {
            VotingCoordFlow()
        } withDependencies: {
            fixture.dependencies(&$0)
        }
    }

    private static func isSubmitting(_ status: BatchSubmissionStatus) -> Bool {
        if case .submitting = status {
            return true
        }
        return false
    }
}
#endif
