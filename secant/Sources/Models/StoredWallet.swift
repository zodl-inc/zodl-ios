//
//  StoredWallet.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.05.2022.
//

import Foundation
@preconcurrency import ZcashLightClientKit
@preconcurrency import MnemonicSwift

/// Representation of the wallet stored in the persistent storage (typically keychain, handled by `WalletStorage`).
struct StoredWallet: Codable, Equatable {
    let language: MnemonicLanguageType
    let seedPhrase: SeedPhrase
    let version: Int
    
    var birthday: Birthday?
    var hasUserPassedPhraseBackupTest: Bool
    
    init(
        language: MnemonicLanguageType,
        seedPhrase: SeedPhrase,
        version: Int,
        birthday: Birthday? = nil,
        hasUserPassedPhraseBackupTest: Bool
    ) {
        self.language = language
        self.seedPhrase = seedPhrase
        self.version = version
        self.birthday = birthday
        self.hasUserPassedPhraseBackupTest = hasUserPassedPhraseBackupTest
    }
}

extension StoredWallet {
    static let placeholder = Self(
        language: .english,
        seedPhrase: SeedPhrase(RecoveryPhrase.testPhrase.joined(separator: " ")),
        version: 0,
        birthday: Birthday(0),
        hasUserPassedPhraseBackupTest: false
    )
}
