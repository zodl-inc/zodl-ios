//
//  WalletAccountTests.swift
//  zodlTests
//
//  Extended — pure logic. Covers WalletAccount.Vendor + vendor derivation (Models/WalletAccount.swift).
//

import Testing
import Foundation
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite struct WalletAccountTests {
    @Test func vendorFlags() {
        #expect(WalletAccount.Vendor.zcash.isDefault())
        #expect(!WalletAccount.Vendor.keystone.isDefault())
        #expect(WalletAccount.Vendor.keystone.isHWWallet())
        #expect(!WalletAccount.Vendor.zcash.isHWWallet())
    }

    @Test func vendorRawValues() {
        #expect(WalletAccount.Vendor.keystone.rawValue == 0)
        #expect(WalletAccount.Vendor.zcash.rawValue == 1)
    }

    @Test(arguments: [WalletAccount.Vendor.keystone, .zcash])
    func vendorCodableRoundTrip(_ vendor: WalletAccount.Vendor) throws {
        let data = try JSONEncoder().encode(vendor)
        #expect(try JSONDecoder().decode(WalletAccount.Vendor.self, from: data) == vendor)
    }

    @Test func vendorNames() {
        #expect(WalletAccount.Vendor.keystone.name() == String(localizable: .accountsKeystone))
        #expect(WalletAccount.Vendor.zcash.name() == String(localizable: .accountsZashi))
    }

    @Test func initDerivesVendorFromKeySource() {
        let keystone = WalletAccount(account(keySource: String(localizable: .accountsKeystone).lowercased()))
        #expect(keystone.vendor == .keystone)
        let zashi = WalletAccount(account(keySource: "zashi"))
        #expect(zashi.vendor == .zcash)
    }

    private func account(keySource: String) -> Account {
        Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: "name",
            keySource: keySource,
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        )
    }
}
