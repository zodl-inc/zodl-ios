//
//  AddressBookEncryptionKeys.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-30-2024.
//

import Foundation
import CryptoKit
@preconcurrency import ZcashLightClientKit

/// Representation of the address book encryption keys
struct AddressBookEncryptionKeys: Codable, Equatable {
    /// Latest encryption version
    enum Constants {
        static let version = 1
    }
    
    // FIXME: Integer is not enough information to uniquely identify the key
    // FIXME: Don't hold keys in the memory when not necessary
    var keys: [Int: AddressBookKey]

    mutating func cacheFor(seed: [UInt8], account: Account, network: NetworkType) throws{
        guard let zip32AccountIndex = account.hdAccountIndex else {
            return
        }
        
        // FIXME: index is not enough - possible security issue - override of the keys
        keys[Int(zip32AccountIndex.index)] = try AddressBookKey(seed: seed, account: account, network: network)
    }

    func getCached(account: Account) -> AddressBookKey? {
        guard let zip32AccountIndex = account.hdAccountIndex else {
            return nil
        }

        return keys[Int(zip32AccountIndex.index)]
    }
}

extension AddressBookEncryptionKeys {
    static let empty = Self(
        keys: [:]
    )
}

struct AddressBookKey: Codable, Equatable, Redactable {
    let key: SymmetricKey

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        key = SymmetricKey(data: try container.decode(Data.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try key.withUnsafeBytes { key in
            let key = Data(key)
            try container.encode(key)
        }
    }

    /**
     * Derives the long-term key that can decrypt the given account's encrypted
     * address book.
     *
     * This requires access to the seed phrase. If the app has separate access
     * control requirements for the seed phrase and the address book, this key
     * should be cached in the app's keystore.
     */
    init(seed: [UInt8], account: Account, network: NetworkType) throws {
        let zip32AccountIndex: Zip32AccountIndex
        
        if let zip32AccountIndexUnwrapped = account.hdAccountIndex {
            zip32AccountIndex = zip32AccountIndexUnwrapped
        } else {
            zip32AccountIndex = Zip32AccountIndex(0)
        }

        self.key = try SymmetricKey(data: DerivationToolClient.live().deriveArbitraryAccountKey(
            [UInt8]("ZashiAddressBookEncryptionV1".utf8),
            seed,
            zip32AccountIndex,
            network
        ))
    }

    /**
     * Derives a one-time address book encryption key.
     *
     * At encryption time, the one-time property MUST be ensured by generating a
     * random 32-byte salt.
     */
    func deriveEncryptionKey(
        salt: Data
    ) -> SymmetricKey {
        assert(salt.count == 32)

        guard let info = "encryption_key".data(using: .utf8) else {
            fatalError("Unable to prepare `encryption_key` info")
        }
        
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: salt + info, outputByteCount: 32)
    }

    /**
     * Derives the filename that this key is able to decrypt.
     */
    func fileIdentifier() -> String? {
        guard let info = "file_identifier".data(using: .utf8) else {
            fatalError("Unable to prepare `file_identifier` info")
        }

        // Perform HKDF with SHA-256
        let hkdfKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: info, outputByteCount: 32)
        
        // Convert the HKDF output to a hex string
        let fileIdentifier = hkdfKey.withUnsafeBytes { rawBytes in
            rawBytes.map { String(format: "%02x", $0) }.joined()
        }
        
        // Prepend the prefix to the result
        return "zashi-address-book-\(fileIdentifier)"
    }
}
