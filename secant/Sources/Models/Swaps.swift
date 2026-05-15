//
//  Swaps.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-09-25.
//

import Foundation

enum SwapConstants {
    static let pendingDeposit = "PENDING_DEPOSIT"
    static let incompleteDeposit = "INCOMPLETE_DEPOSIT"
    static let processing = "PROCESSING"
    static let success = "SUCCESS"
    static let failed = "FAILED"
    static let refunded = "REFUNDED"
    static let expired = "EXPIRED"
    
    static let zecAssetIdOnNear = "near.zec.zec"
}

struct UserMetadata: Codable {
    enum Constants {
        static let version = 3
        static let versionKey = "version"
    }
    
    enum CodingKeys: CodingKey {
        case version
        case lastUpdated
        case accountMetadata
    }
    
    let version: Int
    let lastUpdated: Int64
    let accountMetadata: UMAccount
    
    init(version: Int, lastUpdated: Int64, accountMetadata: UMAccount) {
        self.version = version
        self.lastUpdated = lastUpdated
        self.accountMetadata = accountMetadata
    }
}

struct UMAccount: Codable {
    enum CodingKeys: CodingKey {
        case bookmarked
        case annotations
        case read
        case swaps
    }
    
    let bookmarked: [UMBookmark]
    let annotations: [UMAnnotation]
    let read: [String]
    let swaps: UMSwaps
    
    init(bookmarked: [UMBookmark], annotations: [UMAnnotation], read: [String], swaps: UMSwaps) {
        self.bookmarked = bookmarked
        self.annotations = annotations
        self.read = read
        self.swaps = swaps
    }
}

struct UMBookmark: Codable {
    enum CodingKeys: CodingKey {
        case txId
        case lastUpdated
        case isBookmarked
    }
    
    let txId: String
    let lastUpdated: Int64
    var isBookmarked: Bool
    
    init(txId: String, lastUpdated: Int64, isBookmarked: Bool) {
        self.txId = txId
        self.lastUpdated = lastUpdated
        self.isBookmarked = isBookmarked
    }
}

struct UMAnnotation: Codable {
    enum CodingKeys: CodingKey {
        case txId
        case content
        case lastUpdated
    }
    
    let txId: String
    let content: String?
    let lastUpdated: Int64
    
    init(txId: String, content: String?, lastUpdated: Int64) {
        self.txId = txId
        self.content = content
        self.lastUpdated = lastUpdated
    }
}

struct UMSwaps: Codable {
    enum CodingKeys: CodingKey {
        case lastUsedAssetHistory
        case swapIds
        case lastUpdated
    }

    /// Collection of all swaps that happened in the wallet
    let swapIds: [UMSwapId]
    /// Collection of 10 last SwapAssets
    let lastUsedAssetHistory: [String]
    let lastUpdated: Int64
    
    init(swapIds: [UMSwapId], lastUsedAssetHistory: [String], lastUpdated: Int64) {
        self.swapIds = swapIds
        self.lastUsedAssetHistory = lastUsedAssetHistory
        self.lastUpdated = lastUpdated
    }
}

struct UMSwapId: Codable, Equatable {
    enum CodingKeys: CodingKey {
        case depositAddress
        case provider
        case totalFees
        case totalUSDFees
        case lastUpdated
        case fromAsset
        case toAsset
        case exactInput
        case status
        case amountOutFormatted
    }
    
    enum SwapStatus: Equatable {
        case completed
        case expired
        case failed
        case pending
        case incomplete
        case refunded
    }
    
    var depositAddress: String
    var provider: String
    var totalFees: Int64
    var totalUSDFees: String
    var lastUpdated: Int64
    var fromAsset: String
    var toAsset: String
    var exactInput: Bool
    var status: String
    var amountOutFormatted: String

    var swapStatus: SwapStatus {
        if status == SwapConstants.failed {
            return .failed
        }

        if status == SwapConstants.refunded {
            return .refunded
        }

        if status == SwapConstants.expired {
            return .expired
        }

        if status == SwapConstants.success {
            return .completed
        }

        if status == SwapConstants.incompleteDeposit {
            return .incomplete
        }

        if status == SwapConstants.pendingDeposit || status == SwapConstants.processing {
            return .pending
        }
        
        return .pending
    }
    
    init(
        depositAddress: String,
        provider: String,
        totalFees: Int64,
        totalUSDFees: String,
        lastUpdated: Int64,
        fromAsset: String,
        toAsset: String,
        exactInput: Bool,
        status: String,
        amountOutFormatted: String
    ) {
        self.depositAddress = depositAddress
        self.provider = provider
        self.totalFees = totalFees
        self.totalUSDFees = totalUSDFees
        self.lastUpdated = lastUpdated
        self.fromAsset = fromAsset
        self.toAsset = toAsset
        self.exactInput = exactInput
        self.status = status
        self.amountOutFormatted = amountOutFormatted
    }
}
