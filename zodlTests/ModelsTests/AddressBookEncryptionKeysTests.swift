//
//  AddressBookEncryptionKeysTests.swift
//  zodlTests
//
//  MOB-2020. Covers caching an index-less (Ledger) account's address book encryption key at index 0
//  (Models/AddressBookEncryptionKeys.swift, Models/Account+EncryptionKeyIndex.swift). The address
//  book is shared by design, so the Ledger account's key must equal the key an explicit index-0
//  account derives from the same seed. The seed is the public BIP-39 test vector already used by
//  MnemonicClientTests.swift -- not a wallet seed.
//

import Testing
import Foundation
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite struct AddressBookEncryptionKeysTests {
    // Public BIP-39 test vector, copied verbatim from MnemonicClientTests.swift -- not a wallet seed.
    private let validPhrase =
        "still champion voice habit trend flight survey between bitter process artefact blind " +
        "carbon truly provide dizzy crush flush breeze blouse charge solid fish spread"

    @Test func ledgerAccountWithoutHDIndexCachesAndReturnsTheAddressBookKey() throws {
        let seed = try MnemonicClient.liveValue.toSeed(validPhrase)
        let ledgerAccount = account(hdAccountIndex: nil, name: "Ledger", keySource: "ledger")

        var keys = AddressBookEncryptionKeys.empty
        try keys.cacheFor(seed: seed, account: ledgerAccount, network: .testnet)

        #expect(keys.getCached(account: ledgerAccount) != nil)
    }

    @Test func ledgerAccountKeyEqualsAnIndexZeroAccountKeyFromTheSameSeedBecauseTheAddressBookIsShared() throws {
        let seed = try MnemonicClient.liveValue.toSeed(validPhrase)

        let ledgerAccount = account(hdAccountIndex: nil, name: "Ledger", keySource: "ledger")
        var ledgerKeys = AddressBookEncryptionKeys.empty
        try ledgerKeys.cacheFor(seed: seed, account: ledgerAccount, network: .testnet)

        let zodlAccount = account(hdAccountIndex: Zip32AccountIndex(0), name: "Zodl", keySource: nil)
        var zodlKeys = AddressBookEncryptionKeys.empty
        try zodlKeys.cacheFor(seed: seed, account: zodlAccount, network: .testnet)

        let cachedLedgerKey = ledgerKeys.getCached(account: ledgerAccount)
        let cachedZodlKey = zodlKeys.getCached(account: zodlAccount)

        #expect(cachedLedgerKey != nil)
        #expect(cachedLedgerKey == cachedZodlKey)
    }

    private func account(hdAccountIndex: Zip32AccountIndex?, name: String, keySource: String?) -> Account {
        Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: name,
            keySource: keySource,
            seedFingerprint: nil,
            hdAccountIndex: hdAccountIndex,
            ufvk: nil,
            uivk: nil
        )
    }
}
