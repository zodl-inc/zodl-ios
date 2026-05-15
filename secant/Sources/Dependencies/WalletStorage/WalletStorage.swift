//
//  WalletStorage.swift
//  Zashi
//
//  Created by Lukáš Korba on 03/10/2022.
//

import Foundation
@preconcurrency import MnemonicSwift
@preconcurrency import ZcashLightClientKit

/// Zcash implementation of the keychain that is not universal but designed to deliver functionality needed by the wallet itself.
/// All the APIs should be thread safe according to official doc:
/// https://developer.apple.com/documentation/security/certificate_key_and_trust_services/working_with_concurrency?language=objc
struct WalletStorage {
    enum Constants {
        static let zcashStoredWallet = "zcashStoredWallet"
        static let zcashStoredAdressBookEncryptionKeys = "zcashStoredAdressBookEncryptionKeys"
        static let zcashStoredUserMetadataEncryptionKeys = "zcashStoredMetadataEncryptionKeys"

        static let zcashStoredWalletBackupReminder = "zcashStoredWalletBackupReminder"
        static let zcashStoredShieldingReminder = "zcashStoredShieldingReminder"
        static func zcashStoredShieldingReminder(accountName: String) -> String {
            "\(Constants.zcashStoredShieldingReminder)_\(accountName)"
        }

        static let zcashStoredWalletBackupAcknowledged = "zcashStoredWalletBackupAcknowledged"
        static let zcashStoredShieldingAcknowledged = "zcashStoredShieldingAcknowledged"
        static let zcashStoredTorSetupFlag = "zcashStoredTorSetupFlag"
        static let zcashStoredVotingHotkey = "zcashStoredVotingHotkey"
        static let zcashStoredZodlAnnouncementFlag = "zcashStoredZodlAnnouncementFlag"

        /// Versioning of the stored data
        static let zcashKeychainVersion = 1
        
        static func accountMetadataFilename(account: Account) -> String {
            Constants.zcashStoredUserMetadataEncryptionKeys + "_\(account.name?.lowercased() ?? "")"
        }
    }
    
    /// States of the Swap API access opt-in
    enum SwapAPIAccess: Equatable, Codable, Hashable {
        /// A user decided to allow the API access over Tor
        case protected
        /// A user skipped the protected step by use over Tor so the swaps are done via direct calls, no IP protection
        case direct
    }

    enum KeychainError: Error, Equatable {
        case decoding
        case duplicate
        case encoding
        case noDataFound
        case unknown(OSStatus)
    }

    enum WalletStorageError: Error {
        case alreadyImported
        case uninitializedAddressBookEncryptionKeys
        case uninitializedUserMetadataEncryptionKeys
        case uninitializedWallet
        case storageError(Error)
        case unsupportedVersion(Int)
        case unsupportedLanguage(MnemonicLanguageType)
    }

    private let secItem: SecItemClient
    var zcashStoredWalletPrefix = ""
    
    init(secItem: SecItemClient) {
        self.secItem = secItem
    }

    func importWallet(
        bip39 phrase: String,
        birthday: BlockHeight?,
        language: MnemonicLanguageType = .english,
        hasUserPassedPhraseBackupTest: Bool = false
    ) throws {
        // Future-proof of the bundle to potentially avoid migration. We enforce english mnemonic.
        guard language == .english else {
            throw WalletStorageError.unsupportedLanguage(language)
        }

        let wallet = StoredWallet(
            language: language,
            seedPhrase: SeedPhrase(phrase),
            version: Constants.zcashKeychainVersion,
            birthday: Birthday(birthday),
            hasUserPassedPhraseBackupTest: hasUserPassedPhraseBackupTest
        )

        do {
            guard let data = try encode(object: wallet) else {
                throw KeychainError.encoding
            }
            
            try setData(data, forKey: Constants.zcashStoredWallet)
        } catch KeychainError.duplicate {
            throw WalletStorageError.alreadyImported
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportWallet() throws -> StoredWallet {
        let reqData: Data?
        
        do {
            reqData = try data(forKey: Constants.zcashStoredWallet)
        } catch KeychainError.noDataFound {
            throw WalletStorageError.uninitializedWallet
        } catch {
            throw error
        }
        
        guard let reqData else {
            throw WalletStorageError.uninitializedWallet
        }
        
        guard let wallet = try decode(json: reqData, as: StoredWallet.self) else {
            throw WalletStorageError.uninitializedWallet
        }
        
        guard wallet.version == Constants.zcashKeychainVersion else {
            throw WalletStorageError.unsupportedVersion(wallet.version)
        }
        
        return wallet
    }
    
    func areKeysPresent() throws -> Bool {
        do {
            _ = try exportWallet()
        } catch {
            // TODO: [#219] - report & log error.localizedDescription, https://github.com/Electric-Coin-Company/zashi-ios/issues/219]
            throw error
        }
        
        return true
    }
    
    func updateBirthday(_ height: BlockHeight) throws {
        do {
            var wallet = try exportWallet()
            wallet.birthday = Birthday(height)
            
            guard let data = try encode(object: wallet) else {
                throw KeychainError.encoding
            }
            
            try updateData(data, forKey: Constants.zcashStoredWallet)
        } catch {
            throw error
        }
    }
    
    func markUserPassedPhraseBackupTest(_ flag: Bool = true) throws {
        do {
            var wallet = try exportWallet()
            wallet.hasUserPassedPhraseBackupTest = flag
            
            guard let data = try encode(object: wallet) else {
                throw KeychainError.encoding
            }
            
            try updateData(data, forKey: Constants.zcashStoredWallet)
        } catch {
            throw error
        }
    }
    
    func resetZashi() throws {
        try deleteData(forKey: Constants.zcashStoredWallet)
        try? deleteData(forKey: Constants.zcashStoredAdressBookEncryptionKeys)
        try? deleteData(forKey: "\(Constants.zcashStoredUserMetadataEncryptionKeys)_zashi")
        try? deleteData(forKey: "\(Constants.zcashStoredUserMetadataEncryptionKeys)_keystone")
        try? deleteData(forKey: Constants.zcashStoredWalletBackupReminder)
        try? deleteData(forKey: "\(Constants.zcashStoredShieldingReminder)_zashi")
        try? deleteData(forKey: "\(Constants.zcashStoredShieldingReminder)_keystone")
        try? deleteData(forKey: Constants.zcashStoredWalletBackupAcknowledged)
        try? deleteData(forKey: Constants.zcashStoredShieldingAcknowledged)
        try? deleteData(forKey: Constants.zcashStoredTorSetupFlag)
        try? deleteData(forKey: Constants.zcashStoredZodlAnnouncementFlag)
    }
    
    func importAddressBookEncryptionKeys(_ keys: AddressBookEncryptionKeys) throws {
        do {
            guard let data = try encode(object: keys) else {
                throw KeychainError.encoding
            }
            
            try setData(data, forKey: Constants.zcashStoredAdressBookEncryptionKeys)
        } catch KeychainError.duplicate {
            throw WalletStorageError.alreadyImported
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportAddressBookEncryptionKeys() throws -> AddressBookEncryptionKeys {
        let reqData: Data?
        
        do {
            reqData = try data(forKey: Constants.zcashStoredAdressBookEncryptionKeys)
        } catch KeychainError.noDataFound {
            throw WalletStorageError.uninitializedAddressBookEncryptionKeys
        } catch {
            throw error
        }
        
        guard let reqData else {
            throw WalletStorageError.uninitializedAddressBookEncryptionKeys
        }
        
        guard let wallet = try decode(json: reqData, as: AddressBookEncryptionKeys.self) else {
            throw WalletStorageError.uninitializedAddressBookEncryptionKeys
        }

        return wallet
    }
    
    func importUserMetadataEncryptionKeys(_ keys: UserMetadataEncryptionKeys, account: Account) throws {
        do {
            guard let data = try encode(object: keys) else {
                throw KeychainError.encoding
            }
            
            try setData(data, forKey: Constants.accountMetadataFilename(account: account))
        } catch KeychainError.duplicate {
            throw WalletStorageError.alreadyImported
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportUserMetadataEncryptionKeys(account: Account) throws -> UserMetadataEncryptionKeys {
        let reqData: Data?
        
        do {
            reqData = try data(forKey: Constants.accountMetadataFilename(account: account))
        } catch KeychainError.noDataFound {
            throw WalletStorageError.uninitializedUserMetadataEncryptionKeys
        } catch {
            throw error
        }
        
        guard let reqData else {
            throw WalletStorageError.uninitializedUserMetadataEncryptionKeys
        }
        
        guard let wallet = try decode(json: reqData, as: UserMetadataEncryptionKeys.self) else {
            throw WalletStorageError.uninitializedUserMetadataEncryptionKeys
        }

        return wallet
    }
    
    func clearEncryptionKeys(_ account: Account) throws {
        try deleteData(forKey: Constants.accountMetadataFilename(account: account))
    }
    
    // MARK: - Remind Me
    
    func importWalletBackupReminder(_ reminder: ReminedMeTimestamp) throws {
        guard let data = try? encode(object: reminder) else {
            throw KeychainError.encoding
        }

        do {
            try setData(data, forKey: Constants.zcashStoredWalletBackupReminder)
        } catch KeychainError.duplicate {
            try updateData(data, forKey: Constants.zcashStoredWalletBackupReminder)
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportWalletBackupReminder() -> ReminedMeTimestamp? {
        let reqData: Data?
        
        do {
            reqData = try data(forKey: Constants.zcashStoredWalletBackupReminder)
        } catch {
            return nil
        }
        
        guard let reqData else {
            return nil
        }
        
        return try? decode(json: reqData, as: ReminedMeTimestamp.self)
    }

    func importShieldingReminder(_ reminder: ReminedMeTimestamp, accountName: String) throws {
        guard let data = try? encode(object: reminder) else {
            throw KeychainError.encoding
        }

        do {
            try setData(data, forKey: Constants.zcashStoredShieldingReminder(accountName: accountName))
        } catch KeychainError.duplicate {
            try updateData(data, forKey: Constants.zcashStoredShieldingReminder(accountName: accountName))
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportShieldingReminder(accountName: String) -> ReminedMeTimestamp? {
        let reqData: Data?
        
        do {
            reqData = try data(forKey: Constants.zcashStoredShieldingReminder(accountName: accountName))
        } catch {
            return nil
        }
        
        guard let reqData else {
            return nil
        }
        
        return try? decode(json: reqData, as: ReminedMeTimestamp.self)
    }
    
    func resetShieldingReminder(accountName: String) {
        try? deleteData(forKey: Constants.zcashStoredShieldingReminder(accountName: accountName))

    }
    
    // MARK: - Acknowledged flags
    
    func importWalletBackupAcknowledged(_ acknowledged: Bool) throws {
        guard let data = try? encode(object: acknowledged) else {
            throw KeychainError.encoding
        }

        do {
            try setData(data, forKey: Constants.zcashStoredWalletBackupAcknowledged)
        } catch KeychainError.duplicate {
            try updateData(data, forKey: Constants.zcashStoredWalletBackupAcknowledged)
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportWalletBackupAcknowledged() -> Bool {
        let reqData: Data?
        
        do {
            reqData = try data(forKey: Constants.zcashStoredWalletBackupAcknowledged)
        } catch {
            return false
        }
        
        guard let reqData else {
            return false
        }
        
        return (try? decode(json: reqData, as: Bool.self)) ?? false
    }
    
    func importShieldingAcknowledged(_ acknowledged: Bool) throws {
        guard let data = try? encode(object: acknowledged) else {
            throw KeychainError.encoding
        }

        do {
            try setData(data, forKey: Constants.zcashStoredShieldingAcknowledged)
        } catch KeychainError.duplicate {
            try updateData(data, forKey: Constants.zcashStoredShieldingAcknowledged)
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportShieldingAcknowledged() -> Bool {
        let reqData: Data?
        
        do {
            reqData = try data(forKey: Constants.zcashStoredShieldingAcknowledged)
        } catch {
            return false
        }
        
        guard let reqData else {
            return false
        }
        
        return (try? decode(json: reqData, as: Bool.self)) ?? false
    }

    func importTorSetupFlag(_ enabled: Bool) throws {
        guard let data = try? encode(object: enabled) else {
            throw KeychainError.encoding
        }

        do {
            try setData(data, forKey: Constants.zcashStoredTorSetupFlag)
        } catch KeychainError.duplicate {
            try updateData(data, forKey: Constants.zcashStoredTorSetupFlag)
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }
    
    func exportTorSetupFlag() -> Bool? {
        let reqData: Data?
        
        do {
            reqData = try data(forKey: Constants.zcashStoredTorSetupFlag)
        } catch {
            return nil
        }
        
        guard let reqData else {
            return nil
        }
        
        return try? decode(json: reqData, as: Bool.self)
    }

    // MARK: - Voting Hotkey

    func importVotingHotkey(_ phrase: String, accountTag: String) throws {
        let hotkey = StoredVotingHotkey(seedPhrase: SeedPhrase(phrase), version: Constants.zcashKeychainVersion)
        let key = "\(Constants.zcashStoredVotingHotkey)_\(accountTag)"
        do {
            guard let data = try encode(object: hotkey) else { throw KeychainError.encoding }
            try setData(data, forKey: key)
        } catch KeychainError.duplicate {
            throw WalletStorageError.alreadyImported
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }

    func exportVotingHotkey(accountTag: String) throws -> StoredVotingHotkey {
        let key = "\(Constants.zcashStoredVotingHotkey)_\(accountTag)"
        let reqData: Data?
        do {
            reqData = try data(forKey: key)
        } catch KeychainError.noDataFound {
            throw WalletStorageError.uninitializedWallet
        }
        guard let reqData else { throw WalletStorageError.uninitializedWallet }
        guard let hotkey = try decode(json: reqData, as: StoredVotingHotkey.self) else {
            throw WalletStorageError.uninitializedWallet
        }
        guard hotkey.version == Constants.zcashKeychainVersion else {
            throw WalletStorageError.unsupportedVersion(hotkey.version)
        }
        return hotkey
    }

    // MARK: - Wallet Storage Codable & Query helpers
    
    func decode<T: Decodable>(json: Data, as clazz: T.Type) throws -> T? {
        do {
            let decoder = JSONDecoder()
            let data = try decoder.decode(T.self, from: json)
            return data
        } catch {
            throw KeychainError.decoding
        }
    }

    func encode<T: Codable>(object: T) throws -> Data? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            return try encoder.encode(object)
        } catch {
            throw KeychainError.encoding
        }
    }
    
    func baseQuery(forAccount account: String = "", andKey forKey: String) -> [String: Any] {
        let query: [String: AnyObject] = [
            /// Uniquely identify this keychain accessor
            kSecAttrService as String: (zcashStoredWalletPrefix + forKey) as AnyObject,
            kSecAttrAccount as String: account as AnyObject,
            kSecClass as String: kSecClassGenericPassword,
            /// The data in the keychain item can be accessed only while the device is unlocked by the user.
            /// This is recommended for items that need to be accessible only while the application is in the foreground.
            /// Items with this attribute do not migrate to a new device.
            /// Thus, after restoring from a backup of a different device, these items will not be present.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        return query
    }
    
    func restoreQuery(forAccount account: String = "", andKey forKey: String) -> [String: Any] {
        var query = baseQuery(forAccount: account, andKey: forKey)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecReturnRef as String] = kCFBooleanFalse
        query[kSecReturnPersistentRef as String] = kCFBooleanFalse
        query[kSecReturnAttributes as String] = kCFBooleanFalse
        
        return query
    }

    /// Restore data for key
    func data(
        forKey: String,
        account: String = ""
    ) throws -> Data? {
        let query = restoreQuery(forAccount: account, andKey: forKey)

        var result: AnyObject?
        let status = secItem.copyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.noDataFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unknown(status)
        }
        
        return result as? Data
    }
    
    /// Use carefully:  Deletes data for key
    func deleteData(
        forKey: String,
        account: String = ""
    ) throws {
        let query = baseQuery(forAccount: account, andKey: forKey)

        let status = secItem.delete(query as CFDictionary)

        // If the item is not present, the goal of the function is fulfilled => no error
        if status == errSecItemNotFound {
            return
        }

        guard status == noErr else {
            throw KeychainError.unknown(status)
        }
    }
    
    /// Store data for key
    func setData(
        _ data: Data,
        forKey: String,
        account: String = ""
    ) throws {
        var query = baseQuery(forAccount: account, andKey: forKey)
        query[kSecValueData as String] = data as AnyObject

        var result: AnyObject?
        let status = secItem.add(query as CFDictionary, &result)
        
        guard status != errSecDuplicateItem else {
            throw KeychainError.duplicate
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.unknown(status)
        }
    }

    /// Use carefully:  Update data for key
    func updateData(
        _ data: Data,
        forKey: String,
        account: String = ""
    ) throws {
        let query = baseQuery(forAccount: account, andKey: forKey)
        
        let attributes: [String: AnyObject] = [
            kSecValueData as String: data as AnyObject
        ]

        let status = secItem.update(query as CFDictionary, attributes as CFDictionary)
        
        guard status != errSecItemNotFound else {
            throw KeychainError.noDataFound
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.unknown(status)
        }
    }
}
