import Testing
import Foundation
@testable import zodl_internal
@testable import VotingRecovery

@Suite struct DelegationRestorePackageTests {
    private let roundId = String(repeating: "4a", count: 31) + "01"

    private func entry(
        _ index: UInt32,
        hash: String? = nil,
        source: DelegationEscrowEntry.Source = .recovered,
        weight: UInt64 = 130_000_000,
        van: Data? = nil,
        rand: UInt8? = nil,
        rank: Int = 0,
        rejected: Bool = false
    ) -> DelegationEscrowEntry {
        DelegationEscrowEntry(
            roundId: roundId,
            bundleIndex: index,
            vanCommRand: Data(repeating: rand ?? UInt8(0xA0 + index), count: 31) + Data([0x01]),
            van: van ?? Data(repeating: 0xC0, count: 32),
            totalNoteValue: weight,
            delegationTxHash: hash ?? String(repeating: String(format: "%02x", 0xD0 + index), count: 32),
            source: source,
            createdAt: Date(timeIntervalSince1970: 0),
            provenanceRank: rank,
            rejectedAt: rejected ? Date(timeIntervalSince1970: 1) : nil
        )
    }

    private func entryWithoutHash(_ index: UInt32, rand: UInt8? = nil, rank: Int = 0) -> DelegationEscrowEntry {
        DelegationEscrowEntry(
            roundId: roundId,
            bundleIndex: index,
            vanCommRand: Data(repeating: rand ?? UInt8(0xA0 + index), count: 31) + Data([0x01]),
            van: Data(repeating: 0xC0, count: 32),
            totalNoteValue: 130_000_000,
            delegationTxHash: nil,
            source: .recovered,
            createdAt: Date(timeIntervalSince1970: 0),
            provenanceRank: rank
        )
    }

    @Test func aCompleteEscrowBecomesAPackageInIndexOrder() {
        let package = DelegationRestore.package(from: [entry(2), entry(0), entry(1)])

        #expect(package?.map(\.bundleIndex) == [0, 1, 2])
        #expect(package?.map(\.totalNoteValue) == [130_000_000, 130_000_000, 130_000_000])
        #expect(package?[0].vanCommRand == Data(repeating: 0xA0, count: 31) + Data([0x01]))
    }

    @Test func liveCapturesAreNotPartOfARecoveredPackage() {
        #expect(DelegationRestore.package(from: [entry(0), entry(1, source: .liveCapture)])?.count == 1)
        #expect(DelegationRestore.package(from: [entry(0, source: .liveCapture)]) == nil)
    }

    @Test func theRunStopsAtTheFirstMissingIndex() {
        #expect(DelegationRestore.package(from: [entry(0), entry(2)])?.map(\.bundleIndex) == [0])
        #expect(DelegationRestore.package(from: [entry(1), entry(2)]) == nil)
    }

    @Test func aBundleWithoutATransactionHashEndsTheRun() {
        #expect(DelegationRestore.package(from: [entry(0), entryWithoutHash(1)])?.count == 1)
        #expect(DelegationRestore.package(from: [entryWithoutHash(0)]) == nil)
    }

    @Test func duplicateAndMalformedHashesEndTheRun() {
        let shared = String(repeating: "ee", count: 32)
        #expect(DelegationRestore.package(from: [entry(0, hash: shared), entry(1, hash: shared)])?.count == 1)
        #expect(DelegationRestore.package(from: [entry(0, hash: String(repeating: "EE", count: 32))]) == nil)
        #expect(DelegationRestore.package(from: [entry(0, hash: "abc")]) == nil)
    }

    @Test func aWeightBelowOneBallotIsRejected() {
        #expect(DelegationRestore.package(from: [entry(0, weight: 12_499_999)]) == nil)
        #expect(DelegationRestore.package(from: [entry(0, weight: 12_500_000)]) != nil)
    }

    @Test func aCommitmentThatIsNotThirtyTwoBytesEndsTheRun() {
        #expect(DelegationRestore.package(from: [entry(0), entry(1, van: Data(repeating: 0xC0, count: 31))])?.count == 1)
        #expect(DelegationRestore.package(from: [entry(0, van: Data())]) == nil)
    }

    @Test func thePackageCarriesTheCommitmentTheRowHeld() {
        let van = Data(repeating: 0xC1, count: 32)
        #expect(DelegationRestore.package(from: [entry(0, van: van)])?.first?.van == van)
    }

    @Test func theBestRankedCandidatePerBundleIsChosen() {
        let package = DelegationRestore.package(from: [
            entry(0, rand: 0xA0, rank: 0), entry(0, rand: 0xA1, rank: 4), entry(1, rand: 0xB0, rank: 3)
        ])
        #expect(package?.map(\.vanCommRand.first) == [0xA1, 0xB0])
    }

    @Test func aRejectedCandidateIsSkippedForTheNextBest() {
        let package = DelegationRestore.package(from: [
            entry(0, rand: 0xA0, rank: 0), entry(0, rand: 0xA1, rank: 4, rejected: true)
        ])
        #expect(package?.map(\.vanCommRand.first) == [0xA0])
    }

    @Test func aBundleWithOnlyRejectedCandidatesEndsTheRun() {
        #expect(DelegationRestore.package(from: [entry(0, rank: 2, rejected: true)]) == nil)
        #expect(DelegationRestore.package(from: [entry(0), entry(1, rejected: true)])?.count == 1)
    }

    /// The live row of a rebuilt round outranks the carved original but was
    /// never accepted by the chain; the original is what restores.
    /// A row image whose later columns a rebuild overwrote decodes with a
    /// commitment its blinding does not open. It is passed over, not fatal.
    @Test func aCandidateWhoseBlindingDoesNotOpenItsCommitmentIsSkipped() {
        let genuine = Data(repeating: 0xC0, count: 32)
        let package = DelegationRestore.package(
            from: [entry(0, van: Data(repeating: 0xC1, count: 32), rand: 0xA0, rank: 4), entry(0, van: genuine, rand: 0xA1, rank: 0)],
            opens: { $0.van == genuine }
        )
        #expect(package?.map(\.vanCommRand.first) == [0xA1])
        #expect(DelegationRestore.package(from: [entry(0)], opens: { _ in false }) == nil)
    }

    @Test func aBetterRankedCandidateThatCannotBeImportedYieldsToOneThatCan() {
        let package = DelegationRestore.package(from: [
            entry(0, rand: 0xA0, rank: 0), entryWithoutHash(0, rand: 0xB0, rank: 3)
        ])
        #expect(package?.map(\.vanCommRand.first) == [0xA0])
    }
}

@Suite struct DelegationRestoreOrchestrationTests {
    private let roundId = String(repeating: "4a", count: 31) + "01"

    private var roundParams: RoundParameters {
        RoundParameters(
            voteRoundId: Data(repeating: 0x4a, count: 31) + Data([0x01]),
            snapshotHeight: 1,
            eaPK: Data(repeating: 0x07, count: 32),
            ncRoot: Data(repeating: 0x07, count: 32),
            nullifierIMTRoot: Data(repeating: 0x07, count: 32)
        )
    }

    private func entry(_ index: UInt32, van: Data? = nil, rand: UInt8? = nil, rank: Int = 0) -> DelegationEscrowEntry {
        DelegationEscrowEntry(
            roundId: roundId,
            bundleIndex: index,
            vanCommRand: Data(repeating: rand ?? UInt8(0xA0 + index), count: 31) + Data([0x01]),
            van: van ?? Data(repeating: 0xC0, count: 32),
            totalNoteValue: 130_000_000,
            delegationTxHash: String(repeating: String(format: "%02x", 0xD0 + index), count: 32),
            source: .recovered,
            createdAt: Date(timeIntervalSince1970: 0),
            provenanceRank: rank
        )
    }

    private final class Recorder: @unchecked Sendable {
        var requests: [RecoveredDelegationImportRequest] = []
        var result: RecoveredDelegationRestoreOutcome = .restored
        var error: Error?

        func client() -> RecoveryBackend {
            RecoveryBackend(
                vanCommitment: { _, _, _, _, _ in Data(repeating: 0xC0, count: 32) },
                restore: { [self] request in
                    requests.append(request)
                    if let error { throw error }
                    return result
                }
            )
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
            escrowEntries: [entry(0), entry(1)], crypto: recorder.client()
        )

        #expect(outcome == .restored(bundleCount: 2))
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.bundles.map(\.bundleIndex) == [0, 1])
        #expect(recorder.requests.first?.voteChainId == DelegationRestore.voteChainId)
        #expect(recorder.requests.first?.hotkeyStoredSecret == Data([1, 2, 3]))
    }

    /// The restore recomputes each candidate's commitment through the crypto
    /// client and offers only the ones that open.
    @Test func aCandidateThatDoesNotOpenIsNotOfferedToTheSdk() async {
        let recorder = Recorder()
        let damaged = entry(0, van: Data(repeating: 0xC1, count: 32), rand: 0xA0, rank: 4)

        let outcome = await DelegationRestore.restoreIfNeeded(
            roundId: roundId, roundParams: roundParams, networkId: 1, hotkeyStoredSecret: Data([1]),
            escrowEntries: [damaged, entry(0, rand: 0xA1, rank: 0)], crypto: recorder.client()
        )

        #expect(outcome == .restored(bundleCount: 1))
        #expect(recorder.requests.first?.bundles.map(\.vanCommRand.first) == [0xA1])
    }

    @Test func theSdkSayingAlreadyRestoredIsReportedAsSuch() async {
        let recorder = Recorder()
        recorder.result = .alreadyRestored

        let outcome = await DelegationRestore.restoreIfNeeded(
            roundId: roundId, roundParams: roundParams, networkId: 1, hotkeyStoredSecret: Data([1]),
            escrowEntries: [entry(0)], crypto: recorder.client()
        )

        #expect(outcome == .alreadyRestored)
    }

    @Test func anEscrowWithoutBundleZeroNeverReachesTheSdk() async {
        let recorder = Recorder()

        let outcome = await DelegationRestore.restoreIfNeeded(
            roundId: roundId, roundParams: roundParams, networkId: 1, hotkeyStoredSecret: Data([1]),
            escrowEntries: [entry(1)], crypto: recorder.client()
        )

        #expect(outcome == .notApplicable(reason: "escrow holds no restorable delegation"))
        #expect(recorder.requests.isEmpty)
    }

    @Test func noHotkeyNeverReachesTheSdk() async {
        let recorder = Recorder()

        let outcome = await DelegationRestore.restoreIfNeeded(
            roundId: roundId, roundParams: roundParams, networkId: 1, hotkeyStoredSecret: nil,
            escrowEntries: [entry(0)], crypto: recorder.client()
        )

        #expect(outcome == .notApplicable(reason: "no voting hotkey on this device"))
        #expect(recorder.requests.isEmpty)
    }

    @Test func aGuardRefusalIsReportedWithItsReason() async {
        let recorder = Recorder()
        recorder.error = Refusal()

        let outcome = await DelegationRestore.restoreIfNeeded(
            roundId: roundId, roundParams: roundParams, networkId: 1, hotkeyStoredSecret: Data([1]),
            escrowEntries: [entry(0)], crypto: recorder.client()
        )

        #expect(outcome == .refused(reason: "round holds 2 cast vote(s); nothing may be cleared"))
    }

    @Test func anyOtherErrorIsAFailure() async {
        let recorder = Recorder()
        recorder.error = Boom()

        let outcome = await DelegationRestore.restoreIfNeeded(
            roundId: roundId, roundParams: roundParams, networkId: 1, hotkeyStoredSecret: Data([1]),
            escrowEntries: [entry(0)], crypto: recorder.client()
        )

        #expect(outcome == .failed)
    }

    private final class RejectionRecorder: @unchecked Sendable {
        var rejected: [(UInt32, Data)] = []
    }

    private struct SyncRefusal: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// The chain names the bundle it refused; only that bundle's candidate
    /// is marked, so a correct neighbour is still offered next time.
    @Test func aLeafMismatchRejectsOnlyTheBundleTheChainNamed() async {
        let recorder = RejectionRecorder()
        let offered = [entry(0), entry(1)]
        var escrow = DelegationEscrowClient.testValue
        escrow.entries = { _ in offered }
        escrow.markRejected = { _, index, rand in recorder.rejected.append((index, rand)) }

        let handled = await DelegationRestore.rejectRestoredCandidates(
            roundId: roundId,
            error: SyncRefusal(
                text: "sync_vote_tree failed: confirmed delegation bundle 1 \(DelegationRestore.leafMismatchMarker)"
            ),
            escrow: escrow
        )

        #expect(handled)
        #expect(recorder.rejected.map(\.0) == [1])
        #expect(recorder.rejected.map(\.1.first) == [0xA1])
    }

    /// The candidate marked is the one the restore offered: the same
    /// predicate picks it, not the best-ranked image regardless of opening.
    @Test func theRejectedCandidateIsTheOneTheRestoreOffered() async {
        let recorder = RejectionRecorder()
        let genuine = Data(repeating: 0xC0, count: 32)
        let offered = [entry(0, van: Data(repeating: 0xC1, count: 32), rand: 0xB0, rank: 4), entry(0, rand: 0xA0, rank: 0)]
        var escrow = DelegationEscrowClient.testValue
        escrow.entries = { _ in offered }
        escrow.markRejected = { _, index, rand in recorder.rejected.append((index, rand)) }

        _ = await DelegationRestore.rejectRestoredCandidates(
            roundId: roundId,
            error: SyncRefusal(
                text: "confirmed delegation bundle 0 \(DelegationRestore.leafMismatchMarker)"
            ),
            escrow: escrow,
            opens: { $0.van == genuine }
        )

        #expect(recorder.rejected.map(\.1.first) == [0xA0])
    }

    @Test func aLeafMismatchNamingNoBundleRejectsEveryOfferedCandidate() async {
        let recorder = RejectionRecorder()
        let offered = [entry(0), entry(1)]
        var escrow = DelegationEscrowClient.testValue
        escrow.entries = { _ in offered }
        escrow.markRejected = { _, index, rand in recorder.rejected.append((index, rand)) }

        let handled = await DelegationRestore.rejectRestoredCandidates(
            roundId: roundId,
            error: SyncRefusal(text: "sync_vote_tree failed: \(DelegationRestore.leafMismatchMarker)"),
            escrow: escrow
        )

        #expect(handled)
        #expect(recorder.rejected.map(\.0) == [0, 1])
    }

    @Test func theRefusedBundleIsReadFromTheSdkMessage() {
        let marker = DelegationRestore.leafMismatchMarker
        #expect(DelegationRestore.refusedBundleIndex(in: "confirmed delegation bundle 12 \(marker)") == 12)
        #expect(DelegationRestore.refusedBundleIndex(in: "sync failed: bundle 3 \(marker), retry") == 3)
        #expect(DelegationRestore.refusedBundleIndex(in: "bundle x \(marker)") == nil)
        #expect(DelegationRestore.refusedBundleIndex(in: marker) == nil)
    }

    @Test func anUnrelatedSyncErrorRejectsNothing() async {
        var escrow = DelegationEscrowClient.testValue
        escrow.entries = { _ in [] }
        escrow.markRejected = { _, _, _ in Issue.record("nothing may be rejected") }

        let handled = await DelegationRestore.rejectRestoredCandidates(
            roundId: roundId, error: Boom(), escrow: escrow
        )

        #expect(handled == false)
    }
}
