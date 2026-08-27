#if VOTING_ENABLED
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite struct VotingDatabaseRecoveryTests {
    private let roundId = String(repeating: "4a", count: 32)
    private let walletId = "fixture1"
    private let acceptedVan = Data(repeating: 0x22, count: 32)
    private let rebuiltVan = Data(repeating: 0x33, count: 32)
    private let originalRand = Data(repeating: 0x11, count: 32)
    private let rebuiltRand = Data(repeating: 0x12, count: 32)

    @Test func mainDatabaseRequiresAnExactCommitmentMatch() throws {
        let row = bundleRecord(van: acceptedVan, rand: originalRand)
        let database = databasePage(liveRecord: row)

        let accepted = try VotingDatabaseRecovery.recover(
            databaseBytes: database,
            vanCmx: acceptedVan,
            roundId: roundId,
            walletId: walletId
        )
        let unrelated = try VotingDatabaseRecovery.recover(
            databaseBytes: database,
            vanCmx: Data(repeating: 0x99, count: 32),
            roundId: roundId,
            walletId: walletId
        )

        let candidate = try #require(accepted.candidates.first)
        #expect(accepted.candidates.count == 1)
        #expect(candidate.vanCommRand == originalRand)
        #expect(candidate.vanCmx == acceptedVan)
        #expect(candidate.totalNoteValue == 130_000_000)
        #expect(candidate.alpha == Data(repeating: 0x44, count: 32))
        #expect(candidate.rk == Data(repeating: 0x55, count: 32))
        #expect(candidate.pcztSighash == Data(repeating: 0x66, count: 32))
        #expect(candidate.source == .databaseLive(page: 1))
        #expect(unrelated.candidates.isEmpty)
        #expect(unrelated.rawTargetHits.isEmpty)
    }

    @Test func batchSearchOnlyDecodesTargetsPresentInPreservedBytes() throws {
        let database = databasePage(
            liveRecord: bundleRecord(van: rebuiltVan, rand: rebuiltRand),
            releasedRecord: bundleRecord(van: acceptedVan, rand: originalRand)
        )
        var absentWithSamePrefix = acceptedVan
        absentWithSamePrefix[31] = 0x23

        let reports = try VotingDatabaseRecovery.recover(
            databaseBytes: database,
            vanCmxTargets: [
                acceptedVan,
                rebuiltVan,
                absentWithSamePrefix
            ],
            roundId: roundId,
            walletId: walletId
        )

        #expect(Set(reports.map(\.vanCmx)) == [acceptedVan, rebuiltVan])
        #expect(reports.allSatisfy { $0.recovered })
    }

    @Test func conflictingRecoveryMaterialIsNotDeduplicatedAway() throws {
        let database = databasePage(
            liveRecord: bundleRecord(
                van: acceptedVan,
                rand: originalRand,
                totalNoteValue: 130_000_000
            ),
            releasedRecord: bundleRecord(
                van: acceptedVan,
                rand: originalRand,
                totalNoteValue: 140_000_000
            )
        )

        let report = try VotingDatabaseRecovery.recover(
            databaseBytes: database,
            vanCmx: acceptedVan,
            roundId: roundId,
            walletId: walletId
        )

        #expect(Set(report.candidates.map(\.totalNoteValue)) == [130_000_000, 140_000_000])
    }

    @Test func completeBatchUsesTheValidatedTreePosition() throws {
        let report = try VotingDatabaseRecovery.recover(
            databaseBytes: databasePage(
                liveRecord: bundleRecord(van: acceptedVan, rand: originalRand)
            ),
            vanCmx: acceptedVan,
            roundId: roundId,
            walletId: walletId
        )
        let snapshot = VotingVerifiedVoteTreeSnapshot(
            anchorHeight: 42,
            root: [UInt8](repeating: 0x77, count: 32),
            leaves: [VotingVerifiedVoteTreeLeaf(position: 7, commitment: [UInt8](acceptedVan))]
        )

        let bundles = try #require(VotingHistoricalDelegationRecovery.completeBatch(
            reports: [report],
            snapshot: snapshot,
            expectedBundleCount: 1
        ))

        #expect(bundles.count == 1)
        #expect(bundles[0].bundleIndex == 0)
        #expect(bundles[0].vanCommRand == [UInt8](originalRand))
        #expect(bundles[0].vanLeafPosition == 7)
    }

    @Test func completeBatchRejectsConflictingCandidates() throws {
        let report = try VotingDatabaseRecovery.recover(
            databaseBytes: databasePage(
                liveRecord: bundleRecord(
                    van: acceptedVan,
                    rand: originalRand,
                    totalNoteValue: 130_000_000
                ),
                releasedRecord: bundleRecord(
                    van: acceptedVan,
                    rand: originalRand,
                    totalNoteValue: 140_000_000
                )
            ),
            vanCmx: acceptedVan,
            roundId: roundId,
            walletId: walletId
        )
        let snapshot = VotingVerifiedVoteTreeSnapshot(
            anchorHeight: 42,
            root: [UInt8](repeating: 0x77, count: 32),
            leaves: [VotingVerifiedVoteTreeLeaf(position: 7, commitment: [UInt8](acceptedVan))]
        )

        #expect(VotingHistoricalDelegationRecovery.completeBatch(
            reports: [report],
            snapshot: snapshot,
            expectedBundleCount: 1
        ) == nil)
    }

    @Test func completeBatchRejectsConflictingTransactionHashes() throws {
        let report = try VotingDatabaseRecovery.recover(
            databaseBytes: databasePage(
                liveRecord: bundleRecord(
                    van: acceptedVan,
                    rand: originalRand,
                    delegationTxHash: String(repeating: "a", count: 64)
                ),
                releasedRecord: bundleRecord(
                    van: acceptedVan,
                    rand: originalRand,
                    delegationTxHash: String(repeating: "b", count: 64)
                )
            ),
            vanCmx: acceptedVan,
            roundId: roundId,
            walletId: walletId
        )
        let snapshot = VotingVerifiedVoteTreeSnapshot(
            anchorHeight: 42,
            root: [UInt8](repeating: 0x77, count: 32),
            leaves: [VotingVerifiedVoteTreeLeaf(position: 7, commitment: [UInt8](acceptedVan))]
        )

        #expect(report.candidates.count == 2)
        #expect(VotingHistoricalDelegationRecovery.completeBatch(
            reports: [report],
            snapshot: snapshot,
            expectedBundleCount: 1
        ) == nil)
    }

    @Test func historicalRecoveryRejectsMismatchedRoundBeforeDiscovery() throws {
        let request = HistoricalVotingDelegationRecoveryRequest(
            roundId: roundId,
            walletId: walletId,
            roundParams: VotingRoundParams(
                voteRoundId: Data(repeating: 0x5A, count: 32),
                snapshotHeight: 42,
                eaPK: Data(repeating: 0x10, count: 32),
                ncRoot: Data(repeating: 0x11, count: 32),
                nullifierIMTRoot: Data(repeating: 0x12, count: 32)
            ),
            nodeURL: "https://invalid.example",
            hotkeyStoredSecret: Data(repeating: 0x13, count: 32),
            expectedBundleCount: 1
        )

        let sdkRequest = try VotingHistoricalDelegationRecovery.prepareRequest(request)
        #expect(sdkRequest == nil)
    }

    @Test func replaysEveryChecksumValidCommittedWalPrefix() throws {
        let emptyDatabase = databasePage()
        let originalPage = databasePage(
            liveRecord: bundleRecord(van: acceptedVan, rand: originalRand)
        )
        let rebuiltPage = databasePage(
            liveRecord: bundleRecord(van: rebuiltVan, rand: rebuiltRand)
        )
        let wal = walFile(frames: [
            WalFixtureFrame(page: originalPage, currentGeneration: true),
            WalFixtureFrame(page: rebuiltPage, currentGeneration: true)
        ])

        let original = try VotingDatabaseRecovery.recover(
            databaseBytes: emptyDatabase,
            walBytes: wal,
            vanCmx: acceptedVan,
            roundId: roundId
        )
        let rebuilt = try VotingDatabaseRecovery.recover(
            databaseBytes: emptyDatabase,
            walBytes: wal,
            vanCmx: rebuiltVan,
            roundId: roundId
        )

        #expect(original.validWalFrameCount == 2)
        #expect(original.committedWalPrefixCount == 2)
        #expect(original.candidates.first?.vanCommRand == originalRand)
        #expect(original.candidates.first?.source == .walCommit(frame: 0))
        #expect(rebuilt.candidates.first?.vanCommRand == rebuiltRand)
        #expect(rebuilt.candidates.first?.source == .walCommit(frame: 1))
    }

    @Test func staleWalFramesAreCarvedButNeverTreatedAsChronology() throws {
        let emptyDatabase = databasePage()
        let currentPage = databasePage(
            liveRecord: bundleRecord(van: rebuiltVan, rand: rebuiltRand)
        )
        let stalePage = databasePage(
            liveRecord: bundleRecord(van: acceptedVan, rand: originalRand)
        )
        let wal = walFile(frames: [
            WalFixtureFrame(page: currentPage, currentGeneration: true),
            WalFixtureFrame(page: stalePage, currentGeneration: false)
        ])

        let report = try VotingDatabaseRecovery.recover(
            databaseBytes: emptyDatabase,
            walBytes: wal,
            vanCmx: acceptedVan,
            roundId: roundId
        )

        let candidate = try #require(report.candidates.first)
        #expect(report.validWalFrameCount == 1)
        #expect(report.committedWalPrefixCount == 1)
        #expect(candidate.vanCommRand == originalRand)
        let isStaleWalCarve: Bool
        if case .walCarved(frame: 1, currentGeneration: false, offset: _) =
            candidate.source {
            isStaleWalCarve = true
        } else {
            isStaleWalCarve = false
        }
        #expect(isStaleWalCarve)
    }

    @Test func targetAnchorRecoversBodyAfterDeletedCellHeaderWasDestroyed() throws {
        let rebuilt = bundleRecord(van: rebuiltVan, rand: rebuiltRand)
        let original = bundleRecord(van: acceptedVan, rand: originalRand)
        let database = databasePage(
            liveRecord: rebuilt,
            releasedRecord: original,
            destroyReleasedHeader: true
        )

        let report = try VotingDatabaseRecovery.recover(
            databaseBytes: database,
            vanCmx: acceptedVan,
            roundId: roundId,
            walletId: walletId,
            bundleIndex: 0
        )

        let candidate = try #require(report.candidates.first)
        #expect(report.rawTargetHits.isEmpty == false)
        #expect(candidate.vanCommRand == originalRand)
        #expect(candidate.alpha == Data(repeating: 0x44, count: 32))
        let isDatabaseCarve: Bool
        if case .databaseCarved(page: 1, offset: _) = candidate.source {
            isDatabaseCarve = true
        } else {
            isDatabaseCarve = false
        }
        #expect(isDatabaseCarve)
    }

    @Test func exactTargetWithoutAConsistentRecordIsEvidenceNotRecovery() throws {
        var database = databasePage()
        database.replaceSubrange(512..<544, with: acceptedVan)

        let report = try VotingDatabaseRecovery.recover(
            databaseBytes: database,
            vanCmx: acceptedVan,
            roundId: roundId
        )

        #expect(report.rawTargetHits.count == 1)
        #expect(report.candidates.isEmpty)
    }

    @Test func unreachableLeafPagesAreCarvedButNeverCalledLive() throws {
        let database = databaseWithUnreachableBundle(
            bundleRecord(van: acceptedVan, rand: originalRand)
        )

        let report = try VotingDatabaseRecovery.recover(
            databaseBytes: database,
            vanCmx: acceptedVan,
            roundId: roundId
        )

        let candidate = try #require(report.candidates.first)
        let isUnreachableCarve: Bool
        if case .databaseCarved(page: 3, offset: _) = candidate.source {
            isUnreachableCarve = true
        } else {
            isUnreachableCarve = false
        }
        #expect(isUnreachableCarve)
    }

    @Test func rejectsTargetsThatAreNotCommitmentSized() {
        #expect(throws: VotingDatabaseRecovery.RecoveryError.invalidVanCmxLength(31)) {
            try VotingDatabaseRecovery.recover(
                databaseBytes: databasePage(),
                vanCmx: Data(repeating: 0, count: 31),
                roundId: roundId
            )
        }
    }

    @Test func rejectsAnInvalidRoundIdentifier() {
        #expect(throws: VotingDatabaseRecovery.RecoveryError.invalidRoundId) {
            try VotingDatabaseRecovery.recover(
                databaseBytes: databasePage(),
                vanCmx: acceptedVan,
                roundId: "not-a-round"
            )
        }
    }

    // MARK: - Deterministic SQLite fixtures

    private func bundleRecord(
        van: Data,
        rand: Data,
        totalNoteValue: Int64 = 130_000_000,
        delegationTxHash: String? = String(repeating: "a", count: 64)
    ) -> [UInt8] {
        let transactionHash: FixtureValue = delegationTxHash.map { .text($0) } ?? .null
        let values: [FixtureValue] = [
            .text(roundId),
            .text(walletId),
            .zero,
            .null,
            .null,
            .blob(rand),
            .null,
            .null,
            .null,
            .null,
            .null,
            .blob(Data(repeating: 0x44, count: 32)),
            .null,
            .null,
            .blob(van),
            .integer(totalNoteValue, width: 4),
            .zero,
            .null,
            .blob(Data(repeating: 0x55, count: 32)),
            .null,
            .null,
            .blob(Data(repeating: 0x66, count: 32)),
            .null,
            transactionHash
        ]
        #expect(values.count == 24)

        return sqliteRecord(values)
    }

    private func sqliteRecord(_ values: [FixtureValue]) -> [UInt8] {
        let serialTypes = values.flatMap { encodeVarint($0.serialType) }
        let headerLength = 1 + serialTypes.count
        #expect(headerLength < 128)
        return [UInt8(headerLength)] + serialTypes + values.flatMap(\.body)
    }

    private func databaseWithUnreachableBundle(
        _ releasedRecord: [UInt8]
    ) -> [UInt8] {
        let schemaRecord = sqliteRecord([
            .text("table"),
            .text("bundles"),
            .text("bundles"),
            .integer(2, width: 1),
            .text("CREATE TABLE bundles(round_id TEXT)")
        ])

        var schemaPage = tableLeafPage(record: schemaRecord, headerOffset: 100)
        schemaPage.replaceSubrange(
            0..<16,
            with: Array("SQLite format 3\u{0}".utf8)
        )
        putUInt16(4_096, into: &schemaPage, at: 16)
        schemaPage[18] = 2
        schemaPage[19] = 2
        let bundlesPage = tableLeafPage(record: nil, headerOffset: 0)
        let releasedPage = tableLeafPage(
            record: releasedRecord,
            headerOffset: 0
        )
        return schemaPage + bundlesPage + releasedPage
    }

    private func tableLeafPage(
        record: [UInt8]?,
        headerOffset: Int
    ) -> [UInt8] {
        let pageSize = 4_096
        var page = [UInt8](repeating: 0, count: pageSize)
        page[headerOffset] = 0x0D

        if let record {
            let cell = encodeVarint(UInt64(record.count))
                + encodeVarint(1)
                + record
            let cellOffset = pageSize - cell.count
            putUInt16(1, into: &page, at: headerOffset + 3)
            putUInt16(
                UInt16(cellOffset),
                into: &page,
                at: headerOffset + 5
            )
            putUInt16(
                UInt16(cellOffset),
                into: &page,
                at: headerOffset + 8
            )
            page.replaceSubrange(cellOffset..<pageSize, with: cell)
        } else {
            putUInt16(0, into: &page, at: headerOffset + 3)
            putUInt16(UInt16(pageSize), into: &page, at: headerOffset + 5)
        }
        return page
    }

    private func databasePage(
        liveRecord: [UInt8]? = nil,
        releasedRecord: [UInt8]? = nil,
        destroyReleasedHeader: Bool = false
    ) -> [UInt8] {
        let pageSize = 4_096
        var page = [UInt8](repeating: 0, count: pageSize)
        page.replaceSubrange(0..<16, with: Array("SQLite format 3\u{0}".utf8))
        putUInt16(UInt16(pageSize), into: &page, at: 16)
        page[18] = 2
        page[19] = 2
        page[20] = 0
        page[100] = 0x0D

        if let liveRecord {
            let cell = encodeVarint(UInt64(liveRecord.count))
                + encodeVarint(1)
                + liveRecord
            let cellOffset = pageSize - cell.count
            putUInt16(1, into: &page, at: 103)
            putUInt16(UInt16(cellOffset), into: &page, at: 105)
            putUInt16(UInt16(cellOffset), into: &page, at: 108)
            page.replaceSubrange(cellOffset..<pageSize, with: cell)
        } else {
            putUInt16(0, into: &page, at: 103)
            putUInt16(UInt16(pageSize), into: &page, at: 105)
        }

        if var releasedRecord {
            if destroyReleasedHeader { releasedRecord[0] = 0 }
            let offset = 512
            #expect(offset + releasedRecord.count < pageSize / 2)
            page.replaceSubrange(
                offset..<(offset + releasedRecord.count),
                with: releasedRecord
            )
        }
        return page
    }

    private struct WalFixtureFrame {
        let page: [UInt8]
        let currentGeneration: Bool
    }

    private func walFile(frames: [WalFixtureFrame]) -> [UInt8] {
        let magic: UInt32 = 0x377F_0683
        let salt1: UInt32 = 0x1020_3040
        let salt2: UInt32 = 0x5060_7080
        var header = [UInt8](repeating: 0, count: 32)
        putUInt32(magic, into: &header, at: 0)
        putUInt32(3_007_000, into: &header, at: 4)
        putUInt32(4_096, into: &header, at: 8)
        putUInt32(0, into: &header, at: 12)
        putUInt32(salt1, into: &header, at: 16)
        putUInt32(salt2, into: &header, at: 20)

        var running = checksum(Array(header[0..<24]), seed: (0, 0))
        putUInt32(running.0, into: &header, at: 24)
        putUInt32(running.1, into: &header, at: 28)

        var wal = header
        for fixture in frames {
            var frameHeader = [UInt8](repeating: 0, count: 24)
            putUInt32(1, into: &frameHeader, at: 0)
            putUInt32(1, into: &frameHeader, at: 4)
            putUInt32(
                fixture.currentGeneration ? salt1 : salt1 &+ 1,
                into: &frameHeader,
                at: 8
            )
            putUInt32(
                fixture.currentGeneration ? salt2 : salt2 &+ 1,
                into: &frameHeader,
                at: 12
            )

            let frameChecksum = checksum(
                Array(frameHeader[0..<8]) + fixture.page,
                seed: running
            )
            putUInt32(frameChecksum.0, into: &frameHeader, at: 16)
            putUInt32(frameChecksum.1, into: &frameHeader, at: 20)
            if fixture.currentGeneration { running = frameChecksum }
            wal += frameHeader + fixture.page
        }
        return wal
    }

    private enum FixtureValue {
        case null
        case zero
        case integer(Int64, width: Int)
        case blob(Data)
        case text(String)

        var serialType: UInt64 {
            switch self {
            case .null: return 0
            case .zero: return 8
            case let .integer(_, width): return UInt64(width)
            case let .blob(data): return UInt64(12 + data.count * 2)
            case let .text(value): return UInt64(13 + value.utf8.count * 2)
            }
        }

        var body: [UInt8] {
            switch self {
            case .null, .zero:
                return []
            case let .integer(value, width):
                let bits = UInt64(bitPattern: value)
                return (0..<width).map { index in
                    UInt8(truncatingIfNeeded: bits >> UInt64((width - index - 1) * 8))
                }
            case let .blob(data):
                return [UInt8](data)
            case let .text(value):
                return [UInt8](value.utf8)
            }
        }
    }

    private func encodeVarint(_ value: UInt64) -> [UInt8] {
        if value <= 0x7F { return [UInt8(value)] }
        var groups: [UInt8] = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            groups.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        return groups.reversed()
    }

    private func checksum(
        _ bytes: [UInt8],
        seed: (UInt32, UInt32)
    ) -> (UInt32, UInt32) {
        var first = seed.0
        var second = seed.1
        for offset in stride(from: 0, to: bytes.count, by: 8) {
            first = first &+ readUInt32(bytes, at: offset) &+ second
            second = second &+ readUInt32(bytes, at: offset + 4) &+ first
        }
        return (first, second)
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private func putUInt16(
        _ value: UInt16,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private func putUInt32(
        _ value: UInt32,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
    }
}
#endif
