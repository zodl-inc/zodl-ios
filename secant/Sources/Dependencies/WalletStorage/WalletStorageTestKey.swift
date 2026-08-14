//
//  WalletStorageTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 14.11.2022.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension WalletStorageClient {
    static let noOp = Self(
        importWallet: { _, _, _, _ in },
        exportWallet: { _ in .placeholder },
        exportWalletMetadata: { StoredWallet.placeholder.metadata },
        areKeysPresent: { false },
        isSecureStorageAvailable: { true },
        migrateToSecureEnclave: { },
        updateBirthday: { _ in },
        markUserPassedPhraseBackupTest: { _ in },
        resetZashi: { },
        importAddressBookEncryptionKeys: { _ in },
        exportAddressBookEncryptionKeys: { .empty },
        importUserMetadataEncryptionKeys: { _, _ in },
        exportUserMetadataEncryptionKeys: { _ in .empty },
        clearEncryptionKeys: { _ in },
        importWalletBackupReminder: { _ in },
        exportWalletBackupReminder: { nil },
        importShieldingReminder: { _, _ in },
        exportShieldingReminder: { _ in nil },
        resetShieldingReminder: { _ in },
        importWalletBackupAcknowledged: { _ in },
        exportWalletBackupAcknowledged: { false },
        importShieldingAcknowledged: { _ in },
        exportShieldingAcknowledged: { false },
        importTorSetupFlag: { _ in },
        exportTorSetupFlag: { false },
        // `true` (not `nil`) is deliberate: `.noOp` is used at many test sites, several of which drive
        // the app's Root reducer through launch and sync and assert it lands on Home. `true` means
        // "already acknowledged", which keeps the Ironwood announcement gate closed for all of them.
        // Do not "fix" this to `nil` — that would make the announcement pop up across those tests.
        importIronwoodAnnouncementFlag: { _ in },
        exportIronwoodAnnouncementFlag: { true },
        importVotingHotkey: { _, _ in },
        exportVotingHotkey: { _ in .init(seedPhrase: .init(""), version: 0) }
    )
}
