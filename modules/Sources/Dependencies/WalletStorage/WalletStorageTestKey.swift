//
//  WalletStorageTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 14.11.2022.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension WalletStorageClient: TestDependencyKey {
    public static let testValue = Self(
        importWallet: unimplemented("\(Self.self).importWallet", placeholder: {}()),
        exportWallet: unimplemented("\(Self.self).exportWallet", placeholder: .placeholder),
        areKeysPresent: unimplemented("\(Self.self).areKeysPresent", placeholder: false),
        updateBirthday: unimplemented("\(Self.self).updateBirthday", placeholder: {}()),
        markUserPassedPhraseBackupTest: unimplemented("\(Self.self).markUserPassedPhraseBackupTest", placeholder: {}()),
        resetZashi: unimplemented("\(Self.self).resetZashi", placeholder: {}()),
        importAddressBookEncryptionKeys: unimplemented("\(Self.self).importAddressBookEncryptionKeys", placeholder: {}()),
        exportAddressBookEncryptionKeys: unimplemented("\(Self.self).exportAddressBookEncryptionKeys", placeholder: .empty),
        importUserMetadataEncryptionKeys: unimplemented("\(Self.self).importUserMetadataEncryptionKeys", placeholder: {}()),
        exportUserMetadataEncryptionKeys: unimplemented("\(Self.self).exportUserMetadataEncryptionKeys", placeholder: .empty),
        clearEncryptionKeys: unimplemented("\(Self.self).clearEncryptionKeys"),
        importWalletBackupReminder: unimplemented("\(Self.self).importWalletBackupReminder"),
        exportWalletBackupReminder: unimplemented("\(Self.self).exportWalletBackupReminder", placeholder: nil),
        importShieldingReminder: unimplemented("\(Self.self).importShieldingReminder"),
        exportShieldingReminder: unimplemented("\(Self.self).exportShieldingReminder", placeholder: nil),
        resetShieldingReminder: unimplemented("\(Self.self).resetShieldingReminder"),
        importWalletBackupAcknowledged: unimplemented("\(Self.self).importWalletBackupAcknowledged"),
        exportWalletBackupAcknowledged: unimplemented("\(Self.self).exportWalletBackupAcknowledged", placeholder: false),
        importShieldingAcknowledged: unimplemented("\(Self.self).importShieldingAcknowledged"),
        exportShieldingAcknowledged: unimplemented("\(Self.self).exportShieldingAcknowledged", placeholder: false),
        importTorSetupFlag: unimplemented("\(Self.self).importTorSetupFlag"),
        exportTorSetupFlag: unimplemented("\(Self.self).exportTorSetupFlag", placeholder: nil),
        importZodlAnnouncementFlag: unimplemented("\(Self.self).importZodlAnnouncementFlag"),
        exportZodlAnnouncementFlag: unimplemented("\(Self.self).exportZodlAnnouncementFlag", placeholder: nil)
    )
}

extension WalletStorageClient {
    public static let noOp = Self(
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
        importZodlAnnouncementFlag: { _ in },
        exportZodlAnnouncementFlag: { false }
    )
}
