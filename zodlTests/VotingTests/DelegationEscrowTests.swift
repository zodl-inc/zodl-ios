import Foundation
import Testing
@testable import zodl_internal
@testable import VotingRecovery

/// The live store, on the test host's own Documents directory.
@Suite(.serialized) struct DelegationEscrowTests {
    private let roundId = "\(String(repeating: "4b", count: 31))01"

    private func candidate(bundle: UInt32, rand: UInt8, rank: Int, source: DelegationEscrowEntry.Source = .recovered) -> DelegationEscrowEntry {
        DelegationEscrowEntry(
            roundId: roundId,
            bundleIndex: bundle,
            vanCommRand: Data(repeating: rand, count: 31) + Data([0x01]),
            van: Data(repeating: 0xC0, count: 32),
            totalNoteValue: 130_000_000,
            delegationTxHash: String(repeating: String(format: "%02x", 0xD0 + bundle), count: 32),
            source: source,
            createdAt: Date(timeIntervalSince1970: 0),
            walletId: "w",
            addressIndex: 0,
            vanLeafPosition: nil,
            provenance: "test",
            provenanceRank: rank,
            rejectedAt: nil
        )
    }

    @Test func twoCandidatesForOneBundleBothSurviveBestFirst() async throws {
        try await SharedLiveEscrow.exclusive {
            let escrow = DelegationEscrowClient.liveValue
            await escrow.reset()
            defer { Task { await escrow.reset() } }
            try await escrow.record(candidate(bundle: 0, rand: 0xA0, rank: 0))
            try await escrow.record(candidate(bundle: 0, rand: 0xA1, rank: 4))

            let entries = try await escrow.entries(roundId)

            #expect(entries.map(\.vanCommRand.first) == [0xA1, 0xA0])
        }
    }

    @Test func aLiveCaptureNeverDisplacesARecoveredCopyOfTheSameValue() async throws {
        try await SharedLiveEscrow.exclusive {
            let escrow = DelegationEscrowClient.liveValue
            await escrow.reset()
            defer { Task { await escrow.reset() } }
            try await escrow.record(candidate(bundle: 0, rand: 0xA0, rank: 3))
            try await escrow.record(candidate(bundle: 0, rand: 0xA0, rank: 0, source: .liveCapture))

            let entries = try await escrow.entries(roundId)

            #expect(entries.count == 1)
            #expect(entries.first?.source == .recovered)
            #expect(entries.first?.provenanceRank == 3)
        }
    }

    @Test func markRejectedStampsOnlyThatCandidate() async throws {
        try await SharedLiveEscrow.exclusive {
            let escrow = DelegationEscrowClient.liveValue
            await escrow.reset()
            defer { Task { await escrow.reset() } }
            try await escrow.record(candidate(bundle: 0, rand: 0xA0, rank: 0))
            try await escrow.record(candidate(bundle: 0, rand: 0xA1, rank: 4))

            try await escrow.markRejected(roundId, 0, Data(repeating: 0xA1, count: 31) + Data([0x01]))

            let entries = try await escrow.entries(roundId)
            #expect(entries.first { $0.vanCommRand.first == 0xA1 }?.rejectedAt != nil)
            #expect(entries.first { $0.vanCommRand.first == 0xA0 }?.rejectedAt == nil)
        }
    }

    /// A rebuild can overwrite part of a row, leaving an image whose blinding
    /// survived but whose commitment did not. Both images stay, so the intact
    /// one is still there to open.
    @Test func twoImagesOfOneBlindingWithDifferentCommitmentsBothSurvive() async throws {
        try await SharedLiveEscrow.exclusive {
            let escrow = DelegationEscrowClient.liveValue
            await escrow.reset()
            defer { Task { await escrow.reset() } }
            let intact = candidate(bundle: 0, rand: 0xA0, rank: 4)
            let damaged = DelegationEscrowEntry(
                roundId: intact.roundId,
                bundleIndex: intact.bundleIndex,
                vanCommRand: intact.vanCommRand,
                van: Data(repeating: 0xC1, count: 32),
                totalNoteValue: 1,
                delegationTxHash: intact.delegationTxHash,
                source: .recovered,
                createdAt: intact.createdAt,
                provenanceRank: 0
            )
            try await escrow.record(intact)
            try await escrow.record(damaged)

            let entries = try await escrow.entries(roundId)

            #expect(entries.count == 2)
            #expect(entries.first?.van == intact.van, "the intact image ranks first")
        }
    }

    /// Recovery runs on every launch and escrows the same candidates again;
    /// a refusal recorded in between must not be forgotten.
    @Test func aRefusedCandidateStaysRefusedWhenEscrowedAgain() async throws {
        try await SharedLiveEscrow.exclusive {
            let escrow = DelegationEscrowClient.liveValue
            await escrow.reset()
            defer { Task { await escrow.reset() } }
            try await escrow.record(candidate(bundle: 0, rand: 0xA0, rank: 0))
            try await escrow.markRejected(roundId, 0, Data(repeating: 0xA0, count: 31) + Data([0x01]))

            try await escrow.record(candidate(bundle: 0, rand: 0xA0, rank: 2))

            let entries = try await escrow.entries(roundId)
            #expect(entries.count == 1)
            #expect(entries.first?.rejectedAt != nil)
            #expect(entries.first?.provenanceRank == 2, "the fresh provenance still replaces the old")
        }
    }

    /// The ownership boundary a wallet reset relies on: a run that began
    /// before the reset can write nothing that survives it.
    @Test func aRecoveryLeaseGoesStaleWhenTheWalletResets() async throws {
        try await SharedLiveEscrow.exclusive {
            let escrow = DelegationEscrowClient.liveValue
            await escrow.reset()
            defer { Task { await escrow.reset() } }
            let documents = try #require(
                FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            )
            let lease = await escrow.beginRecovery()
            try await escrow.recordRecovered(candidate(bundle: 0, rand: 0xA0, rank: 0), lease)

            DelegationEscrowFile.invalidate(inDocuments: documents)

            await #expect(throws: DelegationEscrowError.staleLease) {
                try await escrow.recordRecovered(candidate(bundle: 1, rand: 0xA1, rank: 0), lease)
            }
            #expect(
                FileManager.default.fileExists(atPath: documents.appendingPathComponent(DelegationEscrowFile.name).path)
                    == false
            )
            #expect(try await escrow.entries(roundId).isEmpty)
            #expect(await escrow.beginRecovery() != lease, "a new run takes a fresh lease")
        }
    }

    /// An escrow written before the candidate fields existed still reads,
    /// and reads as a single unranked, unrefused candidate.
    @Test func anEntryWithoutTheCandidateFieldsDecodesWithDefaults() throws {
        let encoded = try JSONEncoder().encode(candidate(bundle: 2, rand: 0xA2, rank: 4))
        var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["walletId", "addressIndex", "vanLeafPosition", "provenance", "provenanceRank", "rejectedAt"] {
            json.removeValue(forKey: key)
        }
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let entry = try JSONDecoder().decode(DelegationEscrowEntry.self, from: stripped)

        #expect(entry.bundleIndex == 2)
        #expect(entry.walletId.isEmpty)
        #expect(entry.addressIndex == 0)
        #expect(entry.vanLeafPosition == nil)
        #expect(entry.provenance == "unknown")
        #expect(entry.provenanceRank == 0)
        #expect(entry.rejectedAt == nil)
    }
}
