//
//  WalletStorageLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.11.2022.
//

import Foundation
@preconcurrency import MnemonicSwift
@preconcurrency import ZcashLightClientKit
import ComposableArchitecture

extension WalletStorageClient: DependencyKey {
    static let liveValue = WalletStorageClient.live()

    static func live(walletStorage: WalletStorage = .liveStorage) -> Self {
        Self(
            importWallet: { bip39, birthday, language, hasUserPassedPhraseBackupTest  in
                try walletStorage.importWallet(
                    bip39: bip39,
                    birthday: birthday,
                    language: language,
                    hasUserPassedPhraseBackupTest: hasUserPassedPhraseBackupTest
                )
            },
            exportWallet: { reason in
                try await walletStorage.exportWallet(reason: reason)
            },
            exportWalletMetadata: {
                try walletStorage.exportWalletMetadata()
            },
            areKeysPresent: {
                try walletStorage.areKeysPresent()
            },
            isSecureStorageAvailable: {
                walletStorage.isSecureStorageAvailable()
            },
            migrateToSecureEnclave: {
                try await walletStorage.migrateToSecureEnclaveIfNeeded()
            },
            updateBirthday: { birthday in
                try walletStorage.updateBirthday(birthday)
            },
            markUserPassedPhraseBackupTest: { flag in
                try walletStorage.markUserPassedPhraseBackupTest(flag)
            },
            resetZashi: {
                try walletStorage.resetZashi()
            },
            importAddressBookEncryptionKeys: { keys in
                try walletStorage.importAddressBookEncryptionKeys(keys)
            },
            exportAddressBookEncryptionKeys: {
                try walletStorage.exportAddressBookEncryptionKeys()
            },
            importUserMetadataEncryptionKeys: { keys, account in
                try walletStorage.importUserMetadataEncryptionKeys(keys, account: account)
            },
            exportUserMetadataEncryptionKeys: { account in
                try walletStorage.exportUserMetadataEncryptionKeys(account: account)
            },
            clearEncryptionKeys: { account in
                try walletStorage.clearEncryptionKeys(account)
            },
            importWalletBackupReminder: { reminedMeTimestamp in
                try walletStorage.importWalletBackupReminder(reminedMeTimestamp)
            },
            exportWalletBackupReminder: {
                walletStorage.exportWalletBackupReminder()
            },
            importShieldingReminder: { reminedMeTimestamp, accountName in
                try walletStorage.importShieldingReminder(reminedMeTimestamp, accountName: accountName)
            },
            exportShieldingReminder: { accountName in
                walletStorage.exportShieldingReminder(accountName: accountName)
            },
            resetShieldingReminder: { accountName in
                walletStorage.resetShieldingReminder(accountName: accountName)
            },
            importWalletBackupAcknowledged: { acknowledged in
                try walletStorage.importWalletBackupAcknowledged(acknowledged)
            },
            exportWalletBackupAcknowledged: {
                walletStorage.exportWalletBackupAcknowledged()
            },
            importShieldingAcknowledged: { acknowledged in
                try walletStorage.importShieldingAcknowledged(acknowledged)
            },
            exportShieldingAcknowledged: {
                walletStorage.exportShieldingAcknowledged()
            },
            importTorSetupFlag: { enabled in
                try walletStorage.importTorSetupFlag(enabled)
            },
            exportTorSetupFlag: {
                walletStorage.exportTorSetupFlag()
            },
            importIronwoodAnnouncementFlag: { enabled in
                try walletStorage.importIronwoodAnnouncementFlag(enabled)
            },
            exportIronwoodAnnouncementFlag: {
                walletStorage.exportIronwoodAnnouncementFlag()
            },
            importVotingHotkey: { phrase, accountId in
                try walletStorage.importVotingHotkey(phrase, accountId: accountId)
            },
            exportVotingHotkey: { accountId in
                try walletStorage.exportVotingHotkey(accountId: accountId)
            }
        )
    }
}

extension WalletStorage {
    /// The live storage: Secure-Enclave-backed on macOS (seed wrapped by a non-extractable enclave
    /// key), legacy plaintext on iOS. See docs/macos/KEYCHAIN_SE_HARDENING.md.
    static var liveStorage: WalletStorage {
#if os(macOS)
        var storage = WalletStorage(secItem: .live, secureEnclave: .liveValue)
        // Data Protection keychain (MOB-1485): silent signature-based access instead of the login
        // keychain's per-item ACL password dialogs. Existing items relocate once on first access.
        storage.useDataProtectionKeychain = true
#else
        var storage = WalletStorage(secItem: .live)
#endif
#if SECANT_TESTNET
        // Testnet builds must NEVER share keychain entries with a mainnet build
        // on the same machine (macOS login-keychain items are keyed by service
        // string only — an unscoped testnet restore would overwrite the mainnet
        // seed entry). The prefix isolates every testnet key.
        storage.zcashStoredWalletPrefix = "testnet_"
#else
        storage.zcashStoredWalletPrefix = ""
#endif
        return storage
    }
}
