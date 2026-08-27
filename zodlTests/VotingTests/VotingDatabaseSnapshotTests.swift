#if VOTING_ENABLED
import Testing
import Foundation
@testable import zodl_internal

/// The snapshot ships ahead of any restore path, so its contract is narrow and
/// worth pinning: copy all three files byte-for-byte, put a timestamp in the
/// name, keep the trio mutually resolvable, and never run twice.
///
/// These exercise `captureThrowing` against a scratch directory rather than the
/// real Documents folder, so they do not depend on simulator container state.
@Suite struct VotingDatabaseSnapshotTests {
    @Test func timestampIsSortableUTCAndFilesystemSafe() {
        let stamp = VotingDatabaseSnapshot.timestamp(Date(timeIntervalSince1970: 1_787_675_522))

        #expect(stamp == "20260825-163202")
        #expect(stamp.contains(":") == false)
        #expect(stamp.contains("/") == false)
    }

    /// Ordering matters for a set of snapshots, so the format must sort the
    /// same way the clock does.
    @Test func timestampsSortChronologically() {
        let earlier = VotingDatabaseSnapshot.timestamp(Date(timeIntervalSince1970: 1_000_000))
        let later = VotingDatabaseSnapshot.timestamp(Date(timeIntervalSince1970: 2_000_000))

        #expect(earlier < later)
    }

    /// The copies keep the canonical names, so the preserved set stays
    /// openable as a database: SQLite resolves sidecars as `<database>-wal`.
    /// The capture time lives in the marker filename instead.
    @Test func preservedSetKeepsCanonicalNamesAndRecordsTheTime() throws {
        let scratch = try Scratch()
        let snapshot = try #require(
            try VotingDatabaseSnapshot.captureThrowing(
                databasePath: scratch.databaseURL.path,
                now: Date(timeIntervalSince1970: 1_787_675_522),
                root: scratch.destination
            )
        )

        #expect(snapshot.databaseURL.lastPathComponent == "voting.sqlite3")
        #expect(snapshot.walURL.path == snapshot.databaseURL.path + "-wal")
        #expect(snapshot.shmURL.path == snapshot.databaseURL.path + "-shm")
        #expect(snapshot.markerURL.lastPathComponent == "captured-20260825-163202.txt")
    }

    @Test func copiesAllThreeFilesByteForByte() throws {
        let scratch = try Scratch()
        let snapshot = try #require(
            try VotingDatabaseSnapshot.captureThrowing(
                databasePath: scratch.databaseURL.path,
                now: Date(),
                root: scratch.destination
            )
        )

        #expect(try Data(contentsOf: snapshot.databaseURL) == Data(contentsOf: scratch.databaseURL))
        #expect(try Data(contentsOf: snapshot.walURL) == Data(contentsOf: scratch.walURL))
        #expect(try Data(contentsOf: snapshot.shmURL) == Data(contentsOf: scratch.shmURL))
    }

    /// The originals are evidence. Capturing must not disturb them.
    @Test func leavesTheSourceFilesUntouched() throws {
        let scratch = try Scratch()
        let before = try [scratch.databaseURL, scratch.walURL, scratch.shmURL].map {
            try Data(contentsOf: $0)
        }

        _ = try VotingDatabaseSnapshot.captureThrowing(
            databasePath: scratch.databaseURL.path,
            now: Date(),
            root: scratch.destination
        )

        let after = try [scratch.databaseURL, scratch.walURL, scratch.shmURL].map {
            try Data(contentsOf: $0)
        }
        #expect(before == after)
    }

    /// The whole guard: if the recovery copy already holds data, do nothing.
    /// The first capture is the valuable one — taken before any launch
    /// checkpoints the WAL — so a later one must not replace it.
    @Test func doesNothingOnceTheRecoveryCopyHoldsData() throws {
        let scratch = try Scratch()

        let first = try VotingDatabaseSnapshot.captureThrowing(
            databasePath: scratch.databaseURL.path,
            now: Date(timeIntervalSince1970: 1_000_000),
            root: scratch.destination
        )
        let preserved = try Data(contentsOf: try #require(first).databaseURL)

        try Data("the-app-moved-on".utf8).write(to: scratch.databaseURL)
        let second = try VotingDatabaseSnapshot.captureThrowing(
            databasePath: scratch.databaseURL.path,
            now: Date(timeIntervalSince1970: 2_000_000),
            root: scratch.destination
        )

        #expect(second == nil, "a later, already-checkpointed copy must not replace the first")
        #expect(try Data(contentsOf: try #require(first).databaseURL) == preserved)
    }

    /// An empty leftover from an interrupted run is not "data": the guard must
    /// let the capture proceed rather than preserving a zero-byte file forever.
    @Test func replacesAnEmptyLeftoverFromAnInterruptedRun() throws {
        let scratch = try Scratch()
        try Data().write(to: scratch.destination.appendingPathComponent("voting.sqlite3"))

        let snapshot = try VotingDatabaseSnapshot.captureThrowing(
            databasePath: scratch.databaseURL.path,
            now: Date(),
            root: scratch.destination
        )

        #expect(snapshot != nil)
        #expect(try Data(contentsOf: try #require(snapshot).databaseURL)
            == Data(contentsOf: scratch.databaseURL))
    }

    @Test func holdsDataDistinguishesMissingEmptyAndPopulated() throws {
        let scratch = try Scratch()
        let missing = scratch.destination.appendingPathComponent("absent.sqlite3")
        let empty = scratch.destination.appendingPathComponent("empty.sqlite3")
        try Data().write(to: empty)

        #expect(VotingDatabaseSnapshot.holdsData(at: missing) == false)
        #expect(VotingDatabaseSnapshot.holdsData(at: empty) == false)
        #expect(VotingDatabaseSnapshot.holdsData(at: scratch.databaseURL))
    }

    /// A checkpoint can unlink the WAL while leaving deleted record bytes in
    /// freed main-database pages, so the main database remains evidence.
    @Test func capturesTheMainDatabaseWhenThereIsNoWriteAheadLog() throws {
        let scratch = try Scratch()
        try FileManager.default.removeItem(at: scratch.walURL)

        let snapshot = try #require(
            try VotingDatabaseSnapshot.captureThrowing(
                databasePath: scratch.databaseURL.path,
                now: Date(),
                root: scratch.destination
            )
        )

        #expect(try Data(contentsOf: snapshot.databaseURL)
            == Data(contentsOf: scratch.databaseURL))
        #expect(FileManager.default.fileExists(atPath: snapshot.walURL.path) == false)
        #expect(try Data(contentsOf: snapshot.shmURL) == Data(contentsOf: scratch.shmURL))
    }

    @Test func skipsWhenTheDatabaseDoesNotExist() throws {
        let scratch = try Scratch()

        let snapshot = try VotingDatabaseSnapshot.captureThrowing(
            databasePath: scratch.directory.appendingPathComponent("absent.sqlite3").path,
            now: Date(),
            root: scratch.destination
        )

        #expect(snapshot == nil)
    }
}

// MARK: - Scratch layout

extension VotingDatabaseSnapshotTests {
    /// A throwaway `voting.sqlite3` trio plus an empty destination, each in its
    /// own directory so the suite is safe under parallel execution.
    final class Scratch {
        let directory: URL
        let destination: URL
        let databaseURL: URL
        let walURL: URL
        let shmURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("voting-snapshot-\(UUID().uuidString)", isDirectory: true)
            destination = directory.appendingPathComponent("snapshots", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            databaseURL = directory.appendingPathComponent("voting.sqlite3")
            walURL = directory.appendingPathComponent("voting.sqlite3-wal")
            shmURL = directory.appendingPathComponent("voting.sqlite3-shm")

            try Data("database-bytes".utf8).write(to: databaseURL)
            try Data("wal-bytes".utf8).write(to: walURL)
            try Data("shm-bytes".utf8).write(to: shmURL)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
#endif
