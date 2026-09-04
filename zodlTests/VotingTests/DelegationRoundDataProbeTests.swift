#if RECOVERY_VOTING_ENABLED
import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

/// The cheap early-out that decides whether recovery runs at launch at all.
///
/// The predicate is "does this device hold any voting round", NOT "is it
/// healthy". Those come apart in exactly the case that matters: a wiped round
/// was deleted and immediately REBUILT, so a corrupted database has a `rounds`
/// row like any other. If the probe treated presence as health it would skip
/// the one situation recovery exists for, which is what
/// `detectsRoundDataInACorruptedDatabase` pins down.
@Suite(.serialized) struct DelegationRoundDataProbeTests {
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

    // MARK: - A healthy database is never acted on

    /// The strongest form of "recovery is not used": run the REAL client
    /// against a healthy database and fail if it writes anything at all.
    ///
    /// Recovery runs on every cold launch, on every wallet, most of which have
    /// nothing wrong with them. A carver that escrowed something for an intact
    /// round would be rewriting delegation secrets nothing had harmed, and the
    /// user would have no way to notice. `plan` returning empty is checked
    /// elsewhere; this asserts the consequence, which is that nothing is
    /// written.
    @Test func anIntactDatabaseCausesNoEscrowWriteAtAll() async throws {
        let healthy = try VotingRecoveryEndToEndTests.CorruptedDatabase(
            rebuildAfterClearing: false
        )
        let planted = try PlantedDocuments(preserving: healthy)

        let wrote = LockIsolated(false)
        let report = await withDependencies {
            // Traps EVERY mutating call, not just `record`. The requirement
            // is that a good database is never acted on at all, so `forget`
            // and `reset` would be violations too.
            $0.delegationEscrow = DelegationEscrowClient(
                record: { _ in wrote.setValue(true) },
                entries: { _ in [] },
                holdsDelegation: { _ in false },
                forget: { _ in wrote.setValue(true) },
                markRejected: { _, _, _ in wrote.setValue(true) },
                reset: { wrote.setValue(true) }
            )
        } operation: {
            await DelegationRecoveryClient.liveValue.run()
        }

        #expect(wrote.value == false, "recovery wrote to the escrow for an intact database")
        #expect(report.bundlesEscrowed == 0)
        #expect(report.outcome == .nothingToRecover)
        _ = planted
    }

    /// The same for a database that holds no round at all, which is what the
    /// overwhelming majority of wallets look like.
    @Test func aWalletThatNeverVotedCausesNoEscrowWriteAtAll() async throws {
        let empty = try EmptyVotingDatabase()
        let planted = try PlantedDocuments(preservingDatabaseAt: empty.databaseURL)

        let wrote = LockIsolated(false)
        let report = await withDependencies {
            // Traps EVERY mutating call, not just `record`. The requirement
            // is that a good database is never acted on at all, so `forget`
            // and `reset` would be violations too.
            $0.delegationEscrow = DelegationEscrowClient(
                record: { _ in wrote.setValue(true) },
                entries: { _ in [] },
                holdsDelegation: { _ in false },
                forget: { _ in wrote.setValue(true) },
                markRejected: { _, _, _ in wrote.setValue(true) },
                reset: { wrote.setValue(true) }
            )
        } operation: {
            await DelegationRecoveryClient.liveValue.run()
        }

        #expect(wrote.value == false)
        #expect(report.bundlesEscrowed == 0)
        _ = planted
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

// MARK: - Planting into the container the client reads

extension DelegationRoundDataProbeTests {
    /// Puts a database into `voting_recovery/` so the real client finds it,
    /// and removes it again on teardown so suites do not leak state into each
    /// other. Any pre-existing preserved set is moved aside and restored.
    final class PlantedDocuments {
        private let preserved: URL
        private let stashed: URL?
        private let stashedLive: URL?

        convenience init(preserving database: VotingRecoveryEndToEndTests.CorruptedDatabase) throws {
            try self.init(preservingDatabaseAt: database.databaseURL)
        }

        init(preservingDatabaseAt databaseURL: URL) throws {
            let documents = try #require(
                FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            )
            preserved = documents.appendingPathComponent("voting_recovery", isDirectory: true)

            // Stash OUTSIDE Documents. `sources()` discovers any voting
            // database anywhere beneath it, so parking the old set in a
            // differently-named subdirectory would leave it discoverable and
            // the test would carve the very data it thought it had removed.
            if FileManager.default.fileExists(atPath: preserved.path) {
                let aside = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voting-stash-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.moveItem(at: preserved, to: aside)
                stashed = aside
            } else {
                stashed = nil
            }

            // The live database counts as a source too, so a leftover from
            // another suite would be carved here. Move it aside as well.
            let live = documents.appendingPathComponent("voting.sqlite3")
            if FileManager.default.fileExists(atPath: live.path) {
                let liveAside = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voting-live-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: liveAside, withIntermediateDirectories: true
                )
                for suffix in ["", "-wal", "-shm"] {
                    let url = documents.appendingPathComponent("voting.sqlite3" + suffix)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    try FileManager.default.moveItem(
                        at: url, to: liveAside.appendingPathComponent("voting.sqlite3" + suffix)
                    )
                }
                stashedLive = liveAside
            } else {
                stashedLive = nil
            }

            try FileManager.default.createDirectory(
                at: preserved, withIntermediateDirectories: true
            )
            for suffix in ["", "-wal", "-shm"] {
                let source = databaseURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(databaseURL.lastPathComponent + suffix)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.copyItem(
                    at: source,
                    to: preserved.appendingPathComponent("voting.sqlite3" + suffix)
                )
            }
        }

        deinit {
            let documents = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first
            try? FileManager.default.removeItem(at: preserved)
            if let stashed {
                try? FileManager.default.moveItem(at: stashed, to: preserved)
            }
            if let stashedLive, let documents {
                for suffix in ["", "-wal", "-shm"] {
                    let source = stashedLive.appendingPathComponent("voting.sqlite3" + suffix)
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    try? FileManager.default.moveItem(
                        at: source,
                        to: documents.appendingPathComponent("voting.sqlite3" + suffix)
                    )
                }
                try? FileManager.default.removeItem(at: stashedLive)
            }
        }
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
