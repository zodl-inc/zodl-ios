//
//  SwapQuoteIntentTests.swift
//  Zashi
//

import Foundation
import Testing
@testable import zodl_internal

@Suite struct SwapQuoteIntentTests {
    private func quote(recipient: String = "addr", origin: String = "zec.id", destination: String = "btc.id") -> SwapQuote {
        SwapQuote(
            depositAddress: "deposit", amountIn: Decimal(100_000_000), amountInUsd: "10",
            minAmountIn: Decimal(100_000_000), amountOut: Decimal(2_000_000), amountOutUsd: "10",
            timeEstimate: 60, recipient: recipient, originAssetId: origin, destinationAssetId: destination
        )
    }

    @Test func matchesWhenAllFieldsAgree() {
        #expect(quote().matchesSigningIntent(address: "addr", originAssetId: "zec.id", destinationAssetId: "btc.id"))
    }

    @Test func failsWhenRecipientDiffers() {
        #expect(!quote(recipient: "other").matchesSigningIntent(address: "addr", originAssetId: "zec.id", destinationAssetId: "btc.id"))
    }

    @Test func failsWhenDestinationAssetDiffers() {
        #expect(!quote().matchesSigningIntent(address: "addr", originAssetId: "zec.id", destinationAssetId: "eth.id"))
    }
}
