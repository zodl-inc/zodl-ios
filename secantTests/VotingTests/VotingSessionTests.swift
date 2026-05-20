import XCTest
import Foundation
@testable import secant_testnet

final class VotingSessionTests: XCTestCase {
    func testLastMomentBufferUsesFortyPercentForShortRounds() throws {
        let ceremonyStart = Date(timeIntervalSince1970: 1_000)
        let voteEndTime = ceremonyStart.addingTimeInterval(10 * 60)
        let session = makeSession(ceremonyStart: ceremonyStart, voteEndTime: voteEndTime)

        XCTAssertEqual(try XCTUnwrap(session.lastMomentBuffer), 4 * 60, accuracy: 0.001)
    }

    func testLastMomentBufferCapsAtSixHoursForLongRounds() throws {
        let ceremonyStart = Date(timeIntervalSince1970: 1_000)
        let voteEndTime = ceremonyStart.addingTimeInterval(24 * 60 * 60)
        let session = makeSession(ceremonyStart: ceremonyStart, voteEndTime: voteEndTime)

        XCTAssertEqual(try XCTUnwrap(session.lastMomentBuffer), 6 * 60 * 60, accuracy: 0.001)
    }

    func testLastMomentBufferIsNilForInvalidRoundTimes() {
        let ceremonyStart = Date(timeIntervalSince1970: 1_000)
        let voteEndTime = ceremonyStart
        let session = makeSession(ceremonyStart: ceremonyStart, voteEndTime: voteEndTime)

        XCTAssertNil(session.lastMomentBuffer)
    }

    func testIsLastMomentForShortRoundWithinBuffer() {
        let now = Date()
        let voteEndTime = now.addingTimeInterval(3 * 60)
        let ceremonyStart = voteEndTime.addingTimeInterval(-10 * 60)
        let session = makeSession(ceremonyStart: ceremonyStart, voteEndTime: voteEndTime)

        XCTAssertTrue(session.isLastMoment)
    }

    func testIsLastMomentForShortRoundBeforeBuffer() {
        let now = Date()
        let voteEndTime = now.addingTimeInterval(5 * 60)
        let ceremonyStart = voteEndTime.addingTimeInterval(-10 * 60)
        let session = makeSession(ceremonyStart: ceremonyStart, voteEndTime: voteEndTime)

        XCTAssertFalse(session.isLastMoment)
    }

    private func makeSession(ceremonyStart: Date, voteEndTime: Date) -> VotingSession {
        VotingSession(
            voteRoundId: Data(repeating: 0xAA, count: 32),
            snapshotHeight: 1,
            snapshotBlockhash: Data(repeating: 0x01, count: 32),
            proposalsHash: Data(repeating: 0x02, count: 32),
            voteEndTime: voteEndTime,
            ceremonyStart: ceremonyStart,
            eaPK: Data(repeating: 0x03, count: 32),
            vkZkp1: Data(repeating: 0x04, count: 32),
            vkZkp2: Data(repeating: 0x05, count: 32),
            vkZkp3: Data(repeating: 0x06, count: 32),
            ncRoot: Data(repeating: 0x07, count: 32),
            nullifierIMTRoot: Data(repeating: 0x08, count: 32),
            creator: "creator",
            proposals: [],
            status: .active
        )
    }
}
