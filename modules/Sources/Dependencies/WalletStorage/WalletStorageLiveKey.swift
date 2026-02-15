//
//  WalletStorageLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.11.2022.
//

import Foundation
import MnemonicSwift
import ZcashLightClientKit
import ComposableArchitecture
import SecItem

extension WalletStorageClient: DependencyKey {
    public static let liveValue = WalletStorageClient.live()

    public static func live(walletStorage: WalletStorage = WalletStorage(secItem: .live)) -> Self {
        Self(
            importWallet: { bip39, birthday, language, hasUserPassedPhraseBackupTest  in
                try walletStorage.importWallet(
                    bip39: bip39,
                    birthday: birthday,
                    language: language,
                    hasUserPassedPhraseBackupTest: hasUserPassedPhraseBackupTest
                )
            },
            exportWallet: {
                try walletStorage.exportWallet()
            },
            areKeysPresent: {
                try walletStorage.areKeysPresent()
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
            importZodlAnnouncementFlag: { enabled in
                try walletStorage.importZodlAnnouncementFlag(enabled)
            },
            exportZodlAnnouncementFlag: {
                walletStorage.exportZodlAnnouncementFlag()
            }
        )
    }
}
