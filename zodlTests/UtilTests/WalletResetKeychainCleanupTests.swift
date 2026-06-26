//
//  WalletResetKeychainCleanupTests.swift
//  zodlTests
//
//  Regression coverage: `WalletStorage.resetZashi()` must delete the per-account
//  metadata-encryption-key and shielding-reminder keychain entries for the CURRENT
//  account name. Those keys are stored under "<base>_<accountName>", and the account
//  name comes from a localizable string ("Zodl" after the ZODL rebrand). A hardcoded
//  "_zashi" suffix in resetZashi orphaned the live key, leaking a stale metadata
//  encryption key into the next wallet — the same class of bug as MOB-1450.
//

import Foundation
import os
import Security
import Testing
@testable import zodl_internal

@Suite("Wallet reset keychain cleanup")
struct WalletResetKeychainCleanupTests {
    @Test func resetZashiDeletesCurrentAccountMetadataAndShieldingKeys() throws {
        let keychain = EnumerableInMemoryKeychain()
        let storage = WalletStorage(secItem: keychain.makeClient())

        let zashiName = WalletAccount.Vendor.zcash.name()       // "Zodl"
        let keystoneName = WalletAccount.Vendor.keystone.name() // "Keystone"

        // Metadata encryption keys live at `accountMetadataFilename` = "<base>_<name.lowercased()>".
        // Seed the entries exactly as production stores them for both vendors.
        let metadataZashi = "\(WalletStorage.Constants.zcashStoredUserMetadataEncryptionKeys)_\(zashiName.lowercased())"
        let metadataKeystone = "\(WalletStorage.Constants.zcashStoredUserMetadataEncryptionKeys)_\(keystoneName.lowercased())"
        keychain.seed(service: metadataZashi, data: Data([0x01]))
        keychain.seed(service: metadataKeystone, data: Data([0x02]))

        // Shielding reminders are written via the real API; `SmartBannerStore` passes
        // `vendor.name()` as-is (NOT lowercased), e.g. "zcashStoredShieldingReminder_Zodl".
        try storage.importShieldingReminder(ReminedMeTimestamp(timestamp: 0, occurence: 1), accountName: zashiName)
        try storage.importShieldingReminder(ReminedMeTimestamp(timestamp: 0, occurence: 1), accountName: keystoneName)

        try storage.resetZashi()

        // The seed-derived metadata encryption key must NOT survive a wallet reset
        // (a surviving key leaks into the next wallet — MOB-1450 class).
        #expect(!keychain.contains(service: metadataZashi))
        #expect(!keychain.contains(service: metadataKeystone))
        // Shielding reminders for every account must be cleared too.
        #expect(storage.exportShieldingReminder(accountName: zashiName) == nil)
        #expect(storage.exportShieldingReminder(accountName: keystoneName) == nil)
    }
}

/// In-memory `SecItemClient` backing keyed by `kSecAttrService`. Supports both single-item
/// lookups and the `kSecMatchLimitAll` enumeration that `WalletStorage.keychainKeys(withPrefix:)`
/// relies on, so `resetZashi`'s prefix-based wipe is exercised for real. Exposes `seed`/`contains`
/// for assertions.
private final class EnumerableInMemoryKeychain: Sendable {
    private let store = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    func seed(service: String, data: Data) {
        store.withLock { $0[service] = data }
    }

    func contains(service: String) -> Bool {
        store.withLock { $0[service] != nil }
    }

    func makeClient() -> SecItemClient {
        SecItemClient(
            copyMatching: { query, result in
                let dict = query as? [String: Any]
                // Enumeration query (kSecMatchLimitAll) → return every service as attributes.
                if let limit = dict?[kSecMatchLimit as String] as? String, limit == (kSecMatchLimitAll as String) {
                    let services = self.store.withLock { Array($0.keys) }
                    guard !services.isEmpty else { return errSecItemNotFound }
                    let items: [[String: Any]] = services.map { [kSecAttrService as String: $0] }
                    result = items as AnyObject
                    return errSecSuccess
                }
                // Single-item lookup by service.
                guard let service = EnumerableInMemoryKeychain.service(dict) else { return errSecParam }
                guard let data = self.store.withLock({ $0[service] }) else { return errSecItemNotFound }
                result = data as AnyObject
                return errSecSuccess
            },
            add: { query, _ in
                guard let dict = query as? [String: Any],
                      let service = EnumerableInMemoryKeychain.service(dict),
                      let data = dict[kSecValueData as String] as? Data else { return errSecParam }
                return self.store.withLock { items in
                    guard items[service] == nil else { return errSecDuplicateItem }
                    items[service] = data
                    return errSecSuccess
                }
            },
            update: { query, attributes in
                guard let service = EnumerableInMemoryKeychain.service(query as? [String: Any]),
                      let data = (attributes as? [String: Any])?[kSecValueData as String] as? Data else { return errSecParam }
                return self.store.withLock { items in
                    guard items[service] != nil else { return errSecItemNotFound }
                    items[service] = data
                    return errSecSuccess
                }
            },
            delete: { query in
                guard let service = EnumerableInMemoryKeychain.service(query as? [String: Any]) else { return errSecParam }
                return self.store.withLock { items in
                    guard items[service] != nil else { return errSecItemNotFound }
                    items[service] = nil
                    return errSecSuccess
                }
            }
        )
    }

    private static func service(_ dict: [String: Any]?) -> String? {
        dict?[kSecAttrService as String] as? String
    }
}
