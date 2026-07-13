//
//  WalletStoragePureTests.swift
//  zodlTests
//
//  Batch 4 — dependency logic. Covers WalletStorage pure key-derivation helpers + SwapAPIAccess Codable
//  (Dependencies/WalletStorage/WalletStorage.swift).
//  NOTE: the keychain import/export round-trip is deferred (needs a stateful in-memory SecItem fake).
//

import Testing
import Foundation
import Security
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct WalletStoragePureTests {
    @Test func votingHotkeyKeyEncodesAccountUUIDAsHex() {
        let accountId = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))
        let key = WalletStorage.Constants.zcashStoredVotingHotkey(accountId: accountId)
        #expect(key == "zcashStoredVotingHotkey_" + String(repeating: "01", count: 16))
    }

    @Test func votingHotkeyKeyDiffersPerAccount() {
        let a = WalletStorage.Constants.zcashStoredVotingHotkey(accountId: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)))
        let b = WalletStorage.Constants.zcashStoredVotingHotkey(accountId: AccountUUID(id: [UInt8](repeating: 0x02, count: 16)))
        #expect(a != b)
    }

    @Test func accountMetadataFilenameUsesLowercasedAccountName() {
        #expect(WalletStorage.Constants.accountMetadataFilename(account: account(name: "Zashi")) == "zcashStoredMetadataEncryptionKeys_zashi")
    }

    @Test func shieldingReminderKeyIncludesAccountName() {
        #expect(WalletStorage.Constants.zcashStoredShieldingReminder(accountName: "main") == "zcashStoredShieldingReminder_main")
    }

    @Test(arguments: [WalletStorage.SwapAPIAccess.protected, .direct])
    func swapAPIAccessCodableRoundTrip(_ value: WalletStorage.SwapAPIAccess) throws {
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(WalletStorage.SwapAPIAccess.self, from: data) == value)
    }

    @Test func deleteDataMatchQueryOmitsAccessibilityAttribute() throws {
        // Regression (macOS reset bug): including kSecAttrAccessible in a SecItemDelete query makes it match
        // nothing on the macOS login keychain, so resetZashi() silently left every keychain item behind and
        // surfaced "Wallet deletion failed — Keychain keys are still present". The delete match query must
        // carry only the identity attributes (service, account, class), never the accessibility class.
        final class Box: @unchecked Sendable { var query: [String: Any]? }
        let box = Box()
        let storage = WalletStorage(
            secItem: SecItemClient(delete: { query in
                box.query = query as? [String: Any]
                return errSecSuccess
            })
        )

        try storage.deleteData(forKey: WalletStorage.Constants.zcashStoredWalletSeed)

        let query = try #require(box.query)
        #expect(query[kSecAttrAccessible as String] == nil)
        #expect(query[kSecAttrService as String] as? String == WalletStorage.Constants.zcashStoredWalletSeed)
        #expect(query[kSecClass as String] != nil)
    }

    @Test func deleteDataMatchQueryDropsEmptyAccountButKeepsRealOne() throws {
        // Regression (macOS reset → stuck wallet, confirmed on a live wallet): an item ADDED with
        // account "" persists on the macOS login keychain with a NULL account, and a SecItemDelete
        // carrying account "" then matches it on NOTHING — so the SE-wrapped seed survived resetZashi()
        // ("Keychain keys are still present") and the half-wiped wallet hung at the launch logo.
        // `security delete-generic-password -s zcashStoredWalletSeed` (service only) removed exactly that
        // item, proving the empty account was the blocker. The delete/update match query must therefore
        // drop account when empty (match by service alone) while still carrying a real per-account value.
        final class Box: @unchecked Sendable { var query: [String: Any]? }

        // Empty account → no account attribute in the match query (single-instance items).
        let empty = Box()
        let s1 = WalletStorage(secItem: SecItemClient(delete: { q in
            empty.query = q as? [String: Any]
            return errSecSuccess
        }))
        try s1.deleteData(forKey: WalletStorage.Constants.zcashStoredWalletSeed)
        #expect(try #require(empty.query)[kSecAttrAccount as String] == nil)

        // Real per-account value → preserved (so per-account items still target the right row).
        let real = Box()
        let s2 = WalletStorage(secItem: SecItemClient(delete: { q in
            real.query = q as? [String: Any]
            return errSecSuccess
        }))
        try s2.deleteData(forKey: WalletStorage.Constants.zcashStoredWalletSeed, account: "acc-1")
        #expect(try #require(real.query)[kSecAttrAccount as String] as? String == "acc-1")
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
