#if RECOVERY_VOTING_ENABLED
import Testing
import Foundation
@testable import zodl_internal

@Suite struct DelegationRestorePackageTests {
    private let roundId = String(repeating: "4a", count: 31) + "01"

    private func entry(
        _ index: UInt32,
        hash: String? = nil,
        source: DelegationEscrowEntry.Source = .recovered,
        weight: UInt64 = 130_000_000
    ) -> DelegationEscrowEntry {
        DelegationEscrowEntry(
            roundId: roundId,
            bundleIndex: index,
            vanCommRand: Data(repeating: UInt8(0xA0 + index), count: 31) + Data([0x01]),
            van: Data(repeating: 0xC0, count: 32),
            totalNoteValue: weight,
            delegationTxHash: hash ?? String(repeating: String(format: "%02x", 0xD0 + index), count: 32),
            source: source,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func entryWithoutHash(_ index: UInt32) -> DelegationEscrowEntry {
        DelegationEscrowEntry(
            roundId: roundId,
            bundleIndex: index,
            vanCommRand: Data(repeating: UInt8(0xA0 + index), count: 31) + Data([0x01]),
            van: Data(repeating: 0xC0, count: 32),
            totalNoteValue: 130_000_000,
            delegationTxHash: nil,
            source: .recovered,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func aCompleteEscrowBecomesAPackageInIndexOrder() {
        let package = DelegationRestore.package(from: [entry(2), entry(0), entry(1)], expectedBundleCount: 3)

        #expect(package?.map(\.bundleIndex) == [0, 1, 2])
        #expect(package?.map(\.totalNoteValue) == [130_000_000, 130_000_000, 130_000_000])
        #expect(package?[0].vanCommRand == Data(repeating: 0xA0, count: 31) + Data([0x01]))
    }

    @Test func liveCapturesAreNotPartOfARecoveredPackage() {
        #expect(DelegationRestore.package(from: [entry(0), entry(1, source: .liveCapture)], expectedBundleCount: 2) == nil)
    }

    @Test func aGapInTheIndicesIsIncomplete() {
        #expect(DelegationRestore.package(from: [entry(0), entry(2)], expectedBundleCount: nil) == nil)
    }

    @Test func aBundleWithoutATransactionHashCannotBeImported() {
        #expect(DelegationRestore.package(from: [entry(0), entryWithoutHash(1)], expectedBundleCount: nil) == nil)
    }

    @Test func duplicateAndMalformedHashesAreRejected() {
        let shared = String(repeating: "ee", count: 32)
        #expect(DelegationRestore.package(from: [entry(0, hash: shared), entry(1, hash: shared)], expectedBundleCount: nil) == nil)
        #expect(DelegationRestore.package(from: [entry(0, hash: String(repeating: "EE", count: 32))], expectedBundleCount: nil) == nil)
        #expect(DelegationRestore.package(from: [entry(0, hash: "abc")], expectedBundleCount: nil) == nil)
    }

    @Test func aWeightBelowOneBallotIsRejected() {
        #expect(DelegationRestore.package(from: [entry(0, weight: 12_499_999)], expectedBundleCount: nil) == nil)
        #expect(DelegationRestore.package(from: [entry(0, weight: 12_500_000)], expectedBundleCount: nil) != nil)
    }

    @Test func theRoundsBundleCountMustMatchWhenKnown() {
        #expect(DelegationRestore.package(from: [entry(0), entry(1)], expectedBundleCount: 3) == nil)
        #expect(DelegationRestore.package(from: [entry(0), entry(1)], expectedBundleCount: nil)?.count == 2)
    }
}
#endif
