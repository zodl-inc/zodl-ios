//
//  EncryptionKeysTests.swift
//  zodlTests
//
//  Batch 2 — crypto. Covers AddressBookKey / UserMetadataKeys HKDF derivation + file identifiers
//  (Models/AddressBookEncryptionKeys.swift, Models/UserMetadataEncryptionKeys.swift).
//

import Testing
import Foundation
import CryptoKit
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite struct EncryptionKeysTests {
    // MARK: - AddressBookKey

    @Test func addressBookDeriveEncryptionKeyIsDeterministicAndSaltDependent() throws {
        let key = try addressBookKey(byte: 0x01)
        let salt = Data(repeating: 0x02, count: 32)
        let otherSalt = Data(repeating: 0x03, count: 32)
        #expect(bytes(key.deriveEncryptionKey(salt: salt)) == bytes(key.deriveEncryptionKey(salt: salt)))
        #expect(bytes(key.deriveEncryptionKey(salt: salt)) != bytes(key.deriveEncryptionKey(salt: otherSalt)))
    }

    @Test func addressBookFileIdentifierIsPrefixedHex() throws {
        let key = try addressBookKey(byte: 0x01)
        let id = try #require(key.fileIdentifier())
        #expect(id.hasPrefix("zashi-address-book-"))
        #expect(id.count == "zashi-address-book-".count + 64)
        #expect(key.fileIdentifier() == id) // deterministic
    }

    @Test func addressBookEncryptionKeysCodableRoundTrip() throws {
        let keys = AddressBookEncryptionKeys(keys: [0: try addressBookKey(byte: 0x07)])
        let data = try JSONEncoder().encode(keys)
        let decoded = try JSONDecoder().decode(AddressBookEncryptionKeys.self, from: data)
        #expect(decoded == keys)
    }

    @Test func addressBookEmptyHasNoKeys() {
        #expect(AddressBookEncryptionKeys.empty.keys.isEmpty)
    }

    // MARK: - UserMetadataKeys

    @Test func userMetadataEncryptionAndDecryptionKeysMatchForSingleKey() {
        let keys = UserMetadataKeys(privateKeys: [Data(repeating: 0x01, count: 32)])
        let salt = Data(repeating: 0x09, count: 32)
        let decryptionKeys = keys.deriveDecryptionKeys(salt: salt)
        #expect(decryptionKeys.count == 1)
        #expect(bytes(decryptionKeys[0]) == bytes(keys.deriveEncryptionKey(salt: salt)))
    }

    @Test func userMetadataDeriveDecryptionKeysOnePerKey() {
        let keys = UserMetadataKeys(privateKeys: [
            Data(repeating: 0x01, count: 32),
            Data(repeating: 0x02, count: 32)
        ])
        #expect(keys.deriveDecryptionKeys(salt: Data(repeating: 0x09, count: 32)).count == 2)
    }

    @Test func userMetadataFileIdentifierDomainSeparatesMetadataAndVoting() {
        let keys = UserMetadataKeys(privateKeys: [Data(repeating: 0x01, count: 32)])
        let account = account(name: "test")
        let metaId = keys.fileIdentifier(account: account)
        let voteId = keys.votingFileIdentifier(account: account)
        #expect(metaId?.hasPrefix("test-metadata-") == true)
        #expect(voteId?.hasPrefix("test-voting-") == true)
        #expect(metaId != voteId)
    }

    @Test func userMetadataFileIdentifierAppliesZodlToZashiHotfix() {
        let keys = UserMetadataKeys(privateKeys: [Data(repeating: 0x01, count: 32)])
        let id = keys.fileIdentifier(account: account(name: "zodl"))
        #expect(id?.hasPrefix("zashi-metadata-") == true)
    }

    @Test func userMetadataKeysCodableRoundTrip() throws {
        let keys = UserMetadataKeys(privateKeys: [Data(repeating: 0x05, count: 32)])
        let data = try JSONEncoder().encode(keys)
        let decoded = try JSONDecoder().decode(UserMetadataKeys.self, from: data)
        #expect(decoded == keys)
    }

    // MARK: - Helpers

    private func addressBookKey(byte: UInt8) throws -> AddressBookKey {
        let keyData = Data(repeating: byte, count: 32)
        let encoded = try JSONEncoder().encode(keyData)
        return try JSONDecoder().decode(AddressBookKey.self, from: encoded)
    }

    private func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private func account(name: String) -> Account {
        Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: name,
            keySource: "test",
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        )
    }
}
