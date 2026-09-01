#if VOTING_ENABLED
import Testing
import Foundation
@testable import zodl_internal

/// The page size is the first value the carver trusts from a file, and every
/// page boundary it walks is a multiple of it. These pin the header rules of
/// spec section 1.3, <https://www.sqlite.org/fileformat.html#the_database_header>.
@Suite struct DelegationWalRecoveryGeometryTests {
    /// A page size is a power of two, not merely a multiple of 512. No SQLite
    /// file was ever written with 1536, so a header that claims it is not a
    /// database.
    @Test func rejectsAPageSizeThatIsNotAPowerOfTwo() {
        let geometry = DelegationWalRecovery.geometry(databaseBytes: Self.header(pageSizeField: 1536))

        #expect(geometry == nil)
    }

    @Test(arguments: [512, 1024, 2048, 4096, 8192, 16_384, 32_768])
    func acceptsEveryPowerOfTwoPageSize(_ pageSize: Int) throws {
        let geometry = try #require(
            DelegationWalRecovery.geometry(databaseBytes: Self.header(pageSizeField: pageSize))
        )

        #expect(geometry.pageSize == pageSize)
    }

    /// 65536 does not fit the 16-bit field, so the spec encodes it as 1.
    @Test func readsTheSentinelForTheLargestPageSize() throws {
        let geometry = try #require(
            DelegationWalRecovery.geometry(databaseBytes: Self.header(pageSizeField: 1))
        )

        #expect(geometry.pageSize == 65_536)
    }

    /// Nothing below 512 is valid, and the sentinel is the only value under
    /// it that the spec gives a meaning.
    @Test(arguments: [0, 2, 256])
    func rejectsAPageSizeBelowTheSmallest(_ pageSizeField: Int) {
        let geometry = DelegationWalRecovery.geometry(databaseBytes: Self.header(pageSizeField: pageSizeField))

        #expect(geometry == nil)
    }

    /// One page of zeros behind a valid magic, with `pageSizeField` at offset
    /// 16 in big-endian order, exactly as the file carries it.
    private static func header(pageSizeField: Int) -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: 4096)
        bytes.replaceSubrange(0..<16, with: Array("SQLite format 3\u{0}".utf8))
        bytes[16] = UInt8(pageSizeField >> 8)
        bytes[17] = UInt8(pageSizeField & 0xFF)
        return bytes
    }
}
#endif
