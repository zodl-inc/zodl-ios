#if RECOVERY_VOTING_ENABLED
import Testing
import Foundation
@testable import zodl_internal

/// The decoder reads released space: freed pages, freeblocks, and the
/// unallocated gap. Those bytes are whatever was last written there, so every
/// length and offset it decodes is arbitrary rather than trusted.
///
/// A Swift integer overflow is a trap, not an error, so a single bad length
/// takes the process down. These tests assert only that decoding RETURNS.
/// Reaching the end of one is the whole assertion: a regression would abort
/// the test run rather than fail a check.
@Suite struct VotingDatabaseRecoveryHostileInputTests {
    /// `0x0C` is a plausible record-header length, `0x81 0x0D` is the serial
    /// type of `round_id` as TEXT of length 64, and the nine `0xFF` bytes are
    /// a varint serial type of about 2^64.
    private static let hostilePayload: [UInt8] = [0x0C, 0x81, 0x0D] + Array(repeating: 0xFF, count: 9)

    @Test func decodingSurvivesASerialTypeNearTwoToTheSixtyFour() throws {
        let report = try? VotingDatabaseRecovery.recoverAll(
            databaseBytes: Self.database(pages: [Self.page(filledWith: Self.hostilePayload)]),
            roundId: nil,
            walletId: nil
        )

        // Whatever it returns, it must not be a `bundles` row: nothing here
        // carries a round id, so this can never reach the escrow.
        #expect(report?.candidates.isEmpty ?? true)
    }

    /// A header length that also exceeds `Int.max`.
    @Test func decodingSurvivesAHeaderLengthLargerThanInt() {
        _ = VotingDatabaseRecovery.decodeRecord(Array(repeating: UInt8(0xFF), count: 12))
    }

    /// Truncation must stay non-fatal: the columns the decoder needs sit near
    /// the front, so a payload cut short still has to decode or refuse.
    @Test func decodingSurvivesEveryPrefixOfTheHostilePayload() {
        for length in 0...Self.hostilePayload.count {
            _ = VotingDatabaseRecovery.decodeRecord(Array(Self.hostilePayload.prefix(length)))
        }
    }

    /// A whole page of the signature back to back, so the sweep decodes at
    /// every offset rather than once.
    @Test func carvingSurvivesAPageMadeEntirelyOfTheSignature() {
        let report = try? VotingDatabaseRecovery.recoverAll(
            databaseBytes: Self.database(pages: [Self.page(filledWith: Self.hostilePayload)]),
            roundId: nil,
            walletId: nil
        )

        #expect(report?.candidates.isEmpty ?? true, "no real bundle exists in this page")
    }

    /// Deterministic pseudo-random pages, which is what freed space holding
    /// old blob and proof bytes actually looks like.
    @Test func carvingSurvivesArbitraryBytes() {
        var seed: UInt64 = 0x5DEE_CE66_D1E4_2F13
        func next() -> UInt8 {
            // xorshift64, so the corpus is reproducible across runs.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return UInt8(truncatingIfNeeded: seed)
        }

        for _ in 0..<64 {
            var page = (0..<4096).map { _ in next() }
            // Seed the signature at a few offsets so the sweep is exercised
            // rather than skipping the page outright.
            for offset in stride(from: 16, to: 4000, by: 512) {
                page[offset] = 0x81
                page[offset + 1] = 0x0D
            }
            _ = try? VotingDatabaseRecovery.recoverAll(
                databaseBytes: Self.database(pages: [page]),
                roundId: nil,
                walletId: nil
            )
        }
    }

    /// A page that is nothing but the payload, repeated.
    private static func page(filledWith payload: [UInt8]) -> [UInt8] {
        var page: [UInt8] = []
        while page.count < 4096 {
            page += payload
        }
        return Array(page.prefix(4096))
    }

    /// Wraps pages in a minimal but valid database header so the scan gets
    /// past its own validation and reaches the page walk.
    private static func database(pages: [[UInt8]]) -> [UInt8] {
        let pageSize = 4096
        var bytes = Array("SQLite format 3\u{0}".utf8)
        bytes += [UInt8(pageSize >> 8), UInt8(pageSize & 0xFF)]     // page size at 16
        bytes += Array(repeating: 0, count: 100 - bytes.count)      // rest of the header
        var first = pages.first ?? Array(repeating: 0, count: pageSize)
        first.replaceSubrange(0..<bytes.count, with: bytes)
        var out = Array(first.prefix(pageSize))
        for page in pages.dropFirst() {
            out += Array(page.prefix(pageSize))
        }
        return out
    }
}
#endif
