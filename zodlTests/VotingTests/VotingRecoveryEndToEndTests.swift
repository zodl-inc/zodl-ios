#if VOTING_ENABLED
import Testing
import Foundation
import SQLite3
@testable import zodl_internal

/// End-to-end recovery against a database this test builds itself.
///
/// No committed fixtures: the database, its write-ahead log and its shared-memory
/// index are created here with real SQLite, corrupted the way the app corrupted
/// them, and then recovered. That keeps the test honest — the bytes it parses
/// were laid out by SQLite, not by us — and keeps binaries out of the repository.
///
/// The corruption reproduces the incident exactly: a round is delegated, the
/// round row is deleted (`bundles` cascading away with it, taking
/// `van_comm_rand`), and a fresh round is rebuilt in its place with newly
/// sampled secrets. Through SQL the original is gone for good. It survives only
/// in superseded write-ahead log frames.
@Suite struct VotingRecoveryEndToEndTests {
    // MARK: - Recovery

    @Test func recoversEveryOriginalSecretFromACorruptedDatabase() throws {
        let corrupted = try CorruptedDatabase(rebuildAfterClearing: true)

        let plan = try DelegationWalRecovery.plan(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )

        #expect(plan.needsRecovery)
        #expect(plan.replacements.count == Fixture.bundleCount)
        for (index, replacement) in plan.replacements.enumerated() {
            #expect(replacement.original.bundleIndex == UInt32(index))
            #expect(replacement.original.vanCommRand.hexString == Fixture.originalRand[index])
            #expect(replacement.current?.vanCommRand.hexString == Fixture.rebuiltRand[index])
        }
    }

    /// The recovered value must come from an image written before the wipe.
    @Test func recoveredSecretsPredateTheOnesThatReplacedThem() throws {
        let corrupted = try CorruptedDatabase(rebuildAfterClearing: true)

        let plan = try DelegationWalRecovery.plan(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )

        for replacement in plan.replacements {
            let current = try #require(replacement.current)
            #expect(replacement.original.origin < current.origin)
        }
    }

    @Test func recoveredSecretsAreCanonicalPallasElements() throws {
        let corrupted = try CorruptedDatabase(rebuildAfterClearing: true)

        let plan = try DelegationWalRecovery.plan(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )

        #expect(plan.replacements.isEmpty == false)
        for replacement in plan.replacements {
            #expect(DelegationWalRecovery.isCanonicalPallasElement(replacement.original.vanCommRand))
        }
    }

    // MARK: - The artifact itself

    /// The write-ahead log and the shared-memory index are part of the artifact,
    /// not incidental clutter. The log is where the recovered bytes live, and
    /// its presence is what says the database was captured before a clean close
    /// checkpointed it away.
    @Test func theCapturedArtifactIsAWholeThreeFileSet() throws {
        let corrupted = try CorruptedDatabase(rebuildAfterClearing: true)

        for url in [corrupted.databaseURL, corrupted.walURL, corrupted.shmURL] {
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "missing \(url.lastPathComponent) — the trio must be captured together"
            )
            let size = try Data(contentsOf: url).count
            #expect(size > 0, "\(url.lastPathComponent) is empty")
        }

        // A WAL that still carries frames is the whole point: had SQLite
        // checkpointed, the superseded images would already be overwritten.
        let wal = try Data(contentsOf: corrupted.walURL)
        #expect(wal.count > 32, "the log holds only a header, so there is nothing to recover from")
    }

    /// Through SQL the original secrets are unreachable — that is what makes
    /// this a recovery rather than a query.
    ///
    /// Deliberately run against a *second* copy: opening a database checkpoints
    /// and unlinks its log, which would destroy the very frames the other tests
    /// read. The same trap the recovery code exists to avoid.
    @Test func theOriginalSecretsAreUnreachableThroughSQL() throws {
        let corrupted = try CorruptedDatabase(rebuildAfterClearing: true)
        let queryable = try corrupted.duplicate()

        let visible = try queryable.queryVanCommRands()

        #expect(visible == Fixture.rebuiltRand, "SQL must see only the rebuilt secrets")
        for original in Fixture.originalRand {
            #expect(visible.contains(original) == false)
        }
    }

    // MARK: - Idempotence

    /// The same construction without the clearing step. Every bundle has one
    /// secret, so there is nothing to restore and recovery must not act.
    @Test func anUncorruptedDatabaseYieldsNothingToRecover() throws {
        let healthy = try CorruptedDatabase(rebuildAfterClearing: false)

        let plan = try DelegationWalRecovery.plan(
            databaseURL: healthy.databaseURL,
            walURL: healthy.walURL,
            roundId: Fixture.roundId
        )

        #expect(plan.needsRecovery == false)
        #expect(plan.replacements.isEmpty)
    }

    /// …but its bundles really are in the log, so the empty plan above is a
    /// decision, not an accident of finding nothing.
    @Test func anUncorruptedDatabaseStillHasItsBundlesInTheLog() throws {
        let healthy = try CorruptedDatabase(rebuildAfterClearing: false)

        let rows = try DelegationWalRecovery.recover(
            databaseURL: healthy.databaseURL,
            walURL: healthy.walURL,
            roundId: Fixture.roundId
        )

        #expect(rows.count == Fixture.bundleCount)
        for (index, row) in rows.sorted(by: { $0.bundleIndex < $1.bundleIndex }).enumerated() {
            #expect(row.vanCommRand.hexString == Fixture.originalRand[index])
        }
    }

    // MARK: - Non-destructiveness

    @Test func recoveryLeavesAllThreeFilesByteForByteIdentical() throws {
        let corrupted = try CorruptedDatabase(rebuildAfterClearing: true)
        let before = try corrupted.allURLs.map { try Data(contentsOf: $0) }

        _ = try DelegationWalRecovery.plan(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )

        let after = try corrupted.allURLs.map { try Data(contentsOf: $0) }
        #expect(before == after)
    }
}
#endif
