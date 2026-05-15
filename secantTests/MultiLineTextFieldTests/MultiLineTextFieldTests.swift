//
//  MessageEditorTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 01.08.2022.
//

import XCTest
import ComposableArchitecture
@testable import secant_testnet

@MainActor
class MessageEditorTests: XCTestCase {
    func testIsCharLimited() async throws {
        let store = TestStore(
            initialState: MessageEditor.State(charLimit: 1)
        ) {
            MessageEditor()
        }
        
        let value = "test".redacted
        await store.send(.inputChanged(value)) { state in
            state.text = value
            XCTAssertTrue(
                state.isCharLimited,
                "Multiline TextFiler tests: `testIsCharLimited` is expected to be true but it is \(state.isCharLimited)"
            )
        }
    }

    func testIsNotCharLimited() async throws {
        let store = TestStore(
            initialState: MessageEditor.State()
        ) {
            MessageEditor()
        }

        let value = "test".redacted
        await store.send(.inputChanged(value)) { state in
            state.text = value
            XCTAssertFalse(
                state.isCharLimited,
                "Multiline TextFiler tests: `testIsNotCharLimited` is expected to be false but it is \(state.isCharLimited)"
            )
        }
    }

    func testByteLength() async throws {
        let store = TestStore(
            initialState: MessageEditor.State()
        ) {
            MessageEditor()
        }

        let value = "test".redacted
        await store.send(.inputChanged(value)) { state in
            state.text = value
            XCTAssertEqual(
                4,
                state.byteLength,
                "Multiline TextFiler tests: `testByteLength` is expected to be 4 but it is \(state.byteLength)"
            )
        }
    }
    
    func testByteLengthUnicode() async throws {
        let store = TestStore(
            initialState: MessageEditor.State()
        ) {
            MessageEditor()
        }

        // unicode char 😊 takes 4 bytes
        let value = "😊😊😊😊😊".redacted
        await store.send(.inputChanged(value)) { state in
            state.text = value
            XCTAssertEqual(
                20,
                state.byteLength,
                "Multiline TextFiler tests: `testByteLengthUnicode` is expected to be 20 but it is \(state.byteLength)"
            )
        }
    }
    
    func testIsValid_CharLimit() async throws {
        let store = TestStore(
            initialState: MessageEditor.State(charLimit: 4)
        ) {
            MessageEditor()
        }

        let value = "test".redacted
        await store.send(.inputChanged(value)) { state in
            state.text = value
            XCTAssertTrue(
                state.isValid,
                "Multiline TextFiler tests: `testIsValid_CharLimit` is expected to be true but it is \(state.isValid)"
            )
        }
    }

    func testIsValid_NoCharLimit() async throws {
        let store = TestStore(
            initialState: MessageEditor.State()
        ) {
            MessageEditor()
        }

        let value = "test".redacted
        await store.send(.inputChanged(value)) { state in
            state.text = value
            XCTAssertTrue(
                state.isValid,
                "Multiline TextFiler tests: `testIsValid_NoCharLimit` is expected to be true but it is \(state.isValid)"
            )
        }
    }
    
    func testIsInvalid() async throws {
        let store = TestStore(
            initialState: MessageEditor.State(charLimit: 3)
        ) {
            MessageEditor()
        }

        let value = "test".redacted
        await store.send(.inputChanged(value)) { state in
            state.text = value
            XCTAssertFalse(
                state.isValid,
                "Multiline TextFiler tests: `testIsInvalid` is expected to be false but it is \(state.isValid)"
            )
        }
    }
    
    func testCharLimitText_NoCharLimit() async throws {
        let store = TestStore(
            initialState: MessageEditor.State()
        ) {
            MessageEditor()
        }

        let value = "test".redacted
        await store.send(.inputChanged(value)) { state in
            state.text = value
            XCTAssertEqual(
                "",
                state.charLimitText,
                "Multiline TextFiler tests: `testCharLimitText_NoCharLimit` is expected to be \"\" but it is \(state.charLimitText)"
            )
        }
    }
    
    func testCharLimitText_CharLimit_LessCharacters() async throws {
        let store = TestStore(
            initialState: MessageEditor.State(charLimit: 5)
        ) {
            MessageEditor()
        }

        let value = "test".redacted
        await store.send(.inputChanged(value)) { state in
            state.text = value
            XCTAssertEqual(
                "1/5",
                state.charLimitText,
                "Multiline TextFiler tests: `testCharLimitText_CharLimit_LessCharacters` is expected to be \"1/5\" but it is \(state.charLimitText)"
            )
        }
    }
    
    func testCharLimitText_CharLimit_Exceeded() async throws {
        let store = TestStore(
            initialState: MessageEditor.State(charLimit: 3)
        ) {
            MessageEditor()
        }

        let value = "test".redacted
        await store.send(.inputChanged(value)) { state in
            state.text = value
            XCTAssertEqual(
                "-1/3",
                state.charLimitText,
                "Multiline TextFiler tests: `testCharLimitText_CharLimit_Exceeded` is expected to be \"-1/3\" but it is \(state.charLimitText)"
            )
        }
    }
}
