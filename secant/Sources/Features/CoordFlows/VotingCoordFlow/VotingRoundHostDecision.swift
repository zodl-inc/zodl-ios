#if VOTING_ENABLED
//
//  VotingRoundHostDecision.swift
//  Zashi
//

import Foundation
@preconcurrency import ZODLSwiftWalletSDK

/// What the host owes a round once one run of the driver has stopped.
///
/// A run always ends in a quiescence — the crate's word for "nothing more can
/// happen without you" — and each one names work only the host can do: show a
/// ballot, collect a signature, wait out a backoff, or give up. This is that
/// translation and nothing else. It touches no state and does no I/O, so the
/// coordinator's reaction to a run can be tested without opening a session.
enum VotingRoundHostDecision: Equatable, Sendable {
    /// The round holds a ballot choice but no bundle rows yet: persist the
    /// bundle plan, then run again.
    case runBundleSetupThenRerun
    /// Nothing can be planned until the voter decides. `unrosteredIntents` are
    /// durable intents for proposals outside the authenticated roster, which
    /// the host must clear before they can be cast.
    case waitForBallot(openProposals: [UInt32], unrosteredIntents: [UInt32])
    /// These bundles still need the voter's signing material.
    case collectSignatures(bundles: [UInt32])
    /// Only helper-share confirmation is left, and it is not blocking: hand it
    /// to the background tracking timer rather than holding the flow open.
    case startShareTracking
    case completed
    case cancelled
    /// A submission ended without a confirmation and no further work will be
    /// planned for it. Terminal: re-running the round will not retry it.
    case chainTerminal(message: String)
    case retryLater(seconds: Double)
    /// Every failure the run recorded is one a later run clears on its own --
    /// the network, a busy store -- and the crate isolated each to its bundle,
    /// so running the round again redoes only those bundles. `message` is the
    /// first failure's, for when the re-runs run out.
    case rerunFailedBundles(message: String, seconds: Double)
    case failed(message: String, retryable: Bool)

    /// The host's next move for one run's report.
    ///
    /// The report is authoritative — the live event stream may drop events —
    /// so this reads the report alone.
    // One branch per quiescence the crate can stop in, exhaustively: the
    // compiler must fail this switch when the SDK names a new one.
    // swiftlint:disable:next cyclomatic_complexity
    static func decide(_ report: VotingRoundRunReport) -> VotingRoundHostDecision {
        let quiescence = report.quiescence

        switch quiescence.kind {
        case .noWorkLeft:
            return VotingRoundHostDecision.completed
        case .needsBundleSetup:
            return VotingRoundHostDecision.runBundleSetupThenRerun
        case .needsBallot:
            return VotingRoundHostDecision.waitForBallot(
                openProposals: quiescence.openProposals,
                unrosteredIntents: quiescence.unrosteredIntents
            )
        case .needsDelegationSignatures:
            return VotingRoundHostDecision.collectSignatures(bundles: quiescence.bundles)
        case .backgroundShareWorkOnly:
            return VotingRoundHostDecision.startShareTracking
        case .cancelled:
            return VotingRoundHostDecision.cancelled
        case .persistedChainTerminal, .chainTerminal:
            return VotingRoundHostDecision.chainTerminal(message: Self.chainTerminalMessage(quiescence.chainOutcome))
        case .chainRecoveryStalled:
            // Recovery stalled on a submission that may still confirm: a long
            // wait, because nothing the host does makes it land sooner.
            return VotingRoundHostDecision.retryLater(seconds: Self.recoveryStalledDelay)
        case .passBudgetExhausted:
            // The run hit its own pass ceiling with work still to do, so the
            // next run picks up immediately where this one left off.
            return VotingRoundHostDecision.retryLater(seconds: Self.passBudgetDelay)
        case .failures:
            return Self.failedDecision(report.failures)
        case .unknown:
            // An SDK too old to name this quiescence cannot know whether
            // retrying is safe, so it does not.
            return VotingRoundHostDecision.failed(message: "unknown quiescence", retryable: false)
        }
    }

    // MARK: - Mapping detail

    private static let recoveryStalledDelay: Double = 30
    private static let passBudgetDelay: Double = 2
    private static let failedBundlesRerunDelay: Double = 2

    /// Failure kinds a later run clears on its own, the Android app's set: the
    /// network, or a store another pass is holding. Never a wrong request or a
    /// failed proof, which fail the same way every time.
    private static let rerunnableFailureKinds: Set<VotingRoundStepFailureKind> = [
        VotingRoundStepFailureKind.transport,
        VotingRoundStepFailureKind.busy
    ]
    private static let chainTerminalFallback = "submission ended without confirmation"

    /// Failure kinds worth another run: a transient environment rather than a
    /// wrong request. Everything else — bad input, a failed proof, an ended
    /// vote — fails the same way every time.
    private static let retryableFailureKinds: Set<VotingRoundStepFailureKind> = [
        VotingRoundStepFailureKind.transport,
        VotingRoundStepFailureKind.busy,
        VotingRoundStepFailureKind.protocol,
        VotingRoundStepFailureKind.storage
    ]

    /// The first failure a run recorded is the one that explains the rest:
    /// later ones are usually the same cause reported for another bundle. When
    /// every failure is one a later run clears on its own, the round is run
    /// again instead of failing.
    private static func failedDecision(_ failures: [VotingRoundStepFailureRecord]) -> VotingRoundHostDecision {
        guard let failure = failures.first?.failure else {
            return VotingRoundHostDecision.failed(message: "voting failed", retryable: false)
        }
        if failures.allSatisfy({ Self.rerunnableFailureKinds.contains($0.failure.kind) }) {
            return VotingRoundHostDecision.rerunFailedBundles(
                message: failure.message,
                seconds: Self.failedBundlesRerunDelay
            )
        }
        return VotingRoundHostDecision.failed(
            message: failure.message,
            retryable: Self.retryableFailureKinds.contains(failure.kind)
        )
    }

    /// What a terminal submission is shown as.
    ///
    /// The outcome kind leads, because it is the part that changes what the
    /// voter can do — a rejection is not a lost transaction hash — and the
    /// crate's bounded, redacted diagnostic follows when it sent one.
    private static func chainTerminalMessage(_ outcome: VotingChainSubmissionOutcome?) -> String {
        guard let outcome else { return Self.chainTerminalFallback }
        return "\(outcome.kind.rawValue): \(outcome.diagnosticMessage ?? Self.chainTerminalFallback)"
    }
}
#endif
