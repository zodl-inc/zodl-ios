#if VOTING_ENABLED
import Foundation

/// Finds delegation bundles that match a VAN commitment already accepted by
/// the voting chain.
///
/// Recovery is deliberately target-bound. WAL position, database free-space
/// ordering, and the presence of multiple random values are forensic hints,
/// not proof that a candidate is the delegation that landed. An exact
/// `gov_comm == vanCmx` match is required before any bundle is returned.
///
/// The source files are read as bytes and are never opened through SQLite.
enum VotingDatabaseRecovery {
    private enum BundleColumn: Int, CaseIterable {
        case roundId = 0
        case walletId = 1
        case bundleIndex = 2
        case notePositions = 3
        case noteIdentityHashes = 4
        case vanCommRand = 5
        case dummyNullifiers = 6
        case rhoSigned = 7
        case paddedNoteData = 8
        case nfSigned = 9
        case cmxNew = 10
        case alpha = 11
        case rseedSigned = 12
        case rseedOutput = 13
        case govComm = 14
        case totalNoteValue = 15
        case addressIndex = 16
        case vanLeafPosition = 17
        case rk = 18
        case govNullifiers = 19
        case paddedNoteSecrets = 20
        case pcztSighash = 21
        case tx1Effects = 22
        case delegationTxHash = 23
    }

    private static let bundleColumnCount = BundleColumn.allCases.count
    private static let walMagic: Set<UInt32> = [0x377F_0682, 0x377F_0683]

    private static let maxMoneyZatoshi: Int64 = 2_100_000_000_000_000

    /// Pallas base-field modulus, encoded big-endian for lexical comparison.
    private static let pallasModulus =
        "40000000000000000000000000000000224698fc094cf91b992d30ed00000001"

    enum RecoveryError: Error, Equatable {
        case invalidVanCmxLength(Int)
        case invalidRoundId
    }

    /// Physical provenance for a recovered row.
    enum Source: Equatable, Hashable, Sendable {
        /// A live row in the preserved main database.
        case databaseLive(page: Int)
        /// A record decoded or reconstructed from raw main-database bytes.
        case databaseCarved(page: Int, offset: Int)
        /// A live row in a checksum-valid committed WAL state.
        case walCommit(frame: Int)
        /// A record decoded or reconstructed directly from one WAL page image.
        case walCarved(frame: Int, currentGeneration: Bool, offset: Int)
    }

    /// One schema-consistent bundle whose stored commitment exactly matches the
    /// requested on-chain VAN.
    struct RecoveredBundle: Equatable, Sendable {
        let roundId: String
        let walletId: String
        let bundleIndex: UInt32
        let notePositionsBlob: Data?
        let noteIdentityHashesBlob: Data?
        let vanCommRand: Data
        let dummyNullifiers: Data?
        let rhoSigned: Data?
        let paddedNoteData: Data?
        let nfSigned: Data?
        let cmxNew: Data?
        let alpha: Data?
        let rseedSigned: Data?
        let rseedOutput: Data?
        let vanCmx: Data
        let totalNoteValue: UInt64
        let addressIndex: UInt32?
        let vanLeafPosition: UInt32?
        let rk: Data?
        let govNullifiersBlob: Data?
        let paddedNoteSecrets: Data?
        let pcztSighash: Data?
        let tx1Effects: Data?
        let delegationTxHash: String?
        let source: Source
    }

    /// An exact occurrence of the target commitment in preserved bytes. A hit
    /// is evidence, but is not returned as a bundle unless the surrounding
    /// fields can also be recovered and validated structurally.
    struct RawTargetHit: Equatable, Hashable, Sendable {
        let source: Source
    }

    struct Report: Equatable, Sendable {
        let vanCmx: Data
        let candidates: [RecoveredBundle]
        let rawTargetHits: [RawTargetHit]
        let validWalFrameCount: Int
        let committedWalPrefixCount: Int

        var recovered: Bool { !candidates.isEmpty }
    }

    /// Recovers only bundles matching `vanCmx` from preserved database files.
    ///
    /// `roundId` is required because commitment leaves are round-scoped.
    /// `walletId` and `bundleIndex` are optional additional constraints. Pass
    /// `bundleIndex` when available: SQLite stores the common indices zero and
    /// one entirely in the record header, so a header-damaged raw record cannot
    /// prove either value on its own.
    static func recover(
        databaseURL: URL,
        walURL: URL? = nil,
        vanCmx: Data,
        roundId: String,
        walletId: String? = nil,
        bundleIndex: UInt32? = nil
    ) throws -> Report {
        guard vanCmx.count == 32 else {
            throw RecoveryError.invalidVanCmxLength(vanCmx.count)
        }
        guard isCanonicalRoundId(roundId) else {
            throw RecoveryError.invalidRoundId
        }

        let database = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        let wal: Data?
        if let walURL, FileManager.default.fileExists(atPath: walURL.path) {
            wal = try Data(contentsOf: walURL, options: .mappedIfSafe)
        } else {
            wal = nil
        }

        return try recover(
            databaseBytes: [UInt8](database),
            walBytes: wal.map { [UInt8]($0) },
            vanCmx: vanCmx,
            roundId: roundId,
            walletId: walletId,
            bundleIndex: bundleIndex
        )
    }

    /// Recovers every exact on-chain target present in the preserved files.
    ///
    /// The files are loaded once and searched in one pass before the full
    /// forensic decoder runs. This keeps a complete public vote tree usable as
    /// the target set without reparsing the database for leaves that never
    /// occur in the preserved bytes.
    static func recover(
        databaseURL: URL,
        walURL: URL? = nil,
        vanCmxTargets: Set<Data>,
        roundId: String,
        walletId: String? = nil
    ) throws -> [Report] {
        let database = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        let wal: Data?
        if let walURL, FileManager.default.fileExists(atPath: walURL.path) {
            wal = try Data(contentsOf: walURL, options: .mappedIfSafe)
        } else {
            wal = nil
        }

        return try recover(
            databaseBytes: [UInt8](database),
            walBytes: wal.map { [UInt8]($0) },
            vanCmxTargets: vanCmxTargets,
            roundId: roundId,
            walletId: walletId
        )
    }

    static func recover(
        databaseBytes: [UInt8],
        walBytes: [UInt8]? = nil,
        vanCmxTargets: Set<Data>,
        roundId: String,
        walletId: String? = nil
    ) throws -> [Report] {
        if let invalid = vanCmxTargets.first(where: { $0.count != 32 }) {
            throw RecoveryError.invalidVanCmxLength(invalid.count)
        }
        guard isCanonicalRoundId(roundId) else {
            throw RecoveryError.invalidRoundId
        }

        var presentTargets = targetsPresent(in: databaseBytes, targets: vanCmxTargets)
        if let walBytes {
            presentTargets.formUnion(targetsPresent(in: walBytes, targets: vanCmxTargets))
        }

        return try presentTargets
            .sorted { $0.lexicographicallyPrecedes($1) }
            .map { target in
                try recover(
                    databaseBytes: databaseBytes,
                    walBytes: walBytes,
                    vanCmx: target,
                    roundId: roundId,
                    walletId: walletId
                )
            }
    }

    static func recover(
        databaseBytes: [UInt8],
        walBytes: [UInt8]? = nil,
        vanCmx: Data,
        roundId: String,
        walletId: String? = nil,
        bundleIndex: UInt32? = nil
    ) throws -> Report {
        guard vanCmx.count == 32 else {
            throw RecoveryError.invalidVanCmxLength(vanCmx.count)
        }
        guard isCanonicalRoundId(roundId) else {
            throw RecoveryError.invalidRoundId
        }

        let target = [UInt8](vanCmx)
        let databaseLayout = DatabaseLayout(bytes: databaseBytes)
        let wal = walBytes.flatMap {
            WalFile(bytes: $0, fallbackPageSize: databaseLayout?.pageSize)
        }

        var candidates: [RecoveredBundle] = []
        var templates: [RecordTemplate] = []
        var rawPages: [RawPage] = []

        if let databaseLayout {
            let scan = scanLiveDatabase(
                databaseLayout,
                source: { .databaseLive(page: $0) },
                target: vanCmx,
                roundId: roundId,
                walletId: walletId,
                bundleIndex: bundleIndex
            )
            candidates += scan.candidates
            templates += scan.templates

            for page in databaseLayout.pages {
                rawPages.append(
                    RawPage(
                        bytes: page.bytes,
                        headerOffset: page.number == 1 ? 100 : 0,
                        source: { offset in
                            .databaseCarved(page: page.number, offset: offset)
                        }
                    )
                )
            }
        }

        var validWalFrameCount = 0
        var committedWalPrefixCount = 0
        if let wal {
            validWalFrameCount = wal.validFrames.count
            committedWalPrefixCount = wal.validFrames.reduce(into: 0) {
                if $1.databasePageCount > 0 { $0 += 1 }
            }

            for frame in wal.frames {
                rawPages.append(
                    RawPage(
                        bytes: frame.page,
                        headerOffset: 0,
                        source: { offset in
                            .walCarved(
                                frame: frame.index,
                                currentGeneration: frame.isCurrentGeneration,
                                offset: offset
                            )
                        }
                    )
                )
            }

            if let databaseLayout {
                var state = databaseLayout.bytes
                for frame in wal.validFrames {
                    apply(frame: frame, pageSize: wal.pageSize, to: &state)
                    guard frame.databasePageCount > 0 else { continue }

                    resize(
                        database: &state,
                        pageCount: frame.databasePageCount,
                        pageSize: wal.pageSize
                    )
                    guard let committed = DatabaseLayout(bytes: state) else {
                        continue
                    }
                    let scan = scanLiveDatabase(
                        committed,
                        source: { _ in .walCommit(frame: frame.index) },
                        target: vanCmx,
                        roundId: roundId,
                        walletId: walletId,
                        bundleIndex: bundleIndex
                    )
                    candidates += scan.candidates
                    templates += scan.templates
                }
            }
        }

        // First collect every decodable schema layout. A damaged record can
        // precede the surviving row that provides its layout template, so
        // anchoring must be a separate pass over the pages.
        for rawPage in rawPages {
            let signatureScan = scanRecordSignatures(
                rawPage,
                target: vanCmx,
                roundId: roundId,
                walletId: walletId,
                bundleIndex: bundleIndex
            )
            candidates += signatureScan.candidates
            templates += signatureScan.templates
        }
        templates = Array(Set(templates))

        var hits: [RawTargetHit] = []
        for rawPage in rawPages {
            for offset in offsets(of: target, in: rawPage.bytes) {
                let source = rawPage.source(offset)
                hits.append(RawTargetHit(source: source))
                candidates += recoverAnchoredRecord(
                    page: rawPage.bytes,
                    targetOffset: offset,
                    templates: templates,
                    source: source,
                    target: vanCmx,
                    roundId: roundId,
                    walletId: walletId,
                    bundleIndex: bundleIndex
                )
            }
        }

        return Report(
            vanCmx: vanCmx,
            candidates: deduplicated(candidates),
            rawTargetHits: Array(Set(hits)).sorted(by: rawHitOrder),
            validWalFrameCount: validWalFrameCount,
            committedWalPrefixCount: committedWalPrefixCount
        )
    }

    // MARK: - Logical database states

    private struct DatabaseLayout {
        let bytes: [UInt8]
        let pageSize: Int
        let usableSize: Int

        init?(bytes: [UInt8]) {
            guard bytes.count >= 100,
                  Array(bytes[0..<16]) == Array("SQLite format 3\u{0}".utf8)
            else {
                return nil
            }

            let declared = Int(readUInt16(bytes, 16))
            let pageSize = declared == 1 ? 65_536 : declared
            guard validPageSize(pageSize), bytes.count >= pageSize else {
                return nil
            }

            let usableSize = pageSize - Int(bytes[20])
            guard usableSize > 35 else { return nil }

            self.bytes = bytes
            self.pageSize = pageSize
            self.usableSize = usableSize
        }

        var pages: [DatabasePage] {
            let count = bytes.count / pageSize
            return (0..<count).map { index in
                let start = index * pageSize
                return DatabasePage(
                    number: index + 1,
                    bytes: Array(bytes[start..<(start + pageSize)])
                )
            }
        }

        func page(number: Int) -> [UInt8]? {
            guard number > 0 else { return nil }
            let start = (number - 1) * pageSize
            guard start >= 0, start + pageSize <= bytes.count else { return nil }
            return Array(bytes[start..<(start + pageSize)])
        }
    }

    private struct DatabasePage {
        let number: Int
        let bytes: [UInt8]
    }

    private struct ScanResult {
        var candidates: [RecoveredBundle] = []
        var templates: [RecordTemplate] = []
    }

    private static func scanLiveDatabase(
        _ database: DatabaseLayout,
        source: (Int) -> Source,
        target: Data,
        roundId: String,
        walletId: String?,
        bundleIndex: UInt32?
    ) -> ScanResult {
        var result = ScanResult()

        for page in bundleLeafPages(in: database) {
            let headerOffset = page.number == 1 ? 100 : 0
            for payload in livePayloads(
                page: page,
                database: database,
                headerOffset: headerOffset
            ) {
                guard let record = decodeRecord(payload) else { continue }
                append(
                    record: record,
                    source: source(page.number),
                    target: target,
                    roundId: roundId,
                    walletId: walletId,
                    bundleIndex: bundleIndex,
                    to: &result
                )
            }
        }
        return result
    }

    /// Resolves `bundles` through `sqlite_schema` and walks only pages reachable
    /// from that table's root. A freed page can retain a stale `0x0D` header and
    /// cell-pointer array after deletion; scanning all apparent leaf pages
    /// would incorrectly label those bytes as live.
    private static func bundleLeafPages(
        in database: DatabaseLayout
    ) -> [DatabasePage] {
        guard let rootPage = tableRootPage(named: "bundles", in: database) else {
            // Hand-built unit fixtures place a bundle directly on page 1. This
            // fallback is deliberately narrow: it is accepted only if page 1
            // already decodes as the bundles schema, never for arbitrary pages.
            guard let first = database.page(number: 1) else { return [] }
            let page = DatabasePage(number: 1, bytes: first)
            let records = livePayloads(
                page: page,
                database: database,
                headerOffset: 100
            ).compactMap(decodeRecord)
            guard records.contains(where: looksLikeBundleRecord) else { return [] }
            return [page]
        }
        return tableLeafPages(rootPage: rootPage, in: database)
    }

    private static func tableRootPage(
        named tableName: String,
        in database: DatabaseLayout
    ) -> Int? {
        for page in tableLeafPages(rootPage: 1, in: database) {
            let headerOffset = page.number == 1 ? 100 : 0
            for payload in livePayloads(
                page: page,
                database: database,
                headerOffset: headerOffset
            ) {
                guard let record = decodeRecord(payload),
                      record.values.count >= 5,
                      case let .text(type) = record.values[0],
                      type == "table",
                      case let .text(name) = record.values[1],
                      name == tableName,
                      case let .integer(rootPage) = record.values[3],
                      rootPage > 0,
                      rootPage <= Int64(Int.max)
                else {
                    continue
                }
                return Int(rootPage)
            }
        }
        return nil
    }

    private static func tableLeafPages(
        rootPage: Int,
        in database: DatabaseLayout
    ) -> [DatabasePage] {
        var pending = [rootPage]
        var visited: Set<Int> = []
        var leaves: [DatabasePage] = []

        while let pageNumber = pending.popLast() {
            guard visited.insert(pageNumber).inserted,
                  let bytes = database.page(number: pageNumber)
            else {
                continue
            }
            let page = DatabasePage(number: pageNumber, bytes: bytes)
            let headerOffset = pageNumber == 1 ? 100 : 0
            guard bytes.indices.contains(headerOffset) else { continue }

            switch bytes[headerOffset] {
            case 0x0D:
                leaves.append(page)
            case 0x05:
                let cellCount = Int(readUInt16(bytes, headerOffset + 3))
                let pointerArrayEnd = headerOffset + 12 + 2 * cellCount
                guard pointerArrayEnd <= database.usableSize else { continue }

                let rightmost = Int(readUInt32(bytes, headerOffset + 8))
                if rightmost > 0 { pending.append(rightmost) }
                for cellIndex in 0..<cellCount {
                    let pointer = headerOffset + 12 + 2 * cellIndex
                    let cellOffset = Int(readUInt16(bytes, pointer))
                    guard cellOffset > 0,
                          cellOffset + 4 <= database.usableSize
                    else {
                        continue
                    }
                    let child = Int(readUInt32(bytes, cellOffset))
                    if child > 0 { pending.append(child) }
                }
            default:
                continue
            }
        }
        return leaves.sorted { $0.number < $1.number }
    }

    private static func looksLikeBundleRecord(_ record: DecodedRecord) -> Bool {
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

    private static func livePayloads(
        page: DatabasePage,
        database: DatabaseLayout,
        headerOffset: Int
    ) -> [[UInt8]] {
        let cellCount = Int(readUInt16(page.bytes, headerOffset + 3))
        let pointerArrayEnd = headerOffset + 8 + 2 * cellCount
        guard cellCount > 0, pointerArrayEnd <= database.usableSize else {
            return []
        }

        var payloads: [[UInt8]] = []
        for cellIndex in 0..<cellCount {
            let pointer = headerOffset + 8 + 2 * cellIndex
            let cellOffset = Int(readUInt16(page.bytes, pointer))
            guard cellOffset > 0, cellOffset < database.usableSize,
                  let (length, lengthBytes) = varint(page.bytes, cellOffset),
                  length <= UInt64(Int.max),
                  let (_, rowIdBytes) = varint(
                      page.bytes,
                      cellOffset + lengthBytes
                  )
            else {
                continue
            }

            let payloadLength = Int(length)
            let payloadStart = cellOffset + lengthBytes + rowIdBytes
            let localCount = localPayloadSize(
                payloadLength: payloadLength,
                usable: database.usableSize
            )
            guard payloadStart >= 0,
                  payloadStart + localCount <= database.usableSize
            else {
                continue
            }

            var payload = Array(
                page.bytes[payloadStart..<(payloadStart + localCount)]
            )
            if payload.count < payloadLength {
                let overflowPointer = payloadStart + localCount
                guard overflowPointer + 4 <= database.usableSize else {
                    continue
                }
                var nextPage = Int(readUInt32(page.bytes, overflowPointer))
                var visited: Set<Int> = []

                while payload.count < payloadLength,
                      nextPage > 0,
                      visited.insert(nextPage).inserted,
                      let overflow = database.page(number: nextPage) {
                    let following = Int(readUInt32(overflow, 0))
                    let remaining = payloadLength - payload.count
                    let count = min(remaining, database.usableSize - 4)
                    guard count > 0, 4 + count <= overflow.count else { break }
                    payload += overflow[4..<(4 + count)]
                    nextPage = following
                }
            }

            if payload.count >= payloadLength {
                payloads.append(Array(payload.prefix(payloadLength)))
            }
        }
        return payloads
    }

    private static func apply(
        frame: WalFrame,
        pageSize: Int,
        to database: inout [UInt8]
    ) {
        guard frame.pageNumber > 0 else { return }
        let start = (frame.pageNumber - 1) * pageSize
        let required = start + pageSize
        if database.count < required {
            database += [UInt8](repeating: 0, count: required - database.count)
        }
        database.replaceSubrange(start..<required, with: frame.page)
    }

    private static func resize(
        database: inout [UInt8],
        pageCount: Int,
        pageSize: Int
    ) {
        guard pageCount > 0, pageCount <= Int.max / pageSize else { return }
        let expected = pageCount * pageSize
        if database.count > expected {
            database.removeLast(database.count - expected)
        } else if database.count < expected {
            database += [UInt8](repeating: 0, count: expected - database.count)
        }
    }

    // MARK: - Raw page carving

    private struct RawPage {
        let bytes: [UInt8]
        let headerOffset: Int
        let source: (Int) -> Source
    }

    private static func scanRecordSignatures(
        _ page: RawPage,
        target: Data,
        roundId: String,
        walletId: String?,
        bundleIndex: UInt32?
    ) -> ScanResult {
        var result = ScanResult()
        var index = max(1, page.headerOffset)

        while index + 1 < page.bytes.count {
            guard page.bytes[index] == 0x81,
                  page.bytes[index + 1] == 0x0D
            else {
                index += 1
                continue
            }

            let payloadStart = index - 1
            if let record = decodeRecord(
                Array(page.bytes[payloadStart..<page.bytes.count])
            ) {
                append(
                    record: record,
                    source: page.source(payloadStart),
                    target: target,
                    roundId: roundId,
                    walletId: walletId,
                    bundleIndex: bundleIndex,
                    to: &result
                )
            }
            index += 1
        }
        return result
    }

    /// Uses the body layout of a surviving bundle as a template when SQLite has
    /// overwritten the deleted cell header but left its column bytes intact.
    /// The exact target VAN anchors the old body's location.
    private static func recoverAnchoredRecord(
        page: [UInt8],
        targetOffset: Int,
        templates: [RecordTemplate],
        source: Source,
        target: Data,
        roundId: String,
        walletId: String?,
        bundleIndex: UInt32?
    ) -> [RecoveredBundle] {
        var candidates: [RecoveredBundle] = []

        for template in templates {
            let govIndex = BundleColumn.govComm.rawValue
            guard template.spans.indices.contains(govIndex) else { continue }
            let govSpan = template.spans[govIndex]
            guard govSpan.range.count == target.count else { continue }

            let payloadStart = targetOffset - govSpan.range.lowerBound
            guard payloadStart >= 0 else { continue }

            var values: [RecordValue] = []
            for (columnIndex, span) in template.spans.enumerated() {
                if columnIndex == BundleColumn.bundleIndex.rawValue,
                   let bundleIndex {
                    values.append(.integer(Int64(bundleIndex)))
                    continue
                }
                // Serial types 8 and 9 encode integer 0/1 entirely in the
                // destroyed record header. A layout template cannot prove
                // which value the deleted row used.
                if span.range.isEmpty, span.serialType == 8 || span.serialType == 9 {
                    values.append(.unavailable)
                    continue
                }
                let lower = payloadStart + span.range.lowerBound
                let upper = payloadStart + span.range.upperBound
                guard lower >= 0, upper <= page.count else {
                    values.append(.unavailable)
                    continue
                }
                values.append(
                    serialValue(span.serialType, Array(page[lower..<upper]))
                )
            }

            guard let bundle = makeBundle(values: values, source: source),
                  bundle.vanCmx == target,
                  matches(
                      bundle,
                      roundId: roundId,
                      walletId: walletId,
                      bundleIndex: bundleIndex
                  )
            else {
                continue
            }
            candidates.append(bundle)
        }
        return candidates
    }

    private static func offsets(of needle: [UInt8], in bytes: [UInt8]) -> [Int] {
        guard !needle.isEmpty, bytes.count >= needle.count else { return [] }
        var matches: [Int] = []
        var offset = 0
        let finalOffset = bytes.count - needle.count

        while offset <= finalOffset {
            if bytes[offset..<(offset + needle.count)].elementsEqual(needle) {
                matches.append(offset)
                offset += needle.count
            } else {
                offset += 1
            }
        }
        return matches
    }

    /// Finds which fixed-width targets occur in raw bytes without scanning the
    /// same database once for every public tree leaf.
    private static func targetsPresent(
        in bytes: [UInt8],
        targets: Set<Data>
    ) -> Set<Data> {
        guard bytes.count >= 32, !targets.isEmpty else { return [] }

        // A four-byte prefix keeps each lookup effectively constant-time even
        // when the validated public tree contains many unrelated leaves.
        let grouped = Dictionary(grouping: targets.map { ([UInt8]($0), $0) }) {
            targetPrefix($0.0)
        }
        var found: Set<Data> = []
        let finalOffset = bytes.count - 32
        for offset in 0...finalOffset {
            guard let candidates = grouped[targetPrefix(bytes, at: offset)] else { continue }
            for (targetBytes, target) in candidates
            where !found.contains(target)
                && bytes[offset..<(offset + 32)].elementsEqual(targetBytes) {
                found.insert(target)
            }
            if found.count == targets.count { break }
        }
        return found
    }

    private static func targetPrefix(_ bytes: [UInt8], at offset: Int = 0) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    // MARK: - WAL validation

    private struct WalFile {
        let pageSize: Int
        let frames: [WalFrame]
        let validFrames: [WalFrame]

        init?(bytes: [UInt8], fallbackPageSize: Int?) {
            guard bytes.count >= 32 else { return nil }
            let magic = readUInt32(bytes, 0)
            let declaredPageSize = Int(readUInt32(bytes, 8))
            let pageSize = validPageSize(declaredPageSize)
                ? declaredPageSize
                : fallbackPageSize ?? 0
            guard validPageSize(pageSize) else { return nil }

            let checksumOrder: ChecksumByteOrder = magic == 0x377F_0683
                ? .bigEndian
                : .littleEndian
            let storedHeaderChecksum = (
                readUInt32(bytes, 24),
                readUInt32(bytes, 28)
            )
            let headerChecksumIsValid = walMagic.contains(magic) && checksum(
                Array(bytes[0..<24]),
                order: checksumOrder,
                seed: (0, 0)
            ) == storedHeaderChecksum

            let salt = (readUInt32(bytes, 16), readUInt32(bytes, 20))
            let stride = 24 + pageSize
            let frameCount = (bytes.count - 32) / stride
            var frames: [WalFrame] = []
            var validFrames: [WalFrame] = []
            var runningChecksum = storedHeaderChecksum
            var acceptingValidFrames = headerChecksumIsValid

            for index in 0..<frameCount {
                let offset = 32 + index * stride
                let header = Array(bytes[offset..<(offset + 24)])
                let page = Array(
                    bytes[(offset + 24)..<(offset + 24 + pageSize)]
                )
                let frameSalt = (readUInt32(header, 8), readUInt32(header, 12))
                let storedChecksum = (
                    readUInt32(header, 16),
                    readUInt32(header, 20)
                )
                let calculated = checksum(
                    Array(header[0..<8]) + page,
                    order: checksumOrder,
                    seed: runningChecksum
                )
                let valid = acceptingValidFrames
                    && frameSalt == salt
                    && calculated == storedChecksum

                let frame = WalFrame(
                    index: index,
                    pageNumber: Int(readUInt32(header, 0)),
                    databasePageCount: Int(readUInt32(header, 4)),
                    page: page,
                    isCurrentGeneration: frameSalt == salt
                )
                frames.append(frame)

                if valid {
                    validFrames.append(frame)
                    runningChecksum = storedChecksum
                } else {
                    acceptingValidFrames = false
                }
            }

            self.pageSize = pageSize
            self.frames = frames
            self.validFrames = validFrames
        }
    }

    private struct WalFrame {
        let index: Int
        let pageNumber: Int
        let databasePageCount: Int
        let page: [UInt8]
        let isCurrentGeneration: Bool
    }

    private enum ChecksumByteOrder {
        case bigEndian
        case littleEndian
    }

    private static func checksum(
        _ bytes: [UInt8],
        order: ChecksumByteOrder,
        seed: (UInt32, UInt32)
    ) -> (UInt32, UInt32) {
        guard bytes.count.isMultiple(of: 8) else { return seed }
        var first = seed.0
        var second = seed.1

        for offset in stride(from: 0, to: bytes.count, by: 8) {
            let word0 = checksumWord(bytes, offset, order: order)
            let word1 = checksumWord(bytes, offset + 4, order: order)
            first = first &+ word0 &+ second
            second = second &+ word1 &+ first
        }
        return (first, second)
    }

    private static func checksumWord(
        _ bytes: [UInt8],
        _ offset: Int,
        order: ChecksumByteOrder
    ) -> UInt32 {
        switch order {
        case .bigEndian:
            return readUInt32(bytes, offset)
        case .littleEndian:
            guard offset + 3 < bytes.count else { return 0 }
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
    }

    // MARK: - SQLite records

    private enum RecordValue: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
        case unavailable
    }

    private struct ColumnSpan: Equatable, Hashable {
        let serialType: UInt64
        let range: Range<Int>
    }

    private struct DecodedRecord {
        let values: [RecordValue]
        let spans: [ColumnSpan]
    }

    private struct RecordTemplate: Equatable, Hashable {
        let spans: [ColumnSpan]
    }

    private static func decodeRecord(_ payload: [UInt8]) -> DecodedRecord? {
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

    private static func append(
        record: DecodedRecord,
        source: Source,
        target: Data,
        roundId: String,
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
        guard bundle.vanCmx == target,
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

    private static func makeBundle(
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

    private static func matches(
        _ bundle: RecoveredBundle,
        roundId: String,
        walletId: String?,
        bundleIndex: UInt32?
    ) -> Bool {
        if bundle.roundId.caseInsensitiveCompare(roundId) != .orderedSame {
            return false
        }
        if let walletId, bundle.walletId != walletId { return false }
        if let bundleIndex, bundle.bundleIndex != bundleIndex { return false }
        return true
    }

    private static func isCanonicalRoundId(_ roundId: String) -> Bool {
        let bytes = [UInt8](roundId.utf8)
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (0x30...0x39).contains(byte)
                || (0x61...0x66).contains(byte)
                || (0x41...0x46).contains(byte)
        }
    }

    private static func blob(_ value: RecordValue, count: Int) -> Data? {
        guard case let .blob(data) = value, data.count == count else { return nil }
        return data
    }

    private static func blob(_ value: RecordValue) -> Data? {
        guard case let .blob(data) = value else { return nil }
        return data
    }

    private static func isCanonicalPallasElement(_ candidate: Data) -> Bool {
        guard candidate.count == 32 else { return false }
        return Data(candidate.reversed()).hexString < pallasModulus
    }

    private static func deduplicated(
        _ candidates: [RecoveredBundle]
    ) -> [RecoveredBundle] {
        var best: [String: RecoveredBundle] = [:]
        for candidate in candidates {
            let key = [
                candidate.roundId,
                candidate.walletId,
                String(candidate.bundleIndex),
                String(candidate.totalNoteValue),
                candidate.addressIndex.map(String.init) ?? "nil",
                candidate.vanCommRand.hexString,
                candidate.vanCmx.hexString,
                candidate.delegationTxHash ?? "nil"
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
        switch source {
        case .walCommit: return 4
        case .databaseLive: return 3
        case let .walCarved(_, current, _): return current ? 2 : 1
        case .databaseCarved: return 1
        }
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

    private static func rawHitOrder(_ lhs: RawTargetHit, _ rhs: RawTargetHit) -> Bool {
        String(describing: lhs.source) < String(describing: rhs.source)
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

    private static func serialValue(
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

    private static func localPayloadSize(
        payloadLength: Int,
        usable: Int
    ) -> Int {
        let maxLocal = usable - 35
        if payloadLength <= maxLocal { return payloadLength }
        let minLocal = ((usable - 12) * 32 / 255) - 23
        let surplus = minLocal + (payloadLength - minLocal) % (usable - 4)
        return surplus <= maxLocal ? surplus : minLocal
    }

    // MARK: - Byte primitives

    private static func varint(
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

    private static func validPageSize(_ size: Int) -> Bool {
        size >= 512 && size <= 65_536 && size.nonzeroBitCount == 1
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}

// `Data.hexString` is declared once for the voting flavor in
// `VotingCryptoClientLiveKey.swift` and reused here.
#endif
