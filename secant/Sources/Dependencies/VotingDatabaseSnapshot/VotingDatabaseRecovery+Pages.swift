#if RECOVERY_VOTING_ENABLED
import Foundation

// MARK: - Logical database states

extension VotingDatabaseRecovery {
    struct DatabaseLayout {
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

    struct DatabasePage {
        let number: Int
        let bytes: [UInt8]
    }

    struct ScanResult {
        var candidates: [RecoveredBundle] = []
        var templates: [RecordTemplate] = []
    }

    static func scanLiveDatabase(
        _ database: DatabaseLayout,
        source: (Int) -> Source,
        target: Data?,
        roundId: String?,
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
}
#endif
