#if RECOVERY_VOTING_ENABLED
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

/// File-backed store for `DelegationEscrowEntry`.
///
/// Serialized through an actor so concurrent bundle preparation cannot
/// interleave a read-modify-write and lose an entry.
private actor DelegationEscrowStore {
    /// Bumped only for a layout change that older builds cannot read. A file
    /// carrying an unknown version is left untouched rather than overwritten,
    /// so downgrading never destroys an escrow written by a newer build.
    static let schemaVersion = 1

    private struct Envelope: Codable {
        var version: Int
        var entries: [DelegationEscrowEntry]
    }

    private func fileURL() throws -> URL {
        guard let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
        else {
            throw DelegationEscrowError.documentsFolder
        }

        return documents.appendingPathComponent(DelegationEscrowFile.name)
    }

    /// Always re-reads from disk. The file is a handful of small entries, and
    /// caching would let a wallet reset that deletes the file out from under us
    /// resurrect the previous wallet's secrets on the next write.
    private func loadAll() throws -> [DelegationEscrowEntry] {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.version <= Self.schemaVersion else {
            throw DelegationEscrowError.schemaVersionNotSupported
        }

        return envelope.entries
    }

    private func persist(_ entries: [DelegationEscrowEntry]) throws {
        let url = try fileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Envelope(version: Self.schemaVersion, entries: entries))
            .write(to: url, options: .atomic)

        // `.complete` would make the write fail whenever the delegation is
        // prepared with the device locked, which is exactly when a background
        // task might run it. Until-first-unlock still encrypts at rest.
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )

        // Deliberately NOT excluded from backup, unlike `VotingMetadataStorage`.
        // These bytes exist nowhere else -- not on any server, not on chain,
        // and not derivable from the seed -- so excluding them would make a
        // device migration silently forfeit the user's vote. This matches the
        // trade-off `DatabaseFiles` documents for the wallet databases.
    }

    func record(_ entry: DelegationEscrowEntry) throws {
        var entries = try loadAll()

        // A live capture must never displace a recovered one.
        //
        // Overwriting is right for the ordinary case this was written for:
        // re-running a delegation samples fresh randomness and the newest
        // sample is the one the chain will see. That reasoning fails exactly
        // where it matters most. For a round whose delegation is ALREADY on
        // chain, the chain holds the OLD commitment, the rescued secret is its
        // only opening, and a rebuild's fresh sample is worthless against it.
        //
        // So a rebuild of an already-broadcast round would otherwise overwrite
        // the one copy recovery just carved out of a wiped database -- the
        // second, quieter version of the loss this whole mechanism exists to
        // undo.
        //
        // One bundle may hold several candidates, each a distinct blinding
        // the carve found, so the key includes the value itself, and the
        // commitment beside it: two images of one blinding can disagree on
        // the commitment when a rebuild overwrote part of a row, and only
        // the intact one opens. A live capture of the SAME candidate adds
        // nothing the recovered copy lacks.
        let sameCandidate: (DelegationEscrowEntry) -> Bool = {
            $0.roundId.caseInsensitiveCompare(entry.roundId) == .orderedSame
                && $0.bundleIndex == entry.bundleIndex
                && $0.vanCommRand == entry.vanCommRand
                && $0.van == entry.van
        }
        if let existing = entries.first(where: sameCandidate),
           existing.source == .recovered, entry.source == .liveCapture {
            return
        }

        // A candidate the chain refused stays refused when a later run
        // escrows the same value again.
        let refusedAt = entries.first(where: sameCandidate)?.rejectedAt
        entries.removeAll(where: sameCandidate)
        entries.append(refusedAt.map { entry.refused(at: $0) } ?? entry)
        entries.sort(by: Self.precedes)
        try persist(entries)
    }

    func entries(roundId: String) throws -> [DelegationEscrowEntry] {
        try loadAll()
            .filter { $0.roundId.caseInsensitiveCompare(roundId) == .orderedSame }
            .sorted(by: Self.precedes)
    }

    /// A total order, so the file and `entries` read the same from one run to
    /// the next: round, bundle, best rank first, then the candidate's own bytes.
    private static func precedes(_ lhs: DelegationEscrowEntry, _ rhs: DelegationEscrowEntry) -> Bool {
        if lhs.roundId != rhs.roundId { return lhs.roundId < rhs.roundId }
        if lhs.bundleIndex != rhs.bundleIndex { return lhs.bundleIndex < rhs.bundleIndex }
        if lhs.provenanceRank != rhs.provenanceRank { return lhs.provenanceRank > rhs.provenanceRank }
        if lhs.vanCommRand != rhs.vanCommRand { return lhs.vanCommRand.lexicographicallyPrecedes(rhs.vanCommRand) }
        return lhs.van.lexicographicallyPrecedes(rhs.van)
    }

    func holdsDelegation(roundId: String) -> Bool {
        ((try? entries(roundId: roundId)) ?? []).isEmpty == false
    }

    func forget(roundId: String) throws {
        var entries = try loadAll()
        entries.removeAll { $0.roundId.caseInsensitiveCompare(roundId) == .orderedSame }
        try persist(entries)
    }

    func markRejected(roundId: String, bundleIndex: UInt32, vanCommRand: Data) throws {
        let entries = try loadAll().map { entry -> DelegationEscrowEntry in
            guard entry.roundId.caseInsensitiveCompare(roundId) == .orderedSame,
                  entry.bundleIndex == bundleIndex,
                  entry.vanCommRand == vanCommRand
            else { return entry }
            return entry.refused(at: Date())
        }
        try persist(entries)
    }

    func reset() {
        if let url = try? fileURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private extension DelegationEscrowEntry {
    /// The same entry, stamped as refused by the chain at `date`.
    func refused(at date: Date) -> DelegationEscrowEntry {
        DelegationEscrowEntry(
            roundId: roundId,
            bundleIndex: bundleIndex,
            vanCommRand: vanCommRand,
            van: van,
            totalNoteValue: totalNoteValue,
            delegationTxHash: delegationTxHash,
            source: source,
            createdAt: createdAt,
            walletId: walletId,
            addressIndex: addressIndex,
            vanLeafPosition: vanLeafPosition,
            provenance: provenance,
            provenanceRank: provenanceRank,
            rejectedAt: date
        )
    }
}

/// Location of the escrow file, shared so wallet-reset code can remove it
/// alongside `voting.sqlite3` without reaching into the actor.
enum DelegationEscrowFile {
    /// Sits beside `voting.sqlite3` in Documents so the two share a lifetime.
    static let name = "voting-delegation-escrow.json"
}

enum DelegationEscrowError: Error {
    case documentsFolder
    case schemaVersionNotSupported
}

extension DelegationEscrowClient: DependencyKey {
    static var liveValue: Self {
        let store = DelegationEscrowStore()

        return Self(
            record: { entry in
                try await store.record(entry)
            },
            entries: { roundId in
                try await store.entries(roundId: roundId)
            },
            holdsDelegation: { roundId in
                await store.holdsDelegation(roundId: roundId)
            },
            forget: { roundId in
                try await store.forget(roundId: roundId)
            },
            markRejected: { roundId, bundleIndex, vanCommRand in
                try await store.markRejected(roundId: roundId, bundleIndex: bundleIndex, vanCommRand: vanCommRand)
            },
            reset: {
                await store.reset()
            }
        )
    }
}
#endif
