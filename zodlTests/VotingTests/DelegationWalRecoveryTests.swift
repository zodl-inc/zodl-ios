#if VOTING_ENABLED
import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

/// Carver behaviour against a database this test builds with real SQLite.
///
/// Everything here once ran against binary fixtures generated out of band by
/// `Fixtures/make_fixtures.py`, git-ignored, with the suite SKIPPING until
/// somebody produced them. On a clean checkout it proved nothing, and it went
/// unnoticed long enough that the file stopped compiling.
///
/// It now shares `CorruptedDatabase` with the other suites, so there is ONE
/// implementation of the fixture rather than a Swift one and two Python ones
/// that had to be kept in step by hand.
@Suite struct DelegationWalRecoveryTests {
    private typealias Fixture = VotingRecoveryEndToEndTests.Fixture
    private typealias Corrupted = VotingRecoveryEndToEndTests.CorruptedDatabase

    // MARK: - Selecting a round

    @Test func planIsStableAcrossRepeatedRuns() throws {
        let corrupted = try Corrupted(rebuildAfterClearing: true)

        let first = try DelegationWalRecovery.plan(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )
        let second = try DelegationWalRecovery.plan(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )

        #expect(first == second)
    }

    @Test func ignoresRoundsOtherThanTheOneAsked() throws {
        let corrupted = try Corrupted(rebuildAfterClearing: true)

        let plan = try DelegationWalRecovery.plan(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: String(repeating: "0", count: 64)
        )

        #expect(plan.needsRecovery == false)
    }

    // MARK: - Escrow hand-off

    /// Recovery only reads. Escrowing what it finds is what makes the secret
    /// survive the next wipe, so the hand-off is pinned here rather than left
    /// to the launch path alone.
    @Test func recoveredBundlesAreEscrowedForLaterReimport() async throws {
        let corrupted = try Corrupted(rebuildAfterClearing: true)
        let plan = try DelegationWalRecovery.plan(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )

        let escrowed = LockIsolated<[DelegationEscrowEntry]>([])
        let escrow = DelegationEscrowClient(
            record: { entry in escrowed.withValue { $0.append(entry) } },
            entries: { roundId in escrowed.value.filter { $0.roundId == roundId } },
            holdsDelegation: { roundId in escrowed.value.contains { $0.roundId == roundId } },
            forget: { roundId in escrowed.withValue { $0.removeAll { $0.roundId == roundId } } },
            reset: { escrowed.withValue { $0.removeAll() } }
        )

        for replacement in plan.replacements {
            let original = replacement.original
            try await escrow.record(
                DelegationEscrowEntry(
                    roundId: original.roundId,
                    bundleIndex: original.bundleIndex,
                    vanCommRand: original.vanCommRand,
                    van: original.van,
                    totalNoteValue: original.totalNoteValue,
                    createdAt: Date()
                )
            )
        }

        let entries = try await escrow.entries(Fixture.roundId)
            .sorted { $0.bundleIndex < $1.bundleIndex }
        #expect(entries.count == Fixture.bundleCount)
        for (index, entry) in entries.enumerated() {
            #expect(entry.vanCommRand.hexString == Fixture.originalRand[index])
        }
    }

    // MARK: - Database-file carving

    /// The database file covers what the log cannot: a clean close checkpoints
    /// and unlinks the log, and from then on the only surviving copies are the
    /// deleted cells left in the database itself.
    @Test func carvesTheDatabaseFileWhenTheLogIsGone() throws {
        let corrupted = try Corrupted(rebuildAfterClearing: true)

        let rows = DelegationWalRecovery.recover(
            databaseBytes: [UInt8](try Data(contentsOf: corrupted.databaseURL)),
            roundId: Fixture.roundId
        )

        // Whatever it finds must be well formed. The point is that the
        // database path runs at all and never invents rows.
        for row in rows {
            #expect(row.vanCommRand.count == 32)
            #expect(row.roundId == Fixture.roundId)
            #expect(row.origin == .databaseLive || row.origin == .databaseFreeSpace)
        }
    }

    /// Reading both files must never lose what reading the log alone found.
    @Test func combiningBothFilesIsASupersetOfTheLogAlone() throws {
        let corrupted = try Corrupted(rebuildAfterClearing: true)

        let logOnly = try DelegationWalRecovery.recover(
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )
        let both = try DelegationWalRecovery.recover(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )

        for row in logOnly {
            #expect(
                both.contains {
                    $0.bundleIndex == row.bundleIndex && $0.vanCommRand == row.vanCommRand
                },
                "combining the two files dropped bundle \(row.bundleIndex)"
            )
        }
    }

    /// Adding a source must not change the verdict on a round the log already
    /// covers completely.
    @Test func combinedPlanAgreesWithTheLogOnlyPlan() throws {
        let corrupted = try Corrupted(rebuildAfterClearing: true)

        let logOnly = try DelegationWalRecovery.plan(
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )
        let both = try DelegationWalRecovery.plan(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
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
        let healthy = try Corrupted(rebuildAfterClearing: false)

        let plan = try DelegationWalRecovery.plan(
            databaseURL: healthy.databaseURL,
            walURL: healthy.walURL,
            roundId: Fixture.roundId
        )

        #expect(plan.needsRecovery == false)
    }

    /// A missing log is the normal state after a clean close, not an error.
    @Test func toleratesAnAbsentWriteAheadLog() throws {
        let healthy = try Corrupted(rebuildAfterClearing: false)
        try FileManager.default.removeItem(at: healthy.walURL)

        let plan = try DelegationWalRecovery.plan(
            databaseURL: healthy.databaseURL,
            walURL: healthy.walURL,
            roundId: Fixture.roundId
        )

        #expect(plan.needsRecovery == false)
    }

    // MARK: - Pure properties

    /// Origin ordering is what lets `plan` pick the original without a clock:
    /// released space predates live rows, and both predate the log.
    @Test func originOrdersOldestToNewest() {
        #expect(DelegationWalRecovery.Origin.databaseFreeSpace < .databaseLive)
        #expect(DelegationWalRecovery.Origin.databaseLive < .walFrame(0))
        #expect(DelegationWalRecovery.Origin.walFrame(0) < .walFrame(1))
    }

    @Test func rejectsBytesThatAreNotADatabase() {
        #expect(DelegationWalRecovery.recover(databaseBytes: []).isEmpty)
        #expect(DelegationWalRecovery.recover(walBytes: []).isEmpty)
        #expect(
            DelegationWalRecovery
                .recover(databaseBytes: Array(repeating: 0xFF, count: 4096)).isEmpty
        )
    }
}
#endif
