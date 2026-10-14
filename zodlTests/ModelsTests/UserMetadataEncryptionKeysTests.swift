//
//  UserMetadataEncryptionKeysTests.swift
//  zodlTests
//
//  MOB-2020. Covers caching an index-less (Ledger) account's user metadata encryption keys at
//  index 0 alongside a normally-derived account that is *also* at index 0 (Models/UserMetadataEncryptionKeys.swift,
//  Models/Account+EncryptionKeyIndex.swift). The seed is the public BIP-39 test vector already used
//  by MnemonicClientTests.swift -- not a wallet seed.
//

import Testing
import Foundation
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite struct UserMetadataEncryptionKeysTests {
    // Public BIP-39 test vector, copied verbatim from MnemonicClientTests.swift -- not a wallet seed.
    private let validPhrase =
        "still champion voice habit trend flight survey between bitter process artefact blind " +
        "carbon truly provide dizzy crush flush breeze blouse charge solid fish spread"

    @Test func ledgerAccountWithoutHDIndexCachesAndReturnsMetadataKeys() throws {
        let seed = try MnemonicClient.liveValue.toSeed(validPhrase)
        let ledgerAccount = account(hdAccountIndex: nil, name: "Ledger", keySource: "ledger", ufvk: nil)

        var ledgerKeys = UserMetadataEncryptionKeys.empty
        try ledgerKeys.cacheFor(seed: seed, account: ledgerAccount, network: .testnet)

        #expect(ledgerKeys.getCached(account: ledgerAccount) != nil)
        // Cached at index 0, the same stand-in `Account+EncryptionKeyIndex.swift` uses for the
        // shared address book key.
        #expect(ledgerKeys.keys[0] != nil)
    }

    @Test func ledgerAndZodlAccountsShareIndexZeroButOwnSeparateKeyValues() throws {
        let seed = try MnemonicClient.liveValue.toSeed(validPhrase)

        let ledgerAccount = account(hdAccountIndex: nil, name: "Ledger", keySource: "ledger", ufvk: nil)
        var ledgerKeys = UserMetadataEncryptionKeys.empty
        try ledgerKeys.cacheFor(seed: seed, account: ledgerAccount, network: .testnet)

        let zodlAccount = account(hdAccountIndex: Zip32AccountIndex(0), name: "Zodl", keySource: nil, ufvk: nil)
        var zodlKeys = UserMetadataEncryptionKeys.empty
        try zodlKeys.cacheFor(seed: seed, account: zodlAccount, network: .testnet)

        let cachedLedgerKeys = ledgerKeys.getCached(account: ledgerAccount)
        let cachedZodlKeys = zodlKeys.getCached(account: zodlAccount)

        // Both cached under the same integer key (0) -- but each in its own `UserMetadataEncryptionKeys`
        // value, which in production is its own keychain item (`accountMetadataFilename` is keyed by
        // account name, not by this index).
        #expect(ledgerKeys.keys[0] != nil)
        #expect(zodlKeys.keys[0] != nil)
        #expect(cachedLedgerKeys != nil)
        #expect(cachedZodlKeys != nil)

        // A Ledger account carrying a real UnifiedFullViewingKey derives distinct key material from
        // the Zodl account sharing the same index 0, because `cacheFor` folds `account.ufvk` into the
        // derivation (see the `derivePrivateUseMetadataKey(ufvk:privateUseSubject:)` call).
        let spendingKey = try DerivationToolClient.liveValue.deriveSpendingKey(seed, Zip32AccountIndex(1), .testnet)
        let ufvk = try DerivationToolClient.liveValue.deriveUnifiedFullViewingKey(spendingKey, .testnet)
        let ledgerAccountWithUFVK = account(hdAccountIndex: nil, name: "Ledger", keySource: "ledger", ufvk: ufvk)

        var ledgerWithUFVKKeys = UserMetadataEncryptionKeys.empty
        try ledgerWithUFVKKeys.cacheFor(seed: seed, account: ledgerAccountWithUFVK, network: .testnet)
        let cachedLedgerWithUFVKKeys = ledgerWithUFVKKeys.getCached(account: ledgerAccountWithUFVK)

        #expect(cachedLedgerWithUFVKKeys != nil)
        #expect(cachedLedgerWithUFVKKeys != cachedZodlKeys)
    }

    @Test func ledgerAccountFileIdentifierStartsWithLedgerMetadataPrefix() throws {
        let seed = try MnemonicClient.liveValue.toSeed(validPhrase)
        let ledgerAccount = account(hdAccountIndex: nil, name: "Ledger", keySource: "ledger", ufvk: nil)

        var ledgerKeys = UserMetadataEncryptionKeys.empty
        try ledgerKeys.cacheFor(seed: seed, account: ledgerAccount, network: .testnet)

        let identifier = ledgerKeys.getCached(account: ledgerAccount)?.fileIdentifier(account: ledgerAccount)

        #expect(identifier?.hasPrefix("ledger-metadata-") == true)
    }

    private func account(hdAccountIndex: Zip32AccountIndex?, name: String, keySource: String?, ufvk: UnifiedFullViewingKey?) -> Account {
        Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: name,
            keySource: keySource,
            seedFingerprint: nil,
            hdAccountIndex: hdAccountIndex,
            ufvk: ufvk,
            uivk: nil
        )
    }
}
