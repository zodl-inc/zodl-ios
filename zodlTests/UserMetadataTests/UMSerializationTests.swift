//
//  UMSerializationTests.swift
//  zodlTests
//
//  Batch 2 — persistence/crypto. Covers UserMetadata serialization primitives, v1/v2 migrations,
//  and the encrypt/decrypt round-trip (Dependencies/UserMetadataProvider/UMSerialization.swift + Migration/).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite struct UMSerializationTests {
    // MARK: - Primitives

    @Test func bytesToIntRoundTripsAndGuardsLength() {
        #expect(UserMetadata.bytesToInt(Serializer.intToBytes(123_456)) == 123_456)
        #expect(UserMetadata.bytesToInt(Serializer.intToBytes(-1)) == -1)
        #expect(UserMetadata.bytesToInt([0, 0, 0]) == nil)
    }

    @Test func subdataThrowsWhenOutOfBounds() throws {
        #expect(try UserMetadata.subdata(of: Data([1, 2, 3, 4]), in: 0..<2) == Data([1, 2]))
        #expect(throws: (any Error).self) {
            _ = try UserMetadata.subdata(of: Data([1, 2, 3]), in: 0..<5)
        }
    }

    // MARK: - v1 -> latest migration

    @Test func v1ToLatestCarriesOverFieldsAndAddsEmptySwaps() {
        let v1 = UserMetadataV1(
            version: 2,
            lastUpdated: 100,
            accountMetadata: UMAccountV1(
                bookmarked: [UMBookmark(txId: "t", lastUpdated: 1, isBookmarked: true)],
                annotations: [UMAnnotation(txId: "t", content: "note", lastUpdated: 2)],
                read: ["r"]
            )
        )
        let latest = UserMetadata.v1ToLatest(v1)
        #expect(latest.version == 3)
        #expect(latest.lastUpdated == 100)
        #expect(latest.accountMetadata.bookmarked.first?.isBookmarked == true)
        #expect(latest.accountMetadata.annotations.first?.content == "note")
        #expect(latest.accountMetadata.read == ["r"])
        #expect(latest.accountMetadata.swaps.swapIds.isEmpty)
        #expect(latest.accountMetadata.swaps.lastUsedAssetHistory.isEmpty)
    }

    // MARK: - v2 -> latest migration (hardcoded swap defaults)

    @Test func v2ToLatestHardcodesSwapDefaults() {
        let v2 = makeV2(provider: "near.btc.near", totalFees: 7, lastUsed: ["near.eth.usdc"], swapsLastUpdated: 9)
        let latest = UserMetadata.v2ToLatest(v2)
        #expect(latest.version == 3)
        #expect(latest.lastUpdated == 200)
        #expect(latest.accountMetadata.swaps.lastUsedAssetHistory == ["near.eth.usdc"])
        #expect(latest.accountMetadata.swaps.lastUpdated == 9)

        let swap = latest.accountMetadata.swaps.swapIds.first
        #expect(swap?.depositAddress == "deposit")
        #expect(swap?.toAsset == "near.btc.near")                   // toAsset = original provider
        #expect(swap?.fromAsset == SwapConstants.zecAssetIdOnNear)  // non-ZEC provider -> from ZEC
        #expect(swap?.exactInput == true)
        #expect(swap?.swapStatus == .completed)                     // status hardcoded to SUCCESS
        #expect(swap?.totalFees == 7)
    }

    @Test func v2ToLatestClearsFromAssetWhenProviderIsZec() {
        let v2 = makeV2(provider: SwapConstants.zecAssetIdOnNear, totalFees: 0, lastUsed: [], swapsLastUpdated: 0)
        let swap = UserMetadata.v2ToLatest(v2).accountMetadata.swaps.swapIds.first
        #expect(swap?.fromAsset.isEmpty == true)
        #expect(swap?.toAsset == SwapConstants.zecAssetIdOnNear)
    }

    // MARK: - Encrypt / decrypt round-trip (latest version)

    @Test func encryptDecryptRoundTripForLatestVersion() throws {
        let meta = UserMetadata(
            version: 3,
            lastUpdated: 1,
            accountMetadata: UMAccount(
                bookmarked: [],
                annotations: [],
                read: ["tx1", "tx2"],
                swaps: UMSwaps(swapIds: [], lastUsedAssetHistory: [], lastUpdated: 0)
            )
        )
        let testAccount = account()
        let keys = UserMetadataEncryptionKeys(keys: [0: UserMetadataKeys(privateKeys: [Data(repeating: 0x42, count: 32)])])

        try withDependencies {
            $0.walletStorage.exportUserMetadataEncryptionKeys = { _ in keys }
        } operation: {
            let encrypted = try UserMetadata.encryptUserMetadata(meta, account: testAccount)
            let (decrypted, migrated) = try UserMetadata.userMetadataFrom(encryptedData: encrypted, account: testAccount)
            #expect(!migrated)
            #expect(decrypted?.version == 3)
            #expect(decrypted?.accountMetadata.read == ["tx1", "tx2"])
        }
    }

    // MARK: - Helpers

    private func makeV2(provider: String, totalFees: Int64, lastUsed: [String], swapsLastUpdated: Int64) -> UserMetadataV2 {
        UserMetadataV2(
            version: 3,
            lastUpdated: 200,
            accountMetadata: UMAccountV2(
                bookmarked: [],
                annotations: [],
                read: [],
                swaps: UMSwapsV2(
                    swapIds: [UMSwapIdV2(depositAddress: "deposit", provider: provider, totalFees: totalFees, totalUSDFees: "1.0", lastUpdated: 5)],
                    lastUsedAssetHistory: lastUsed,
                    lastUpdated: swapsLastUpdated
                )
            )
        )
    }

    private func account() -> Account {
        Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: "test",
            keySource: "test",
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        )
    }
}
