#if VOTING_ENABLED
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
        entries.removeAll { $0.roundId == entry.roundId && $0.bundleIndex == entry.bundleIndex }
        entries.append(entry)
        entries.sort { ($0.roundId, $0.bundleIndex) < ($1.roundId, $1.bundleIndex) }
        try persist(entries)
    }

    func entries(roundId: String) throws -> [DelegationEscrowEntry] {
        try loadAll()
            .filter { $0.roundId.caseInsensitiveCompare(roundId) == .orderedSame }
            .sorted { $0.bundleIndex < $1.bundleIndex }
    }

    func holdsDelegation(roundId: String) -> Bool {
        ((try? entries(roundId: roundId)) ?? []).isEmpty == false
    }

    func forget(roundId: String) throws {
        var entries = try loadAll()
        entries.removeAll { $0.roundId.caseInsensitiveCompare(roundId) == .orderedSame }
        try persist(entries)
    }

    func reset() {
        if let url = try? fileURL() {
            try? FileManager.default.removeItem(at: url)
        }
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
            reset: {
                await store.reset()
            }
        )
    }
}
#endif
