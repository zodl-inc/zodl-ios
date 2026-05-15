//
//  AddressBookEncryption.swift
//  Zashi
//
//  Created by Lukáš Korba on 11-11-2024.
//

import ComposableArchitecture

import Foundation
import CryptoKit
@preconcurrency import ZcashLightClientKit

extension AddressBookClient {
    static func serializeContacts(_ abContacts: AddressBookContacts) -> Data {
        var dataForEncryption = Data()
        
        // Serialize `address book version`
        dataForEncryption.append(contentsOf: intToBytes(abContacts.version))
        
        // Serialize `lastUpdated`
        dataForEncryption.append(contentsOf: AddressBookClient.serializeDate(Date()))
        
        // Serialize `contacts.count`
        dataForEncryption.append(contentsOf: intToBytes(abContacts.contacts.count))
        
        // Serialize `contacts`
        abContacts.contacts.forEach { contact in
            let serializedContact = serializeContact(contact)
            dataForEncryption.append(serializedContact)
        }
        
        return dataForEncryption
    }
    
    /// Encrypts address book contacts. The structure:
    ///     [Unencrypted data]    `encryption version`
    ///     [Unencrypted data]    `salt`
    ///     [Encrypted data]        `address book version`
    ///     [Encrypted data]        `timestamp`
    ///     [Encrypted data]        `contacts`
    ///
    /// This method always produces the latest structure with the latest encryption version.
    static func encryptContacts(_ contacts: AddressBookContacts, account: Account) throws -> Data {
        @Dependency(\.walletStorage) var walletStorage
        
        // TODO: [#1581] - Refactor encryption metadata terminology for keys
        // https://github.com/Electric-Coin-Company/zashi-ios/issues/1581
        guard let encryptionKeys = try? walletStorage.exportAddressBookEncryptionKeys(),
              let addressBookKey = encryptionKeys.getCached(account: account) else {
            throw AddressBookClient.AddressBookClientError.missingEncryptionKey
        }
        
        var encryptionVersionData = Data()
        encryptionVersionData.append(contentsOf: intToBytes(AddressBookEncryptionKeys.Constants.version))
        
        let dataForEncryption = AddressBookClient.serializeContacts(contacts)
        
        // Generate a fresh one-time sub-key for encrypting the address book.
        let salt = SymmetricKey(size: SymmetricKeySize.bits256)
        
        return try salt.withUnsafeBytes { salt in
            let salt = Data(salt)
            let subKey = addressBookKey.deriveEncryptionKey(salt: salt)
            
            // Encrypt the serialized address book.
            // CryptoKit encodes the SealedBox as `nonce || ciphertext || tag`.
            let sealed = try ChaChaPoly.seal(dataForEncryption, using: subKey)
            
            // Prepend the encryption version & salt to the SealedBox so we can re-derive the sub-key.
            
            // unencrypted data
            return encryptionVersionData + salt
            // encrypted data
            + sealed.combined
        }
    }
    
    /// Tries to decrypt the data with the structure:
    ///     [Unencrypted data]    `encryption version`
    ///     [Unencrypted data]    `salt`
    ///     [Encrypted data]        `address book version`
    ///     [Encrypted data]        `timestamp`
    ///     [Encrypted data]        `contacts`
    static func contactsFrom(encryptedData: Data, account: Account) throws -> (AddressBookContacts, Bool) {
        @Dependency(\.walletStorage) var walletStorage
        
        guard let encryptionKeys = try? walletStorage.exportAddressBookEncryptionKeys(), let addressBookKey = encryptionKeys.getCached(account: account) else {
            throw AddressBookClient.AddressBookClientError.missingEncryptionKey
        }
        
        var offset = 0
        
        // Deserialize `encryption version`
        let encryptionVersionBytes = try AddressBookClient.subdata(of: encryptedData, in: offset..<(offset + Constants.int64Size))
        offset += Constants.int64Size
        
        guard let encryptionVersion = AddressBookClient.bytesToInt(Array(encryptionVersionBytes)) else {
            return (.empty, false)
        }
        
        if encryptionVersion == AddressBookEncryptionKeys.Constants.version {
            let encryptedSubData = try AddressBookClient.subdata(of: encryptedData, in: offset..<encryptedData.count)
            
            // Derive the sub-key for decrypting the address book.
            let salt = encryptedSubData.prefix(upTo: 32)
            let subKey = addressBookKey.deriveEncryptionKey(salt: salt)
            
            // Unseal the encrypted address book.
            let sealed = try ChaChaPoly.SealedBox.init(combined: encryptedSubData.suffix(from: 32))
            let data = try ChaChaPoly.open(sealed, using: subKey)
            
            return try contactsFrom(plainData: data)
        } else {
            throw AddressBookClientError.encryptionVersionNotSupported
        }
    }
    
    /// Tries to decode the unencrypted data
    ///     [Unencrypted data]        `address book version`
    ///     [Unencrypted data]        `timestamp`
    ///     [Unencrypted data]        `contacts`
    static func contactsFrom(plainData: Data) throws -> (AddressBookContacts, Bool) {
        var offset = 0
        
        // Deserialize `version`
        let versionBytes = try AddressBookClient.subdata(of: plainData, in: offset..<(offset + Constants.int64Size))
        offset += Constants.int64Size
        
        // Deserialize and check `address book version`
        guard let version = AddressBookClient.bytesToInt(Array(versionBytes)) else {
            return (.empty, false)
        }
        
        guard version == AddressBookContacts.Constants.version else {
            // Attempt to migrate
            switch version {
            case 1:
                let latestAddressBook = try AddressBookClient.contactsFromV1(plainData: plainData, offset: offset)
                return (latestAddressBook, true)
            default:
                return (.empty, false)
            }
        }

        // Deserialize `lastUpdated`
        guard let lastUpdated = try AddressBookClient.deserializeDate(from: plainData, at: &offset) else {
            return (.empty, false)
        }
        
        // Deserialize `contactsCount`
        let contactsCountBytes = try AddressBookClient.subdata(of: plainData, in: offset..<(offset + Constants.int64Size))
        offset += Constants.int64Size
        
        guard let contactsCount = AddressBookClient.bytesToInt(Array(contactsCountBytes)) else {
            return (.empty, false)
        }
        
        var contacts: [Contact] = []
        for _ in 0..<contactsCount {
            if let contact = try AddressBookClient.deserializeContact(from: plainData, at: &offset) {
                contacts.append(contact)
            }
        }
        
        let abContacts = AddressBookContacts(
            lastUpdated: lastUpdated,
            version: version,
            contacts: IdentifiedArrayOf(uniqueElements: contacts)
        )
        
        return (abContacts, false)
    }
}
    
// MARK: - Helper methods for the data handling

extension AddressBookClient {
    static func serializeContact(_ contact: Contact) -> Data {
        var data = Data()
        
        // Serialize `lastUpdated`
        data.append(contentsOf: AddressBookClient.serializeDate(contact.lastUpdated))
        
        // Serialize `address` (length + UTF-8 bytes)
        let addressBytes = stringToBytes(contact.address)
        data.append(contentsOf: intToBytes(addressBytes.count))
        data.append(contentsOf: addressBytes)
        
        // Serialize `name` (length + UTF-8 bytes)
        let nameBytes = stringToBytes(contact.name)
        data.append(contentsOf: intToBytes(nameBytes.count))
        data.append(contentsOf: nameBytes)

        // Serialize `chainId` (length + UTF-8 bytes)
        if let chainId = contact.chainId {
            let chainIdBytes = stringToBytes(chainId)
            data.append(contentsOf: intToBytes(chainIdBytes.count))
            data.append(contentsOf: chainIdBytes)
        } else {
            data.append(contentsOf: intToBytes(0))
        }

        return data
    }
    
    static func deserializeContact(from data: Data, at offset: inout Int) throws -> Contact? {
        // Deserialize `lastUpdated`
        guard let lastUpdated = try AddressBookClient.deserializeDate(from: data, at: &offset) else {
            return nil
        }
        
        // Deserialize `address`
        guard let address = try readString(from: data, at: &offset) else {
            return nil
        }
        
        // Deserialize `name`
        guard let name = try readString(from: data, at: &offset) else {
            return nil
        }

        // Deserialize `chainId`
        let chainId = try? readString(from: data, at: &offset)

        return Contact(
            address: address,
            name: name,
            lastUpdated: lastUpdated,
            chainId: chainId
        )
    }
    
    static func stringToBytes(_ string: String) -> [UInt8] {
        return Array(string.utf8)
    }
    
    static func bytesToString(_ bytes: [UInt8]) -> String? {
        return String(bytes: bytes, encoding: .utf8)
    }
    
    static func intToBytes(_ value: Int) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
    
    static func bytesToInt(_ bytes: [UInt8]) -> Int? {
        guard bytes.count == Constants.int64Size else {
            return nil
        }
        
        return bytes.withUnsafeBytes { ptr -> Int? in
            Int.init(exactly: ptr.loadUnaligned(as: Int64.self).bigEndian)
        }
    }
    
    static func serializeDate(_ date: Date) -> [UInt8] {
        // Convert Date to Unix time (number of seconds since 1970)
        let timestamp = Int(date.timeIntervalSince1970)
        
        // Convert the timestamp to bytes
        return AddressBookClient.intToBytes(timestamp)
    }
    
    static func deserializeDate(from data: Data, at offset: inout Int) throws -> Date? {
        // Extract the bytes for the timestamp (assume it's stored as an Int)
        let timestampBytes = try AddressBookClient.subdata(of: data, in: offset..<(offset + Constants.int64Size))
        offset += Constants.int64Size
        
        // Convert the bytes back to an Int
        guard let timestamp = AddressBookClient.bytesToInt(Array(timestampBytes)) else { return nil }
        
        // Convert the timestamp back to a Date
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
    
    // Helper function to read a string from the data using a length prefix
    static func readString(from data: Data, at offset: inout Int) throws -> String? {
        // Read the length first (assumes the length is stored as an Int)
        let lengthBytes = try AddressBookClient.subdata(of: data, in: offset..<(offset + Constants.int64Size))
        offset += Constants.int64Size
        guard let length = AddressBookClient.bytesToInt(Array(lengthBytes)), length > 0 else { return nil }
        
        // Read the string bytes
        let stringBytes = try AddressBookClient.subdata(of: data, in: offset..<(offset + length))
        offset += length
        return AddressBookClient.bytesToString(Array(stringBytes))
    }
    
    static func subdata(of data: Data, in range: Range<Data.Index>) throws -> Data {
        guard data.count >= range.upperBound else {
            throw AddressBookClient.AddressBookClientError.subdataRange
        }
        
        return data.subdata(in: range)
    }
}
