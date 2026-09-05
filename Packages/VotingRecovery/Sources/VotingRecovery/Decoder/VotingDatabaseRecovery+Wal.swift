import Foundation

// MARK: - WAL validation

extension VotingDatabaseRecovery {
    struct WalFile {
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

    struct WalFrame {
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

    static func apply(
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

    static func resize(
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
}
