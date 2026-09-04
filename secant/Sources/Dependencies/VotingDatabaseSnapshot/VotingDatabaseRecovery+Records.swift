#if RECOVERY_VOTING_ENABLED
import Foundation

// MARK: - SQLite records

extension VotingDatabaseRecovery {
    enum RecordValue: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
        case unavailable
    }

    struct ColumnSpan: Equatable, Hashable {
        let serialType: UInt64
        let range: Range<Int>
    }

    struct DecodedRecord {
        let values: [RecordValue]
        let spans: [ColumnSpan]
    }

    struct RecordTemplate: Equatable, Hashable {
        let spans: [ColumnSpan]
    }

    static func decodeRecord(_ payload: [UInt8]) -> DecodedRecord? {
        guard let (headerLength, headerBytes) = varint(payload, 0),
              headerLength <= UInt64(payload.count)
        else {
            return nil
        }
        let headerEnd = Int(headerLength)
        guard headerEnd >= headerBytes else { return nil }

        var serialTypes: [UInt64] = []
        var cursor = headerBytes
        while cursor < headerEnd {
            guard let (serial, used) = varint(payload, cursor) else { return nil }
            serialTypes.append(serial)
            cursor += used
        }

        var values: [RecordValue] = []
        var spans: [ColumnSpan] = []
        var body = headerEnd
        for serial in serialTypes {
            guard let width = serialWidth(serial), body <= Int.max - width else {
                return nil
            }
            let range = body..<(body + width)
            spans.append(ColumnSpan(serialType: serial, range: range))
            if range.upperBound <= payload.count {
                values.append(serialValue(serial, Array(payload[range])))
            } else {
                values.append(.unavailable)
            }
            body += width
        }
        return DecodedRecord(values: values, spans: spans)
    }

    private static func serialWidth(_ serial: UInt64) -> Int? {
        switch serial {
        case 0, 8, 9, 10, 11: return 0
        case 1, 2, 3, 4: return Int(serial)
        case 5: return 6
        case 6, 7: return 8
        default:
            guard serial >= 12,
                  serial - 12 <= UInt64(Int.max) * 2
            else {
                return nil
            }
            return Int((serial - 12) / 2)
        }
    }

    static func serialValue(
        _ serial: UInt64,
        _ raw: [UInt8]
    ) -> RecordValue {
        switch serial {
        case 0: return .null
        case 1, 2, 3, 4, 5, 6:
            var bits: UInt64 = 0
            for byte in raw { bits = (bits << 8) | UInt64(byte) }
            if raw.count < 8, raw.first.map({ $0 & 0x80 != 0 }) == true {
                bits |= UInt64.max << UInt64(raw.count * 8)
            }
            return .integer(Int64(bitPattern: bits))
        case 7:
            var bits: UInt64 = 0
            for byte in raw { bits = (bits << 8) | UInt64(byte) }
            return .real(Double(bitPattern: bits))
        case 8: return .integer(0)
        case 9: return .integer(1)
        case 10, 11: return .unavailable
        default:
            if serial.isMultiple(of: 2) { return .blob(Data(raw)) }
            guard let text = String(bytes: raw, encoding: .utf8) else {
                return .unavailable
            }
            return .text(text)
        }
    }

    static func localPayloadSize(
        payloadLength: Int,
        usable: Int
    ) -> Int {
        let maxLocal = usable - 35
        if payloadLength <= maxLocal { return payloadLength }
        let minLocal = ((usable - 12) * 32 / 255) - 23
        let surplus = minLocal + (payloadLength - minLocal) % (usable - 4)
        return surplus <= maxLocal ? surplus : minLocal
    }

    // MARK: - Bundle rows

    static func looksLikeBundleRecord(_ record: DecodedRecord) -> Bool {
        guard record.values.count >= bundleColumnCount,
              case let .text(roundId) =
                  record.values[BundleColumn.roundId.rawValue],
              isCanonicalRoundId(roundId),
              case .text = record.values[BundleColumn.walletId.rawValue],
              case .integer = record.values[BundleColumn.bundleIndex.rawValue],
              blob(record.values[BundleColumn.vanCommRand.rawValue], count: 32)
                  != nil,
              blob(record.values[BundleColumn.govComm.rawValue], count: 32) != nil
        else {
            return false
        }
        return true
    }

    static func append(
        record: DecodedRecord,
        source: Source,
        target: Data?,
        roundId: String?,
        walletId: String?,
        bundleIndex: UInt32?,
        to result: inout ScanResult
    ) {
        guard let bundle = makeBundle(values: record.values, source: source) else {
            return
        }
        if record.spans.count >= bundleColumnCount {
            result.templates.append(RecordTemplate(spans: record.spans))
        }
        guard target.map({ bundle.vanCmx == $0 }) ?? true,
              matches(
                  bundle,
                  roundId: roundId,
                  walletId: walletId,
                  bundleIndex: bundleIndex
              )
        else {
            return
        }
        result.candidates.append(bundle)
    }

    static func makeBundle(
        values: [RecordValue],
        source: Source
    ) -> RecoveredBundle? {
        guard values.count >= bundleColumnCount,
              case let .text(roundId) = values[BundleColumn.roundId.rawValue],
              isCanonicalRoundId(roundId),
              case let .text(walletId) = values[BundleColumn.walletId.rawValue],
              case let .integer(bundleIndex) = values[BundleColumn.bundleIndex.rawValue],
              bundleIndex >= 0,
              bundleIndex <= Int64(UInt32.max),
              let vanCommRand = blob(
                  values[BundleColumn.vanCommRand.rawValue],
                  count: 32
              ),
              isCanonicalPallasElement(vanCommRand),
              let vanCmx = blob(values[BundleColumn.govComm.rawValue], count: 32),
              case let .integer(storedValue) =
                  values[BundleColumn.totalNoteValue.rawValue],
              storedValue >= 0,
              storedValue <= maxMoneyZatoshi
        else {
            return nil
        }

        let addressIndex: UInt32?
        if case let .integer(value) = values[BundleColumn.addressIndex.rawValue],
           value >= 0,
           value <= Int64(UInt32.max) {
            addressIndex = UInt32(value)
        } else {
            addressIndex = nil
        }

        let vanLeafPosition: UInt32?
        if case let .integer(value) = values[BundleColumn.vanLeafPosition.rawValue],
           value >= 0,
           value <= Int64(UInt32.max) {
            vanLeafPosition = UInt32(value)
        } else {
            vanLeafPosition = nil
        }

        let delegationTxHash: String?
        if case let .text(value) = values[BundleColumn.delegationTxHash.rawValue] {
            delegationTxHash = value
        } else {
            delegationTxHash = nil
        }

        return RecoveredBundle(
            roundId: roundId.lowercased(),
            walletId: walletId,
            bundleIndex: UInt32(bundleIndex),
            notePositionsBlob: blob(values[BundleColumn.notePositions.rawValue]),
            noteIdentityHashesBlob: blob(
                values[BundleColumn.noteIdentityHashes.rawValue]
            ),
            vanCommRand: vanCommRand,
            dummyNullifiers: blob(values[BundleColumn.dummyNullifiers.rawValue]),
            rhoSigned: blob(values[BundleColumn.rhoSigned.rawValue]),
            paddedNoteData: blob(values[BundleColumn.paddedNoteData.rawValue]),
            nfSigned: blob(values[BundleColumn.nfSigned.rawValue]),
            cmxNew: blob(values[BundleColumn.cmxNew.rawValue]),
            alpha: blob(values[BundleColumn.alpha.rawValue], count: 32),
            rseedSigned: blob(values[BundleColumn.rseedSigned.rawValue]),
            rseedOutput: blob(values[BundleColumn.rseedOutput.rawValue]),
            vanCmx: vanCmx,
            totalNoteValue: UInt64(storedValue),
            addressIndex: addressIndex,
            vanLeafPosition: vanLeafPosition,
            rk: blob(values[BundleColumn.rk.rawValue], count: 32),
            govNullifiersBlob: blob(
                values[BundleColumn.govNullifiers.rawValue]
            ),
            paddedNoteSecrets: blob(
                values[BundleColumn.paddedNoteSecrets.rawValue]
            ),
            pcztSighash: blob(
                values[BundleColumn.pcztSighash.rawValue],
                count: 32
            ),
            tx1Effects: blob(values[BundleColumn.tx1Effects.rawValue]),
            delegationTxHash: delegationTxHash,
            source: source
        )
    }

    /// A nil constraint is no constraint: an untargeted scan admits every
    /// round, wallet and bundle index the schema accepts.
    static func matches(
        _ bundle: RecoveredBundle,
        roundId: String?,
        walletId: String?,
        bundleIndex: UInt32?
    ) -> Bool {
        if let roundId,
           bundle.roundId.caseInsensitiveCompare(roundId) != .orderedSame {
            return false
        }
        if let walletId, bundle.walletId != walletId { return false }
        if let bundleIndex, bundle.bundleIndex != bundleIndex { return false }
        return true
    }

    static func isCanonicalRoundId(_ roundId: String) -> Bool {
        let bytes = [UInt8](roundId.utf8)
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (0x30...0x39).contains(byte)
                || (0x61...0x66).contains(byte)
                || (0x41...0x46).contains(byte)
        }
    }

    static func blob(_ value: RecordValue, count: Int) -> Data? {
        guard case let .blob(data) = value, data.count == count else { return nil }
        return data
    }

    static func blob(_ value: RecordValue) -> Data? {
        guard case let .blob(data) = value else { return nil }
        return data
    }

    static func isCanonicalPallasElement(_ candidate: Data) -> Bool {
        guard candidate.count == 32 else { return false }
        return Data(candidate.reversed()).hexString < pallasModulus
    }

    // MARK: - Choosing between copies of one row

    static func deduplicated(
        _ candidates: [RecoveredBundle]
    ) -> [RecoveredBundle] {
        var best: [String: RecoveredBundle] = [:]
        for candidate in candidates {
            let key = [
                candidate.roundId,
                candidate.walletId,
                String(candidate.bundleIndex),
                candidate.vanCommRand.hexString,
                candidate.vanCmx.hexString
            ].joined(separator: "/")
            if let existing = best[key] {
                let existingRank = (
                    sourceConfidence(existing.source),
                    recoveredFieldCount(existing)
                )
                let candidateRank = (
                    sourceConfidence(candidate.source),
                    recoveredFieldCount(candidate)
                )
                if existingRank >= candidateRank { continue }
            }
            best[key] = candidate
        }
        return best.values.sorted {
            ($0.roundId, $0.walletId, $0.bundleIndex)
                < ($1.roundId, $1.walletId, $1.bundleIndex)
        }
    }

    private static func sourceConfidence(_ source: Source) -> Int {
        source.rank
    }

    private static func recoveredFieldCount(_ bundle: RecoveredBundle) -> Int {
        [
            bundle.notePositionsBlob,
            bundle.noteIdentityHashesBlob,
            bundle.dummyNullifiers,
            bundle.rhoSigned,
            bundle.paddedNoteData,
            bundle.nfSigned,
            bundle.cmxNew,
            bundle.alpha,
            bundle.rseedSigned,
            bundle.rseedOutput,
            bundle.rk,
            bundle.govNullifiersBlob,
            bundle.paddedNoteSecrets,
            bundle.pcztSighash,
            bundle.tx1Effects
        ].compactMap { $0 }.count
            + (bundle.addressIndex == nil ? 0 : 1)
            + (bundle.vanLeafPosition == nil ? 0 : 1)
            + (bundle.delegationTxHash == nil ? 0 : 1)
    }

    static func rawHitOrder(_ lhs: RawTargetHit, _ rhs: RawTargetHit) -> Bool {
        String(describing: lhs.source) < String(describing: rhs.source)
    }

    // MARK: - Byte primitives

    static func varint(
        _ bytes: [UInt8],
        _ offset: Int
    ) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var index = 0
        while index < 8 {
            guard offset >= 0, offset + index < bytes.count else { return nil }
            let byte = bytes[offset + index]
            value = (value << 7) | UInt64(byte & 0x7F)
            if byte & 0x80 == 0 { return (value, index + 1) }
            index += 1
        }
        guard offset >= 0, offset + 8 < bytes.count else { return nil }
        return ((value << 8) | UInt64(bytes[offset + 8]), 9)
    }

    static func validPageSize(_ size: Int) -> Bool {
        size >= 512 && size <= 65_536 && size.nonzeroBitCount == 1
    }

    static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}
#endif
