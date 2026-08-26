#if VOTING_ENABLED
import Foundation

/// Recovers `bundles` rows that `clear_round` deleted, by carving the voting
/// database's write-ahead log.
///
/// In WAL mode SQLite appends a fresh image of every modified page to the
/// `-wal` file on each commit, so a page written by several commits appears in
/// the WAL several times. The frames written before the delete still hold the
/// intact row, including the 32-byte VAN blinding factor that exists nowhere
/// else and cannot be recomputed.
///
/// Nothing here opens a SQLite connection. Opening one would run WAL recovery
/// and checkpoint, which is precisely what overwrites the frames being read.
/// The files are parsed as bytes and never written to.
enum DelegationWalRecovery {
    /// `bundles` column order, from `storage/migrations/001_init.sql`. Only
    /// `rounds` has ever gained a column (at schema v13), so this record layout
    /// is valid for every schema version the app has shipped.
    enum BundleColumn: Int {
        case roundId = 0
        case walletId = 1
        case bundleIndex = 2
        case vanCommRand = 5
        case govComm = 14
        case totalNoteValue = 15
        case addressIndex = 16
    }

    /// Number of columns in `bundles`; a record with fewer is not one of ours.
    static let bundleColumnCount = 24

    /// Pallas base field modulus. A genuine blinding factor is a canonical
    /// little-endian element below it.
    static let pallasModulus = "40000000000000000000000000000000224698fc094cf91b992d30ed00000001"

    static let walMagic: [UInt32] = [0x377F_0682, 0x377F_0683]

    struct RecoveredBundle: Equatable, Sendable {
        let roundId: String
        let bundleIndex: UInt32
        let vanCommRand: Data
        let van: Data
        let totalNoteValue: UInt64
        /// Zero-based WAL frame the row came from. Lower is older.
        let frame: Int
    }

    /// One bundle whose secrets `prepareFreshRound` replaced.
    struct Replacement: Equatable, Sendable {
        /// The delegation the user actually broadcast, from the older frame.
        let original: RecoveredBundle
        /// What the rebuild put in its place, from the newest frame. Matches
        /// the row currently in `bundles`.
        let current: RecoveredBundle
    }

    /// What recovery would restore, if anything.
    struct Plan: Equatable, Sendable {
        let replacements: [Replacement]

        /// False when the round was never cleared. Callers must treat this as
        /// "do nothing" rather than restoring anything.
        var needsRecovery: Bool { !replacements.isEmpty }
    }

    // MARK: - Public entry point

    /// Decides whether `walURL` shows a round that was cleared and rebuilt.
    ///
    /// Idempotent by construction. A bundle only qualifies when the WAL holds
    /// **two or more distinct** `van_comm_rand` values for it: that can only
    /// happen if something replaced the secrets. A round that was never
    /// cleared has exactly one value per bundle no matter how many times its
    /// page was rewritten, so the plan comes back empty and nothing is
    /// touched. Re-running against an already-restored database is likewise a
    /// no-op, because restoring does not append a new `van_comm_rand`.
    static func plan(walURL: URL, roundId: String? = nil) throws -> Plan {
        plan(bundles: try recover(walURL: walURL, roundId: roundId))
    }

    static func plan(bundles: [RecoveredBundle]) -> Plan {
        var byBundle: [String: [RecoveredBundle]] = [:]
        for bundle in bundles {
            byBundle["\(bundle.roundId)/\(bundle.bundleIndex)", default: []].append(bundle)
        }

        var replacements: [Replacement] = []
        for key in byBundle.keys.sorted() {
            guard let versions = byBundle[key] else { continue }
            let distinct = Set(versions.map(\.vanCommRand))
            // One value means nothing was replaced: leave this bundle alone.
            guard distinct.count > 1 else { continue }
            guard let original = versions.min(by: { $0.frame < $1.frame }),
                  let current = versions.max(by: { $0.frame < $1.frame })
            else {
                continue
            }
            replacements.append(Replacement(original: original, current: current))
        }

        return Plan(replacements: replacements)
    }

    /// Carves every recoverable `bundles` row from `walURL`.
    ///
    /// Rows are returned oldest-frame-first and de-duplicated on
    /// `(roundId, bundleIndex, vanCommRand)`, so a value rewritten unchanged by
    /// later commits appears once.
    static func recover(walURL: URL, roundId: String? = nil) throws -> [RecoveredBundle] {
        let blob = try Data(contentsOf: walURL, options: .mappedIfSafe)
        return recover(walBytes: [UInt8](blob), roundId: roundId)
    }

    static func recover(walBytes: [UInt8], roundId: String? = nil) -> [RecoveredBundle] {
        guard walBytes.count > 32 else { return [] }

        let magic = readUInt32(walBytes, 0)
        guard walMagic.contains(magic) else { return [] }

        let pageSize = Int(readUInt32(walBytes, 8))
        guard pageSize >= 512, pageSize <= 65_536, pageSize % 512 == 0 else { return [] }

        var recovered: [RecoveredBundle] = []
        var seen: Set<String> = []

        // Frames are 24 bytes of header followed by one page image. Every frame
        // is walked, including any whose salts no longer match the WAL header:
        // SQLite ignores those, but they are physically intact and are often
        // the oldest surviving copy of a page.
        var offset = 32
        var frame = 0
        while offset + 24 + pageSize <= walBytes.count {
            let page = Array(walBytes[(offset + 24)..<(offset + 24 + pageSize)])
            for columns in bundleRecords(inPage: page, usable: pageSize) {
                guard let bundle = makeBundle(columns: columns, frame: frame) else { continue }
                if let roundId, bundle.roundId.caseInsensitiveCompare(roundId) != .orderedSame {
                    continue
                }
                let key = "\(bundle.roundId)/\(bundle.bundleIndex)/\(bundle.vanCommRand.hexString)"
                if seen.insert(key).inserted {
                    recovered.append(bundle)
                }
            }
            offset += 24 + pageSize
            frame += 1
        }

        return recovered
    }

    /// Whether `candidate` could be a Pallas base field element. A carved value
    /// that fails this was never a blinding factor.
    static func isCanonicalPallasElement(_ candidate: Data) -> Bool {
        guard candidate.count == 32 else { return false }
        // Stored little-endian; compare big-endian against the modulus.
        let reversed = Data(candidate.reversed()).hexString
        return reversed < pallasModulus
    }

    // MARK: - SQLite b-tree pages

    private static func makeBundle(columns: [RecordValue], frame: Int) -> RecoveredBundle? {
        guard columns.count >= bundleColumnCount,
              case let .text(roundId) = columns[BundleColumn.roundId.rawValue],
              roundId.count == 64,
              roundId.allSatisfy(\.isHexDigit),
              case let .integer(bundleIndex) = columns[BundleColumn.bundleIndex.rawValue],
              bundleIndex >= 0, bundleIndex < Int64(UInt32.max),
              case let .blob(rand) = columns[BundleColumn.vanCommRand.rawValue],
              rand.count == 32
        else {
            return nil
        }

        let van: Data
        if case let .blob(stored) = columns[BundleColumn.govComm.rawValue], stored.count == 32 {
            van = stored
        } else {
            van = Data()
        }

        var weight: UInt64 = 0
        if case let .integer(stored) = columns[BundleColumn.totalNoteValue.rawValue], stored >= 0 {
            weight = UInt64(stored)
        }

        return RecoveredBundle(
            roundId: roundId.lowercased(),
            bundleIndex: UInt32(bundleIndex),
            vanCommRand: rand,
            van: van,
            totalNoteValue: weight,
            frame: frame
        )
    }

    /// Every decodable `bundles` record on one page image.
    ///
    /// Live cells are walked through the cell-pointer array. Deleted cells are
    /// no longer referenced there, so the page is additionally swept for the
    /// record signature: a `bundles` record opens with the serial type for its
    /// 64-character hex `round_id` (TEXT of length 64 -> 2 * 64 + 13 = 141,
    /// encoded as the varint `0x81 0x0D`), with the single-byte header-length
    /// varint immediately before it.
    private static func bundleRecords(inPage page: [UInt8], usable: Int) -> [[RecordValue]] {
        var records: [[RecordValue]] = []

        if page.first == 0x0D {
            for payload in tableLeafPayloads(page: page, usable: usable) {
                if let columns = decodeRecord(payload) { records.append(columns) }
            }
        }

        var index = 1
        while index + 1 < page.count {
            guard page[index] == 0x81, page[index + 1] == 0x0D else {
                index += 1
                continue
            }
            let start = index - 1
            let end = min(start + usable, page.count)
            if let columns = decodeRecord(Array(page[start..<end])) {
                records.append(columns)
            }
            index += 1
        }

        return records
    }

    private static func tableLeafPayloads(page: [UInt8], usable: Int) -> [[UInt8]] {
        let cellCount = Int(readUInt16(page, 3))
        guard cellCount > 0, 8 + 2 * cellCount <= page.count else { return [] }

        var payloads: [[UInt8]] = []
        for cell in 0..<cellCount {
            let cellOffset = Int(readUInt16(page, 8 + 2 * cell))
            guard cellOffset > 0, cellOffset < page.count else { continue }
            guard let (payloadLength, lengthBytes) = varint(page, cellOffset) else { continue }
            guard let (_, rowidBytes) = varint(page, cellOffset + lengthBytes) else { continue }

            let body = cellOffset + lengthBytes + rowidBytes
            let local = localPayloadSize(payloadLength: Int(payloadLength), usable: usable)
            let end = min(body + local, page.count)
            guard body < end else { continue }
            payloads.append(Array(page[body..<end]))
        }
        return payloads
    }

    /// Bytes of a table-leaf payload held in-page before overflow begins.
    private static func localPayloadSize(payloadLength: Int, usable: Int) -> Int {
        let maxLocal = usable - 35
        if payloadLength <= maxLocal { return payloadLength }
        let minLocal = ((usable - 12) * 32 / 255) - 23
        let surplus = minLocal + (payloadLength - minLocal) % (usable - 4)
        return surplus <= maxLocal ? surplus : minLocal
    }

    // MARK: - SQLite records

    enum RecordValue: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
        case unavailable
    }

    /// Decodes a SQLite record, tolerating a payload truncated by overflow: the
    /// columns we need sit near the front, so a missing tail is not fatal.
    static func decodeRecord(_ payload: [UInt8]) -> [RecordValue]? {
        guard let (headerLength, headerBytes) = varint(payload, 0) else { return nil }
        let headerEnd = Int(headerLength)
        guard headerEnd >= headerBytes, headerEnd <= payload.count else { return nil }

        var serialTypes: [UInt64] = []
        var cursor = headerBytes
        while cursor < headerEnd {
            guard let (serial, used) = varint(payload, cursor) else { return nil }
            serialTypes.append(serial)
            cursor += used
        }

        var values: [RecordValue] = []
        var body = headerEnd
        for serial in serialTypes {
            let width = serialWidth(serial)
            guard body + width <= payload.count else {
                values.append(.unavailable)
                body += width
                continue
            }
            values.append(serialValue(serial, Array(payload[body..<(body + width)])))
            body += width
        }
        return values
    }

    private static func serialWidth(_ serial: UInt64) -> Int {
        switch serial {
        case 0, 8, 9, 10, 11: return 0
        case 1, 2, 3, 4: return Int(serial)
        case 5: return 6
        case 6, 7: return 8
        default: return Int((serial - 12) / 2)
        }
    }

    private static func serialValue(_ serial: UInt64, _ raw: [UInt8]) -> RecordValue {
        switch serial {
        case 0: return .null
        case 1, 2, 3, 4, 5, 6:
            var value: Int64 = raw.first.map { $0 & 0x80 != 0 ? -1 : 0 } ?? 0
            for byte in raw { value = (value << 8) | Int64(byte) }
            return .integer(value)
        case 7:
            var bits: UInt64 = 0
            for byte in raw { bits = (bits << 8) | UInt64(byte) }
            return .real(Double(bitPattern: bits))
        case 8: return .integer(0)
        case 9: return .integer(1)
        default:
            if serial >= 12, serial % 2 == 0 { return .blob(Data(raw)) }
            return .text(String(decoding: raw, as: UTF8.self))
        }
    }

    // MARK: - Primitives

    /// SQLite variable-length integer. Returns the value and bytes consumed.
    static func varint(_ bytes: [UInt8], _ offset: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var index = 0
        while index < 8 {
            guard offset + index < bytes.count else { return nil }
            let byte = bytes[offset + index]
            value = (value << 7) | UInt64(byte & 0x7F)
            if byte & 0x80 == 0 { return (value, index + 1) }
            index += 1
        }
        guard offset + 8 < bytes.count else { return nil }
        return ((value << 8) | UInt64(bytes[offset + 8]), 9)
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}
// `Data.hexString` is declared once for the voting flavor in
// `VotingCryptoClientLiveKey.swift` and reused here; see the collision note in
// `MigrationCommitPipeline` for why it must not be redeclared.
#endif
