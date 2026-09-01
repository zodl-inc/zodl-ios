#if VOTING_ENABLED
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


/// A read-only picture of what the recovery would find, without changing
/// anything. Backs the diagnostics screen.
struct DelegationRecoveryInspection: Equatable, Sendable {
    /// One copy of the voting database that was looked at.
    struct Source: Equatable, Sendable, Identifiable {
        enum Verdict: Equatable, Sendable {
            /// A delegation was replaced, and the original is still reachable.
            case replacedDelegation(bundles: Int)
            /// Readable, with nothing to restore.
            case intact
            /// Present but could not be parsed.
            case unreadable
            /// No file at this path.
            case absent
        }

        var id: String { name }
        /// Short label, e.g. "preserved" or "live".
        let name: String
        /// File name only. The container path is a UUID that changes on every
        /// install, so it is noise rather than information.
        let fileName: String
        let databaseBytes: Int
        let walBytes: Int
        let shmBytes: Int
        let verdict: Verdict
        /// Bundles carved out of this copy, oldest surviving value first.
        let rows: [Row]
    }

    /// One carved `bundles` row.
    struct Row: Equatable, Sendable, Identifiable {
        var id: String { "\(roundId)/\(bundleIndex)/\(vanCommRand)" }
        let roundId: String
        let bundleIndex: UInt32
        /// Elided: the middle is dropped, but both ends are kept. The fixture
        /// generations differ only in the LAST byte, so a prefix alone cannot
        /// tell them apart.
        let vanCommRand: String
        /// Whether this value is a canonical Pallas element, and so could have
        /// been a real blinding factor.
        let isPlausible: Bool
        /// Where it was found: released space, a live row, or a log frame.
        let origin: String
        /// True when this is the value recovery would restore.
        let isOriginal: Bool
    }

    let sources: [Source]
    /// Entries already sitting in the escrow, which recovery would overwrite
    /// for the same round and bundle.
    let escrowedBundles: Int
    let escrowedRounds: Int

    /// Any copy showing a replaced delegation.
    var needsRecovery: Bool {
        sources.contains {
            if case .replacedDelegation = $0.verdict { return true }
            return false
        }
    }

    /// Bundles recovery would restore, counted once per round and bundle
    /// across every copy.
    var restorableBundles: Int {
        var seen: Set<String> = []
        for source in sources {
            for row in source.rows where row.isOriginal {
                seen.insert("\(row.roundId)/\(row.bundleIndex)")
            }
        }
        return seen.count
    }
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

    /// Reports what `run` WOULD do, changing nothing. Reads the same copies in
    /// the same order, so what it shows is what the button will act on.
    var inspect: @Sendable () async -> DelegationRecoveryInspection = {
        DelegationRecoveryInspection(sources: [], escrowedBundles: 0, escrowedRounds: 0)
    }
}
#endif
