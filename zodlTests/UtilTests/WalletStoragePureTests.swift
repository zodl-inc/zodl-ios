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
@testable @preconcurrency import ZODLSwiftWalletSDK
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
