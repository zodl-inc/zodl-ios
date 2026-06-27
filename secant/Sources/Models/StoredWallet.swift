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

/// The non-secret metadata persisted alongside the seed. On macOS this is stored as a SEPARATE
/// plaintext keychain item, so reading it (birthday, backup-flag, existence) never has to decrypt the
/// Secure-Enclave-wrapped seed and therefore never triggers a biometric prompt. On iOS it is projected
/// from the single `StoredWallet` blob. See docs/macos/KEYCHAIN_SE_HARDENING.md.
struct WalletMetadata: Codable, Equatable {
    var version: Int
    var birthday: Birthday?
    var hasUserPassedPhraseBackupTest: Bool
    /// Non-sensitive seed fingerprint for the launch-time desync guard — populated in a later step.
    var seedFingerprint: Data?

    init(
        version: Int,
        birthday: Birthday? = nil,
        hasUserPassedPhraseBackupTest: Bool,
        seedFingerprint: Data? = nil
    ) {
        self.version = version
        self.birthday = birthday
        self.hasUserPassedPhraseBackupTest = hasUserPassedPhraseBackupTest
        self.seedFingerprint = seedFingerprint
    }
}

extension StoredWallet {
    /// The metadata projection of this wallet (everything except the secret seed material).
    var metadata: WalletMetadata {
        WalletMetadata(
            version: version,
            birthday: birthday,
            hasUserPassedPhraseBackupTest: hasUserPassedPhraseBackupTest
        )
    }
}
