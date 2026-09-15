#if VOTING_ENABLED
//
//  VotingBundleConcurrencyTests.swift
//  zodlTests
//
//  MOB-1930. A wallet whose weight spans several note bundles used to submit its ballot strictly
//  serially: question by question and, inside each question, bundle by bundle. The second bundle's
//  proof could not start until the first bundle's vote had been broadcast, confirmed on-chain and
//  its shares handed over — minutes of chain latency with the CPU idle.
//
//  These tests pin the replacement. The batch is bundle-major: up to
//  `VotingCoordFlow.maxConcurrentVoteBundles` bundle pipelines run at once, each walking the
//  questions in order (the authority-note chain forces that order inside a bundle), so one
//  bundle's confirmation and share delivery overlap the other bundle's proof. Proofs themselves
//  stay serial — the SDK serializes FFI calls behind its handle lock — which is the intended
//  memory profile, so nothing here asserts two proofs run at the same time.
//
//  A question is reported submitted only once *every* bundle has cast it, and a bundle that fails
//  one question carries on with its next one.
//

import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

// Serialized for the same reason as `VotingBatchSubmissionOverlapTests`: the coordinator's State
// touches process-global `@Shared` storage (`selectedWalletAccount`). The time limit is the
// backstop for the deadline-free waits these tests use — a wait that never fires is recorded as a
// failure rather than running until the CI job's own timeout.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct VotingBundleConcurrencyTests {
    private let roundId = VotingBatchSubmissionFixture.roundId

    /// The point of the change: while bundle 0 sits waiting for its vote to be written back from
    /// the chain, bundle 1 is already proving the same question.
    @Test func secondBundleProvesWhileTheFirstBundleWaitsForConfirmation() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 3, bundleCount: 2)
        // Registered before the run, so `confirm:0:1` cannot be recorded until this test opens it.
        let firstBundleConfirmation = fixture.confirmationGate(forBundle: 0, proposal: 1)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        await fixture.recorder.awaitEvent("commit:1:1")
        #expect(!fixture.recorder.events().contains("confirm:0:1"))

        firstBundleConfirmation.open()
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus == .completed(successCount: 3)
        }

        let events = fixture.recorder.events()
        let provedIndex = try #require(events.firstIndex(of: "commit:1:1"))
        let confirmedIndex = try #require(events.firstIndex(of: "confirm:0:1"))
        #expect(provedIndex < confirmedIndex)
    }

    /// Bundle-major does not mean a question is done early: every bundle casts a vote for it, so
    /// it is reported submitted only once the last of them has.
    @Test func aProposalCompletesOnlyAfterEveryBundleSubmittedIt() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 2, bundleCount: 2)
        let secondBundleConfirmation = fixture.confirmationGate(forBundle: 1, proposal: 1)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        // Bundle 0 has cast question 1, its shares are delivered and recorded, and it has already
        // run ahead to question 2 — none of which may report question 1 as submitted.
        await fixture.recorder.awaitEvent("confirm:0:1")
        await fixture.recorder.awaitEvent("record:0:1:\(VotingBatchSubmissionFixture.shareCount - 1)")
        await fixture.recorder.awaitEvent("commit:0:2")
        #expect(store.state.roundCache[roundId]?.votes[1] == nil)

        secondBundleConfirmation.open()
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.votes[1] != nil
        }
    }

    /// A bundle that cannot cast one question fails that question and nothing else — and carries
    /// on with its own next question rather than abandoning the rest of the ballot.
    @Test func aFailureInOneBundleFailsThatProposalOnly() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 3, bundleCount: 2)
        fixture.failCommit(forBundle: 1, proposal: 2)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus.isFailureState == true
        }

        let session = try #require(store.state.roundCache[roundId])
        #expect(Set(session.batchVoteErrors.keys) == [2])
        #expect(Set(session.votes.keys) == [1, 3])
        // The bundle whose question 2 failed still reached question 3.
        #expect(fixture.recorder.events().contains("commit:1:3"))
    }

    /// Each bundle's own votes stay in ballot order: the authority note of a bundle chains one
    /// vote to the next, so a bundle may never reorder or overlap its own questions.
    @Test func proposalsStaySequentialWithinABundle() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 3, bundleCount: 2)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus == .completed(successCount: 3)
        }

        let events = fixture.recorder.events()
        for bundleIndex in UInt32(0)...1 {
            #expect(Self.committedProposals(in: events, bundle: bundleIndex) == [1, 2, 3])
        }
    }

    /// The overwhelming majority of wallets hold one bundle. Their submission must be exactly
    /// what it was before this change — one question proved, broadcast and confirmed, then the
    /// next — so the concurrency only ever adds a lane, never reshuffles the single-lane order.
    @Test func singleBundleEventOrderIsUnchanged() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 3, bundleCount: 1)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus == .completed(successCount: 3)
        }

        let events = fixture.recorder.events()
        let chainEvents = events.filter { event in
            event.hasPrefix("commit:") || event.hasPrefix("submit:") || event.hasPrefix("confirm:")
        }
        #expect(chainEvents == [
            "commit:0:1", "submit:1", "confirm:0:1",
            "commit:0:2", "submit:2", "confirm:0:2",
            "commit:0:3", "submit:3", "confirm:0:3"
        ])
        // The deliveries and their share records all happened; where they interleave with the
        // walk is the overlap change's business, not this one's.
        let lastShareIndex = VotingBatchSubmissionFixture.shareCount - 1
        for proposalId in UInt32(1)...3 {
            #expect(events.contains("deliver:\(proposalId)"))
            #expect(events.contains("record:0:\(proposalId):0"))
            #expect(events.contains("record:0:\(proposalId):\(lastShareIndex)"))
        }
    }

    /// The vote-tree sync and the VAN witness it anchors are one unit, whatever else is running.
    ///
    /// The SDK's lock serializes each of those FFI calls on its own but not the pair, so with two
    /// pipelines a sibling's sync landing between one bundle's sync and its own witness would be
    /// the steady state — and nothing in the crate's contract says the witness is rooted at the
    /// anchor height that sync returned rather than at whatever the tree holds when it runs.
    @Test func theTreeSyncAndItsWitnessAreNotInterleavedAcrossBundles() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 1, bundleCount: 2)
        // Holds the very first sync open, which is the whole window the other bundle would have to
        // slip its own sync into.
        let firstSync = fixture.firstTreeSyncGate()
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        await fixture.recorder.awaitEvent("sync")
        let duringPair = fixture.recorder.events()
        #expect(duringPair.filter { $0 == "sync" }.count == 1)
        #expect(!duringPair.contains { $0.hasPrefix("witness:") })

        firstSync.open()
        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus == .completed(successCount: 1)
        }

        // Two complete pairs, one after the other — never `sync, sync, witness, witness`. Which
        // bundle wins the queue is the scheduler's business (both pipelines are admitted together
        // and the queue is FIFO on arrival), so the pairing is asserted, not the bundle order.
        let treeEvents = fixture.recorder.events().filter { $0 == "sync" || $0.hasPrefix("witness:") }
        #expect(treeEvents.count == 4)
        guard treeEvents.count == 4 else { return }
        #expect(treeEvents[0] == "sync")
        #expect(treeEvents[1].hasPrefix("witness:"))
        #expect(treeEvents[2] == "sync")
        #expect(treeEvents[3].hasPrefix("witness:"))
        #expect(Set([treeEvents[1], treeEvents[3]]) == ["witness:0", "witness:1"])
    }

    /// The helper pool can only be seen empty at a question boundary, so a question whose proof was
    /// already under way when the last server dropped out cannot avoid being proved. It can avoid
    /// being broadcast — and it must: a vote confirmed on chain whose tally shares have nowhere to
    /// go leaves the voter with stranded shares, where an unbroadcast proof costs only CPU.
    @Test func aVoteProvedAfterThePoolRanDryIsNeverBroadcast() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 3, bundleCount: 1)
        // Question 1's shares all land, but every helper drops out of the working set behind them.
        fixture.emptyServerPool(afterProposal: 1)
        let firstDelivery = fixture.gate(forProposal: 1)
        let secondQuestionProof = fixture.commitGate(forBundle: 0, proposal: 2)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        // Question 1's delivery is parked before it can prune anything, and question 2 is already
        // past its boundary check — its witness is generated — so the pool it saw was still full.
        await fixture.recorder.awaitEvent("deliver:1")
        await fixture.recorder.awaitEvents { $0.filter { $0 == "witness:0" }.count >= 2 }

        // Let the delivery finish and empty the pool, then release the proof it was racing.
        firstDelivery.open()
        await fixture.recorder.awaitEvent("record:0:1:\(VotingBatchSubmissionFixture.shareCount - 1)")
        secondQuestionProof.open()

        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus.isFailureState == true
        }

        let events = fixture.recorder.events()
        #expect(events.contains("commit:0:2"))
        // The proof was spent; the on-chain vote was not.
        #expect(!events.contains("submit:2"))
        // And the pipeline stops there rather than proving question 3 as well.
        #expect(!events.contains("commit:0:3"))

        let session = try #require(store.state.roundCache[roundId])
        #expect(Set(session.batchVoteErrors.keys) == [2])
        #expect(Set(session.votes.keys) == [1])
    }

    /// The post-proof check runs before the broadcast waits for the transaction guard, and the
    /// delivery it waits behind can be the one that empties the pool. The API re-checks the pool
    /// inside the guard right before the POST — the fixture's broadcast gate stands in for that
    /// wait — so a vote whose servers vanished while it queued is never broadcast.
    @Test func aVoteWhosePoolEmptiedWhileItsBroadcastWasQueuedIsNeverBroadcast() async throws {
        let fixture = VotingBatchSubmissionFixture(proposalCount: 3, bundleCount: 1)
        // Question 1's shares all land, but every helper drops out of the working set behind them.
        fixture.emptyServerPool(afterProposal: 1)
        let firstDelivery = fixture.gate(forProposal: 1)
        let secondBroadcast = fixture.broadcastGate(forProposal: 2)
        let store = makeStore(fixture)

        store.send(.authenticationSucceeded(roundId: roundId))

        // Question 2 is proved and its broadcast is parked, i.e. it passed the post-proof check
        // while the pool was still full; question 1's delivery has not pruned anything yet.
        await fixture.recorder.awaitEvent("broadcast:2")
        #expect(fixture.recorder.events().contains("commit:0:2"))

        // The delivery finishes and empties the pool while the broadcast waits its turn.
        firstDelivery.open()
        await fixture.recorder.awaitEvent("record:0:1:\(VotingBatchSubmissionFixture.shareCount - 1)")
        secondBroadcast.open()

        await fixture.waitForStoreState(store) { state in
            state.roundCache[self.roundId]?.batchSubmissionStatus.isFailureState == true
        }

        let events = fixture.recorder.events()
        #expect(!events.contains("submit:2"))
        #expect(!events.contains("commit:0:3"))

        let session = try #require(store.state.roundCache[roundId])
        #expect(Set(session.batchVoteErrors.keys) == [2])
        #expect(Set(session.votes.keys) == [1])
    }

    // MARK: - Helpers

    private func makeStore(_ fixture: VotingBatchSubmissionFixture) -> StoreOf<VotingCoordFlow> {
        Store(initialState: fixture.makeState()) {
            VotingCoordFlow()
        } withDependencies: {
            fixture.dependencies(&$0)
        }
    }

    /// The proposal ids one bundle committed, in the order it committed them.
    private static func committedProposals(in events: [String], bundle bundleIndex: UInt32) -> [UInt32] {
        events.compactMap { event in
            let parts = event.split(separator: ":")
            guard parts.count == 3, parts[0] == "commit", parts[1] == "\(bundleIndex)" else { return nil }
            return UInt32(parts[2])
        }
    }
}
#endif
