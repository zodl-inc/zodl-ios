//
//  UMv2.swift
//  modules
//
//  Created by Lukáš Korba on 23.09.2025.
//

import Foundation
import CryptoKit

// The structure of Metadata in version 2, this exactly must be loaded and migrated
struct UserMetadataV2: Codable {
    enum Constants {
        static let version = 3
    }
    
    enum CodingKeys: CodingKey {
        case version
        case lastUpdated
        case accountMetadata
    }
    
    let version: Int
    let lastUpdated: Int64
    let accountMetadata: UMAccountV2
    
    init(version: Int, lastUpdated: Int64, accountMetadata: UMAccountV2) {
        self.version = version
        self.lastUpdated = lastUpdated
        self.accountMetadata = accountMetadata
    }
}

struct UMAccountV2: Codable {
    enum CodingKeys: CodingKey {
        case bookmarked
        case annotations
        case read
        case swaps
    }
    
    let bookmarked: [UMBookmark]
    let annotations: [UMAnnotation]
    let read: [String]
    let swaps: UMSwapsV2
}

struct UMSwapsV2: Codable {
    enum CodingKeys: CodingKey {
        case lastUsedAssetHistory
        case swapIds
        case lastUpdated
    }

    /// Collection of all swaps that happened in the wallet
    let swapIds: [UMSwapIdV2]
    /// Collection of 10 last SwapAssets
    let lastUsedAssetHistory: [String]
    let lastUpdated: Int64
    
    init(swapIds: [UMSwapIdV2], lastUsedAssetHistory: [String], lastUpdated: Int64) {
        self.swapIds = swapIds
        self.lastUsedAssetHistory = lastUsedAssetHistory
        self.lastUpdated = lastUpdated
    }
}
struct UMSwapIdV2: Codable, Equatable {
    enum CodingKeys: CodingKey {
        case depositAddress
        case provider
        case totalFees
        case totalUSDFees
        case lastUpdated
    }
    
    let depositAddress: String
    let provider: String
    let totalFees: Int64
    let totalUSDFees: String
    let lastUpdated: Int64
}

extension UserMetadata {
    // Changes:
    /// `provider` Provider at the time of version 1 was Near only so I can hardcode the value.
    /// `fromAsset` up to this point before swap to ZEC has been released, all fromAsset are from ZEC so hardcoded
    /// `toAsset` is a provider value in version 1, example: `near.btc.near` <provider>.<token>.<chain>
    /// `exactInput` we don't know from version 2 data if the swap was swap or crosspay, hardcoded all to swap
    /// `status` we don't know from version 2 data in what status the swap ended, hardcoded to completed
    static func v2ToLatest(_ userMetadata: UserMetadataV2) -> UserMetadata {
        let umSwaps = UMSwaps(
            swapIds: userMetadata.accountMetadata.swaps.swapIds.map {
                UMSwapId(
                    depositAddress: $0.depositAddress,
                    provider: String(localizable: .swapNearProvider),
                    totalFees: $0.totalFees,
                    totalUSDFees: $0.totalUSDFees,
                    lastUpdated: $0.lastUpdated,
                    fromAsset: $0.provider == SwapConstants.zecAssetIdOnNear ? "" : SwapConstants.zecAssetIdOnNear,
                    toAsset: $0.provider,
                    exactInput: true,
                    status: SwapConstants.success,
                    amountOutFormatted: ""
                )
            },
            lastUsedAssetHistory: userMetadata.accountMetadata.swaps.lastUsedAssetHistory,
            lastUpdated: userMetadata.accountMetadata.swaps.lastUpdated
        )
        
        return UserMetadata(
            version: UserMetadata.Constants.version,
            lastUpdated: userMetadata.lastUpdated,
            accountMetadata:
                UMAccount(
                    bookmarked: userMetadata.accountMetadata.bookmarked,
                    annotations: userMetadata.accountMetadata.annotations,
                    read: userMetadata.accountMetadata.read,
                    swaps: umSwaps
                )
        )
    }
}
