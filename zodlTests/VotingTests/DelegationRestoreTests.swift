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

@Suite struct DelegationRestoreOrchestrationTests {
    private let roundId = String(repeating: "4a", count: 31) + "01"

    private var roundParams: VotingRoundParams {
        VotingRoundParams(
            voteRoundId: Data(repeating: 0x4a, count: 31) + Data([0x01]),
            snapshotHeight: 1,
            eaPK: Data(repeating: 0x07, count: 32),
            ncRoot: Data(repeating: 0x07, count: 32),
            nullifierIMTRoot: Data(repeating: 0x07, count: 32)
        )
    }

    private func entry(_ index: UInt32) -> DelegationEscrowEntry {
        DelegationEscrowEntry(
            roundId: roundId,
            bundleIndex: index,
            vanCommRand: Data(repeating: UInt8(0xA0 + index), count: 31) + Data([0x01]),
            van: Data(repeating: 0xC0, count: 32),
            totalNoteValue: 130_000_000,
            delegationTxHash: String(repeating: String(format: "%02x", 0xD0 + index), count: 32),
            source: .recovered,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private final class Recorder: @unchecked Sendable {
        var requests: [RecoveredDelegationImportRequest] = []
        var result: RecoveredDelegationRestoreOutcome = .restored
        var error: Error?

        func client() -> VotingCryptoClient {
            var client = VotingCryptoClient.testValue
            client.restoreRecoveredDelegation = { [self] request in
                requests.append(request)
                if let error { throw error }
                return result
            }
            return client
        }
    }

    private struct Refusal: LocalizedError {
        var errorDescription: String? {
            "restore_recovered_delegation failed: round holds 2 cast vote(s); nothing may be cleared"
        }
    }

    private struct Boom: LocalizedError {
        var errorDescription: String? { "disk I/O error" }
    }

    @Test func aCompleteEscrowIsHandedToTheSdkOnce() async {
        let recorder = Recorder()

        let outcome = await DelegationRestore.restoreIfNeeded(
            roundId: roundId, roundParams: roundParams, networkId: 1, hotkeyStoredSecret: Data([1, 2, 3]),
            escrowEntries: [entry(0), entry(1)], expectedBundleCount: 2, crypto: recorder.client()
        )

        #expect(outcome == .restored(bundleCount: 2))
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.bundles.map(\.bundleIndex) == [0, 1])
        #expect(recorder.requests.first?.voteChainId == DelegationRestore.voteChainId)
        #expect(recorder.requests.first?.hotkeyStoredSecret == Data([1, 2, 3]))
    }

    @Test func theSdkSayingAlreadyRestoredIsReportedAsSuch() async {
        let recorder = Recorder()
        recorder.result = .alreadyRestored

        let outcome = await DelegationRestore.restoreIfNeeded(
            roundId: roundId, roundParams: roundParams, networkId: 1, hotkeyStoredSecret: Data([1]),
            escrowEntries: [entry(0)], expectedBundleCount: 1, crypto: recorder.client()
        )

        #expect(outcome == .alreadyRestored)
    }

    @Test func anIncompleteEscrowNeverReachesTheSdk() async {
        let recorder = Recorder()

        let outcome = await DelegationRestore.restoreIfNeeded(
            roundId: roundId, roundParams: roundParams, networkId: 1, hotkeyStoredSecret: Data([1]),
            escrowEntries: [entry(0)], expectedBundleCount: 2, crypto: recorder.client()
        )

        #expect(outcome == .notApplicable(reason: "escrow holds no complete recovered delegation"))
        #expect(recorder.requests.isEmpty)
    }

    @Test func noHotkeyNeverReachesTheSdk() async {
        let recorder = Recorder()

        let outcome = await DelegationRestore.restoreIfNeeded(
            roundId: roundId, roundParams: roundParams, networkId: 1, hotkeyStoredSecret: nil,
            escrowEntries: [entry(0)], expectedBundleCount: 1, crypto: recorder.client()
        )

        #expect(outcome == .notApplicable(reason: "no voting hotkey on this device"))
        #expect(recorder.requests.isEmpty)
    }

    @Test func aGuardRefusalIsReportedWithItsReason() async {
        let recorder = Recorder()
        recorder.error = Refusal()

        let outcome = await DelegationRestore.restoreIfNeeded(
            roundId: roundId, roundParams: roundParams, networkId: 1, hotkeyStoredSecret: Data([1]),
            escrowEntries: [entry(0)], expectedBundleCount: 1, crypto: recorder.client()
        )

        #expect(outcome == .refused(reason: "round holds 2 cast vote(s); nothing may be cleared"))
    }

    @Test func anyOtherErrorIsAFailure() async {
        let recorder = Recorder()
        recorder.error = Boom()

        let outcome = await DelegationRestore.restoreIfNeeded(
            roundId: roundId, roundParams: roundParams, networkId: 1, hotkeyStoredSecret: Data([1]),
            escrowEntries: [entry(0)], expectedBundleCount: 1, crypto: recorder.client()
        )

        #expect(outcome == .failed)
    }
}
#endif
