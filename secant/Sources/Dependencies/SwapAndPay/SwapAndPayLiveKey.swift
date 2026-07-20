//
//  SwapAndPayLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-15-2025.
//

import Foundation
import Network
@preconcurrency import Combine
import ComposableArchitecture

extension SwapAndPayClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            submitDepositTxId: { txId, depositAddress in
                try await Near1Click.liveValue.submitDepositTxId(
                    txId,
                    depositAddress
                )
            },
            swapAssets: {
                try await Near1Click.liveValue.swapAssets()
            },
            quote: { dry, isSwapToZec, exactInput, slippageTolerance, zecAsset, toAsset, refundTo, destination, amount in
                try await Near1Click.liveValue.quote(
                    dry,
                    isSwapToZec,
                    exactInput,
                    slippageTolerance,
                    zecAsset,
                    toAsset,
                    refundTo,
                    destination,
                    amount
                )
            },
            status: { depositAddress, isSwapToZec in
                try await Near1Click.liveValue.status(depositAddress, isSwapToZec)
            }
        )
    }
}
