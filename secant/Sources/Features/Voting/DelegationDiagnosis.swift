//
//  DelegationDiagnosis.swift
//  zodl
//
//  Classifies why a poll's local delegation state is unusable, from what can
//  be OBSERVED about that state rather than from the text of a database error.
//

import Foundation

/// What is wrong with a round's local delegation state, and therefore what the
/// voter should be told to do.
///
/// The raw value is a short code carried in the message, so a voter can read
/// it back to support and the state is identified without a log export.
enum DelegationDiagnosis: String, Equatable, Sendable, CaseIterable {
    /// Setup is incomplete and nothing was submitted for this round, confirmed
    /// against the voting service. Rebuilding locally loses nothing.
    case rebuildIsSafe = "POLL-01"

    /// Setup is incomplete but the delegation was already submitted. The
    /// secrets on this device are the only opening of a commitment the chain
    /// already holds, so a rebuild would strand it.
    case broadcastDoNotRebuild = "POLL-02"

    /// The secrets are gone from the database and recovery has them escrowed.
    /// Voting resumes once they are restored.
    case secretsRecovered = "POLL-03"

    /// The secrets are gone, recovery found nothing, and the delegation was
    /// submitted. This is the unrecoverable state.
    case secretsLost = "POLL-04"

    /// The voting service could not be reached, so whether a delegation was
    /// submitted is unknown. Nothing destructive may follow.
    ///
    /// This case exists because its absence caused the incident: an
    /// unreachable service was treated as "not delegated", which routed to the
    /// destructive rebuild.
    case undetermined = "POLL-05"

    /// What the voter is shown. Every message names the state, says whether
    /// re-entering the poll is safe, and carries the code.
    var message: String {
        switch self {
        case .rebuildIsSafe:
            return String(localizable: .coinVoteStoreUserErrorDelegationDiagnosisNotBroadcast)
        case .broadcastDoNotRebuild:
            return String(localizable: .coinVoteStoreUserErrorDelegationDiagnosisAlreadyBroadcast)
        case .secretsRecovered:
            return String(localizable: .coinVoteStoreUserErrorDelegationDiagnosisSecretsRecovered)
        case .secretsLost:
            return String(localizable: .coinVoteStoreUserErrorDelegationDiagnosisSecretsLost)
        case .undetermined:
            return String(localizable: .coinVoteStoreUserErrorDelegationDiagnosisUndetermined)
        }
    }

    /// Whether the app may discard local delegation state for this round.
    ///
    /// True for exactly one case, and only on POSITIVE evidence that nothing
    /// was submitted. Every uncertain state answers false, which is the
    /// inversion of the behaviour that caused the incident.
    var mayRebuildLocalState: Bool { self == .rebuildIsSafe }
}

extension DelegationDiagnosis {
    /// What the app can observe about one round's delegation state.
    struct Signals: Equatable, Sendable {
        /// A `van_comm_rand` is present in `bundles` for this round.
        let hasLocalSecret: Bool
        /// `delegation_tx_hash` is present, so this device recorded a
        /// broadcast. Absent does NOT prove nothing was broadcast: the hash is
        /// stored only after `submitDelegation` returns.
        let hasDelegationTxHash: Bool
        /// The escrow holds recovered secrets for this round.
        let escrowHoldsSecrets: Bool
        /// The voting service answered, so "no delegation recorded" can be
        /// trusted. False whenever the check failed OR was inconclusive.
        let voteServiceAnswered: Bool
    }

    /// Classifies the state, ordered so that a wrong answer fails safe.
    ///
    /// The checks run most-protective first, and `rebuildIsSafe` is reachable
    /// only from positive evidence: the service answered AND recorded no
    /// delegation AND the secrets are present. Every other combination lands
    /// somewhere that forbids the destructive path.
    static func diagnose(_ signals: Signals) -> DelegationDiagnosis {
        // Recovery already rescued them; restoring is the next step, and
        // rebuilding would overwrite what was just saved.
        if signals.escrowHoldsSecrets && !signals.hasLocalSecret {
            return .secretsRecovered
        }

        // Gone locally, nothing escrowed. Only call it lost when there is
        // evidence something was actually submitted; otherwise the round was
        // simply never set up, which is not an error state.
        if !signals.hasLocalSecret && signals.hasDelegationTxHash {
            return .secretsLost
        }

        // The secret is here and a broadcast is recorded, so the round can be
        // resumed but never rebuilt.
        if signals.hasDelegationTxHash {
            return .broadcastDoNotRebuild
        }

        // No local record of a broadcast, and no way to confirm that with the
        // service. Absence of the hash is not evidence of absence of a
        // broadcast, so this must not fall through to the safe case.
        if !signals.voteServiceAnswered {
            return .undetermined
        }

        return .rebuildIsSafe
    }
}
