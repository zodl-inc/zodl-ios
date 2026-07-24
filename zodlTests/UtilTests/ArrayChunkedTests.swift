//
//  ArrayChunkedTests.swift
//  zodlTests
//
//  Batch 1 — pure logic. Covers Array.removingDuplicates (Utils/Array+Chunked.swift). `chunked(into:)`
//  and its tests here were removed with MOB-1513's Keystone batch-signing chunker
//  (`MigrationCoordFlow.chunkKeystoneBatch`, its only caller) — the real SDK protocol needs no
//  app-side chunking (see `MigrationCoordFlowCoordinator.swift`'s header).
//

import Testing
@testable import zodl_internal

@Suite struct ArrayChunkedTests {
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
        #expect([Item]().removingDuplicates().isEmpty)
    }
}

private struct Item: Identifiable, Equatable {
    let id: Int
    let tag: String
}
