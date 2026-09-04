#if RECOVERY_VOTING_ENABLED
import Foundation
import Testing
@testable import zodl_internal

/// The targeted scan against the incident's database, once a leaf list is
/// available. Until then, the evidence is honestly unavailable.
@Suite struct DelegationEvidenceTests {
    private typealias Fixture = VotingRecoveryEndToEndTests.Fixture
    private typealias Corrupted = VotingRecoveryEndToEndTests.CorruptedDatabase

    private func sources(_ corrupted: Corrupted) -> [DelegationRecoveryClient.Source] {
        [DelegationRecoveryClient.Source(name: "fixture", databaseURL: corrupted.databaseURL)]
    }

    private static func bytes(fromHex hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
        })
    }

    @Test func withoutALeafListTheEvidenceIsUnavailable() throws {
        let corrupted = try Corrupted(rebuildAfterClearing: true)

        #expect(DelegationEvidence.gather(roundId: Fixture.roundId, leaves: nil, sources: sources(corrupted)) == .unavailable)
        #expect(DelegationEvidence.gather(roundId: Fixture.roundId, leaves: [], sources: sources(corrupted)) == .unavailable)
    }

    @Test func theChainsCommitmentIsVerifiedAgainstTheDevice() throws {
        let corrupted = try Corrupted(rebuildAfterClearing: true)

        let evidence = DelegationEvidence.gather(
            roundId: Fixture.roundId,
            leaves: [Self.bytes(fromHex: Fixture.govComm)],
            sources: sources(corrupted)
        )

        #expect(evidence == .verified(bundleCount: Fixture.bundleCount))
    }

    @Test func aCommitmentTheDeviceNeverHeldIsNothingOnDevice() throws {
        let corrupted = try Corrupted(rebuildAfterClearing: true)

        let evidence = DelegationEvidence.gather(
            roundId: Fixture.roundId,
            leaves: [Data(repeating: 0x99, count: 32)],
            sources: sources(corrupted)
        )

        #expect(evidence == .nothingOnDevice)
    }
}
#endif
