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

    /// Where a carved row came from, ordered oldest to newest.
    ///
    /// The main database file holds the last checkpointed state, so anything
    /// still in the WAL is newer than anything in it; and within the database,
    /// a row sitting in freed space was superseded by whatever is live. That
    /// total order is what lets `plan` pick the original without a clock.
    enum Origin: Comparable, Hashable, Sendable {
        /// A deleted cell in the database file: freed pages, freeblocks, or
        /// the unallocated gap. Oldest.
        case databaseFreeSpace
        /// A row still reachable through the database file's b-tree.
        case databaseLive
        /// A page image in the write-ahead log, by zero-based frame index.
        /// Newest, since the WAL holds commits made after the last checkpoint.
        case walFrame(Int)
    }

    struct RecoveredBundle: Equatable, Sendable {
        let roundId: String
        let bundleIndex: UInt32
        let vanCommRand: Data
        let van: Data
        let totalNoteValue: UInt64
        let origin: Origin
    }

    /// One bundle whose secrets a wipe destroyed.
    struct Replacement: Equatable, Sendable {
        /// The delegation the user actually broadcast, from the oldest origin.
        let original: RecoveredBundle
        /// What the rebuild put in its place, from the newest origin — matching
        /// the row currently in `bundles`. `nil` when the round was cleared and
        /// never rebuilt, so nothing stands in the original's place.
        let current: RecoveredBundle?
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

    /// Same decision, over both files. Use this when the database is available:
    /// it adds the rows the WAL cannot supply once a clean close checkpointed
    /// and unlinked it.
    static func plan(
        databaseURL: URL,
        walURL: URL? = nil,
        roundId: String? = nil
    ) throws -> Plan {
        plan(bundles: try recover(databaseURL: databaseURL, walURL: walURL, roundId: roundId))
    }

    static func plan(bundles: [RecoveredBundle]) -> Plan {
        var byBundle: [String: [RecoveredBundle]] = [:]
        for bundle in bundles {
            byBundle["\(bundle.roundId)/\(bundle.bundleIndex)", default: []].append(bundle)
        }

        var replacements: [Replacement] = []
        for key in byBundle.keys.sorted() {
            guard let versions = byBundle[key] else { continue }
            guard let original = versions.min(by: { $0.origin < $1.origin }),
                  let newest = versions.max(by: { $0.origin < $1.origin })
            else {
                continue
            }

            // Two signals mean the bundle lost its secrets, and only these two.
            //
            // More than one distinct value: something replaced them, which is
            // the rebuild `prepareFreshRound` performs. And every surviving
            // copy sitting in released space with nothing live above it: the
            // row was deleted and never rebuilt, so it is gone from the
            // database entirely.
            //
            // Neither fires for an untouched round. Its bundles are live, so
            // they always have a live or WAL origin, and a page rewritten any
            // number of times still yields exactly one `van_comm_rand`.
            let distinct = Set(versions.map(\.vanCommRand))
            let allReleased = versions.allSatisfy { $0.origin == .databaseFreeSpace }
            guard distinct.count > 1 || allReleased else { continue }

            replacements.append(
                Replacement(original: original, current: allReleased ? nil : newest)
            )
        }

        return Plan(replacements: replacements)
    }

    /// Carves every recoverable `bundles` row from both files.
    ///
    /// The WAL holds the newest page images and is where a freshly cleared
    /// round is usually still intact. The database file covers the case the WAL
    /// cannot: it was checkpointed and unlinked by a clean close, but the
    /// deleted cells were never overwritten, so they survive in freed pages,
    /// in freeblocks inside live pages, and in the unallocated gap. `bundles`
    /// rows are only zeroed on delete if SQLite was built with
    /// `SQLITE_SECURE_DELETE`, and the bundled build is not.
    ///
    /// A missing WAL is normal, not an error.
    static func recover(
        databaseURL: URL,
        walURL: URL? = nil,
        roundId: String? = nil
    ) throws -> [RecoveredBundle] {
        var rows: [RecoveredBundle] = []

        let database = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        rows += recover(databaseBytes: [UInt8](database), roundId: roundId)

        if let walURL, FileManager.default.fileExists(atPath: walURL.path) {
            let wal = try Data(contentsOf: walURL, options: .mappedIfSafe)
            rows += recover(walBytes: [UInt8](wal), roundId: roundId)
        }

        return deduplicated(rows)
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

    /// Carves the main database file: live b-tree rows, plus deleted cells that
    /// no cell-pointer array references any more.
    static func recover(databaseBytes: [UInt8], roundId: String? = nil) -> [RecoveredBundle] {
        guard databaseBytes.count > 100 else { return [] }
        guard Array(databaseBytes[0..<16]) == Array("SQLite format 3\u{0}".utf8) else { return [] }

        // Page size lives at offset 16; the value 1 means 65536, which does not
        // fit the 16-bit field. Byte 20 is the per-page reserved region, which
        // is not part of the usable payload area.
        let declared = Int(readUInt16(databaseBytes, 16))
        let pageSize = declared == 1 ? 65_536 : declared
        guard pageSize >= 512, pageSize <= 65_536, pageSize % 512 == 0 else { return [] }
        let usable = pageSize - Int(databaseBytes[20])
        guard usable > 35 else { return [] }

        var rows: [RecoveredBundle] = []
        let pageCount = databaseBytes.count / pageSize
        for index in 0..<pageCount {
            let page = Array(databaseBytes[(index * pageSize)..<((index + 1) * pageSize)])
            // Page 1 carries the 100-byte file header before its b-tree header.
            let headerOffset = index == 0 ? 100 : 0
            for (columns, isLive) in bundleRecords(
                inPage: page, usable: usable, headerOffset: headerOffset
            ) {
                let origin: Origin = isLive ? .databaseLive : .databaseFreeSpace
                guard let bundle = makeBundle(columns: columns, origin: origin) else { continue }
                if let roundId, bundle.roundId.caseInsensitiveCompare(roundId) != .orderedSame {
                    continue
                }
                rows.append(bundle)
            }
        }
        return rows
    }

    /// Keeps one row per `(roundId, bundleIndex, vanCommRand)`, preferring the
    /// oldest origin so `plan` sees the earliest surviving copy of a value.
    private static func deduplicated(_ rows: [RecoveredBundle]) -> [RecoveredBundle] {
        var best: [String: RecoveredBundle] = [:]
        for row in rows {
            let key = "\(row.roundId)/\(row.bundleIndex)/\(row.vanCommRand.hexString)"
            if let existing = best[key], existing.origin <= row.origin { continue }
            best[key] = row
        }
        return best.values.sorted {
            ($0.bundleIndex, $0.origin) < ($1.bundleIndex, $1.origin)
        }
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
            for (columns, _) in bundleRecords(inPage: page, usable: pageSize) {
                guard let bundle = makeBundle(columns: columns, origin: .walFrame(frame))
                else { continue }
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

    private static func makeBundle(columns: [RecordValue], origin: Origin) -> RecoveredBundle? {
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
            origin: origin
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
    /// Returns each decoded record with whether it is still live, i.e. still
    /// referenced by the page's cell-pointer array. A record found only by the
    /// signature sweep sits in space the b-tree has released — a freed page, a
    /// freeblock inside a page that still holds other rows, or the unallocated
    /// gap — and is therefore an older version than anything live.
    ///
    /// `headerOffset` is 100 for page 1 of a database file, which carries the
    /// file header before its b-tree header, and 0 everywhere else.
    private static func bundleRecords(
        inPage page: [UInt8],
        usable: Int,
        headerOffset: Int = 0
    ) -> [(columns: [RecordValue], isLive: Bool)] {
        var records: [(columns: [RecordValue], isLive: Bool)] = []
        var liveRanges: [Range<Int>] = []

        if page.count > headerOffset, page[headerOffset] == 0x0D {
            for payload in tableLeafPayloads(
                page: page, usable: usable, headerOffset: headerOffset
            ) {
                liveRanges.append(payload.range)
                if let columns = decodeRecord(payload.bytes) {
                    records.append((columns, true))
                }
            }
        }

        // Sweep for the record signature. A `bundles` record opens with the
        // serial type for its 64-character hex `round_id` (TEXT of length 64 ->
        // 2 * 64 + 13 = 141, the varint `0x81 0x0D`), with the single-byte
        // header-length varint immediately before it.
        var index = max(1, headerOffset)
        while index + 1 < page.count {
            guard page[index] == 0x81, page[index + 1] == 0x0D else {
                index += 1
                continue
            }
            let start = index - 1
            // Anything the cell-pointer walk already returned is live and has
            // been recorded; re-decoding it here would double count it.
            if !liveRanges.contains(where: { $0.contains(start) }) {
                let end = min(start + usable, page.count)
                if let columns = decodeRecord(Array(page[start..<end])) {
                    records.append((columns, false))
                }
            }
            index += 1
        }

        return records
    }

    private static func tableLeafPayloads(
        page: [UInt8],
        usable: Int,
        headerOffset: Int = 0
    ) -> [(bytes: [UInt8], range: Range<Int>)] {
        let cellCount = Int(readUInt16(page, headerOffset + 3))
        let arrayEnd = headerOffset + 8 + 2 * cellCount
        guard cellCount > 0, arrayEnd <= page.count else { return [] }

        var payloads: [(bytes: [UInt8], range: Range<Int>)] = []
        for cell in 0..<cellCount {
            let cellOffset = Int(readUInt16(page, headerOffset + 8 + 2 * cell))
            guard cellOffset > 0, cellOffset < page.count else { continue }
            guard let (payloadLength, lengthBytes) = varint(page, cellOffset) else { continue }
            guard let (_, rowidBytes) = varint(page, cellOffset + lengthBytes) else { continue }

            let body = cellOffset + lengthBytes + rowidBytes
            let local = localPayloadSize(payloadLength: Int(payloadLength), usable: usable)
            let end = min(body + local, page.count)
            guard body < end else { continue }
            payloads.append((Array(page[body..<end]), body..<end))
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
