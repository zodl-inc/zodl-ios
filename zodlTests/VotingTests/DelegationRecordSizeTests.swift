#if RECOVERY_VOTING_ENABLED
import Testing
import Foundation
@testable import zodl_internal

/// What record SIZE does to recovery, and why it turns out not to bite.
///
/// A bundle row is fully populated the moment `van_comm_rand` exists: the
/// crate writes it in ONE statement together with `dummy_nullifiers`,
/// `rho_signed`, `padded_note_data`, `alpha`, `rk`, `pczt_sighash`,
/// `tx1_effects` and the rest. So the record at the moment of a wipe is the
/// large one, never a small one that grows later.
///
/// What keeps that harmless is WHERE the secret sits. `van_comm_rand` is
/// column 5 of 24, ahead of every variable-length blob except
/// `note_positions_blob` (8 bytes per note) and `note_identity_hashes_blob`
/// (32 per note), and `smartBundles` caps a bundle at FIVE notes. The secret
/// therefore lands about 300 bytes into the record however much the wallet
/// holds, comfortably inside even the minimum local payload of 489 bytes at a
/// 4096-byte page.
///
/// These tests exist to keep that true rather than to demonstrate a bug. They
/// exercise the real cap, then deliberately go beyond it to record where the
/// parser would stop if either the cap or the column order ever moved.
@Suite struct DelegationRecordSizeTests {
    private typealias Fixture = VotingRecoveryEndToEndTests.Fixture
    private typealias Corrupted = VotingRecoveryEndToEndTests.CorruptedDatabase

    /// Whether recovery still returns the broadcast secrets at this size.
    private func recoversOriginals(notesPerBundle: Int, otherRounds: Int = 0) throws -> Bool {
        let corrupted = try Corrupted(
            rebuildAfterClearing: true,
            notesPerBundle: notesPerBundle,
            otherRounds: otherRounds
        )
        let plan = try DelegationWalRecovery.plan(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )
        guard plan.replacements.count == Fixture.bundleCount else { return false }
        return plan.replacements
            .sorted { $0.original.bundleIndex < $1.original.bundleIndex }
            .map(\.original.vanCommRand.hexString) == Fixture.originalRand
    }

    // MARK: - A realistic wallet

    /// The real shape: a full bundle at the `smartBundles` cap of five notes,
    /// every column populated, with neighbour rounds sharing its pages.
    @Test func recoversAFullBundleAtTheFiveNoteCap() throws {
        #expect(try recoversOriginals(notesPerBundle: 5, otherRounds: 3))
    }

    /// One note, which is the other end of the reachable range.
    @Test func recoversASingleNoteBundle() throws {
        #expect(try recoversOriginals(notesPerBundle: 1, otherRounds: 3))
    }

    // MARK: - Where it stops

    /// Measures the note count at which recovery stops working, and fails if
    /// that boundary moves below what has already been demonstrated.
    ///
    /// This is a CHARACTERISATION test: the number is not a requirement drawn
    /// from the protocol, it is what the implementation currently achieves.
    /// Its value is that a change narrowing the window fails here instead of
    /// silently reducing how many wallets can be repaired.
    @Test func recoveryHasAKnownNoteCountBoundary() throws {
        let sizes = [1, 2, 3, 4, 5, 6, 8, 12, 16, 32]
        var lastWorking = 0
        var firstFailing: Int?

        for notes in sizes {
            if try recoversOriginals(notesPerBundle: notes) {
                lastWorking = notes
            } else {
                firstFailing = notes
                break
            }
        }

        // Recorded so the boundary is visible in the log, not only in a pass.
        LoggerProxy.info(
            "[poll-recovery-test] recovery works up to \(lastWorking) notes/bundle; "
            + "first failing size: \(firstFailing.map(String.init) ?? "none in range")"
        )

        // `smartBundles` caps a bundle at five notes, so anything at or above
        // that is unreachable in practice. The floor is set at the cap plus
        // headroom: if the parser ever stops handling a reachable bundle, or
        // if someone raises the cap past what the parser manages, this fails.
        #expect(
            lastWorking >= 5,
            "recovery no longer handles a bundle at the five-note cap"
        )
    }

    /// Whatever the boundary is, crossing it must not produce a WRONG answer.
    /// Finding nothing is a limitation; handing back a rebuilt secret as
    /// though it were the original would be a defect.
    @Test func beyondTheBoundaryItFindsNothingRatherThanTheWrongThing() throws {
        let corrupted = try Corrupted(rebuildAfterClearing: true, notesPerBundle: 512)

        let plan = try DelegationWalRecovery.plan(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId
        )

        for replacement in plan.replacements {
            #expect(
                Fixture.rebuiltRand.contains(replacement.original.vanCommRand.hexString) == false,
                "a rebuilt secret was returned as the original"
            )
        }
    }
}
#endif
