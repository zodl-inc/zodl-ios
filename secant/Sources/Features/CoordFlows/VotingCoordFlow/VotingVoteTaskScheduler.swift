#if VOTING_ENABLED
//
//  VotingVoteTaskScheduler.swift
//  Zashi
//

import Foundation

extension VotingCoordFlow {
    /// One bundle's vote for one question of the ballot: the unit the vote lanes schedule.
    struct VoteTask: Sendable {
        let bundleIndex: UInt32
        let work: VoteBundleWork
    }

    /// The ballot as the lanes consume it: question-major. For every question in ballot order,
    /// the bundles that still owe it, in ascending bundle order. Which `(bundle, question)` pairs
    /// exist is `plan.workByBundle`'s decision, so the skip rules for already-submitted bundles
    /// and synthetic abstains stay `planVoteBundleWork`'s, unchanged.
    static func orderedVoteTasks(from plan: VoteBundlePlan) -> [VoteTask] {
        var workByBundleAndProposal: [UInt32: [UInt32: VoteBundleWork]] = [:]
        for (bundleIndex, work) in plan.workByBundle {
            workByBundleAndProposal[bundleIndex] = Dictionary(
                work.map { ($0.proposalId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let bundles = plan.workByBundle.keys.sorted()
        var tasks: [VoteTask] = []
        for proposal in plan.proposals {
            for bundleIndex in bundles {
                guard let work = workByBundleAndProposal[bundleIndex]?[proposal.proposalId] else { continue }
                tasks.append(VoteTask(bundleIndex: bundleIndex, work: work))
            }
        }
        return tasks
    }
}

/// Hands the ballot's `(bundle, question)` tasks to the vote lanes question-major (MOB-1930).
///
/// The queue is ordered by question, then bundle. `next()` returns the first queued task whose
/// bundle is idle. A bundle's own votes therefore stay in ballot order and never overlap — its
/// next task is only ever its next question, and it is handed out only once the previous one was
/// `finish`ed — while, with three or more bundles, the lanes interleave bundles inside one
/// question before moving to the next. That is what makes a question fully cast roughly one
/// bundle-count of tasks after it was started, rather than when the last bundle finally gets a
/// lane. With one or two bundles each lane effectively owns a bundle, which is exactly the
/// bundle-major walk this replaces.
///
/// A lane whose every queued task belongs to a busy bundle parks in `next()` until a `finish`
/// makes one eligible, the queue is drained, or the lane's task is cancelled.
actor VotingVoteTaskScheduler {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<VotingCoordFlow.VoteTask?, Never>
    }

    private var queue: [VotingCoordFlow.VoteTask]
    private var busyBundles: Set<UInt32> = []
    private var waiters: [Waiter] = []

    init(tasks: [VotingCoordFlow.VoteTask]) {
        queue = tasks
    }

    /// The next task this lane may run, or `nil` once nothing is left to hand out — or when the
    /// caller was cancelled while parked, which the caller tells apart by `Task.isCancelled`.
    /// Marks the task's bundle busy; the caller must `finish` it whatever the outcome.
    func next() async -> VotingCoordFlow.VoteTask? {
        if let task = takeEligibleTask() {
            return task
        }
        guard !queue.isEmpty else {
            return nil
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<VotingCoordFlow.VoteTask?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// The bundle's task has returned — success or failure, its vote is recorded and its shares
    /// are enqueued, or it failed — so the bundle's next question may be handed out.
    func finish(bundleIndex: UInt32) {
        busyBundles.remove(bundleIndex)
        wakeWaiters()
    }

    /// Empties the queue and returns what was left, in order. Parked lanes resume with `nil`,
    /// and so does every later `next()`.
    func drainRemaining() -> [VotingCoordFlow.VoteTask] {
        let remaining = queue
        queue.removeAll()
        wakeWaiters()
        return remaining
    }

    private func takeEligibleTask() -> VotingCoordFlow.VoteTask? {
        guard let index = queue.firstIndex(where: { !busyBundles.contains($0.bundleIndex) }) else {
            return nil
        }
        let task = queue.remove(at: index)
        busyBundles.insert(task.bundleIndex)
        return task
    }

    /// Serves the parked lanes in arrival order: each gets a task while one is eligible; once
    /// the queue is empty they are all released with `nil`; otherwise they keep waiting.
    private func wakeWaiters() {
        while !waiters.isEmpty {
            if let task = takeEligibleTask() {
                let waiter = waiters.removeFirst()
                waiter.continuation.resume(returning: task)
            } else if queue.isEmpty {
                let waiter = waiters.removeFirst()
                waiter.continuation.resume(returning: nil)
            } else {
                return
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }
}
#endif
