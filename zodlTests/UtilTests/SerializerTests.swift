//
//  SerializerTests.swift
//  zodlTests
//
//  Batch 1 — pure logic. Covers `Serializer` (Utils/Data+Serialization.swift).
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct SerializerTests {
    @Test func stringBytesRoundTripASCII() {
        let bytes = Serializer.stringToBytes("hello")
        #expect(bytes == Array("hello".utf8))
        #expect(Serializer.bytesToString(bytes) == "hello")
    }

    @Test func stringBytesRoundTripUnicode() {
        let original = "Příliš žluťoučký 🎉"
        let bytes = Serializer.stringToBytes(original)
        #expect(Serializer.bytesToString(bytes) == original)
    }

    @Test func emptyStringRoundTrip() {
        #expect(Serializer.stringToBytes("").isEmpty)
        #expect(Serializer.bytesToString([])?.isEmpty == true)
    }

    @Test func bytesToStringReturnsNilForInvalidUTF8() {
        #expect(Serializer.bytesToString([0xFF]) == nil)
    }

    @Test func intToBytesIsBigEndianEightBytes() {
        // `Int` is 64-bit on the test platform, so each value is 8 big-endian bytes.
        #expect(Serializer.intToBytes(0) == [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(Serializer.intToBytes(1) == [0, 0, 0, 0, 0, 0, 0, 1])
        #expect(Serializer.intToBytes(256) == [0, 0, 0, 0, 0, 0, 1, 0])
        #expect(Serializer.intToBytes(-1) == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }
}
