//
//  ArrayChunkedTests.swift
//  zodlTests
//
//  Batch 1 — pure logic. Covers Array.chunked / removingDuplicates (Utils/Array+Chunked.swift).
//

import Testing
@testable import zodl_internal

@Suite struct ArrayChunkedTests {
    @Test func chunkedSplitsWithRemainder() {
        #expect([1, 2, 3, 4, 5].chunked(into: 2) == [[1, 2], [3, 4], [5]])
    }

    @Test func chunkedSplitsEvenly() {
        #expect([1, 2, 3, 4].chunked(into: 2) == [[1, 2], [3, 4]])
    }

    @Test func chunkedWithSizeLargerThanCountReturnsSingleChunk() {
        #expect([1, 2].chunked(into: 5) == [[1, 2]])
    }

    @Test func chunkedEmptyArrayReturnsEmpty() {
        #expect([Int]().chunked(into: 3).isEmpty)
    }

    @Test func removingDuplicatesKeepsFirstOccurrencePreservingOrder() {
        let items = [
            Item(id: 1, tag: "a"),
            Item(id: 1, tag: "b"),
            Item(id: 2, tag: "c"),
            Item(id: 2, tag: "d"),
            Item(id: 3, tag: "e")
        ]
        let deduped = items.removingDuplicates()
        #expect(deduped.map(\.id) == [1, 2, 3])
        #expect(deduped.map(\.tag) == ["a", "c", "e"])
    }

    @Test func removingDuplicatesOnEmptyReturnsEmpty() {
        let empty: [Item] = []
        #expect(empty.removingDuplicates().isEmpty)
    }
}

private struct Item: Identifiable, Equatable {
    let id: Int
    let tag: String
}
