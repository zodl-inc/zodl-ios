//
//  AddressBookEncryptionKeyReconcileTests.swift
//  zodlTests
//
//  Regression coverage for MOB-1450: an Address Book encryption key derived from a
//  previous wallet seed must never be reused by a wallet with a different seed. The
//  cached key is the source of contact decryption, so it must always be reconciled
//  against the current seed (and the keychain slot must be overwritable).
//

import Foundation
import os
import Security
import Testing
@testable import zodl_internal

@Suite("Address Book encryption key reconcile (MOB-1450)")
struct AddressBookEncryptionKeyReconcileTests {
    // MARK: importAddressBookEncryptionKeys upsert

    @Test func reimportingAddressBookEncryptionKeysOverwritesPreviousKeys() throws {
        let client = Self.makeWalletStorageClient()
        let keysA = try Self.addressBookKeys(byte: 0xAA)
        let keysB = try Self.addressBookKeys(byte: 0xBB)

        try client.importAddressBookEncryptionKeys(keysA)
        // Re-importing different keys must overwrite, not throw `alreadyImported`.
        try client.importAddressBookEncryptionKeys(keysB)

        #expect(try client.exportAddressBookEncryptionKeys() == keysB)
    }

    // MARK: reconcile against the current seed

    @Test func reconcileOverwritesStaleKeysFromADifferentSeed() throws {
        let client = Self.makeWalletStorageClient()
        let stale = try Self.addressBookKeys(byte: 0xAA)
        let current = try Self.addressBookKeys(byte: 0xBB)

        // A key left over from a previous wallet seed is present in the keychain.
        try client.importAddressBookEncryptionKeys(stale)

        try client.reconcileAddressBookEncryptionKeys(current)

        #expect(try client.exportAddressBookEncryptionKeys() == current)
    }

    @Test func reconcileStoresKeysWhenNoneExist() throws {
        let client = Self.makeWalletStorageClient()
        let current = try Self.addressBookKeys(byte: 0xCC)

        try client.reconcileAddressBookEncryptionKeys(current)

        #expect(try client.exportAddressBookEncryptionKeys() == current)
    }

    @Test func reconcileKeepsKeysThatAlreadyMatchTheCurrentSeed() throws {
        let client = Self.makeWalletStorageClient()
        let current = try Self.addressBookKeys(byte: 0xDD)

        try client.importAddressBookEncryptionKeys(current)
        try client.reconcileAddressBookEncryptionKeys(current)

        #expect(try client.exportAddressBookEncryptionKeys() == current)
    }

    // MARK: Helpers

    static func makeWalletStorageClient() -> WalletStorageClient {
        WalletStorageClient.live(walletStorage: WalletStorage(secItem: InMemoryKeychain().makeClient()))
    }

    /// Builds an `AddressBookEncryptionKeys` (single account, index 0) with a deterministic
    /// 32-byte key via the model's `Codable` form, so no SDK seed derivation is needed.
    static func addressBookKeys(byte: UInt8) throws -> AddressBookEncryptionKeys {
        let raw = Data(repeating: byte, count: 32)
        let json = try JSONSerialization.data(withJSONObject: ["keys": ["0": raw.base64EncodedString()]])
        return try JSONDecoder().decode(AddressBookEncryptionKeys.self, from: json)
    }
}

/// Minimal in-memory keychain backing for `SecItemClient`, keyed by `kSecAttrService`.
/// Mirrors the real add/update/copyMatching/delete semantics (duplicate detection,
/// not-found) so `WalletStorage` upsert/read behaviour is exercised for real.
private final class InMemoryKeychain: Sendable {
    private let store = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    func makeClient() -> SecItemClient {
        SecItemClient(
            copyMatching: { query, result in
                guard let service = InMemoryKeychain.service(query) else { return errSecParam }
                guard let data = self.store.withLock({ $0[service] }) else { return errSecItemNotFound }
                result = data as AnyObject
                return errSecSuccess
            },
            add: { query, _ in
                guard let service = InMemoryKeychain.service(query),
                      let data = InMemoryKeychain.value(from: query) else { return errSecParam }
                return self.store.withLock { items in
                    guard items[service] == nil else { return errSecDuplicateItem }
                    items[service] = data
                    return errSecSuccess
                }
            },
            update: { query, attributes in
                guard let service = InMemoryKeychain.service(query),
                      let data = InMemoryKeychain.value(from: attributes) else { return errSecParam }
                return self.store.withLock { items in
                    guard items[service] != nil else { return errSecItemNotFound }
                    items[service] = data
                    return errSecSuccess
                }
            },
            delete: { query in
                guard let service = InMemoryKeychain.service(query) else { return errSecParam }
                self.store.withLock { $0[service] = nil }
                return errSecSuccess
            }
        )
    }

    private static func service(_ query: CFDictionary) -> String? {
        (query as? [String: Any])?[kSecAttrService as String] as? String
    }

    private static func value(from dict: CFDictionary) -> Data? {
        (dict as? [String: Any])?[kSecValueData as String] as? Data
    }
}
