//
//  SwapQuote.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-06-18.
//

@preconcurrency import ZcashLightClientKit
import Foundation

struct SwapQuote: Codable, Equatable, Hashable {
    /// Deposit address (ZEC)
    let depositAddress: String
    /// Amount of Zatoshi
    let amountIn: Decimal
    /// USD value of the Zatoshi amount, localized (0.1 vs. 0,1)
    let amountInUsd: String
    /// Minimal amount of Zatoshi so this quote can be procesed
    let minAmountIn: Decimal
    /// Amount that should be ideally received on the destination address
    let amountOut: Decimal
    /// USD value of the amount that will be received on the destination address, localized (0.1 vs. 0,1)
    let amountOutUsd: String
    /// Number of seconds it takes to process this quote
    let timeEstimate: TimeInterval
    /// Echoed off-chain payout recipient (the address the user typed); validated == request at parse time.
    let recipient: String
    /// Echoed origin assetId; validated == request at parse time.
    let originAssetId: String
    /// Echoed destination assetId; validated == request at parse time.
    let destinationAssetId: String

    init(
        depositAddress: String,
        amountIn: Decimal,
        amountInUsd: String,
        minAmountIn: Decimal,
        amountOut: Decimal,
        amountOutUsd: String,
        timeEstimate: TimeInterval,
        recipient: String,
        originAssetId: String,
        destinationAssetId: String
    ) {
        self.depositAddress = depositAddress
        self.amountIn = amountIn
        self.amountInUsd = amountInUsd
        self.minAmountIn = minAmountIn
        self.amountOut = amountOut
        self.amountOutUsd = amountOutUsd
        self.timeEstimate = timeEstimate
        self.recipient = recipient
        self.originAssetId = originAssetId
        self.destinationAssetId = destinationAssetId
    }
}

extension SwapQuote {
    /// Re-binds the quote to current user intent immediately before signing (TOCTOU guard): the echoed
    /// payout recipient and both asset ids must still match what the user is looking at.
    func matchesSigningIntent(address: String, originAssetId: String, destinationAssetId: String) -> Bool {
        recipient == address
            && self.originAssetId == originAssetId
            && self.destinationAssetId == destinationAssetId
    }
}
