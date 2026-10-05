#if VOTING_ENABLED
//
//  VotingRoundProgress.swift
//  Zashi
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// What one run has told the flow about itself, folded from its event stream:
/// the crate's own work tally, which the failure states quote, and the last
/// failure worth naming.
///
/// Per run, where ``VotingSubmissionProgress`` is per submission: a run's
/// report replaces this tally when the run stops. The Confirm screen's bar and
/// count come from ``VotingSubmissionProgress``, not from here.
struct VotingRoundProgressSnapshot: Equatable, Sendable {
    var completedProposals: UInt32 = 0
    var totalProposals: UInt32 = 0
    /// The last thing worth telling the voter: a failure, or a skipped bundle.
    var lastMessage: String?
}

extension VotingRoundProgressSnapshot {
    /// Folds one driver event into the snapshot.
    mutating func apply(_ event: VotingRoundDriveEvent) {
        switch event.kind {
        case .planRefreshed:
            // The tally is the run's own count of the voter's selected choices,
            // so it replaces the snapshot's counts rather than accumulating.
            guard let tally = event.tally else { return }
            completedProposals = tally.completedProposals
            totalProposals = tally.totalProposals
        case .stepFailed:
            lastMessage = event.message
        case .bundleSkipped:
            // The crate sends no message with this kind — the bundle index is
            // the whole of what it says — so name the bundle rather than
            // clearing the failure message that preceded it with nothing.
            lastMessage = event.message ?? Self.skippedBundleMessage(event.bundleIndex)
        case .stepSelected, .stepProgress, .stepFinished, .awaitingRepoll, .unknown:
            break
        }
    }

    private static func skippedBundleMessage(_ bundleIndex: UInt32?) -> String {
        guard let bundleIndex else { return "a bundle was skipped" }
        return "bundle \(bundleIndex) skipped"
    }
}
#endif
