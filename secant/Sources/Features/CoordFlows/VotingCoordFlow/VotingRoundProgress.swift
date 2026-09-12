#if VOTING_ENABLED
//
//  VotingRoundProgress.swift
//  Zashi
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// The coarse phase of a round run, at the granularity the UI shows.
///
/// Deliberately coarser than the driver's steps: a run overlaps bundles, so a
/// finer stage would flicker between them without telling the voter anything.
enum VotingRoundProgressStage: Equatable, Sendable {
    case idle
    case proving
    case submitting
    case confirming
    case deliveringShares
    case done
}

/// What a round run has done so far, folded from its live event stream.
///
/// The stream is lossy by design — the SDK drops events under load and the
/// run's report is the authoritative record — so every rule here folds into
/// whatever the snapshot already holds. Nothing reads back out of it to decide
/// what to do next; that is ``VotingRoundHostDecision``'s job, from the report.
struct VotingRoundProgressSnapshot: Equatable, Sendable {
    var completedProposals: UInt32 = 0
    var totalProposals: UInt32 = 0
    /// The bundle the run last reported work for. Nil until one is named.
    var activeBundleIndex: UInt32?
    /// Proving progress in `0...1` for `activeBundleIndex`, when proving
    /// reported one.
    var proofFraction: Double?
    var stage: VotingRoundProgressStage = .idle
    /// The last thing worth telling the voter: a failure, or a skipped bundle.
    var lastMessage: String?
}

extension VotingRoundProgressSnapshot {
    /// Folds one driver event into the snapshot.
    mutating func apply(_ event: VotingRoundDriveEvent) {
        switch event.kind {
        case .planRefreshed:
            // The tally is the run's own count of what it started owing, so it
            // replaces the snapshot's counts rather than accumulating.
            guard let tally = event.tally else { return }
            completedProposals = tally.completedProposals
            totalProposals = tally.totalProposals
        case .stepProgress:
            guard let progress = event.progress else { return }
            apply(stepProgress: progress)
        case .stepFailed:
            lastMessage = event.message
        case .bundleSkipped:
            // The crate sends no message with this kind — the bundle index is
            // the whole of what it says — so name the bundle rather than
            // clearing the failure message that preceded it with nothing.
            lastMessage = event.message ?? Self.skippedBundleMessage(event.bundleIndex)
        case .stepSelected, .stepFinished, .awaitingRepoll, .unknown:
            // A repoll is a wait inside the stage the run is already in, and
            // selecting or finishing a step says nothing the progress events
            // for that step do not say better.
            break
        }
    }

    /// Folds one delegation-pipeline observation into the snapshot.
    ///
    /// These arrive on the session's own stream rather than inside a run, so
    /// they are the only progress a standalone precompute reports.
    mutating func apply(_ progress: VotingDelegationProgress) {
        activeBundleIndex = progress.bundleIndex
        guard progress.stage == VotingDelegationProgressKind.proofProgress else { return }
        stage = VotingRoundProgressStage.proving
        proofFraction = progress.fraction
    }

    private mutating func apply(stepProgress: VotingRoundStepProgress) {
        switch stepProgress.kind {
        case .delegation:
            stage = VotingRoundProgressStage.proving
            proofFraction = stepProgress.proofProgress
            activeBundleIndex = stepProgress.bundleIndex
        case .voteCommit:
            stage = VotingRoundProgressStage.proving
        case .delegateAndVoteBatchPersisted, .helperPlansPrepared:
            stage = VotingRoundProgressStage.submitting
        case .chainOutcome:
            stage = VotingRoundProgressStage.confirming
        case .shareOutcome, .shareConfirmed:
            stage = VotingRoundProgressStage.deliveringShares
        case .selected, .treeSynced, .unknown:
            break
        }
    }

    private static func skippedBundleMessage(_ bundleIndex: UInt32?) -> String {
        guard let bundleIndex else { return "a bundle was skipped" }
        return "bundle \(bundleIndex) skipped"
    }
}
#endif
