import Foundation
import Testing
@testable import zodl_internal
@testable import VotingRecovery

/// The decoder against the database the incident actually produced.
@Suite struct VotingDatabaseRecoveryFixtureTests {
    private typealias Fixture = VotingRecoveryEndToEndTests.Fixture
    private typealias Corrupted = VotingRecoveryEndToEndTests.CorruptedDatabase

    private func scan(_ corrupted: Corrupted) throws -> VotingDatabaseRecovery.Report {
        try VotingDatabaseRecovery.recoverAll(
            databaseURL: corrupted.databaseURL,
            walURL: corrupted.walURL,
            roundId: Fixture.roundId,
            walletId: Fixture.walletId
        )
    }

    private func candidates(_ report: VotingDatabaseRecovery.Report, bundle index: Int) -> [VotingDatabaseRecovery.RecoveredBundle] {
        report.candidates.filter { $0.bundleIndex == UInt32(index) }
    }

    @Test func aClearedAndRebuiltRoundYieldsBothGenerationsPerBundle() throws {
        let report = try scan(try Corrupted(rebuildAfterClearing: true))

        for index in 0..<Fixture.bundleCount {
            let rands = Set(candidates(report, bundle: index).map(\.vanCommRand.hexString))
            #expect(rands.contains(Fixture.originalRand[index]), "bundle \(index) lost its original")
            #expect(rands.contains(Fixture.rebuiltRand[index]), "bundle \(index) lost its rebuild")
        }
    }

    /// Nothing here says which generation is the original. The decoder
    /// reports where each was found; the hash and the chain decide.
    @Test func neitherGenerationIsElected() throws {
        let report = try scan(try Corrupted(rebuildAfterClearing: true))

        #expect(report.vanCmx == nil)
        #expect(report.rawTargetHits.isEmpty)
        let original = candidates(report, bundle: 0).first { $0.vanCommRand.hexString == Fixture.originalRand[0] }
        let rebuilt = candidates(report, bundle: 0).first { $0.vanCommRand.hexString == Fixture.rebuiltRand[0] }
        #expect(original != nil && rebuilt != nil)
        #expect(original?.source != rebuilt?.source)
    }

    @Test func anUntouchedRoundYieldsOneCandidatePerBundle() throws {
        let report = try scan(try Corrupted(rebuildAfterClearing: false))

        let perBundle = Dictionary(grouping: report.candidates, by: \.bundleIndex)
        #expect(perBundle.count == Fixture.bundleCount)
        #expect(perBundle.values.allSatisfy { Set($0.map(\.vanCommRand)).count == 1 })
        for index in 0..<Fixture.bundleCount {
            #expect(candidates(report, bundle: index).first?.vanCommRand.hexString == Fixture.originalRand[index])
        }
    }

    /// The hash is written by a LATER statement than the secrets, so this is
    /// a test that the decoder reports the generation that carries it, not
    /// whichever image of the row happened to survive.
    @Test func everyOriginalCarriesTheHashItsGenerationWrote() throws {
        let report = try scan(try Corrupted(rebuildAfterClearing: true))

        for index in 0..<Fixture.bundleCount {
            let originals = candidates(report, bundle: index)
                .filter { $0.vanCommRand.hexString == Fixture.originalRand[index] }
            #expect(
                originals.contains { $0.delegationTxHash == Fixture.txHash(index) },
                "bundle \(index) original without its hash"
            )
            let rebuilds = candidates(report, bundle: index)
                .filter { $0.vanCommRand.hexString == Fixture.rebuiltRand[index] }
            #expect(rebuilds.allSatisfy { $0.delegationTxHash == nil }, "bundle \(index) rebuild with a hash")
        }
    }

    /// Absent is a legitimate answer, and must not be reported as a value.
    @Test func reportsNoHashWhenTheDelegationWasNeverBroadcast() throws {
        let report = try scan(try Corrupted(rebuildAfterClearing: true, storeTxHash: false))

        #expect(report.candidates.isEmpty == false, "the secrets should still be recovered")
        #expect(report.candidates.allSatisfy { $0.delegationTxHash == nil })
    }

    @Test func everyCandidateIsACanonicalPallasElement() throws {
        let report = try scan(try Corrupted(rebuildAfterClearing: true))

        #expect(report.candidates.isEmpty == false)
        for candidate in report.candidates {
            #expect(VotingDatabaseRecovery.isCanonicalPallasElement(candidate.vanCommRand))
        }
    }

    /// Every generation has an intact image: the commitment and weight its
    /// row held, under its own blinding.
    ///
    /// Other images may appear beside it. The rebuild's rows land in the
    /// space the cleared originals freed, and with some filler a partly
    /// overwritten image still decodes as a row: the blinding survives, the
    /// commitment and weight behind it do not. That is why the escrow keeps
    /// candidates apart by commitment as well as blinding, and why the
    /// restore recomputes each candidate's commitment before offering it.
    @Test func everyGenerationHasAnIntactImage() throws {
        let report = try scan(try Corrupted(rebuildAfterClearing: true))

        for rand in Fixture.originalRand + Fixture.rebuiltRand {
            let intact = report.candidates.contains {
                $0.vanCommRand.hexString == rand
                    && $0.vanCmx.hexString == Fixture.govComm
                    && $0.totalNoteValue == Fixture.totalNoteValue
                    && $0.walletId == Fixture.walletId
            }
            #expect(intact, "no intact image of \(rand.prefix(6))")
        }
    }

    /// Reading is not writing: the next launch must have exactly as much to
    /// work with as this one did.
    @Test func scanningLeavesAllThreeFilesByteForByteIdentical() throws {
        let corrupted = try Corrupted(rebuildAfterClearing: true)
        let before = try corrupted.allURLs.map { try Data(contentsOf: $0) }

        _ = try scan(corrupted)

        let after = try corrupted.allURLs.map { try Data(contentsOf: $0) }
        #expect(before == after)
    }
}
