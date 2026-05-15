//
//  StoredVotingHotkey.swift
//  Zashi
//

import Foundation

struct StoredVotingHotkey: Codable, Equatable {
    let seedPhrase: SeedPhrase
    let version: Int

    init(seedPhrase: SeedPhrase, version: Int) {
        self.seedPhrase = seedPhrase
        self.version = version
    }
}
