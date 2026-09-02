#if RECOVERY_VOTING_ENABLED
import Foundation

/// Recovers `bundles` rows that `clear_round` deleted, by carving the voting
/// database and its write-ahead log.
///
/// THE FILE FORMAT, since every function below works at one of these levels.
/// Reference: <https://www.sqlite.org/fileformat.html>
/// Write-ahead log, section 4: <https://www.sqlite.org/fileformat.html#wal_file_format>
///
///     database file
///     +--------------+--------------+--------------+----  pages, fixed size
///     |   page 1     |   page 2     |   page 3     | ...   (4096 by default)
///     +--------------+--------------+--------------+----
///      ^ first 100 bytes are the FILE header:
///        magic "SQLite format 3\0", page size at 16, reserved byte at 20.
///        Only page 1 carries it, which is why `headerOffset` is 100 there
///        and 0 everywhere else.
///
///     one page (a table b-tree LEAF, type byte 0x0D)
///     +------+-------------------+###############+---------------------+
///     | hdr  | cell pointer array|   free space  |  cells, growing <-- |
///     +------+-------------------+###############+---------------------+
///      0    8                                                     4096
///
///     hdr: type(1) freeblock(2) CELL COUNT(2) content start(2) frag(1)
///          = 8 bytes on a leaf; an interior page adds a 4-byte right-most
///          pointer, making 12. This parser only ever walks leaves.
///
///     Cells are appended from the END of the page downwards, and the pointer
///     array grows from the front. They meet in the middle; what is between
///     them is free. A DELETED row is unlinked from the pointer array and its
///     space joins a freeblock list, but the bytes are NOT zeroed unless
///     SQLite was built with SQLITE_SECURE_DELETE, and this build was not.
///     That is the whole reason carving works: deleted means unreferenced,
///     not erased.
///
///     one cell (table leaf)
///     +--------------+--------+-------------------+------------------+
///     | payload len  | rowid  |   payload         | overflow page no |
///     |   varint     | varint |   (local part)    |   4 bytes, only  |
///     +--------------+--------+-------------------+   when spilled   +
///
///     one payload (a record)
///     +-------------+----------+----------+-----+--------+--------+----
///     | header len  | serial 0 | serial 1 | ... | value0 | value1 | ...
///     |   varint    |  varint  |  varint  |     |        |        |
///     +-------------+----------+----------+-----+--------+--------+----
///     |<------------- header --------------->|<-------- body --------
///
///     A serial type encodes type AND length: 0 is NULL, 1-6 are integers of
///     1/2/3/4/6/8 bytes, 7 is a float, 8 and 9 are the constants 0 and 1
///     costing no body bytes, N>=12 even is a BLOB of (N-12)/2 bytes and
///     N>=13 odd is TEXT of (N-13)/2.
///
///     So a `bundles` record always opens with the serial for `round_id`,
///     TEXT of length 64: 2*64+13 = 141, the varint 0x81 0x0D. That pair is
///     the signature the sweep scans for, and it is how a row is found once
///     nothing points at it any more.
///
/// In WAL mode SQLite appends a fresh image of every modified page on each
/// commit, so a page rewritten by several commits appears several times. The
/// frames written before a delete still hold the intact row, including the
/// 32-byte VAN blinding factor that exists nowhere else and cannot be
/// recomputed.
///
///     write-ahead log
///     +----------+---------------+---------------+---------------+---
///     | 32-byte  | frame hdr(24) | frame hdr(24) | frame hdr(24) |
///     |  header  | + page image  | + page image  | + page image  |
///     +----------+---------------+---------------+---------------+---
///                 ^ the frame header names WHICH page this image is.
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
        /// Written by `store_delegation_tx_hash`, a LATER statement than the
        /// one that writes the rest of this list, so a row image captured at
        /// delegation-build time has it NULL. Legitimately absent whenever the
        /// delegation was never broadcast.
        case delegationTxHash = 23
    }

    /// Number of columns in `bundles`; a record with fewer is not one of ours.
    static let bundleColumnCount = 24

    /// Pallas base field modulus, as big-endian hex. A genuine blinding factor
    /// is a canonical little-endian element below it.
    /// <https://github.com/zcash/pasta_curves/blob/18ee865b9dc9a4a3c6f4f84b0d3db3c887b8970c/src/fields/fp.rs#L110>
    static let pallasModulus = "40000000000000000000000000000000224698fc094cf91b992d30ed00000001"

    /// The first four bytes of a write-ahead log, big-endian. The low bit
    /// names the byte order of the frame checksums: `0x377F0683` big-endian,
    /// `0x377F0682` little-endian. This parser reads page images and never
    /// checks a checksum, so it accepts both. Spec sections 4.1 and 4.2.
    /// <https://www.sqlite.org/fileformat.html#wal_file_format>
    static let walMagic: [UInt32] = [0x377F_0682, 0x377F_0683]

    // MARK: - SQLite file format constants

    /// Every constant below is fixed by the SQLite file format specification,
    /// <https://www.sqlite.org/fileformat.html>. None is a tuning choice: they
    /// describe a layout that already exists on disk, so changing one does not
    /// change behaviour, it makes the parser wrong.
    enum Format {
        // Database header, spec section 1.3.
        // <https://www.sqlite.org/fileformat.html#the_database_header>

        /// The database file header occupies the first 100 bytes of page 1,
        /// ahead of that page's b-tree header. No other page carries it.
        static let fileHeaderLength = 100
        /// The first 16 bytes of every database file.
        static let magic = Array("SQLite format 3\u{0}".utf8)
        /// Offset of the 2-byte page size field.
        static let pageSizeOffset = 16
        /// Offset of the 1-byte "reserved space per page" field. That region
        /// sits at the end of every page and is not usable payload area.
        static let reservedSizeOffset = 20
        /// Page sizes are powers of two in this range. The field is 16 bits,
        /// so the largest is encoded as the value 1 rather than 65536.
        static let smallestPageSize = 512
        static let largestPageSize = 65_536
        static let largestPageSizeSentinel = 1

        // B-tree page header, spec section 1.6.
        // <https://www.sqlite.org/fileformat.html#b_tree_pages>
        //
        // | offset | size | meaning                                   |
        // | ------ | ---- | ----------------------------------------- |
        // |      0 |    1 | page type                                 |
        // |      1 |    2 | first freeblock                           |
        // |      3 |    2 | cell count                                |
        // |      5 |    2 | start of cell content area                |
        // |      7 |    1 | fragmented free bytes                     |
        // |      8 |    4 | right-most pointer, INTERIOR pages only   |

        /// Page type byte for a table b-tree leaf, the only kind that holds
        /// table rows and so the only kind this parser walks.
        static let tableLeafPageType: UInt8 = 0x0D
        /// Offset of the 2-byte cell count within the b-tree page header.
        static let cellCountOffset = 3
        /// A LEAF page header is 8 bytes, and the cell pointer array begins
        /// immediately after it. Interior pages append a 4-byte right-most
        /// pointer, making theirs 12; this parser never reads one, which is
        /// why the fixed 8 is safe here.
        static let leafHeaderLength = 8
        /// Each cell pointer array entry is a 2-byte page offset.
        static let cellPointerWidth = 2

        // Cell payload overflow for a TABLE LEAF page, spec section 1.6.
        // <https://www.sqlite.org/fileformat.html#cell_payload_overflow_pages>
        //
        // With U the usable page size and P the payload length:
        //     X = U - 35                      most payload that may stay local
        //     M = ((U - 12) * 32 / 255) - 23  least that must
        //     K = M + ((P - M) % (U - 4))
        // P <= X keeps the payload local; else K bytes are local if K <= X;
        // otherwise M bytes are.

        /// The `35` in `X = U - 35`. Table leaves only: an index leaf uses
        /// `((U-12)*64/255)-23` instead, so this is correct only because the
        /// caller has already filtered on `tableLeafPageType`.
        static let maxLocalReserve = 35
        /// The `12` and the `23`: the spec's allowances for the page header
        /// and for cell header overhead. Stated by the specification rather
        /// than derived in it.
        static let minLocalHeaderAllowance = 12
        static let minLocalCellOverhead = 23
        /// `32/255`, roughly 12.5%: the minimum fraction of a page a spilled
        /// payload must still occupy, so a long value cannot strand a nearly
        /// empty page behind it.
        static let minLocalNumerator = 32
        static let minLocalDenominator = 255
        /// An overflow page spends its first 4 bytes on the next-page pointer,
        /// so it carries `U - 4` bytes of payload.
        static let overflowPointerLength = 4

        // Record format, spec section 2.1.
        // <https://www.sqlite.org/fileformat.html#record_format>

        /// Serial types 12 and above encode length in the type itself: even
        /// N is a BLOB of `(N-12)/2` bytes, odd N a TEXT of `(N-13)/2`.
        static let firstVariableLengthSerial: UInt64 = 12

        // Varint, spec section 2.1.
        // <https://www.sqlite.org/fileformat.html#varint>

        /// A varint is at most 9 bytes: the first 8 contribute 7 bits each,
        /// the 9th contributes all 8.
        static let varintMaxBytes = 8
        static let varintContinuationBit: UInt8 = 0x80
        static let varintPayloadMask: UInt8 = 0x7F

        // Write-ahead log, spec section 4.1.
        // <https://www.sqlite.org/fileformat.html#wal_file_format>

        /// The WAL header is 32 bytes, then a run of frames.
        static let walHeaderLength = 32
        /// Each frame is a 24-byte header followed by one page image.
        static let walFrameHeaderLength = 24
        /// Offset of the page size within the WAL header.
        static let walPageSizeOffset = 8
    }

    /// A `round_id` is a 32-byte value rendered as lowercase hex, so 64
    /// characters. This is a voting-schema fact, not a SQLite one.
    static let roundIdHexLength = 64

    /// A Pallas base field element is 32 bytes little-endian, and so is the
    /// `gov_comm` commitment stored beside it.
    static let fieldElementLength = 32

    /// The two bytes a `bundles` record always opens with.
    ///
    /// The first column is `round_id`, TEXT of length 64, whose serial type is
    /// `2 * 64 + 13 = 141`. As a SQLite varint that is `0x81 0x0D`. The
    /// single-byte record-header-length varint sits immediately before it,
    /// which is why a match at `index` means the record starts at `index - 1`.
    static let bundleRecordSignature: [UInt8] = [0x81, 0x0D]

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
        /// Hash of the transaction that broadcast this delegation, when the
        /// carved row generation carried one.
        ///
        /// Optional by nature, not by weakness. `store_delegation_tx_hash`
        /// runs only after `submitDelegation` returns, so nil means one of:
        /// the delegation was built but never broadcast (in which case there
        /// is nothing to resume and re-delegating is correct), or the app died
        /// in the window between broadcast and persistence (in which case the
        /// transaction is on chain and has to be found there).
        ///
        /// Never gate escrow admission on it: the blinding factor is the
        /// irreplaceable part and is worth keeping without this.
        let delegationTxHash: String?
        let origin: Origin
        /// False when the record decoded but its tail did not, `gov_comm` or
        /// `total_note_value` having been truncated by overflow. The blinding
        /// factor is still the recovered one; what is missing is the
        /// commitment that would verify it.
        let isComplete: Bool
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


    /// Page sizes are powers of two between 512 and 65536, per spec 1.3.
    /// <https://www.sqlite.org/fileformat.html#the_database_header>
    ///
    /// Takes the DECODED size. The database header stores 65536 as the
    /// 16-bit value 1, and `geometry` maps that sentinel before it calls
    /// this. The WAL header stores the size in 32 bits with no sentinel, so
    /// its readers pass the field through unchanged.
    private static func isPlausiblePageSize(_ pageSize: Int) -> Bool {
        pageSize >= Format.smallestPageSize
            && pageSize <= Format.largestPageSize
            && pageSize.nonzeroBitCount == 1
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
        // Keyed on a STRUCT, not the rendered string. A string key sorts
        // bundle 10 before bundle 2, while `deduplicated` sorts numerically,
        // so the two would disagree about the order of the same bundles.
        struct BundleKey: Hashable, Comparable {
            let roundId: String
            let bundleIndex: UInt32

            static func < (lhs: Self, rhs: Self) -> Bool {
                (lhs.roundId, lhs.bundleIndex) < (rhs.roundId, rhs.bundleIndex)
            }
        }

        var byBundle: [BundleKey: [RecoveredBundle]] = [:]
        for bundle in bundles {
            byBundle[
                BundleKey(roundId: bundle.roundId, bundleIndex: bundle.bundleIndex),
                default: []
            ].append(bundle)
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

            // The transaction hash is taken from ANY generation of this
            // bundle that carried one, not from `original`.
            //
            // Those two selections genuinely conflict. `original` is the
            // OLDEST generation, because that is the delegation the user
            // broadcast and the rebuild's is the impostor. But
            // `store_delegation_tx_hash` runs after `store_delegation_data`,
            // so the hash only ever appears in a NEWER generation than the
            // secrets it belongs to -- reading it off `original` finds nil
            // every time.
            //
            // Sound because the field is write-once at the source: the UPDATE
            // carries `AND (delegation_tx_hash IS NULL OR delegation_tx_hash =
            // :tx_hash)`, so the generations of one bundle can hold at most one
            // distinct hash and there is nothing to choose between. Restricted
            // to versions sharing the original's `van_comm_rand`, so a rebuilt
            // generation's hash can never be attributed to the broadcast one.
            let txHash = versions
                .first { $0.vanCommRand == original.vanCommRand && $0.delegationTxHash != nil }?
                .delegationTxHash

            let recovered = RecoveredBundle(
                roundId: original.roundId,
                bundleIndex: original.bundleIndex,
                vanCommRand: original.vanCommRand,
                van: original.van,
                totalNoteValue: original.totalNoteValue,
                delegationTxHash: original.delegationTxHash ?? txHash,
                origin: original.origin,
                isComplete: original.isComplete
            )

            replacements.append(
                Replacement(original: recovered, current: allReleased ? nil : newest)
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
            // The reserved-region size lives in the database header, so the
            // log can only be read correctly alongside its own database.
            let reserved = database.count > Format.reservedSizeOffset
                ? Int(database[Format.reservedSizeOffset])
                : 0
            rows += recover(walBytes: [UInt8](wal), roundId: roundId, reservedPerPage: reserved)
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
    /// Page size, usable size and page count, or `nil` when the bytes are not
    /// a SQLite database. Shared so the round-data probe and the carver can
    /// never disagree about a file's geometry.
    static func geometry(databaseBytes: [UInt8]) -> (pageSize: Int, usable: Int, pages: Int)? {
        guard databaseBytes.count > Format.fileHeaderLength else { return nil }
        guard Array(databaseBytes[0..<Format.magic.count]) == Format.magic else { return nil }

        // Page size lives at offset 16; the value 1 means 65536, which does not
        // fit the 16-bit field. Byte 20 is the per-page reserved region, which
        // is not part of the usable payload area.
        let declared = Int(readUInt16(databaseBytes, Format.pageSizeOffset))
        let pageSize = declared == Format.largestPageSizeSentinel
            ? Format.largestPageSize
            : declared
        guard isPlausiblePageSize(pageSize) else { return nil }
        let usable = pageSize - Int(databaseBytes[Format.reservedSizeOffset])
        guard usable > Format.maxLocalReserve else { return nil }

        return (pageSize, usable, databaseBytes.count / pageSize)
    }

    static func recover(databaseBytes: [UInt8], roundId: String? = nil) -> [RecoveredBundle] {
        guard let (pageSize, usable, pageCount) = geometry(databaseBytes: databaseBytes) else {
            return []
        }

        var rows: [RecoveredBundle] = []
        for index in 0..<pageCount {
            let page = Array(databaseBytes[(index * pageSize)..<((index + 1) * pageSize)])
            // Page 1 carries the 100-byte file header before its b-tree header.
            let headerOffset = index == 0 ? Format.fileHeaderLength : 0
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


    // MARK: - Is there anything to recover at all?

    /// Whether these files hold any voting round at all.
    ///
    /// A wallet that never opened a poll has an empty `rounds` table, and with
    /// no round there is nothing a wipe could have destroyed. Recovery can skip
    /// such a device without reading further.
    ///
    /// IMPORTANT, because the inverse is the intuitive reading and it is wrong:
    /// a round whose delegation was wiped is NOT absent. `prepareFreshRound`
    /// deleted the row and immediately rebuilt it, so a corrupted database has
    /// a `rounds` row like any other. Presence means "worth looking at", never
    /// "healthy". Only `plan` can tell those apart.
    ///
    /// Detects `rounds` and `bundles` alike. Both begin with a 64-character hex
    /// `round_id`, so both open with the same record signature; the tables
    /// differ only in how many columns follow, which this deliberately ignores.
    ///
    /// Opens no SQLite connection, for the same reason nothing else here does.
    static func holdsRoundData(databaseURL: URL, walURL: URL? = nil) throws -> Bool {
        let database = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        if holdsRoundData(databaseBytes: [UInt8](database)) { return true }

        if let walURL, FileManager.default.fileExists(atPath: walURL.path) {
            let wal = try Data(contentsOf: walURL, options: .mappedIfSafe)
            return holdsRoundData(walBytes: [UInt8](wal))
        }
        return false
    }

    static func holdsRoundData(databaseBytes: [UInt8]) -> Bool {
        guard let (pageSize, usable, pageCount) = geometry(databaseBytes: databaseBytes) else {
            return false
        }

        for index in 0..<pageCount {
            let page = Array(databaseBytes[(index * pageSize)..<((index + 1) * pageSize)])
            let headerOffset = index == 0 ? Format.fileHeaderLength : 0
            for (columns, _) in bundleRecords(
                inPage: page, usable: usable, headerOffset: headerOffset
            ) where carriesRoundId(columns) {
                return true
            }
        }
        return false
    }

    static func holdsRoundData(walBytes: [UInt8]) -> Bool {
        guard walBytes.count > Format.walHeaderLength else { return false }
        guard walMagic.contains(readUInt32(walBytes, 0)) else { return false }

        let pageSize = Int(readUInt32(walBytes, Format.walPageSizeOffset))
        guard isPlausiblePageSize(pageSize) else { return false }

        var offset = Format.walHeaderLength
        let frameLength = Format.walFrameHeaderLength + pageSize
        while offset + frameLength <= walBytes.count {
            let imageStart = offset + Format.walFrameHeaderLength
            let page = Array(walBytes[imageStart..<(imageStart + pageSize)])
            for (columns, _) in bundleRecords(inPage: page, usable: pageSize)
            where carriesRoundId(columns) {
                return true
            }
            offset += frameLength
        }
        return false
    }

    /// A record whose first column is a 64-character hex round id, which both
    /// `rounds` and `bundles` are and stray bytes almost never are.
    private static func carriesRoundId(_ columns: [RecordValue]) -> Bool {
        guard let first = columns.first,
              case let .text(roundId) = first,
              roundId.count == roundIdHexLength,
              roundId.allSatisfy(\.isHexDigit)
        else {
            return false
        }
        return true
    }

    /// Keeps one row per `(roundId, bundleIndex, vanCommRand)`, preferring the
    /// oldest origin so `plan` sees the earliest surviving copy of a value.
    private static func deduplicated(_ rows: [RecoveredBundle]) -> [RecoveredBundle] {
        var best: [String: RecoveredBundle] = [:]
        // The transaction hash is MERGED across generations rather than taken
        // from the winning row, because it arrives in a later write than the
        // rest of the bundle: `store_delegation_data` leaves it NULL and
        // `store_delegation_tx_hash` fills it in afterwards. Picking one row
        // wholesale would drop it whenever the generation that survived is the
        // build-time one -- and a stale WAL frame can outrank a live row here,
        // since `Origin` orders the log above the file.
        //
        // Merging is sound because the source makes the field write-once: the
        // UPDATE carries `AND (delegation_tx_hash IS NULL OR
        // delegation_tx_hash = :tx_hash)`, so a bundle can never hold two
        // different non-nil hashes and there is nothing to choose between.
        var hashes: [String: String] = [:]
        for row in rows {
            let key = "\(row.roundId)/\(row.bundleIndex)/\(row.vanCommRand.hexString)"
            if hashes[key] == nil, let hash = row.delegationTxHash {
                hashes[key] = hash
            }
            if let existing = best[key], existing.origin <= row.origin { continue }
            best[key] = row
        }
        return best.map { key, row in
            RecoveredBundle(
                roundId: row.roundId,
                bundleIndex: row.bundleIndex,
                vanCommRand: row.vanCommRand,
                van: row.van,
                totalNoteValue: row.totalNoteValue,
                delegationTxHash: row.delegationTxHash ?? hashes[key],
                origin: row.origin,
                isComplete: row.isComplete
            )
        }
        .sorted {
            ($0.bundleIndex, $0.origin) < ($1.bundleIndex, $1.origin)
        }
    }

    /// - Parameter reservedPerPage: bytes reserved at the end of every page,
    ///   from the DATABASE header. A write-ahead log has no header of its own
    ///   carrying it, so the value has to come from the database it belongs
    ///   to; the database path already subtracts it and this one did not, so
    ///   the two disagreed about the usable size of the same page whenever a
    ///   reserved region existed.
    static func recover(
        walBytes: [UInt8],
        roundId: String? = nil,
        reservedPerPage: Int = 0
    ) -> [RecoveredBundle] {
        guard walBytes.count > Format.walHeaderLength else { return [] }

        let magic = readUInt32(walBytes, 0)
        guard walMagic.contains(magic) else { return [] }

        let pageSize = Int(readUInt32(walBytes, Format.walPageSizeOffset))
        guard isPlausiblePageSize(pageSize) else { return [] }

        let usable = pageSize - reservedPerPage
        guard usable > Format.maxLocalReserve else { return [] }

        var recovered: [RecoveredBundle] = []
        var seen: Set<String> = []

        // Frames are 24 bytes of header followed by one page image. Every frame
        // is walked, including any whose salts no longer match the WAL header:
        // SQLite ignores those, but they are physically intact and are often
        // the oldest surviving copy of a page.
        var offset = Format.walHeaderLength
        var frame = 0
        let frameLength = Format.walFrameHeaderLength + pageSize
        while offset + frameLength <= walBytes.count {
            let imageStart = offset + Format.walFrameHeaderLength
            let page = Array(walBytes[imageStart..<(imageStart + pageSize)])
            // The frame header names the page this image belongs to, and page
            // 1 carries the 100-byte database header before its b-tree header.
            // Reading it at offset 0, as this did, walks the file header as
            // though it were a b-tree.
            let pageNumber = Int(readUInt32(walBytes, offset))
            let headerOffset = pageNumber == 1 ? Format.fileHeaderLength : 0
            for (columns, _) in bundleRecords(
                inPage: page, usable: usable, headerOffset: headerOffset
            ) {
                guard let bundle = makeBundle(columns: columns, origin: .walFrame(frame))
                else { continue }
                if let roundId, bundle.roundId.caseInsensitiveCompare(roundId) != .orderedSame {
                    continue
                }
                // Keyed on the transaction hash as well as the secret,
                // because one bundle legitimately appears in the log TWICE
                // with the same `van_comm_rand`: once as
                // `store_delegation_data` wrote it, and again once
                // `store_delegation_tx_hash` filled in the hash afterwards.
                // Keying on the secret alone keeps whichever frame came first
                // -- always the one WITHOUT the hash -- and the later
                // generation is dropped here, before `deduplicated` or `plan`
                // can merge it. Both generations must survive the scan for
                // that merge to have anything to work with.
                let key = "\(bundle.roundId)/\(bundle.bundleIndex)/"
                    + "\(bundle.vanCommRand.hexString)/\(bundle.delegationTxHash ?? "")"
                if seen.insert(key).inserted {
                    recovered.append(bundle)
                }
            }
            offset += frameLength
            frame += 1
        }

        return recovered
    }

    /// Whether `candidate` could be a Pallas base field element. A carved value
    /// that fails this was never a blinding factor.
    static func isCanonicalPallasElement(_ candidate: Data) -> Bool {
        guard candidate.count == fieldElementLength else { return false }
        // Stored little-endian; compare big-endian against the modulus.
        let reversed = Data(candidate.reversed()).hexString
        return reversed < pallasModulus
    }

    // MARK: - SQLite b-tree pages

    private static func makeBundle(columns: [RecordValue], origin: Origin) -> RecoveredBundle? {
        guard columns.count >= bundleColumnCount,
              case let .text(roundId) = columns[BundleColumn.roundId.rawValue],
              roundId.count == roundIdHexLength,
              roundId.allSatisfy(\.isHexDigit),
              case let .integer(bundleIndex) = columns[BundleColumn.bundleIndex.rawValue],
              bundleIndex >= 0, bundleIndex < Int64(UInt32.max),
              case let .blob(rand) = columns[BundleColumn.vanCommRand.rawValue],
              rand.count == fieldElementLength
        else {
            return nil
        }

        let van: Data
        // `gov_comm` and `total_note_value` sit past several variable-length
        // blobs, so a payload cut short by overflow can yield the blinding
        // factor and lose them. Still worth recovering, the blinding factor
        // being the irreplaceable part, but the caller has to be able to tell:
        // `van` is what would otherwise verify it.
        var isComplete = true

        if case let .blob(stored) = columns[BundleColumn.govComm.rawValue],
           stored.count == fieldElementLength {
            van = stored
        } else {
            van = Data()
            isComplete = false
        }

        var weight: UInt64 = 0
        if case let .integer(stored) = columns[BundleColumn.totalNoteValue.rawValue], stored >= 0 {
            weight = UInt64(stored)
        } else {
            isComplete = false
        }

        // Absence is normal here, so it does not touch `isComplete`: a
        // delegation that was never broadcast has no hash to carry, and the
        // blinding factor is still worth escrowing.
        var txHash: String?
        if case let .text(stored) = columns[BundleColumn.delegationTxHash.rawValue],
           stored.isEmpty == false {
            txHash = stored
        }

        return RecoveredBundle(
            roundId: roundId.lowercased(),
            bundleIndex: UInt32(bundleIndex),
            vanCommRand: rand,
            van: van,
            totalNoteValue: weight,
            delegationTxHash: txHash,
            origin: origin,
            isComplete: isComplete
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

        if page.count > headerOffset, page[headerOffset] == Format.tableLeafPageType {
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
        // Start at 1 at the earliest: a match at index 0 would put the
        // record header-length varint before the start of the page.
        var index = max(1, headerOffset)
        while index + 1 < page.count {
            guard page[index] == bundleRecordSignature[0],
                  page[index + 1] == bundleRecordSignature[1]
            else {
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
        let cellCount = Int(readUInt16(page, headerOffset + Format.cellCountOffset))
        let arrayEnd = headerOffset + Format.leafHeaderLength
            + Format.cellPointerWidth * cellCount
        guard cellCount > 0, arrayEnd <= page.count else { return [] }

        var payloads: [(bytes: [UInt8], range: Range<Int>)] = []
        for cell in 0..<cellCount {
            let cellOffset = Int(readUInt16(
                page,
                headerOffset + Format.leafHeaderLength + Format.cellPointerWidth * cell
            ))
            guard cellOffset > 0, cellOffset < page.count else { continue }
            guard let (payloadLength, lengthBytes) = varint(page, cellOffset) else { continue }
            guard let (_, rowidBytes) = varint(page, cellOffset + lengthBytes) else { continue }

            // Same trap as the record header: a varint payload length can
            // exceed `Int.max`, and a cell claiming one is not ours.
            guard payloadLength <= UInt64(Int.max) else { continue }

            let body = cellOffset + lengthBytes + rowidBytes
            let local = localPayloadSize(payloadLength: Int(payloadLength), usable: usable)
            let end = min(body + local, page.count)
            guard body < end else { continue }
            payloads.append((Array(page[body..<end]), body..<end))
        }
        return payloads
    }

    /// Bytes of a table-leaf payload held in-page before overflow begins.
    ///
    /// The remainder, if any, lives in a chain of overflow pages that this
    /// parser does NOT follow, and does not need to. `van_comm_rand` is column
    /// 5 of 24, ahead of every variable-length blob except two that scale with
    /// the note count, and `smartBundles` caps a bundle at FIVE notes
    /// (`VotingHelpers.swift`). So the secret sits roughly 300 bytes into the
    /// record whatever the wallet holds, well inside even the pessimistic
    /// minimum local payload of `((U-12)*32/255)-23`, which is 489 bytes at
    /// the usual 4096-byte page.
    ///
    /// It is written in one statement with every other large column
    /// (`queries.rs`, the UPDATE that sets `van_comm_rand`), so there is no
    /// state where the blinding factor exists in a row too large to reach it.
    /// If that cap or that column order ever changes, this assumption has to
    /// be revisited and the chain followed.
    private static func localPayloadSize(payloadLength: Int, usable: Int) -> Int {
        let maxLocal = usable - Format.maxLocalReserve
        if payloadLength <= maxLocal { return payloadLength }
        let minLocal = ((usable - Format.minLocalHeaderAllowance)
            * Format.minLocalNumerator / Format.minLocalDenominator)
            - Format.minLocalCellOverhead
        let surplus = minLocal
            + (payloadLength - minLocal) % (usable - Format.overflowPointerLength)
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
        // Compare before converting. A varint carries up to 64 bits, so a
        // corrupt header length exceeds `Int.max` and `Int(_:)` traps on it.
        // These bytes come from released space and are arbitrary.
        guard headerLength <= UInt64(payload.count) else { return nil }
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
        var body = headerEnd
        for serial in serialTypes {
            let width = serialWidth(serial)
            // Measure the room left rather than summing. `width` comes from
            // the record header, so on carved bytes it can be `Int.max`, and
            // `body + width` would overflow and trap.
            //
            // `body` is only ever advanced by a width that fitted, or pinned
            // to the end, so `payload.count - body` cannot go negative.
            let remaining = payload.count - body
            guard width <= remaining else {
                // The tail is out of reach. Pin `body` rather than advancing
                // it past the end, so the remaining columns read as
                // unavailable without the addition ever overflowing.
                values.append(.unavailable)
                body = payload.count
                continue
            }
            values.append(serialValue(serial, Array(payload[body..<(body + width)])))
            body += width
        }
        return values
    }

    /// Bytes on disk for one record serial type, per spec section 2.1.
    /// <https://www.sqlite.org/fileformat.html#record_format>
    ///
    /// | serial        | type                     | bytes      |
    /// | ------------- | ------------------------ | ---------- |
    /// | 0             | NULL                     | 0          |
    /// | 1, 2, 3, 4    | signed integer           | 1, 2, 3, 4 |
    /// | 5             | signed integer           | 6          |
    /// | 6             | signed integer           | 8          |
    /// | 7             | IEEE-754 float           | 8          |
    /// | 8, 9          | the constants 0 and 1    | 0          |
    /// | 10, 11        | reserved for internal use| 0          |
    /// | N >= 12, even | BLOB                     | (N-12)/2   |
    /// | N >= 13, odd  | TEXT                     | (N-13)/2   |
    ///
    /// Cases 1 to 4 return the serial itself only by coincidence of the first
    /// four codes; 5 and 6 break that pattern, which is why they are listed
    /// separately rather than folded into a formula.
    ///
    /// The default arm covers BLOB and TEXT together: for odd N, `N - 12` is
    /// odd and integer division floors, which yields `(N-13)/2` exactly.
    ///
    /// This also explains the sweep signature. `round_id` is TEXT of length
    /// 64, so its serial is `2 * 64 + 13 = 141`, the varint `0x81 0x0D`.
    private static func serialWidth(_ serial: UInt64) -> Int {
        switch serial {
        case 0, 8, 9, 10, 11: return 0
        case 1, 2, 3, 4: return Int(serial)
        case 5: return 6
        case 6, 7: return 8
        default:
            // Fits `Int64` by a margin of six for the largest serial a varint
            // can encode, which is too close to rely on. Saturate instead: any
            // width past the payload is unusable anyway, and the caller treats
            // it as an unavailable column.
            let width = (serial - Format.firstVariableLengthSerial) / 2
            return width > UInt64(Int.max) ? Int.max : Int(width)
        }
    }

    /// Decodes one value given its serial type and its raw bytes.
    ///
    /// Integers are stored big-endian and two's complement, so decoding seeds
    /// the accumulator with all-ones when the leading byte's sign bit (`0x80`)
    /// is set. That sign-extends a 1-, 2-, 3-, 4- or 6-byte value into `Int64`
    /// without a separate widening step.
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
            if serial >= Format.firstVariableLengthSerial, serial % 2 == 0 {
                return .blob(Data(raw))
            }
            return .text(String(decoding: raw, as: UTF8.self))
        }
    }

    // MARK: - Primitives

    /// SQLite variable-length integer. Returns the value and bytes consumed.
    static func varint(_ bytes: [UInt8], _ offset: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var index = 0
        while index < Format.varintMaxBytes {
            guard offset + index < bytes.count else { return nil }
            let byte = bytes[offset + index]
            value = (value << 7) | UInt64(byte & Format.varintPayloadMask)
            if byte & Format.varintContinuationBit == 0 { return (value, index + 1) }
            index += 1
        }
        guard offset + Format.varintMaxBytes < bytes.count else { return nil }
        // The ninth byte contributes all 8 of its bits, not 7.
        return ((value << 8) | UInt64(bytes[offset + Format.varintMaxBytes]),
                Format.varintMaxBytes + 1)
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
