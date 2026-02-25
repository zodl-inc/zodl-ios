//
//  UserMetadataEncryptionKeys.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-02-18.
//

import Foundation
import CryptoKit
import Utils
import DerivationTool
import ZcashLightClientKit

/// Representation of the user metadata encryption keys
public struct UserMetadataEncryptionKeys: Codable, Equatable {
    /// Latest encryption version
    public enum Constants {
        public static let version = 1
    }
    
    // FIXME: Integer is not enough information to uniquely identify the key
    // FIXME: Don't hold keys in the memory when not necessary
    var keys: [Int: UserMetadataKeys]

    public mutating func cacheFor(seed: [UInt8], account: Account, network: NetworkType) throws {
        guard let zip32AccountIndex = account.hdAccountIndex else {
            return
        }
        
        guard let info = "metadata".data(using: .utf8) else {
            fatalError("Unable to prepare `info` info")
        }
        
        let metadataKey = try AccountMetadataKey(
            from: seed,
            accountIndex: zip32AccountIndex,
            networkType: network
        )

        // FIXME: is the seed fingerprint matches account's seed fingerprint
        
        // FIXME: this will break when there are 2+ online seeds
        let privateMetadataKeys = try metadataKey.derivePrivateUseMetadataKey(
            ufvk: account.name?.lowercased() == "zashi" ? nil : account.ufvk,
            privateUseSubject: [UInt8](info)
        )

        // FIXME: possible security issue - override
        keys[Int(zip32AccountIndex.index)] = UserMetadataKeys(privateKeys: privateMetadataKeys)
    }

    public func getCached(account: Account) -> UserMetadataKeys? {
        guard let zip32AccountIndex = account.hdAccountIndex else {
            return nil
        }

        return keys[Int(zip32AccountIndex.index)]
    }
}

extension UserMetadataEncryptionKeys {
    public static let empty = Self(
        keys: [:]
    )
}

public struct UserMetadataKeys: Codable, Equatable, Redactable {
    let keys: [SymmetricKey]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        keys = try container.decode([Data].self).map { SymmetricKey(data: $0) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        do {
            let privateKeys = keys.map { symmetricKey in
                symmetricKey.withUnsafeBytes { key in
                    return Data(key)
                }
            }
            try container.encode(privateKeys)
        } catch {
            fatalError("Unable to encode `UserMetadataKeys`")
        }
    }

    /**
     * Derives the long-term key that can decrypt the given account's encrypted
     * user metadata.
     *
     * This requires access to the seed phrase. If the app has separate access
     * control requirements for the seed phrase and the user metadata, this key
     * should be cached in the app's keystore.
     */
    public init(privateKeys: [Data]) {
        keys = privateKeys.map { SymmetricKey(data: $0) }
    }

    /**
     * Derives a one-time user metadata encryption key.
     *
     * At encryption time, the one-time property MUST be ensured by generating a
     * random 32-byte salt.
     */
    public func deriveEncryptionKey(
        salt: Data
    ) -> SymmetricKey {
        assert(salt.count == 32)

        guard let info = "metadata_key".data(using: .utf8) else {
            fatalError("Unable to prepare `metadata_key` info")
        }
        
        guard let firstKey = keys.first else {
            fatalError("Unable to process `firstKey`")
        }
        
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: firstKey, info: salt + info, outputByteCount: 32)
    }
    
    /**
     * Derives a one-time user metadata decryption keys.
     *
     * At decryption time, the one-time property MUST be ensured by generating a
     * random 32-byte salt.
     */
    public func deriveDecryptionKeys(
        salt: Data
    ) -> [SymmetricKey] {
        assert(salt.count == 32)

        guard let info = "metadata_key".data(using: .utf8) else {
            fatalError("Unable to prepare `metadata_key` info")
        }

        var decryptionKeys: [SymmetricKey] = []

        keys.forEach {
            decryptionKeys.append(HKDF<SHA256>.deriveKey(inputKeyMaterial: $0, info: salt + info, outputByteCount: 32))
        }

        return decryptionKeys
    }

    /**
     * Derives the filename that this key is able to decrypt.
     */
    public func fileIdentifier(account: Account) -> String? {
        guard let info = "file_identifier".data(using: .utf8) else {
            fatalError("Unable to prepare `file_identifier` info")
        }

        guard let firstKey = keys.first else {
            fatalError("Unable to process `firstKey`")
        }

        // Perform HKDF with SHA-256
        let hkdfKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: firstKey, info: info, outputByteCount: 32)
        
        // Convert the HKDF output to a hex string
        let fileIdentifier = hkdfKey.withUnsafeBytes { rawBytes in
            rawBytes.map { String(format: "%02x", $0) }.joined()
        }
        
        var prefix = "\(account.name?.lowercased() ?? "")"
        
        // Hotfix for the Zashi->Zodl issue
        // The file needs to stay zashi-xxx named for now but account.name provides "zodl"
        if prefix == "zodl" {
            prefix = "zashi"
        }
        
        // Prepend the prefix to the result
        return "\(prefix)-metadata-\(fileIdentifier)"
    }
}
