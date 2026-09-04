#if RECOVERY_VOTING_ENABLED
import ComposableArchitecture
import Foundation

extension DependencyValues {
    var delegationRecovery: DelegationRecoveryClient {
        get { self[DelegationRecoveryClient.self] }
        set { self[DelegationRecoveryClient.self] = newValue }
    }
}

/// What one recovery run found, and what it did about it.
///
/// Counts are reported rather than summarised into a single "it worked",
/// because the interesting cases are the partial ones: a bundle with two
/// candidates was cleared and rebuilt, and a run that read only some of its
/// sources may have missed the one that mattered.
struct DelegationRecoveryReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Nothing was preserved, so there is nothing to read. Either the
        /// wallet never opened a voting database, or this build took its
        /// snapshot after one had already been checkpointed away.
        case noSnapshot
        /// The preserved files were read and hold no replaced delegation.
        /// This is the expected outcome for an unaffected wallet.
        case nothingToRecover
        /// At least one original delegation was carved out and escrowed.
        case recovered
        /// The preserved files could not be read, or the escrow write failed.
        /// The reason is logged; it is not shown, so that raw internals never
        /// reach the user.
        case failed
    }

    var outcome: Outcome
    /// Copies of the database that were successfully read.
    var sourcesScanned = 0
    /// Distinct rounds represented by the escrowed bundles.
    var rounds = 0
    /// Candidate rows written to the escrow: every generation of every
    /// bundle the decoder admitted.
    var candidatesEscrowed = 0
    /// Distinct bundles with at least one candidate.
    var bundles = 0
}

/// Carves the preserved copy of `voting.sqlite3` for delegation secrets an
/// older build replaced, and escrows whatever it finds.
@DependencyClient
struct DelegationRecoveryClient {
    /// Reads only `voting_recovery/`, never the live database, and never
    /// through SQLite: opening a connection checkpoints the write-ahead log
    /// and destroys the frames being read.
    ///
    /// Safe to run repeatedly. The escrow keeps one entry per distinct
    /// candidate, so re-escrowing what an earlier run found changes nothing.
    var run: @Sendable () async -> DelegationRecoveryReport = {
        DelegationRecoveryReport(outcome: .noSnapshot)
    }
}
#endif
