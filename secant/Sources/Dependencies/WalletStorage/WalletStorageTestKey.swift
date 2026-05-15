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
        exportWallet: { .placeholder },
        areKeysPresent: { false },
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
        importVotingHotkey: { _, _ in },
        exportVotingHotkey: { _ in .init(seedPhrase: .init(""), version: 0) }
    )
}
