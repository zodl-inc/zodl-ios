//
//  RecoveryPhrase.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.05.2022.
//

import Foundation
@preconcurrency import ZcashLightClientKit

enum RecoveryPhraseError: Error {
    /// This error is thrown then the Recovery Phrase can't be generated
    case unableToGeneratePhrase
}

struct RecoveryPhrase: Equatable, Redactable {
    struct Group: Hashable {
        var startIndex: Int
        var words: [RedactableString]
    }

    let words: [RedactableString]
    
    private let groupSize = 6

    init(words: [RedactableString]) {
        self.words = words
    }
    
    func toGroups() -> [Group] {
        let chunks = words.count / 3

        var res: [Group] = []
        
        for i in 0..<3 {
            var subwords: [RedactableString] = []
            for j in (i * chunks)..<((i + 1) * chunks) {
                subwords.append(words[j])
            }
            res.append(Group(startIndex: i * chunks, words: subwords))
        }
        
        return res
    }

    func toString() -> RedactableString {
        let result = words
            .map { $0.data }
            .joined(separator: " ")
        return result.redacted
    }
}

// TODO: [#695] This should have a #DEBUG tag, but if so, it's not possible to compile this on release mode and submit it to testflight https://github.com/zcash/ZcashLightClientKit/issues/695
extension RecoveryPhrase {
    static let testPhrase = [
        // 1
        "bring", "salute", "thank",
        "require", "spirit", "toe",
        // 7
        "boil", "hill", "casino",
        "trophy", "drink", "frown",
        // 13
        "bird", "grit", "close",
        "morning", "bind", "cancel",
        // 19
        "daughter", "salon", "quit",
        "pizza", "just", "garlic"
    ]

    static let placeholder = RecoveryPhrase(words: testPhrase.map { $0.redacted })
    static let initial = RecoveryPhrase(words: [])
}

extension RecoveryPhrase.Group {
    /// Returns an array of words where the word at the missing index will be an empty string
    func words(with missingIndex: Int) -> [RedactableString] {
        assert(missingIndex >= 0)
        assert(missingIndex < self.words.count)

        var wordsApplyingMissing = self.words

        wordsApplyingMissing[missingIndex] = .empty
        
        return wordsApplyingMissing
    }
}
