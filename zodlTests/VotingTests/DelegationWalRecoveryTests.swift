#if RECOVERY_VOTING_ENABLED
import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

/// Carver behaviour against a database built with real SQLite.
///
/// Shares `CorruptedDatabase` with every other voting suite, so the fixture
/// has one implementation and the expected values have one source. Nothing
/// here is gated or skipped: the database is built in-process, so these run on
/// a clean checkout with no setup.
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
                    delegationTxHash: original.delegationTxHash,
                    source: .recovered,
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

    // MARK: - A rewritten row is not a wiped one

    /// The lifecycle case that reads as damage if `plan` is not careful.
    ///
    /// Bundle rows are rewritten repeatedly as `alpha`, `rk`, `rseed_signed`,
    /// `pczt_sighash` and `delegation_tx_hash` are filled in. Every rewrite
    /// releases the previous cell, and this build of SQLite does not zero it,
    /// so the SAME `van_comm_rand` ends up both live and in released space.
    ///
    /// The carver must not read that as "deleted and never rebuilt". Getting
    /// it wrong would report a healthy, fully delegated round as damaged, and
    /// recovery would act on a round nothing ever harmed.
    @Test func aRowRewrittenAfterCheckpointIsNotAWipedRow() throws {
        let healthy = try Corrupted(rebuildAfterClearing: false, updateAfterCheckpoint: true)

        let plan = try DelegationWalRecovery.plan(
            databaseURL: healthy.databaseURL,
            walURL: healthy.walURL,
            roundId: Fixture.roundId
        )

        #expect(
            plan.needsRecovery == false,
            "a rewritten row was mistaken for a wiped one"
        )
    }

    /// Why the test above cannot fail for the reason it guards against, which
    /// is worth pinning rather than assuming.
    ///
    /// Growing a row forces SQLite to write a new cell and release the old
    /// one, so the same `van_comm_rand` is briefly present twice. The released
    /// copy does NOT come back as a decodable row: freed cells are coalesced
    /// into a freeblock, which destroys the record framing the carver matches
    /// on. Commit 9fd79239 measured the same thing from the other direction,
    /// finding that database-file carving recovers nothing a checkpointed log
    /// could not.
    ///
    /// This is load-bearing for the verdict logic. `plan` treats "every
    /// surviving copy sits in released space" as evidence of a wipe, and that
    /// rule is only safe while an ordinary rewrite cannot manufacture such a
    /// copy. If a future SQLite, page size or column layout makes freed cells
    /// decodable again, this test fails and the verdict rule has to be
    /// revisited before the carver reports healthy rounds as damaged.
    @Test func arewrittenRowLeavesNoDecodableCopyInReleasedSpace() throws {
        let healthy = try Corrupted(rebuildAfterClearing: false, updateAfterCheckpoint: true)

        let rows = DelegationWalRecovery.recover(
            databaseBytes: [UInt8](try Data(contentsOf: healthy.databaseURL)),
            roundId: Fixture.roundId
        )

        #expect(
            rows.contains { $0.origin == .databaseFreeSpace } == false,
            "a freed cell decoded; `plan`'s all-released rule needs revisiting"
        )
    }

    // MARK: - The recovered value is the right column

    /// Every column the assertions do not name is filled with pseudo-random
    /// bytes, so a parser reading the WRONG column cannot return something
    /// that happens to look right.
    ///
    /// This is the check that gives that filler teeth. `van_comm_rand` is
    /// column 5, sandwiched between `note_identity_hashes_blob` and
    /// `dummy_nullifiers`, and several nearby columns -- `rho_signed`,
    /// `alpha`, `rk`, `pczt_sighash` -- are also 32 bytes wide. An off-by-one
    /// in the column index would return one of those, and with a repeated
    /// filler pattern the mistake could be hard to distinguish from a real
    /// value.
    @Test func theRecoveredValueIsTheBlindingFactorAndNotANeighbour() throws {
        let corrupted = try Corrupted(rebuildAfterClearing: true, notesPerBundle: 5)

        let rows = try DelegationWalRecovery.recover(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )
        #expect(rows.isEmpty == false)

        // Everything carved must be one of the two generations of the SECRET.
        // Anything else means a neighbouring column was read instead.
        let expected = Set(Fixture.originalRand + Fixture.rebuiltRand)
        for row in rows {
            #expect(
                expected.contains(row.vanCommRand.hexString),
                """
                bundle \(row.bundleIndex) carried \(row.vanCommRand.hexString.prefix(16)), \
                which is neither generation of van_comm_rand: a different \
                column was decoded
                """
            )
        }
    }

    /// And the filler really is distinct, so the check above cannot pass
    /// because every column happens to hold the same bytes.
    ///
    /// Read through SQL on a second copy, since opening a database
    /// checkpoints and unlinks its log.
    @Test func theColumnsAroundTheSecretHoldDifferentBytes() throws {
        let healthy = try Corrupted(rebuildAfterClearing: false, notesPerBundle: 5)
        let queryable = try healthy.duplicate()

        let secrets = try queryable.queryColumn("van_comm_rand")
        #expect(secrets.count == Fixture.bundleCount)

        // The 32-byte columns nearest the secret, the ones an off-by-one in
        // the column index would land on.
        for neighbour in ["rho_signed", "alpha", "rk", "pczt_sighash", "cmx_new"] {
            let values = try queryable.queryColumn(neighbour)
            #expect(values.count == Fixture.bundleCount)
            for (index, value) in values.enumerated() {
                // `Comment` takes a single interpolated literal, not a
                // concatenation, so the message is built in one piece.
                #expect(
                    value != secrets[index],
                    "\(neighbour) matches van_comm_rand for bundle \(index), so the filler cannot discriminate"
                )
            }
        }

        // And the bundles differ from each other, so a test cannot pass by
        // reading the wrong bundle either.
        #expect(Set(secrets).count == secrets.count)
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
