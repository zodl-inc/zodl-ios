//
//  MnemonicInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.11.2022.
//

import ComposableArchitecture

extension DependencyValues {
    var mnemonic: MnemonicClient {
        get { self[MnemonicClient.self] }
        set { self[MnemonicClient.self] = newValue }
    }
}

@DependencyClient
struct MnemonicClient {
    /// Random 24 words mnemonic phrase
    var randomMnemonic: @Sendable () throws -> String
    /// Random 24 words mnemonic phrase as array of words
    var randomMnemonicWords: @Sendable () throws -> [String]
    /// Generate deterministic seed from mnemonic phrase
    var toSeed: @Sendable (String) throws -> [UInt8]
    /// Get this mnemonic phrase as array of words
    var asWords: @Sendable (String) -> [String] = { _ in [] }
    /// Validates whether the given mnemonic is correct
    var isValid: @Sendable (String) throws -> Void
    /// Suggests mnemonic words for a given prefix
    var suggestWords: @Sendable (String) -> [String] = { _ in [] }
}
