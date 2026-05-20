//
//  UserMetadataProviderLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-01-28.
//

import ComposableArchitecture

extension UserMetadataProviderClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        let ums = UserMetadataStorage.live

        return UserMetadataProviderClient(
            store: { try ums.store(account: $0) },
            load: { try ums.load(account: $0) },
            resetAccount: { try ums.resetAccount($0) },
            reset: { try ums.reset() },
            isBookmarked: { ums.isBookmarked(txId: $0) },
            toggleBookmarkFor: { ums.toggleBookmarkFor(txId: $0) },
            annotationFor: { ums.annotationFor(txId: $0) },
            addAnnotationFor: { ums.add(annotation: $0, for: $1) },
            deleteAnnotationFor: { ums.deleteAnnotationFor(txId: $0) },
            isRead: { ums.isRead(txId: $0, txTimestamp: $1) },
            readTx: { ums.readTx(txId: $0) },
            allSwaps: { ums.allSwaps() },
            isSwapTransaction: { ums.isSwapTransaction(depositAddress: $0) },
            swapDetailsForTransaction: { ums.swapDetailsForTransaction(depositAddress: $0) },
            markTransactionAsSwapFor: {
                ums.markTransactionAsSwapFor(
                    depositAddress: $0,
                    provider: $1,
                    totalFees: $2,
                    totalUSDFees: $3,
                    fromAsset: $4,
                    toAsset: $5,
                    exactInput: $6,
                    status: $7,
                    amountOutFormatted: $8
                )
            },
            update: { ums.update($0) },
            lastUsedAssetHistory: { ums.lastUsedAssetHistory },
            addLastUsedSwapAsset: { ums.addLastUsedSwap(asset: $0) }
        )
    }
}

extension UserMetadataStorage {
    static let live = UserMetadataStorage()
}
