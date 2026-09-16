#if VOTING_ENABLED
//
//  VotingVoteTaskSchedulerTests.swift
//  zodlTests
//
//  The question-major scheduler behind the vote lanes (MOB-1930): tasks come out ordered by
//  question, then bundle; a bundle never has two tasks out at once; a lane with nothing eligible
//  parks until a bundle is freed; draining releases everything that is left.
//

import Foundation
import os
import Testing
@testable import zodl_internal

@Suite
struct VotingVoteTaskSchedulerTests {
    // MARK: - Ordering

    @Test func tasksAreOrderedByQuestionThenBundle() {
        let plan = Self.plan(proposals: [1, 2], bundles: 3)

        let tasks = VotingCoordFlow.orderedVoteTasks(from: plan)

        #expect(Self.labels(tasks) == ["b0:q1", "b1:q1", "b2:q1", "b0:q2", "b1:q2", "b2:q2"])
    }

    @Test func aBundleThatAlreadyCastAQuestionOwesNoTaskForIt() {
        // Bundle 1 already has questions 1 and 3 on chain with their shares recorded, so
        // `planVoteBundleWork` left them out of its list.
        let plan = Self.plan(
            proposals: [1, 2, 3],
            bundles: 2,
            skipping: [
                Self.BundleProposal(bundle: 1, proposal: 1),
                Self.BundleProposal(bundle: 1, proposal: 3)
            ]
        )

        let tasks = VotingCoordFlow.orderedVoteTasks(from: plan)

        #expect(Self.labels(tasks) == ["b0:q1", "b0:q2", "b1:q2", "b0:q3"])
    }

    @Test func aQuestionWithoutBundleWorkProducesNoTask() {
        // A synthetic abstain carries no on-chain work: it is in the ballot but in no bundle's list.
        var plan = Self.plan(proposals: [1, 3], bundles: 1)
        plan = VotingCoordFlow.VoteBundlePlan(
            workByBundle: plan.workByBundle,
            proposals: [
                plan.proposals[0],
                VotingCoordFlow.VoteProposalPlan(proposalId: 2, choice: VoteChoice.option(0), bundleTaskCount: 0),
                plan.proposals[1]
            ]
        )

        let tasks = VotingCoordFlow.orderedVoteTasks(from: plan)

        #expect(Self.labels(tasks) == ["b0:q1", "b0:q3"])
    }

    // MARK: - Handing out

    @Test func aBusyBundlesNextQuestionIsSkippedInFavourOfAnIdleBundle() async {
        let scheduler = VotingVoteTaskScheduler(tasks: Self.tasks(["b0:q1", "b1:q1", "b0:q2", "b1:q2"]))

        let first = await scheduler.next()
        let second = await scheduler.next()
        #expect(Self.label(first) == "b0:q1")
        #expect(Self.label(second) == "b1:q1")

        // Bundle 1 finished first: its next question is eligible, bundle 0's is not.
        await scheduler.finish(bundleIndex: 1)
        let third = await scheduler.next()
        #expect(Self.label(third) == "b1:q2")
    }

    @Test func threeBundlesFinishAQuestionBeforeAnyBundleStartsTheNext() async {
        let scheduler = VotingVoteTaskScheduler(
            tasks: Self.tasks(["b0:q1", "b1:q1", "b2:q1", "b0:q2", "b1:q2", "b2:q2"])
        )

        // Lane A and lane B take the first two; lane A finishes and asks again.
        let laneA = await scheduler.next()
        let laneB = await scheduler.next()
        #expect(Self.label(laneA) == "b0:q1")
        #expect(Self.label(laneB) == "b1:q1")
        await scheduler.finish(bundleIndex: 0)

        // Question 1 is not done — bundle 2 has not cast it — so lane A gets that, not bundle 0's question 2.
        let laneAAgain = await scheduler.next()
        #expect(Self.label(laneAAgain) == "b2:q1")

        await scheduler.finish(bundleIndex: 1)
        let laneBAgain = await scheduler.next()
        #expect(Self.label(laneBAgain) == "b0:q2")
    }

    @Test func aLaneParksWhenOnlyBusyBundlesRemainAndWakesWhenOneIsFreed() async {
        let scheduler = VotingVoteTaskScheduler(tasks: Self.tasks(["b0:q1", "b0:q2"]))
        let probe = Self.Probe()
        let first = await scheduler.next()
        #expect(Self.label(first) == "b0:q1")

        let parked = Task {
            let task = await scheduler.next()
            probe.record(Self.label(task) ?? "nil")
            return task
        }
        await Self.settle()
        // Bundle 0 is still busy, so the lane must still be parked — nothing recorded yet.
        #expect(probe.events() == [])

        await scheduler.finish(bundleIndex: 0)
        let second = await parked.value
        #expect(Self.label(second) == "b0:q2")
        #expect(probe.events() == ["b0:q2"])
    }

    @Test func twoParkedLanesOnlyTheFirstWakesOnAFinishTheSecondWakesOnDrain() async {
        let scheduler = VotingVoteTaskScheduler(tasks: Self.tasks(["b0:q1", "b1:q1", "b0:q2", "b1:q2"]))
        let probe = Self.Probe()

        let firstHandOut = await scheduler.next()
        let secondHandOut = await scheduler.next()
        #expect(Self.label(firstHandOut) == "b0:q1")
        #expect(Self.label(secondHandOut) == "b1:q1")

        let parkedA = Task {
            let task = await scheduler.next()
            probe.record(Self.label(task) ?? "nil")
            return task
        }
        let parkedB = Task {
            let task = await scheduler.next()
            probe.record(Self.label(task) ?? "nil")
            return task
        }
        await Self.settle()
        // Both bundles are busy, so both lanes must still be parked — nothing recorded yet.
        #expect(probe.events() == [])

        await scheduler.finish(bundleIndex: 0)
        await Self.settle()
        // Only bundle 0 was freed: exactly one of the two waiters may be woken, the other stays parked.
        #expect(probe.events() == ["b0:q2"])

        let remaining = await scheduler.drainRemaining()
        #expect(Self.labels(remaining) == ["b1:q2"])

        // Identity between parkedA/parkedB and which woke first is a race; the probe already
        // pinned the order (one real task, then one nil), so just confirm both lanes settled
        // to that same pair of outcomes.
        let outcomes = Set([Self.label(await parkedA.value) ?? "nil", Self.label(await parkedB.value) ?? "nil"])
        #expect(outcomes == Set(["b0:q2", "nil"]))
        #expect(probe.events() == ["b0:q2", "nil"])
    }

    @Test func aSingleBundleComesOutOneQuestionAtATimeInBallotOrder() async {
        let scheduler = VotingVoteTaskScheduler(tasks: Self.tasks(["b0:q1", "b0:q2", "b0:q3"]))
        var order: [String] = []

        for _ in 0..<3 {
            guard let task = await scheduler.next() else { break }
            order.append(Self.label(task) ?? "nil")
            await scheduler.finish(bundleIndex: task.bundleIndex)
        }

        #expect(order == ["b0:q1", "b0:q2", "b0:q3"])
        let afterwards = await scheduler.next()
        #expect(afterwards == nil)
    }

    @Test func nextReturnsNilOnceEveryTaskWasHandedOutEvenWhileBundlesAreBusy() async {
        let scheduler = VotingVoteTaskScheduler(tasks: Self.tasks(["b0:q1"]))

        let first = await scheduler.next()
        let second = await scheduler.next()

        #expect(Self.label(first) == "b0:q1")
        #expect(second == nil)
    }

    // MARK: - Draining and cancellation

    @Test func drainingReturnsTheRestInOrderAndReleasesParkedLanesWithNil() async {
        let scheduler = VotingVoteTaskScheduler(tasks: Self.tasks(["b0:q1", "b0:q2", "b0:q3"]))
        let probe = Self.Probe()
        _ = await scheduler.next()
        let parked = Task {
            let task = await scheduler.next()
            probe.record(Self.label(task) ?? "nil")
            return task
        }
        await Self.settle()
        #expect(probe.events() == [])

        let remaining = await scheduler.drainRemaining()

        #expect(Self.labels(remaining) == ["b0:q2", "b0:q3"])
        let released = await parked.value
        #expect(released == nil)
        let afterwards = await scheduler.next()
        #expect(afterwards == nil)
    }

    @Test func aCancelledParkedLaneReturnsNilAndLeavesItsTaskQueued() async {
        let scheduler = VotingVoteTaskScheduler(tasks: Self.tasks(["b0:q1", "b0:q2"]))
        _ = await scheduler.next()
        let parked = Task { await scheduler.next() }
        await Self.settle()

        parked.cancel()
        let cancelled = await parked.value
        #expect(cancelled == nil)

        // The task it was waiting for is still there for the next lane.
        await scheduler.finish(bundleIndex: 0)
        let next = await scheduler.next()
        #expect(Self.label(next) == "b0:q2")
    }

    // MARK: - Helpers

    struct BundleProposal: Hashable {
        let bundle: UInt32
        let proposal: UInt32
    }

    /// Thread-safe event list for the parked-lane tests.
    final class Probe: Sendable {
        private let storage = OSAllocatedUnfairLock<[String]>(initialState: [])

        func record(_ event: String) {
            storage.withLock { $0.append(event) }
        }

        func events() -> [String] {
            storage.withLock { $0 }
        }
    }

    /// Gives a parked task every chance to run to its suspension point (or, if the scheduler is
    /// wrong, to completion) before the test looks at the probe.
    private static func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    /// A plan in which every listed bundle owes every listed proposal, minus `skipping`.
    private static func plan(
        proposals: [UInt32],
        bundles: UInt32,
        skipping: Set<BundleProposal> = []
    ) -> VotingCoordFlow.VoteBundlePlan {
        var workByBundle: [UInt32: [VotingCoordFlow.VoteBundleWork]] = [:]
        var proposalPlans: [VotingCoordFlow.VoteProposalPlan] = []
        for proposalId in proposals {
            var pending = 0
            for bundleIndex in 0..<bundles where !skipping.contains(BundleProposal(bundle: bundleIndex, proposal: proposalId)) {
                workByBundle[bundleIndex, default: []].append(
                    VotingCoordFlow.VoteBundleWork(proposalId: proposalId, choice: VoteChoice.option(0), numOptions: 3)
                )
                pending += 1
            }
            proposalPlans.append(
                VotingCoordFlow.VoteProposalPlan(proposalId: proposalId, choice: VoteChoice.option(0), bundleTaskCount: pending)
            )
        }
        return VotingCoordFlow.VoteBundlePlan(workByBundle: workByBundle, proposals: proposalPlans)
    }

    /// `"b<bundle>:q<proposal>"` labels into tasks, in the given order.
    private static func tasks(_ labels: [String]) -> [VotingCoordFlow.VoteTask] {
        labels.map { label in
            let parts = label.split(separator: ":")
            let bundleIndex = UInt32(parts[0].dropFirst()) ?? 0
            let proposalId = UInt32(parts[1].dropFirst()) ?? 0
            return VotingCoordFlow.VoteTask(
                bundleIndex: bundleIndex,
                work: VotingCoordFlow.VoteBundleWork(proposalId: proposalId, choice: VoteChoice.option(0), numOptions: 3)
            )
        }
    }

    private static func label(_ task: VotingCoordFlow.VoteTask?) -> String? {
        task.map { "b\($0.bundleIndex):q\($0.work.proposalId)" }
    }

    private static func labels(_ tasks: [VotingCoordFlow.VoteTask]) -> [String] {
        tasks.compactMap { label($0) }
    }
}
#endif
