//
//  MemoByteCountingTests.swift
//  secantTests
//
//  Created by Cosmos on 18.05.2026.
//

import XCTest
@testable import zashi_internal


class MemoByteCountingTests: XCTestCase {

    func testByteLengthEmptyTextIsZero() {
        let state = MessageEditor.State(charLimit: 512, text: "")

        XCTAssertEqual(
            state.byteLength,
            0,
            "MemoByteCountingTests: `testByteLengthEmptyTextIsZero` byteLength is expected to be 0 but it is \(state.byteLength)"
        )
    }

    func testByteLengthMultipleEmojiAccumulateBytes() {
        let text = String(repeating: "🎉", count: 10)
        let state = MessageEditor.State(charLimit: 512, text: text)

        XCTAssertEqual(
            state.byteLength,
            40,
            "MemoByteCountingTests: `testByteLengthMultipleEmojiAccumulateBytes` byteLength is expected to be 40 but it is \(state.byteLength)"
        )
    }

    func testByteLengthJapaneseTextCountsAsMultipleBytes() {
        let state = MessageEditor.State(charLimit: 512, text: "日本語")

        XCTAssertEqual(
            state.byteLength,
            9,
            "MemoByteCountingTests: `testByteLengthJapaneseTextCountsAsMultipleBytes` byteLength is expected to be 9 but it is \(state.byteLength)"
        )
    }

    func testByteLengthSpanishAccentsCountsCorrectly() {
        let state = MessageEditor.State(charLimit: 512, text: "café")

        XCTAssertEqual(
            state.byteLength,
            5,
            "MemoByteCountingTests: `testByteLengthSpanishAccentsCountsCorrectly` byteLength is expected to be 5 but it is \(state.byteLength)"
        )
    }

    func testByteLengthMixedContentCountsCorrectly() {
        let state = MessageEditor.State(charLimit: 512, text: "Hi 🎉 日本")

        XCTAssertEqual(
            state.byteLength,
            14,
            "MemoByteCountingTests: `testByteLengthMixedContentCountsCorrectly` byteLength is expected to be 14 but it is \(state.byteLength)"
        )
    }

    func testIsValidExactlyAtLimitIsTrue() {
        let text = String(repeating: "a", count: 512)
        let state = MessageEditor.State(charLimit: 512, text: text)

        XCTAssertTrue(
            state.isValid,
            "MemoByteCountingTests: `testIsValidExactlyAtLimitIsTrue` is expected to be true but it is \(state.isValid)"
        )
    }

    func testIsValidEmojiPushingOverLimitIsFalse() {
        let text = String(repeating: "a", count: 510) + "🎉"
        let state = MessageEditor.State(charLimit: 512, text: text)

        XCTAssertFalse(
            state.isValid,
            "MemoByteCountingTests: `testIsValidEmojiPushingOverLimitIsFalse` is expected to be false but it is \(state.isValid)"
        )
    }

    func testIsValidEmojiExactlyAtLimitIsTrue() {
        let text = String(repeating: "a", count: 508) + "🎉"
        let state = MessageEditor.State(charLimit: 512, text: text)

        XCTAssertTrue(
            state.isValid,
            "MemoByteCountingTests: `testIsValidEmojiExactlyAtLimitIsTrue` is expected to be true but it is \(state.isValid)"
        )
    }

    func testIsValidEmptyTextIsTrue() {
        let state = MessageEditor.State(charLimit: 512, text: "")

        XCTAssertTrue(
            state.isValid,
            "MemoByteCountingTests: `testIsValidEmptyTextIsTrue` is expected to be true but it is \(state.isValid)"
        )
    }

    func testCharLimitTextAtLimitShowsZeroRemaining() {
        let text = String(repeating: "a", count: 512)
        let state = MessageEditor.State(charLimit: 512, text: text)

        XCTAssertEqual(
            state.charLimitText,
            "0/512",
            "MemoByteCountingTests: `testCharLimitTextAtLimitShowsZeroRemaining` charLimitText is expected to be \"0/512\" but it is \"\(state.charLimitText)\""
        )
    }

    func testCharLimitTextEmojiCountedAsBytes() {
        let state = MessageEditor.State(charLimit: 512, text: "🎉")

        XCTAssertEqual(
            state.charLimitText,
            "508/512",
            "MemoByteCountingTests: `testCharLimitTextEmojiCountedAsBytes` charLimitText is expected to be \"508/512\" but it is \"\(state.charLimitText)\""
        )
    }

    func testCharLimitTextShowsRemainingBytes() {
        let state = MessageEditor.State(charLimit: 512, text: "Hello")

        XCTAssertEqual(
            state.charLimitText,
            "507/512",
            "MemoByteCountingTests: `testCharLimitTextShowsRemainingBytes` charLimitText is expected to be \"507/512\" but it is \"\(state.charLimitText)\""
        )
    }
}
