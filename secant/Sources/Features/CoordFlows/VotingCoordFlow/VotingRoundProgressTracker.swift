#if VOTING_ENABLED
//
//  VotingRoundProgressTracker.swift
//  Zashi
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// How far a round's submission has got, measured the way the Android app
/// measures it, so both platforms show a voter the same count and bar.
///
/// The crate reports proving per bundle and per question, at fixed points, and
/// its own tally moves only when a vote is confirmed on chain. This folds the
/// proving reports into an estimate that moves question by question:
///
/// - A vote proof names the question it is proving, so every question gets its
///   own progress on every bundle that carries it.
/// - A question's credit is its slowest reporting bundle's progress, scaled by
///   the share of the bundles that must carry it which have reported, capped at
///   one. The bundles that must carry it are the latest plan's vote-carrying
///   bundles together with every bundle seen reporting.
/// - A delegation proof belongs to a bundle, not a question. It is credited per
///   bundle at ``delegationPhaseWeight``, over at least as many units as there
///   are bundles, and dropped once that bundle starts casting, so delegation
///   alone can never fill the bar or count a question as done.
/// - Nothing moves backwards: per-bundle progress, the bar and the count only
///   hold or climb.
struct VotingRoundProgressTracker: Equatable, Sendable {
    /// What one progress report belongs to.
    enum Step: Equatable, Sendable {
        /// A delegation step: a bundle, and no question.
        case delegation(bundleIndex: UInt32)
        /// A step that belongs to one question on one bundle.
        case proposal(bundleIndex: UInt32, proposalId: UInt32)
        /// A step kind this app does not name. It is only ever credited to the
        /// question a vote proof names.
        case unrecognised(bundleIndex: UInt32)
    }

    /// How much a bundle's whole delegation counts for, next to casting.
    static let delegationPhaseWeight = 0.5

    /// Absorbs rounding error before the count is truncated, so a question that
    /// is fully measured is never counted one short.
    static let proposalEstimateEpsilon = 0.0001

    private var bundleProgressByProposal: [UInt32: [UInt32: Double]] = [:]
    private var delegationProgressByBundle: [UInt32: Double] = [:]
    private var planVoteCarryingBundleIndexes: Set<UInt32> = []
    private var lastFraction = 0.0
    private var lastProposalFraction = 0.0
    private var lastEstimatedCompleted: UInt32 = 0

    /// Records one step's proving progress.
    ///
    /// `voteCommitProposalId` is the question a vote proof names. It moves from
    /// question to question while one cast step proves a whole bundle's ballot,
    /// so it wins over the question the step itself was selected with. A report
    /// with no step or no progress records nothing.
    mutating func record(step: Step?, proofProgress: Double?, voteCommitProposalId: UInt32? = nil) {
        guard let step, let proofProgress else { return }
        switch step {
        case let .delegation(bundleIndex):
            delegationProgressByBundle[bundleIndex] = max(delegationProgressByBundle[bundleIndex] ?? 0, proofProgress)
        case let .proposal(bundleIndex, proposalId):
            recordProposal(voteCommitProposalId ?? proposalId, bundleIndex: bundleIndex, proofProgress: proofProgress)
        case let .unrecognised(bundleIndex):
            guard let voteCommitProposalId else { return }
            recordProposal(voteCommitProposalId, bundleIndex: bundleIndex, proofProgress: proofProgress)
        }
    }

    /// Replaces the latest plan's vote-carrying bundles.
    ///
    /// `nil` means the event carried no plan and changes nothing; an empty list
    /// is a real answer and replaces what was there. A bundle that finished and
    /// left the plan still counts, because it is also among the bundles seen
    /// reporting.
    mutating func recordPlan(voteCarryingBundleIndexes: [UInt32]?) {
        guard let voteCarryingBundleIndexes else { return }
        planVoteCarryingBundleIndexes = Set(voteCarryingBundleIndexes)
    }

    /// The bar's share of the round, in `0...1`, or nil while nothing is
    /// measured. Never lower than an earlier answer.
    mutating func fraction(completedProposals: UInt32?, totalProposals: UInt32?) -> Double? {
        guard let total = totalProposals, total > 0 else { return nil }
        let combined = proposalCompletionFraction(completedProposals: completedProposals, total: total)
            + delegationFraction(total: total)
        lastFraction = max(lastFraction, min(max(combined, 0), 1))
        return lastFraction > 0 ? lastFraction : nil
    }

    /// How many questions are done, estimated from proving rather than from the
    /// tally alone, or nil while nothing is measured.
    ///
    /// Never below the tally, never the total until the tally reaches it, and
    /// never lower than an earlier answer. Delegation never moves it.
    mutating func estimatedCompletedProposals(completedProposals: UInt32?, totalProposals: UInt32?) -> UInt32? {
        guard let total = totalProposals, total > 0 else { return nil }
        let authoritative = min(completedProposals ?? 0, total)
        if authoritative >= total {
            lastEstimatedCompleted = total
            return total
        }
        lastProposalFraction = max(
            lastProposalFraction,
            proposalCompletionFraction(completedProposals: completedProposals, total: total)
        )
        guard lastProposalFraction > 0 else { return nil }
        let measured = Int(lastProposalFraction * Double(total) + Self.proposalEstimateEpsilon)
        let estimate = UInt32(min(max(measured, 0), Int(total) - 1))
        lastEstimatedCompleted = max(lastEstimatedCompleted, max(estimate, authoritative))
        return lastEstimatedCompleted
    }

    private mutating func recordProposal(_ proposalId: UInt32, bundleIndex: UInt32, proofProgress: Double) {
        var bundleProgress = bundleProgressByProposal[proposalId] ?? [:]
        bundleProgress[bundleIndex] = max(bundleProgress[bundleIndex] ?? 0, proofProgress)
        bundleProgressByProposal[proposalId] = bundleProgress
    }

    /// Every bundle that has reported progress on any question.
    private var observedBundleIndexes: Set<UInt32> {
        Set(bundleProgressByProposal.values.flatMap(\.keys))
    }

    /// The measured share of the round, or the tally's, whichever is further.
    private func proposalCompletionFraction(completedProposals: UInt32?, total: UInt32) -> Double {
        let tallyFraction = Double(completedProposals ?? 0) / Double(total)
        let requiredBundles = planVoteCarryingBundleIndexes.union(observedBundleIndexes).count
        var fractionSum = 0.0
        if requiredBundles > 0 {
            for proposalId in bundleProgressByProposal.keys.sorted() {
                let bundleProgress = bundleProgressByProposal[proposalId] ?? [:]
                let minProgress = bundleProgress.values.min() ?? 0
                fractionSum += min(minProgress * Double(bundleProgress.count) / Double(requiredBundles), 1)
            }
        }
        return max(fractionSum / Double(total), tallyFraction)
    }

    /// Delegation's weighted share: bundles that are still only delegating,
    /// over at least as many units as there are bundles in play.
    private func delegationFraction(total: UInt32) -> Double {
        let castingBundleIndexes = observedBundleIndexes
        let delegationFractionSum = delegationProgressByBundle
            .sorted { $0.key < $1.key }
            .filter { !castingBundleIndexes.contains($0.key) }
            .reduce(0) { $0 + $1.value }
        let bundleCountFloor = delegationProgressByBundle.count + castingBundleIndexes.count
        return delegationFractionSum / Double(max(Int(total), bundleCountFloor)) * Self.delegationPhaseWeight
    }
}

extension VotingRoundProgressTracker.Step {
    /// The tracker's view of a step the crate named.
    init(_ step: VotingNextStep) {
        switch step.kind {
        case .delegate, .advanceDelegation, .advanceImportedDelegation:
            self = .delegation(bundleIndex: step.bundleIndex)
        case .castVote, .advanceVote, .advanceVoteBatch, .submitShares, .confirmShare:
            self = .proposal(bundleIndex: step.bundleIndex, proposalId: step.proposalId)
        case .unknown:
            self = .unrecognised(bundleIndex: step.bundleIndex)
        }
    }
}

/// One submission's progress as the Confirm screen shows it.
///
/// Holds what the Android app's submission use case holds beside its tracker:
/// the crate's tally as a ratchet, the tracker itself, and the values the
/// screen reads, recomputed once per drive event. It lives for one submission
/// the voter started, across the automatic re-runs the flow schedules on its
/// own, so a re-run never sends the bar back.
struct VotingSubmissionProgress: Equatable, Sendable {
    /// The step kinds that make a bundle carry vote work in a plan.
    static let voteCarryingStepKinds: Set<VotingNextStepKind> = [
        VotingNextStepKind.castVote,
        VotingNextStepKind.advanceVote,
        VotingNextStepKind.advanceVoteBatch,
        VotingNextStepKind.submitShares
    ]

    private(set) var tracker = VotingRoundProgressTracker()
    /// The highest completed count any run of this submission reported.
    private(set) var completedProposals: UInt32?
    /// The highest total any run of this submission reported.
    private(set) var totalProposals: UInt32?
    /// Questions estimated done; nil while nothing is measured.
    private(set) var estimatedCompletedProposals: UInt32?
    /// The bar's measured share of the round; nil while nothing is measured.
    private(set) var fraction: Double?
    /// True while the flow waits to run the round again after a stop it
    /// retries on its own. The next drive event clears it.
    var isRetrying = false

    /// Folds one drive event in, in the order the Android app does: the tally,
    /// the step's proving, the plan, then the values the screen reads.
    mutating func apply(_ event: VotingRoundDriveEvent) {
        if let tally = event.tally {
            completedProposals = max(completedProposals ?? 0, tally.completedProposals)
            totalProposals = max(totalProposals ?? 0, tally.totalProposals)
        }
        tracker.record(
            step: event.step.map { VotingRoundProgressTracker.Step($0) },
            proofProgress: event.progress?.proofProgress,
            voteCommitProposalId: event.progress?.proposalId
        )
        tracker.recordPlan(voteCarryingBundleIndexes: event.plan.map { Self.voteCarryingBundleIndexes(in: $0) })
        estimatedCompletedProposals = tracker.estimatedCompletedProposals(
            completedProposals: completedProposals,
            totalProposals: totalProposals
        )
        fraction = tracker.fraction(completedProposals: completedProposals, totalProposals: totalProposals)
        isRetrying = false
    }

    /// The bundles `plan` still owes vote work for, ascending: the bundles of
    /// its vote-family steps and every bundle its recovered vote work names,
    /// the Android app's rule. The second list is not redundant: a vote whose
    /// blocking helper share is being recovered owes a `confirm_share` step,
    /// which is not a vote-family kind, and is listed there as share work.
    static func voteCarryingBundleIndexes(in plan: VotingRoundPlan) -> [UInt32] {
        let stepBundles = plan.nextSteps.filter { voteCarryingStepKinds.contains($0.kind) }.map(\.bundleIndex)
        let recoveredBundles = plan.recoveredVoteWork.map(\.bundleIndex)
        return Set(stepBundles + recoveredBundles).sorted()
    }
}
#endif
