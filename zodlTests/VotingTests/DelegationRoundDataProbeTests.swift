#if VOTING_ENABLED
import Testing
import Foundation
@testable import zodl_internal

/// The cheap early-out that decides whether recovery runs at launch at all.
///
/// The predicate is "does this device hold any voting round", NOT "is it
/// healthy". Those come apart in exactly the case that matters: a wiped round
/// was deleted and immediately REBUILT, so a corrupted database has a `rounds`
/// row like any other. If the probe treated presence as health it would skip
/// the one situation recovery exists for, which is what
/// `detectsRoundDataInACorruptedDatabase` pins down.
@Suite struct DelegationRoundDataProbeTests {
    // MARK: - The case the guard must not skip

    @Test func detectsRoundDataInACorruptedDatabase() throws {
        let corrupted = try VotingRecoveryEndToEndTests.CorruptedDatabase(
            rebuildAfterClearing: true
        )

        let holdsData = try DelegationWalRecovery.holdsRoundData(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL
        )

        #expect(holdsData, "a wiped round is rebuilt, so its data is still present")
    }

    /// And the recovery it gates really does find the damage, so the two
    /// together cannot silently become a no-op.
    @Test func aDatabaseThePropeAcceptsIsAlsoOneRecoveryActsOn() throws {
        let corrupted = try VotingRecoveryEndToEndTests.CorruptedDatabase(
            rebuildAfterClearing: true
        )

        let holdsData = try DelegationWalRecovery.holdsRoundData(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL
        )
        let plan = try DelegationWalRecovery.plan(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL
        )

        #expect(holdsData)
        #expect(plan.needsRecovery)
        #expect(plan.replacements.count == VotingRecoveryEndToEndTests.Fixture.bundleCount)
    }

    // MARK: - Present and healthy

    @Test func detectsRoundDataInAnUntouchedDatabase() throws {
        let healthy = try VotingRecoveryEndToEndTests.CorruptedDatabase(
            rebuildAfterClearing: false
        )

        let holdsData = try DelegationWalRecovery.holdsRoundData(
            databaseURL: healthy.databaseURL,
            walURL: healthy.walURL
        )
        let plan = try DelegationWalRecovery.plan(
            databaseURL: healthy.databaseURL,
            walURL: healthy.walURL
        )

        // Present, so recovery runs; and finding nothing is its own decision.
        #expect(holdsData)
        #expect(plan.needsRecovery == false)
    }

    /// The log holds the rows here, not the database file, so this also pins
    /// that the probe reads the write-ahead log and not only the main file.
    @Test func findsRoundDataThatExistsOnlyInTheWriteAheadLog() throws {
        let healthy = try VotingRecoveryEndToEndTests.CorruptedDatabase(
            rebuildAfterClearing: false
        )

        let inDatabaseAlone = try DelegationWalRecovery.holdsRoundData(
            databaseURL: healthy.databaseURL
        )
        let withTheLog = try DelegationWalRecovery.holdsRoundData(
            databaseURL: healthy.databaseURL,
            walURL: healthy.walURL
        )

        #expect(inDatabaseAlone == false, "the fixture checkpoints before inserting")
        #expect(withTheLog, "the rows are in the log, so the probe must read it")
    }

    // MARK: - Nothing to do

    @Test func reportsNoRoundDataForADatabaseWithoutOne() throws {
        let empty = try EmptyVotingDatabase()

        let holdsData = try DelegationWalRecovery.holdsRoundData(
            databaseURL: empty.databaseURL,
            walURL: empty.walURL
        )

        #expect(holdsData == false, "no round was ever created, so nothing can be lost")
    }

    @Test func reportsNoRoundDataForBytesThatAreNotADatabase() {
        #expect(DelegationWalRecovery.holdsRoundData(databaseBytes: []) == false)
        #expect(
            DelegationWalRecovery
                .holdsRoundData(databaseBytes: Array(repeating: 0xFF, count: 8192)) == false
        )
        #expect(DelegationWalRecovery.holdsRoundData(walBytes: []) == false)
    }

    /// Garbage that happens to carry the record signature must not read as a
    /// round: the probe gates recovery, and a false positive there means every
    /// launch pays for a full carve.
    @Test func signatureBytesAloneAreNotARound() {
        var page = Array(repeating: UInt8(0), count: 4096)
        for offset in stride(from: 200, to: 3900, by: 64) {
            page[offset] = 0x0C
            page[offset + 1] = 0x81
            page[offset + 2] = 0x0D
        }

        let database = DelegationWalRecoveryHostileInputTests.database(pages: [page])

        #expect(DelegationWalRecovery.holdsRoundData(databaseBytes: database) == false)
    }
}

// MARK: - A voting database with the schema but no rows

extension DelegationRoundDataProbeTests {
    /// The schema applied and nothing inserted, which is what a wallet that
    /// never opened a poll has.
    final class EmptyVotingDatabase {
        let directory: URL
        let databaseURL: URL
        let walURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("voting-empty-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            databaseURL = directory.appendingPathComponent("voting.sqlite3")
            walURL = directory.appendingPathComponent("voting.sqlite3-wal")

            try VotingRecoveryEndToEndTests.CorruptedDatabase
                .writeEmptySchema(to: databaseURL)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
#endif
