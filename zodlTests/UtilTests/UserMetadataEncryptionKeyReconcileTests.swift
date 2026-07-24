//
//  UserMetadataEncryptionKeyReconcileTests.swift
//  zodlTests
//
//  Regression coverage for MOB-1450 (defense-in-depth): a User Metadata encryption key
//  derived from a previous wallet seed must never be reused by a wallet with a different
//  seed. The metadata file is synced through a shared iCloud container, so a stale key
//  would let a new wallet read and write another wallet's encrypted metadata. The cached
//  key must be reconciled against the current seed, and the keychain slot must be
//  overwritable.
//

import Foundation
import os
import Security
import Testing
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite("User metadata encryption key reconcile (MOB-1450)")
struct UserMetadataEncryptionKeyReconcileTests {
    // MARK: importUserMetadataEncryptionKeys upsert

    @Test func reimportingUserMetadataEncryptionKeysOverwritesPreviousKeys() throws {
        let client = Self.makeWalletStorageClient()
        let account = try Self.account()
        let keysA = Self.metadataKeys(byte: 0xAA)
        let keysB = Self.metadataKeys(byte: 0xBB)

        try client.importUserMetadataEncryptionKeys(keysA, account)
        // Re-importing different keys must overwrite, not throw `alreadyImported`.
        try client.importUserMetadataEncryptionKeys(keysB, account)

        #expect(try client.exportUserMetadataEncryptionKeys(account) == keysB)
    }

    // MARK: reconcile against the current seed

    @Test func reconcileOverwritesStaleKeysFromADifferentSeed() throws {
        let client = Self.makeWalletStorageClient()
        let account = try Self.account()
        let stale = Self.metadataKeys(byte: 0xAA)
        let current = Self.metadataKeys(byte: 0xBB)

        // A key left over from a previous wallet seed is present in the keychain.
        try client.importUserMetadataEncryptionKeys(stale, account)

        try client.reconcileUserMetadataEncryptionKeys(current, account: account)

        #expect(try client.exportUserMetadataEncryptionKeys(account) == current)
    }

    @Test func reconcileStoresKeysWhenNoneExist() throws {
        let client = Self.makeWalletStorageClient()
        let account = try Self.account()
        let current = Self.metadataKeys(byte: 0xCC)

        try client.reconcileUserMetadataEncryptionKeys(current, account: account)

        #expect(try client.exportUserMetadataEncryptionKeys(account) == current)
    }

    @Test func reconcileKeepsKeysThatAlreadyMatchTheCurrentSeed() throws {
        let client = Self.makeWalletStorageClient()
        let account = try Self.account()
        let current = Self.metadataKeys(byte: 0xDD)

        try client.importUserMetadataEncryptionKeys(current, account)
        try client.reconcileUserMetadataEncryptionKeys(current, account: account)

        #expect(try client.exportUserMetadataEncryptionKeys(account) == current)
    }

    @Test func reconcileNeverReplacesRealKeysWithAnEmptySet() throws {
        let client = Self.makeWalletStorageClient()
        let account = try Self.account()
        let current = Self.metadataKeys(byte: 0xEE)

        try client.importUserMetadataEncryptionKeys(current, account)
        // A failed derivation surfaces as an empty expected set. Reconcile must treat
        // it as "nothing to enforce", not as ground truth — otherwise a transient
        // derivation failure would erase the only copy of a real key.
        try client.reconcileUserMetadataEncryptionKeys(UserMetadataEncryptionKeys.empty, account: account)

        #expect(try client.exportUserMetadataEncryptionKeys(account) == current)
    }

    // MARK: Helpers

    static func makeWalletStorageClient() -> WalletStorageClient {
        WalletStorageClient.live(walletStorage: WalletStorage(secItem: InMemoryKeychain().makeClient()))
    }

    /// Builds a minimal SDK `Account` via its `Codable` form (the memberwise init is
    /// SDK-internal). Only `id` is required; `name` drives the keychain slot.
    static func account(name: String = "zashi") throws -> Account {
        let json = #"{"id":{"id":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]},"name":"\#(name)"}"#
        return try JSONDecoder().decode(Account.self, from: Data(json.utf8))
    }

    /// Deterministic single-account user-metadata keys (index 0, one 32-byte key), built via
    /// the model's in-memory initializers so no SDK seed derivation is needed.
    static func metadataKeys(byte: UInt8) -> UserMetadataEncryptionKeys {
        UserMetadataEncryptionKeys(keys: [0: UserMetadataKeys(privateKeys: [Data(repeating: byte, count: 32)])])
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
