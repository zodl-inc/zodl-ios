//
//  UserMetadataProviderInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-01-28.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var userMetadataProvider: UserMetadataProviderClient {
        get { self[UserMetadataProviderClient.self] }
        set { self[UserMetadataProviderClient.self] = newValue }
    }
}

@DependencyClient
struct UserMetadataProviderClient {
    // General
    var store: @Sendable (Account) throws -> Void
    var load: @Sendable (Account) throws -> Void
    var resetAccount: @Sendable (Account) throws -> Void
    var reset: @Sendable () throws -> Void

    // Bookmarking
    var isBookmarked: @Sendable (String) -> Bool = { _ in false }
    var toggleBookmarkFor: @Sendable (String) -> Void

    // Annotations
    var annotationFor: @Sendable (String) -> String? = { _ in nil }
    var addAnnotationFor: @Sendable (String, String) -> Void
    var deleteAnnotationFor: @Sendable (String) -> Void

    // Read
    var isRead: @Sendable (String, TimeInterval?) -> Bool = { _, _ in false }
    var readTx: @Sendable (String) -> Void

    // Swap Id
    var allSwaps: @Sendable () -> [UMSwapId] = { [] }
    var isSwapTransaction: @Sendable (String) -> Bool = { _ in false }
    var swapDetailsForTransaction: @Sendable (String) -> UMSwapId? = { _ in nil }
    var markTransactionAsSwapFor: @Sendable (String, String, Int64, String, String, String, Bool, String, String) -> Void
    var update: @Sendable (UMSwapId) -> Void

    // Last User SwapAssets
    var lastUsedAssetHistory: @Sendable () -> [String] = { [] }
    var addLastUsedSwapAsset: @Sendable (String) -> Void
}
