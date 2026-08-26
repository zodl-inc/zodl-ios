#if VOTING_ENABLED
import Foundation
@preconcurrency import ZcashLightClientKit

/// Preserves the voting database's three files before anything opens them.
///
/// A cleared round's original secrets survive only in superseded write-ahead
/// log frames, and those frames are destroyed by the next checkpoint — which
/// SQLite runs when the last connection closes. Opening the database is
/// therefore the act that loses the evidence, so this copy has to happen
/// first, on bytes, with no connection involved.
///
/// The logic is deliberately simple: **if `voting_recovery/voting.sqlite3`
/// holds no data, copy `voting.sqlite3`, `voting.sqlite3-wal` and
/// `voting.sqlite3-shm` into it.** That makes the capture idempotent — once a
/// copy exists it is never replaced — and keeps the first capture, which is
/// the one taken closest to the incident and before any launch checkpointed
/// the WAL.
///
/// This ships ahead of any restore path on purpose: a build that only takes
/// the copy already makes recovery possible later, even for users who upgrade
/// long after the round was wiped.
enum VotingDatabaseSnapshot {
    /// Directory under Documents holding the preserved set.
    static let directoryName = "voting_recovery"

    /// The copies keep the canonical names. Only one set is ever kept, so
    /// there is nothing to disambiguate, and SQLite resolves sidecars as
    /// `<database>-wal` / `-shm` — so preserving the names is what keeps the
    /// trio openable as a database. The capture time is recorded separately by
    /// `markerName`.
    static let databaseName = "voting.sqlite3"

    /// Records when the set was taken, with the timestamp in the filename.
    static func markerName(_ date: Date) -> String { "captured-\(timestamp(date)).txt" }

    enum SnapshotError: Error {
        case documentsFolder
    }

    struct Snapshot: Equatable, Sendable {
        let directory: URL
        let databaseURL: URL
        let walURL: URL
        let shmURL: URL
        let markerURL: URL
    }

    /// Copies the voting database trio into `voting_recovery/` if that
    /// directory does not already hold data.
    ///
    /// Returns `nil` when a copy already exists, when the source database is
    /// missing, or when there is no WAL to preserve — in that last case the
    /// superseded frames are already gone and a copy would only cost space.
    ///
    /// Never throws into the caller's path: preserving evidence must not be
    /// able to stop the voting flow from opening. Failures are logged.
    @discardableResult
    static func capture(databasePath: String, now: Date = Date()) -> Snapshot? {
        do {
            return try captureThrowing(databasePath: databasePath, now: now, root: nil)
        } catch {
            LoggerProxy.error("Voting database snapshot failed: \(error)")
            return nil
        }
    }

    /// `root` overrides the destination directory; tests pass a scratch path so
    /// they do not depend on the simulator's Documents container.
    static func captureThrowing(
        databasePath: String,
        now: Date,
        root overrideRoot: URL? = nil
    ) throws -> Snapshot? {
        let fileManager = FileManager.default
        let source = URL(fileURLWithPath: databasePath)
        let wal = URL(fileURLWithPath: databasePath + "-wal")
        let shm = URL(fileURLWithPath: databasePath + "-shm")

        guard fileManager.fileExists(atPath: source.path) else { return nil }

        // No WAL means a clean close already checkpointed and unlinked it, so
        // there are no superseded frames left to rescue.
        guard fileManager.fileExists(atPath: wal.path) else { return nil }

        let root = try overrideRoot ?? recoveryDirectory()
        let destination = Snapshot(
            directory: root,
            databaseURL: root.appendingPathComponent(databaseName),
            walURL: root.appendingPathComponent("\(databaseName)-wal"),
            shmURL: root.appendingPathComponent("\(databaseName)-shm"),
            markerURL: root.appendingPathComponent(markerName(now))
        )

        guard !holdsData(at: destination.databaseURL) else { return nil }

        // Replace any empty or half-written leftover from an interrupted run.
        for url in [destination.databaseURL, destination.walURL, destination.shmURL] {
            try? fileManager.removeItem(at: url)
        }

        // The WAL first: it is the volatile, high-value artifact, and the one
        // the next open would checkpoint away. The database file only loses its
        // old page images once that checkpoint runs.
        try fileManager.copyItem(at: wal, to: destination.walURL)
        if fileManager.fileExists(atPath: shm.path) {
            try? fileManager.copyItem(at: shm, to: destination.shmURL)
        }
        try fileManager.copyItem(at: source, to: destination.databaseURL)
        try? Data(timestamp(now).utf8).write(to: destination.markerURL)

        for url in [
            destination.walURL, destination.shmURL, destination.databaseURL, destination.markerURL
        ] where fileManager.fileExists(atPath: url.path) {
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }

        // Deliberately left eligible for system backups, like the database it
        // copies: these bytes are the only remaining route to a lost vote, so
        // they must survive a device migration.
        LoggerProxy.info("Preserved voting database into \(directoryName) at \(timestamp(now))")
        return destination
    }

    /// Whether a preserved database is present and non-empty.
    ///
    /// Emptiness is judged on file size, never by querying: opening the copy
    /// through SQLite would checkpoint its WAL and destroy the frames the whole
    /// exercise exists to keep.
    static func holdsData(at url: URL) -> Bool {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber
        else {
            return false
        }
        return size.intValue > 0
    }

    /// Removes the preserved set. Wallet-reset scope only.
    static func reset() {
        guard let root = try? recoveryDirectory() else { return }
        try? FileManager.default.removeItem(at: root)
    }

    static func recoveryDirectory() throws -> URL {
        guard let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
        else {
            throw SnapshotError.documentsFolder
        }

        let root = documents.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    /// UTC, second resolution, lexicographically sortable and filesystem safe.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
#endif
