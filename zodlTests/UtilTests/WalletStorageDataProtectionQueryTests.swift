//
//  WalletStorageDataProtectionQueryTests.swift
//  zodlTests
//
//  MOB-1485: with `useDataProtectionKeychain` set (macOS live wiring), every WalletStorage keychain
//  query must carry kSecUseDataProtectionKeychain so items live in the DP keychain (silent
//  signature-based access) instead of the legacy login keychain (password-dialog ACLs). With the
//  flag off (iOS default) the queries must stay byte-identical to today.
//

import Testing
import Foundation
import Security
@testable import zodl_internal

@Suite struct WalletStorageDataProtectionQueryTests {
    @Test func buildersOmitDataProtectionKeyByDefault() {
        let storage = WalletStorage(secItem: SecItemClient())
        #expect(storage.baseQuery(andKey: "k")[kSecUseDataProtectionKeychain as String] == nil)
        #expect(storage.mutationQuery(andKey: "k")[kSecUseDataProtectionKeychain as String] == nil)
        #expect(storage.restoreQuery(andKey: "k")[kSecUseDataProtectionKeychain as String] == nil)
    }

    @Test func buildersCarryDataProtectionKeyWhenEnabled() {
        var storage = WalletStorage(secItem: SecItemClient())
        storage.useDataProtectionKeychain = true
        #expect(storage.baseQuery(andKey: "k")[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(storage.mutationQuery(andKey: "k")[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(storage.restoreQuery(andKey: "k")[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

    @Test func keychainKeysScanCarriesDataProtectionKeyWhenEnabled() throws {
        final class Box: @unchecked Sendable { var query: [String: Any]? }
        let box = Box()
        var storage = WalletStorage(
            secItem: SecItemClient(copyMatching: { query, _ in
                box.query = (query as NSDictionary) as? [String: Any]
                return errSecItemNotFound
            })
        )
        storage.useDataProtectionKeychain = true
        _ = storage.keychainKeys(withPrefix: "x")
        let query = try #require(box.query)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }
}
