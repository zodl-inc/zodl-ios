//
//  WalletAccountTests.swift
//  zodlTests
//
//  Extended — pure logic. Covers WalletAccount.Vendor + vendor derivation (Models/WalletAccount.swift).
//

import Testing
import Foundation
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

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

    // MARK: - Ledger vendor

    @Test func ledgerVendorFlags() {
        #expect(!WalletAccount.Vendor.ledger.isDefault())
        #expect(WalletAccount.Vendor.ledger.isHWWallet())
    }

    @Test func vendorRawValuesStayKeystoneZcashLedger() {
        #expect(WalletAccount.Vendor.keystone.rawValue == 0)
        #expect(WalletAccount.Vendor.zcash.rawValue == 1)
        #expect(WalletAccount.Vendor.ledger.rawValue == 2)
    }

    @Test func ledgerVendorName() {
        #expect(WalletAccount.Vendor.ledger.name() == "Ledger")
    }

    @Test func initDerivesLedgerVendorFromKeySource() {
        let lowercased = WalletAccount(account(keySource: "ledger"))
        #expect(lowercased.vendor == .ledger)

        let uppercased = WalletAccount(account(keySource: "LEDGER"))
        #expect(uppercased.vendor == .ledger)
    }

    @Test func initDerivesKeystoneVendorFromKeySourceConstant() {
        let keystone = WalletAccount(account(keySource: "keystone"))
        #expect(keystone.vendor == .keystone)
    }

    @Test func initDerivesZcashVendorForNilOrUnrecognizedKeySource() {
        let nilKeySource = WalletAccount(account(keySource: nil))
        #expect(nilKeySource.vendor == .zcash)

        let unrecognized = WalletAccount(account(keySource: "not-a-real-vendor"))
        #expect(unrecognized.vendor == .zcash)
    }

    @Test func sortedByVendorOrdersZodlThenKeystoneThenLedger() {
        let ledger = WalletAccount(account(keySource: "ledger", idByte: 0x03))
        let keystone = WalletAccount(account(keySource: "keystone", idByte: 0x02))
        let zodl = WalletAccount(account(keySource: nil, idByte: 0x01))

        let sorted = WalletAccount.sortedByVendor([ledger, keystone, zodl])

        #expect(sorted.map(\.vendor) == [.zcash, .keystone, .ledger])
    }

    @Test func sortedByVendorIsStableForAccountsSharingAVendor() {
        let firstZodl = WalletAccount(account(keySource: nil, idByte: 0x01))
        let secondZodl = WalletAccount(account(keySource: nil, idByte: 0x02))
        let keystone = WalletAccount(account(keySource: "keystone", idByte: 0x03))

        // Deliberately not already sorted, so a non-stable sort could still coincidentally pass.
        let sorted = WalletAccount.sortedByVendor([secondZodl, keystone, firstZodl])

        #expect(sorted.map(\.id) == [secondZodl.id, firstZodl.id, keystone.id])
    }

    private func account(keySource: String?, idByte: UInt8 = 0x01) -> Account {
        Account(
            id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
            name: "name",
            keySource: keySource,
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        )
    }
}
