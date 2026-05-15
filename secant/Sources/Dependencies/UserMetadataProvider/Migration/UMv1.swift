//
//  UMv1.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-06-23.
//

import Foundation
import CryptoKit

// The structure of Metadata in version 1, this exactly must be loaded and migrated
struct UserMetadataV1: Codable {
    enum Constants {
        static let version = 2
    }
    
    enum CodingKeys: CodingKey {
        case version
        case lastUpdated
        case accountMetadata
    }
    
    let version: Int
    let lastUpdated: Int64
    let accountMetadata: UMAccountV1
    
    init(version: Int, lastUpdated: Int64, accountMetadata: UMAccountV1) {
        self.version = version
        self.lastUpdated = lastUpdated
        self.accountMetadata = accountMetadata
    }
}

struct UMAccountV1: Codable {
    enum CodingKeys: CodingKey {
        case bookmarked
        case annotations
        case read
    }
    
    let bookmarked: [UMBookmark]
    let annotations: [UMAnnotation]
    let read: [String]
}

extension UserMetadata {
    static func v1ToLatest(_ userMetadataV1: UserMetadataV1) -> UserMetadata {
        UserMetadata(
            version: UserMetadata.Constants.version,
            lastUpdated: userMetadataV1.lastUpdated,
            accountMetadata:
                UMAccount(
                    bookmarked: userMetadataV1.accountMetadata.bookmarked,
                    annotations: userMetadataV1.accountMetadata.annotations,
                    read: userMetadataV1.accountMetadata.read,
                    swaps: UMSwaps(
                        swapIds: [],
                        lastUsedAssetHistory: [],
                        lastUpdated: Int64(Date().timeIntervalSince1970 * 1000)
                    )
                )
        )
    }
}
