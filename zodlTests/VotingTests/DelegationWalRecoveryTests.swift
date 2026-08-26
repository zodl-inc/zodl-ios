#if VOTING_ENABLED
import Testing
import Foundation
@testable import zodl_internal

/// End-to-end recovery of a cleared round's delegation secrets, run on the
/// simulator against a full `voting.sqlite3` / `-wal` / `-shm` set injected
/// into a Documents-style directory exactly as the three files sit on device.
///
/// Two fixtures, mirroring the captured reproduction pair:
///
/// - `post-clear` — the round was deleted and rebuilt, so each bundle appears
///   twice in the WAL and the originals must be recovered.
/// - `pre-clear` — the same round, untouched. Recovery must do nothing.
///
/// The fixture binaries are generated, never committed — see
/// `Fixtures/make_fixtures.py`. Until they are generated this suite skips
/// rather than fails, so a clean checkout is green.
///
/// The recovery itself was validated against the real affected database shared
/// by the team: run blind against the post-clear capture, it reproduced all
/// three bundles' original secrets exactly, and returned an empty plan for the
/// pre-clear capture. Those captures hold live voting material and are not in
/// this repository.
@Suite(.enabled(if: DelegationWalRecoveryTests.fixturesAreGenerated))
struct DelegationWalRecoveryTests {
    /// `make_fixtures.py` has been run and both fixture sets are on disk.
    static var fixturesAreGenerated: Bool {
        [Fixture.postClear, .preClear].allSatisfy { fixture in
            FileManager.default.fileExists(
                atPath: InjectedDatabase.fixtureDirectory
                    .appendingPathComponent(fixture.rawValue, isDirectory: true)
                    .appendingPathComponent("voting.sqlite3-wal")
                    .path
            )
        }
    }

    enum Fixture: String {
        case postClear = "post-clear"
        case preClear = "pre-clear"
    }

    enum Expected {
        static let roundId = String(repeating: "4a", count: 32)
        static let bundleCount = 3

        /// Generation 0 — what the user actually broadcast.
        static let originalVanCommRand = [
            String(repeating: "a0", count: 31) + "00",
            String(repeating: "a1", count: 31) + "01",
            String(repeating: "a2", count: 31) + "02"
        ]

        /// Generation 1 — what `prepareFreshRound` regenerated.
        static let rebuiltVanCommRand = [
            String(repeating: "a0", count: 31) + "08",
            String(repeating: "a1", count: 31) + "09",
            String(repeating: "a2", count: 31) + "0a"
        ]

        static let originalGovComm = [
            String(repeating: "c0", count: 31) + "00",
            String(repeating: "c1", count: 31) + "01",
            String(repeating: "c2", count: 31) + "02"
        ]

        static let weights: [UInt64] = [130_000_000, 130_000_000, 26_000_000]
    }

    // MARK: - Recovery from the WAL

    @Test func recoversEveryClearedBundleFromTheWriteAheadLog() throws {
        let injected = try InjectedDatabase(.postClear)

        let plan = try DelegationWalRecovery.plan(walURL: injected.walURL, roundId: Expected.roundId)

        #expect(plan.needsRecovery)
        #expect(plan.replacements.count == Expected.bundleCount)

        for (index, replacement) in plan.replacements.enumerated() {
            #expect(replacement.original.bundleIndex == UInt32(index))
            #expect(replacement.original.vanCommRand.hexString == Expected.originalVanCommRand[index])
            #expect(replacement.original.van.hexString == Expected.originalGovComm[index])
            #expect(replacement.original.totalNoteValue == Expected.weights[index])
            // The rebuild is what SQL would return today; it is not what we restore.
            #expect(replacement.current?.vanCommRand.hexString == Expected.rebuiltVanCommRand[index])
        }
    }

    /// The recovered value must come from an image written before the wipe, not
    /// the newest one — that is the whole point of reading superseded state.
    @Test func restoresTheOlderImageNotTheRebuiltOne() throws {
        let injected = try InjectedDatabase(.postClear)

        let plan = try DelegationWalRecovery.plan(walURL: injected.walURL, roundId: Expected.roundId)

        for replacement in plan.replacements {
            let current = try #require(replacement.current)
            #expect(replacement.original.origin < current.origin)
            #expect(replacement.original.vanCommRand != current.vanCommRand)
        }
    }

    @Test func recoveredBlindingFactorsAreCanonicalPallasElements() throws {
        let injected = try InjectedDatabase(.postClear)

        let plan = try DelegationWalRecovery.plan(walURL: injected.walURL, roundId: Expected.roundId)

        #expect(plan.replacements.isEmpty == false)
        for replacement in plan.replacements {
            #expect(DelegationWalRecovery.isCanonicalPallasElement(replacement.original.vanCommRand))
        }
    }

    // MARK: - Idempotence

    /// A round that was never cleared must produce an empty plan. Its bundles
    /// appear in the WAL once each, however often their page was rewritten.
    @Test func doesNothingWhenTheRoundWasNeverCleared() throws {
        let injected = try InjectedDatabase(.preClear)

        let plan = try DelegationWalRecovery.plan(walURL: injected.walURL, roundId: Expected.roundId)

        #expect(plan.needsRecovery == false)
        #expect(plan.replacements.isEmpty)
    }

    /// The pre-clear fixture is only meaningful if the bundles really are in
    /// its WAL — an empty plan for the wrong reason would pass silently.
    @Test func untouchedRoundStillHasItsBundlesInTheLog() throws {
        let injected = try InjectedDatabase(.preClear)

        let recovered = try DelegationWalRecovery.recover(
            walURL: injected.walURL,
            roundId: Expected.roundId
        )

        #expect(recovered.count == Expected.bundleCount)
        for (index, bundle) in recovered.sorted(by: { $0.bundleIndex < $1.bundleIndex }).enumerated() {
            #expect(bundle.vanCommRand.hexString == Expected.originalVanCommRand[index])
        }
    }

    @Test func planIsStableAcrossRepeatedRuns() throws {
        let injected = try InjectedDatabase(.postClear)

        let first = try DelegationWalRecovery.plan(walURL: injected.walURL, roundId: Expected.roundId)
        let second = try DelegationWalRecovery.plan(walURL: injected.walURL, roundId: Expected.roundId)

        #expect(first == second)
    }

    @Test func ignoresRoundsOtherThanTheOneAsked() throws {
        let injected = try InjectedDatabase(.postClear)

        let plan = try DelegationWalRecovery.plan(
            walURL: injected.walURL,
            roundId: String(repeating: "0", count: 64)
        )

        #expect(plan.needsRecovery == false)
    }

    // MARK: - Non-destructiveness

    /// Recovery must never write to the files it reads. Opening the database
    /// through SQLite would checkpoint the WAL and destroy the very frames the
    /// recovery depends on, so this pins all three files on both sides.
    @Test func leavesTheInjectedFilesByteForByteIdentical() throws {
        let injected = try InjectedDatabase(.postClear)

        let databaseBefore = try Data(contentsOf: injected.databaseURL)
        let walBefore = try Data(contentsOf: injected.walURL)
        let shmBefore = try Data(contentsOf: injected.shmURL)

        _ = try DelegationWalRecovery.plan(walURL: injected.walURL, roundId: Expected.roundId)

        #expect(try Data(contentsOf: injected.databaseURL) == databaseBefore)
        #expect(try Data(contentsOf: injected.walURL) == walBefore)
        #expect(try Data(contentsOf: injected.shmURL) == shmBefore)
    }

    // MARK: - Escrow hand-off

    /// Recovery only reads; escrowing the result is what makes the secret
    /// survive the next wipe.
    @Test func recoveredBundlesAreEscrowedForLaterReimport() async throws {
        let injected = try InjectedDatabase(.postClear)
        let plan = try DelegationWalRecovery.plan(walURL: injected.walURL, roundId: Expected.roundId)

        let escrowed = LockIsolated<[DelegationEscrowEntry]>([])
        let escrow = DelegationEscrowClient(
            record: { entry in escrowed.withValue { $0.append(entry) } },
            entries: { roundId in escrowed.value.filter { $0.roundId == roundId } },
            holdsDelegation: { roundId in escrowed.value.contains { $0.roundId == roundId } },
            forget: { roundId in escrowed.withValue { $0.removeAll { $0.roundId == roundId } } },
            reset: { escrowed.withValue { $0.removeAll() } }
        )

        for replacement in plan.replacements {
            try await escrow.record(
                DelegationEscrowEntry(
                    roundId: replacement.original.roundId,
                    bundleIndex: replacement.original.bundleIndex,
                    vanCommRand: replacement.original.vanCommRand,
                    van: replacement.original.van,
                    totalNoteValue: replacement.original.totalNoteValue,
                    createdAt: Date(timeIntervalSince1970: 0)
                )
            )
        }

        #expect(await escrow.holdsDelegation(Expected.roundId))
        let stored = try await escrow.entries(Expected.roundId).sorted { $0.bundleIndex < $1.bundleIndex }
        #expect(stored.count == Expected.bundleCount)
        for (index, entry) in stored.enumerated() {
            #expect(entry.vanCommRand.hexString == Expected.originalVanCommRand[index])
        }
    }

    // MARK: - Database-file carving

    /// The database file covers what the WAL cannot: a clean close checkpoints
    /// and unlinks the WAL, and from then on the only surviving copies are the
    /// deleted cells left in the database itself.
    @Test func carvesTheDatabaseFileWhenTheLogIsGone() throws {
        let injected = try InjectedDatabase(.postClear)
        try FileManager.default.removeItem(at: injected.walURL)

        let rows = try DelegationWalRecovery.recover(
            databaseURL: injected.databaseURL,
            roundId: Expected.roundId
        )

        // Whatever it finds must be well-formed; the point of this test is that
        // the database path runs at all and never invents rows.
        for row in rows {
            #expect(row.vanCommRand.count == 32)
            #expect(row.roundId == Expected.roundId)
            #expect(row.origin == .databaseLive || row.origin == .databaseFreeSpace)
        }
    }

    /// Reading both files must never lose what reading the log alone found.
    @Test func combiningBothFilesIsASupersetOfTheLogAlone() throws {
        let injected = try InjectedDatabase(.postClear)

        let logOnly = try DelegationWalRecovery.recover(
            walURL: injected.walURL,
            roundId: Expected.roundId
        )
        let both = try DelegationWalRecovery.recover(
            databaseURL: injected.databaseURL,
            walURL: injected.walURL,
            roundId: Expected.roundId
        )

        for row in logOnly {
            #expect(
                both.contains { $0.bundleIndex == row.bundleIndex && $0.vanCommRand == row.vanCommRand },
                "combining the two files dropped bundle \(row.bundleIndex)"
            )
        }
    }

    /// The combined plan must reach the same verdict as the log-only plan on a
    /// round the log fully covers — adding a source must not change the answer.
    @Test func combinedPlanAgreesWithTheLogOnlyPlan() throws {
        let injected = try InjectedDatabase(.postClear)

        let logOnly = try DelegationWalRecovery.plan(
            walURL: injected.walURL,
            roundId: Expected.roundId
        )
        let both = try DelegationWalRecovery.plan(
            databaseURL: injected.databaseURL,
            walURL: injected.walURL,
            roundId: Expected.roundId
        )

        #expect(both.needsRecovery == logOnly.needsRecovery)
        #expect(
            both.replacements.map(\.original.vanCommRand)
                == logOnly.replacements.map(\.original.vanCommRand)
        )
    }

    /// Idempotence must survive the extra source: an untouched round stays a
    /// no-op when the database file is carved as well.
    @Test func combinedPlanStillDoesNothingForAnUntouchedRound() throws {
        let injected = try InjectedDatabase(.preClear)

        let plan = try DelegationWalRecovery.plan(
            databaseURL: injected.databaseURL,
            walURL: injected.walURL,
            roundId: Expected.roundId
        )

        #expect(plan.needsRecovery == false)
    }

    /// A missing log is the normal state after a clean close, not an error.
    @Test func toleratesAnAbsentWriteAheadLog() throws {
        let injected = try InjectedDatabase(.preClear)
        try FileManager.default.removeItem(at: injected.walURL)

        let plan = try DelegationWalRecovery.plan(
            databaseURL: injected.databaseURL,
            walURL: injected.walURL,
            roundId: Expected.roundId
        )

        #expect(plan.needsRecovery == false)
    }

    /// Origin ordering is what lets `plan` pick the original without a clock:
    /// released space predates live rows, and both predate the log.
    @Test func originOrdersOldestToNewest() {
        #expect(DelegationWalRecovery.Origin.databaseFreeSpace < .databaseLive)
        #expect(DelegationWalRecovery.Origin.databaseLive < .walFrame(0))
        #expect(DelegationWalRecovery.Origin.walFrame(0) < .walFrame(1))
    }

    @Test func rejectsBytesThatAreNotADatabase() {
        let rows = DelegationWalRecovery.recover(databaseBytes: [UInt8](repeating: 0x41, count: 8_192))

        #expect(rows.isEmpty)
    }
}

// MARK: - Fixture injection

extension DelegationWalRecoveryTests {
    /// Copies one fixture's `voting.sqlite3` triple into a fresh directory,
    /// mirroring the on-device layout. Each instance gets its own directory so
    /// the suite stays safe under Swift Testing's parallel execution, and the
    /// directory is removed on teardown.
    final class InjectedDatabase {
        let directory: URL
        let databaseURL: URL
        let walURL: URL
        let shmURL: URL

        init(_ fixture: Fixture) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("voting-recovery-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            databaseURL = directory.appendingPathComponent("voting.sqlite3")
            walURL = directory.appendingPathComponent("voting.sqlite3-wal")
            shmURL = directory.appendingPathComponent("voting.sqlite3-shm")

            let source = Self.fixtureDirectory.appendingPathComponent(
                fixture.rawValue,
                isDirectory: true
            )
            for (name, destination) in [
                ("voting.sqlite3", databaseURL),
                ("voting.sqlite3-wal", walURL),
                ("voting.sqlite3-shm", shmURL)
            ] {
                try FileManager.default.copyItem(
                    at: source.appendingPathComponent(name),
                    to: destination
                )
            }
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        /// Read from the source tree rather than a test bundle, so the binary
        /// fixtures never ship inside an app or test bundle. The simulator
        /// shares the host filesystem, so this resolves locally and in CI.
        static var fixtureDirectory: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures", isDirectory: true)
        }
    }
}
#endif
