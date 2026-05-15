//
//  RecoveryFlowTests.swift
//  secantTests
//
//  Created by Francisco Gindre on 10/29/21.
//

import XCTest
@testable import secant_testnet

class RecoveryPhraseBackupTests: XCTestCase {
    func testGiven24WordsBIP39ChunkItIntoHalves() throws {
        let words = [
            "bring", "salute", "thank",
            "require", "spirit", "toe",
            "boil", "hill", "casino",
            "trophy", "drink", "frown",
            // 2nd chunk
            "bird", "grit", "close",
            "morning", "bind", "cancel",
            "daughter", "salon", "quit",
            "pizza", "just", "garlic"
        ]
        let phrase = RecoveryPhrase(words: words.map { $0.redacted })

        let chunks = phrase.toGroups()

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].startIndex, 0)
        XCTAssertEqual(chunks[0].words, [
            "bring", "salute", "thank", "require", "spirit", "toe", "boil", "hill", "casino", "trophy", "drink", "frown"
        ].map { $0.redacted })
        XCTAssertEqual(chunks[1].startIndex, 12)
    }
}
