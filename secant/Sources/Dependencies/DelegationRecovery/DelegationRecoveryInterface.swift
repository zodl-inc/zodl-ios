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
/// because the interesting cases are the partial ones: a carved value that is
/// not a field element was never a blinding factor, and one whose `gov_comm`
/// did not survive carries no self-check.
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
    /// Bundles whose original secrets were written to the escrow.
    var bundlesEscrowed = 0
    /// Carved values discarded because they are not canonical Pallas base
    /// field elements, so they cannot have been blinding factors.
    var bundlesRejected = 0
    /// Escrowed bundles whose `gov_comm` did not survive, so the recovered
    /// blinding factor arrives without the commitment that verifies it.
    var bundlesWithoutVan = 0
}


/// Carves the preserved copy of `voting.sqlite3` for delegation secrets an
/// older build replaced, and escrows whatever it finds.
@DependencyClient
struct DelegationRecoveryClient {
    /// Reads only `voting_recovery/`, never the live database, and never
    /// through SQLite: opening a connection checkpoints the write-ahead log
    /// and destroys the frames being read.
    ///
    /// Safe to run repeatedly. An untouched round yields an empty plan, and
    /// re-escrowing a bundle overwrites its entry in place.
    var run: @Sendable () async -> DelegationRecoveryReport = {
        DelegationRecoveryReport(outcome: .noSnapshot)
    }
}
#endif
