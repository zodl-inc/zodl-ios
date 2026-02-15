//
//  WalletStorageInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.11.2022.
//

import ComposableArchitecture
import MnemonicSwift
import ZcashLightClientKit
import Models

extension DependencyValues {
    public var walletStorage: WalletStorageClient {
        get { self[WalletStorageClient.self] }
        set { self[WalletStorageClient.self] = newValue }
    }
}

/// The `WalletStorageClient` is a wrapper around the `WalletStorage` type that allows for easy testing.
/// The `WalletStorage` Type is comprised of static functions that take and produce data.  In order
/// to easily produce test data, all of these static functions have been wrapped in function
/// properties that live on the `WalletStorageClient` type.  Because of this, you can instantiate
/// the `WalletStorageClient` with your own implementation of these functions for testing purposes,
/// or you can use one of the built in static versions of the `WalletStorageClient`.
@DependencyClient
public struct WalletStorageClient {
    /// Store recovery phrase and optionally even birthday to the secured and persistent storage.
    /// This function creates an instance of `StoredWallet` and automatically handles versioning of the stored data.
    ///
    /// - Parameters:
    ///   - bip39: Mnemonic/Seed phrase from `MnemonicSwift`
    ///   - birthday: BlockHeight from SDK
    ///   - language: Mnemonic's language
    ///   - hasUserPassedPhraseBackupTest: If user passed the puzzle phrase backup
    /// - Throws:
    ///   - `WalletStorageError.unsupportedLanguage`:  when mnemonic's language is anything other than English
    ///   - `WalletStorageError.alreadyImported` when valid wallet is already in the storage
    ///   - `WalletStorageError.storageError` when some unrecognized error occurred
    public let importWallet: (String, BlockHeight?, MnemonicLanguageType, Bool) throws -> Void
    
    /// Load the representation of the wallet from the persistent and secured storage.
    ///
    /// - Returns: the representation of the wallet from the persistent and secured storage.
    /// - Throws:
    ///   - `WalletStorageError.uninitializedWallet`:  when no wallet's data is found in the keychain.
    ///   - `WalletStorageError.storageError` when some unrecognized error occurred.
    ///   - `WalletStorageError.unsupportedVersion` when wallet's version stored in the keychain is outdated.
    public var exportWallet: () throws -> StoredWallet
    
    /// Check if the wallet representation `StoredWallet` is present in the persistent storage.
    ///
    /// - Returns: the information whether some wallet is stored or is not available
    public var areKeysPresent: () throws -> Bool
    
    /// Update the birthday in the securely stored wallet.
    ///
    /// - Parameters:
    ///   - birthday: BlockHeight from SDK
    /// - Throws:
    ///   - `WalletStorage.KeychainError.encoding`:  when encoding the wallet's data failed.
    ///   - `WalletStorageError.storageError` when some unrecognized error occurred.
    public let updateBirthday: (BlockHeight) throws -> Void
    
    /// Update the information that user has passed the recovery phrase backup test.
    /// The function doesn't take any parameters, default value is the user hasn't passed the test
    /// and this function only sets the true = fact user passed.
    ///
    /// - Throws:
    ///   - `WalletStorage.KeychainError.encoding`:  when encoding the wallet's data failed.
    ///   - `WalletStorageError.storageError` when some unrecognized error occurred.
    public let markUserPassedPhraseBackupTest: (Bool) throws -> Void
    
    /// Use carefully: deletes the stored wallet.
    /// There's no fate but what we make for ourselves - Sarah Connor.
    public var resetZashi: () throws -> Void
    
    public var importAddressBookEncryptionKeys: (AddressBookEncryptionKeys) throws -> Void
    public var exportAddressBookEncryptionKeys: () throws -> AddressBookEncryptionKeys
    
    public var importUserMetadataEncryptionKeys: (UserMetadataEncryptionKeys, Account) throws -> Void
    public var exportUserMetadataEncryptionKeys: (Account) throws -> UserMetadataEncryptionKeys
    
    /// Wallet backup reminder set/get
    public var importWalletBackupReminder: (ReminedMeTimestamp) throws -> Void
    public var exportWalletBackupReminder: () -> ReminedMeTimestamp?
    
    /// Shield transparent funds set/get
    public var importShieldingReminder: (ReminedMeTimestamp, String) throws -> Void
    public var exportShieldingReminder: (String) -> ReminedMeTimestamp?
    
    /// Reset  transparent funds reminder
    public var resetShieldingReminder: (String) -> Void
    
    /// Wallet backup acknowledge flag
    public var importWalletBackupAcknowledged: (Bool) throws -> Void
    public var exportWalletBackupAcknowledged: () -> Bool = { false }
    
    /// Shielding acknowledge flag
    public var importShieldingAcknowledged: (Bool) throws -> Void
    public var exportShieldingAcknowledged: () -> Bool = { false }
    
    /// Tor setup flag
    public var importTorSetupFlag: (Bool) throws -> Void
    public var exportTorSetupFlag: () -> Bool? = { nil }
    
    /// Zodl Announcement flag
    public var importZodlAnnouncementFlag: (Bool) throws -> Void
    public var exportZodlAnnouncementFlag: () -> Bool? = { nil }
}
