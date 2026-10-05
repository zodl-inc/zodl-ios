//
//  WalletAccountStashTests.swift
//  zodlTests
//
//  Covers the pure merge helper behind rotation-stash preservation across account reloads
//  (MOB-1859, Models/WalletAccount+Stash.swift `WalletAccount.mergingPrivateUAStash`) and the
//  shared receiver-set rule (`PrivateUAStash.receivers`).
//

import Testing
import Foundation
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite struct WalletAccountStashTests {
    private enum Const {
        /// Sentinel UA built through the SDK's internal `init(validatedEncoding:networkType:)`
        /// (reachable via `@testable import ZcashLightClientKit`) — the merge logic treats
        /// addresses as opaque tokens, so no FFI validation is involved.
        static let existingStashUA = UnifiedAddress(validatedEncoding: "u1modelstashfixture", networkType: .mainnet)
    }

    // MARK: - mergingPrivateUAStash

    @Test func mergeKeepsExistingStashByMatchingAccountId() {
        var withStash = account(idByte: 0x01, vendor: .zcash)
        withStash.nextPrivateUA = Const.existingStashUA
        // As `walletAccounts()` returns it post-MOB-1859: same account, nil stash.
        let freshlyLoaded = account(idByte: 0x01, vendor: .zcash)

        let merged = WalletAccount.mergingPrivateUAStash(from: [withStash], into: [freshlyLoaded])

        #expect(merged.count == 1)
        #expect(merged.first?.nextPrivateUA == Const.existingStashUA)
    }

    @Test func mergeLeavesAnAccountWithNoPriorEntryNil() {
        // Simulates a freshly imported account: nothing in `current` matches its id.
        let newlyImported = account(idByte: 0x02, vendor: .keystone)

        let merged = WalletAccount.mergingPrivateUAStash(from: [], into: [newlyImported])

        #expect(merged.count == 1)
        #expect(merged.first?.nextPrivateUA == nil)
    }

    @Test func mergeLeavesAnAccountNilWhenThePriorEntryHadNoStashEither() {
        let withoutStash = account(idByte: 0x03, vendor: .zcash)
        let freshlyLoaded = account(idByte: 0x03, vendor: .zcash)

        let merged = WalletAccount.mergingPrivateUAStash(from: [withoutStash], into: [freshlyLoaded])

        #expect(merged.first?.nextPrivateUA == nil)
    }

    @Test func mergeOnlyTouchesTheMatchingAccountInAMultiAccountList() {
        var accountAWithStash = account(idByte: 0x01, vendor: .zcash)
        accountAWithStash.nextPrivateUA = Const.existingStashUA
        let accountBWithoutStash = account(idByte: 0x02, vendor: .keystone)

        let freshlyLoaded = [account(idByte: 0x01, vendor: .zcash), account(idByte: 0x02, vendor: .keystone)]
        let merged = WalletAccount.mergingPrivateUAStash(from: [accountAWithStash, accountBWithoutStash], into: freshlyLoaded)

        #expect(merged.first { $0.id == accountAWithStash.id }?.nextPrivateUA == Const.existingStashUA)
        #expect(merged.first { $0.id == accountBWithoutStash.id }?.nextPrivateUA == nil)
    }

    // MARK: - PrivateUAStash.receivers

    @Test func receiversRuleIsOrchardOnlyForKeystoneAndSaplingOrchardForEveryoneElse() {
        let keystoneAccount = account(idByte: 0x04, vendor: .keystone)
        let zcashAccount = account(idByte: 0x05, vendor: .zcash)

        #expect(PrivateUAStash.receivers(for: keystoneAccount) == [.orchard])
        #expect(PrivateUAStash.receivers(for: zcashAccount) == [.sapling, .orchard])
    }

    // MARK: - Helpers

    private func account(idByte: UInt8, vendor: WalletAccount.Vendor) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Test",
                keySource: vendor == .keystone ? String(localizable: .accountsKeystone).lowercased() : "zashi",
                seedFingerprint: [UInt8](repeating: 0x02, count: 32),
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }
}
