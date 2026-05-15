//
//  UMSerialization.swift
//  modules
//
//  Created by Lukáš Korba on 03.02.2025.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import CryptoKit

extension UserMetadata {
    /// Encrypts user metadata. The structure:
    ///     [Unencrypted data]    `encryption version`
    ///     [Unencrypted data]    `salt`
    ///     [Unencrypted data]    `metadata version`
    ///     [Encrypted data]        `serialized metadata`
    /// This method always produces the latest structure with the latest encryption version.
    static func encryptUserMetadata(_ umData: UserMetadata, account: Account) throws -> Data {
        @Dependency(\.walletStorage) var walletStorage
        
        guard let encryptionKeys = try? walletStorage.exportUserMetadataEncryptionKeys(account),
                let umKey = encryptionKeys.getCached(account: account) else {
            throw UserMetadataStorage.UMError.missingEncryptionKey
        }

        var encryptionVersionData = Data()
        encryptionVersionData.append(contentsOf: Serializer.intToBytes(UserMetadataEncryptionKeys.Constants.version))

        var metadataVersionData = Data()
        metadataVersionData.append(contentsOf: Serializer.intToBytes(UserMetadata.Constants.version))

        // Generate a fresh one-time sub-key for encrypting the user metadata.
        let salt = SymmetricKey(size: SymmetricKeySize.bits256)

        guard let dataForEncryption = try? JSONEncoder().encode(umData) else {
            throw UserMetadataStorage.UMError.serialization
        }

        return try salt.withUnsafeBytes { salt in
            let salt = Data(salt)
            let subKey = umKey.deriveEncryptionKey(salt: salt)
            
            // Encrypt the serialized user metadata.
            // CryptoKit encodes the SealedBox as `nonce || ciphertext || tag`.
            let sealed = try ChaChaPoly.seal(dataForEncryption, using: subKey)
            
            // Prepend the encryption version & salt to the SealedBox so we can re-derive the sub-key.
            
            // unencrypted data
            return encryptionVersionData + salt + metadataVersionData
            // encrypted data
            + sealed.combined
        }
    }
    
    /// Tries to decrypt the data with the structure:
    ///     [Unencrypted data]    `encryption version`
    ///     [Unencrypted data]    `salt`
    ///     [Unencrypted data]    `metadata version`
    ///
    /// - returns: `UserMetadata` if successful and a flag whether migration happened or not
    static func userMetadataFrom(encryptedData: Data, account: Account) throws -> (UserMetadata?, Bool) {
        @Dependency(\.walletStorage) var walletStorage
        
        // FIXME: refactor
        guard let encryptionKeys = try? walletStorage.exportUserMetadataEncryptionKeys(account),
                let umKey = encryptionKeys.getCached(account: account) else {
            throw UserMetadataStorage.UMError.missingEncryptionKey
        }
        
        var offset = 0
        
        // Deserialize `encryption version`
        let encryptionVersionBytes = try UserMetadata.subdata(of: encryptedData, in: offset..<(offset + UserMetadataStorage.Constants.int64Size))
        offset += UserMetadataStorage.Constants.int64Size
        
        guard let encryptionVersion = UserMetadata.bytesToInt(Array(encryptionVersionBytes)) else {
            return (nil, false)
        }
        
        guard encryptionVersion == UserMetadataEncryptionKeys.Constants.version else {
            throw UserMetadataStorage.UMError.encryptionVersionNotSupported
        }

        let encryptedSubData = try UserMetadata.subdata(of: encryptedData, in: offset..<encryptedData.count)
        
        // Derive the sub-key for decrypting the user metadata.
        let salt = encryptedSubData.prefix(upTo: 32)
        
        let subKeys = umKey.deriveDecryptionKeys(salt: salt)
        
        for subKey in subKeys {
            offset = 32
            
            do {
                // Ignore unencrypted version bytes and move the pointer
                offset += UserMetadataStorage.Constants.int64Size

                // Unseal the encrypted user metadata.
                let sealed = try ChaChaPoly.SealedBox.init(combined: encryptedSubData.suffix(from: 32 +  UserMetadataStorage.Constants.int64Size))
                let data = try ChaChaPoly.open(sealed, using: subKey)
                
                // Ignore unencrypted version and try to decode data as JSON and take the version from it
                if let dataJson = try? JSONDecoder().decode([String: AnyDecodable].self, from: data),
                   let jsonVersion = dataJson[Constants.versionKey]?.value as? Int {
                    switch jsonVersion {
                    case 1:
                        let userMetadataV1Data = try JSONDecoder().decode(UserMetadataV1.self, from: data)
                        let userMetadataV1 = UserMetadata.v1ToLatest(userMetadataV1Data)
                        return (userMetadataV1, true)
                    case 2:
                        let userMetadataV2Data = try JSONDecoder().decode(UserMetadataV2.self, from: data)
                        let userMetadataV2 = UserMetadata.v2ToLatest(userMetadataV2Data)
                        return (userMetadataV2, true)
                    case 3:
                        // latest version, just continue
                        break
                    default:
                        throw UserMetadataStorage.UMError.metadataVersionNotSupported
                    }
                } else {
                    throw UserMetadataStorage.UMError.encryptedDataStructuralCorruption
                }

                // deserialize the json's data
                let latestUserMetadata = try JSONDecoder().decode(UserMetadata.self, from: data)
                return (latestUserMetadata, false)
            } catch {
                // this key failed to decrypt, try another one
            }
        }

        return (nil, false)
    }

    static func subdata(of data: Data, in range: Range<Data.Index>) throws -> Data {
        guard data.count >= range.upperBound else {
            throw UserMetadataStorage.UMError.subdataRange
        }
        
        return data.subdata(in: range)
    }

    static func bytesToInt(_ bytes: [UInt8]) -> Int? {
        guard bytes.count == UserMetadataStorage.Constants.int64Size else {
            return nil
        }
        
        return bytes.withUnsafeBytes { ptr -> Int? in
            Int.init(exactly: ptr.loadUnaligned(as: Int64.self).bigEndian)
        }
    }
}
