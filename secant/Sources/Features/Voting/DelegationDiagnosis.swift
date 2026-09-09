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

    /// The commitment the chain holds for this delegation is in the device's
    /// preserved files, but the record around it was overwritten, so neither
    /// recovery nor a rebuild can restore it. Support can attempt a manual
    /// recovery from the preserved copy; the app cannot.
    case commitmentUndecodable = "POLL-06"

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
        case .commitmentUndecodable:
            return String(localizable: .coinVoteStoreUserErrorDelegationDiagnosisCommitmentUndecodable)
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
        /// The round has bundle rows at all.
        ///
        /// Named for what it measures. It is NOT "the broadcast secret is
        /// present": after a wipe the round is REBUILT, so rows exist while
        /// the original secret is gone. Reading it as secret-presence is what
        /// made a recovered user read as `broadcastDoNotRebuild` instead of
        /// `secretsRecovered` -- protective, but wrong, and misleading to
        /// whoever they showed it to.
        let roundHasBundles: Bool
        /// The escrow holds an entry this round's recovery CARVED, as opposed
        /// to one the ordinary live capture stored.
        ///
        /// This is the loss signal. Recovery escrows only where it found a
        /// replacement for a secret the live copy no longer holds, so a
        /// `.recovered` entry is evidence the round was cleared and rebuilt.
        let escrowHoldsRecoveredSecrets: Bool
        /// `delegation_tx_hash` is present, so this device recorded a
        /// broadcast. Absent does NOT prove nothing was broadcast: the hash is
        /// stored only after `submitDelegation` returns.
        let hasDelegationTxHash: Bool
        /// The voting service answered, so "no delegation recorded" can be
        /// trusted. False whenever the check failed OR was inconclusive.
        let voteServiceAnswered: Bool
        /// A targeted scan found the chain's commitment in the preserved
        /// bytes with no decodable record around it. False until a
        /// root-validated leaf list is available; see `DelegationEvidence`.
        var commitmentPresentButUndecodable = false
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
        //
        // Checked without reference to whether rows exist. They do exist after
        // a wipe -- the rebuild made them -- so requiring their absence here
        // is what hid this case behind `broadcastDoNotRebuild`.
        if signals.escrowHoldsRecoveredSecrets {
            return .secretsRecovered
        }

        // The chain's commitment is on this device but nothing around it
        // decodes: the escrow has nothing, and neither would a rebuild.
        if signals.commitmentPresentButUndecodable {
            return .commitmentUndecodable
        }

        // No rows and nothing rescued. Only call it lost where something was
        // actually submitted; otherwise the round was simply never set up,
        // which is not an error state.
        if !signals.roundHasBundles && signals.hasDelegationTxHash {
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

extension DelegationDiagnosis {
    /// Reads the signals for one round and classifies it.
    ///
    /// Used where an incomplete-setup error surfaces and the round is known,
    /// so the voter is told which of the several causes they actually hit
    /// instead of the one message that used to cover all of them.
    ///
    /// - Parameter voteServiceAnswered: whether the caller's own check with
    ///   the voting service completed. Pass `false` for a failed OR
    ///   inconclusive check: the two are the same thing here, and conflating
    ///   "inconclusive" with "not delegated" is what routed voters into the
    ///   destructive rebuild in the first place.
    /// - Parameter escrowHoldsRecoveredSecrets: supplied by the caller rather
    ///   than read here, because the escrow lives in the `VotingRecovery`
    ///   package while this file does not. Passing the SIGNAL instead of the
    ///   client keeps every recovery type out of the diagnosis, so the
    ///   messages survive the day the recovery code is
    ///   deleted -- with `secretsRecovered` simply becoming unreachable, which
    ///   is correct once nothing recovers anything.
    static func forRound(
        _ roundId: String,
        bundleIndex: UInt32 = 0,
        voteServiceAnswered: Bool,
        escrowHoldsRecoveredSecrets: Bool,
        commitmentPresentButUndecodable: Bool = false,
        crypto: VotingCryptoClient
    ) async -> DelegationDiagnosis {

        // Both reads are best-effort. A failure to read a signal is not
        // evidence about that signal, and every unknown resolves toward the
        // protective answer rather than the permissive one.
        // `VotingTxHashLookup` already distinguishes "recorded" from "not
        // recorded"; a THROW is a third thing, and must not be read as
        // `.notFound`. Treating a failed read as "nothing was broadcast" is
        // the same mistake, one layer down, that this taxonomy exists to
        // undo -- so it resolves to true, the protective answer.
        let hasTxHash: Bool
        do {
            hasTxHash = try await crypto.getDelegationTxHash(roundId, bundleIndex) != .notFound
        } catch {
            hasTxHash = true
        }

        let roundHasBundles: Bool
        do {
            roundHasBundles = try await crypto.getBundleCount(roundId) > 0
        } catch {
            roundHasBundles = false
        }

        return diagnose(
            Signals(
                roundHasBundles: roundHasBundles,
                escrowHoldsRecoveredSecrets: escrowHoldsRecoveredSecrets,
                hasDelegationTxHash: hasTxHash,
                voteServiceAnswered: voteServiceAnswered,
                commitmentPresentButUndecodable: commitmentPresentButUndecodable
            )
        )
    }
}
