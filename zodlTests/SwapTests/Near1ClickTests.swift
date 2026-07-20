//
//  Near1ClickTests.swift
//  zodlTests
//
//  Batch 4 — dependency logic. Covers Near1Click.amountMessageResolution swap-error parsing
//  (Dependencies/SwapAndPay/sources/Near1Click.swift).
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct Near1ClickTests {
    @Test func unknownErrorWhenNoMessageKey() {
        #expect(throws: SwapAndPayClient.EndpointError.message("Unknown error")) {
            try Near1Click.amountMessageResolution(exactInput: false, isSwapToZec: false, toAsset: asset(), jsonObject: [:])
        }
    }

    @Test func passesThroughUnrecognizedMessage() {
        #expect(throws: SwapAndPayClient.EndpointError.message("some random error")) {
            try Near1Click.amountMessageResolution(exactInput: false, isSwapToZec: false, toAsset: asset(), jsonObject: ["message": "some random error"])
        }
    }

    @Test func failedToGetQuoteMapsToLocalizedMessage() {
        #expect(throws: SwapAndPayClient.EndpointError.message(String(localizable: .swapQuoteUnavailableSwap))) {
            try Near1Click.amountMessageResolution(exactInput: true, isSwapToZec: false, toAsset: asset(), jsonObject: ["message": "Failed to get quote"])
        }
        #expect(throws: SwapAndPayClient.EndpointError.message(String(localizable: .swapQuoteUnavailable))) {
            try Near1Click.amountMessageResolution(exactInput: false, isSwapToZec: false, toAsset: asset(), jsonObject: ["message": "Failed to get quote"])
        }
    }

    @Test func rescalesAmountTooLowToZec() {
        do {
            try Near1Click.amountMessageResolution(
                exactInput: true,
                isSwapToZec: false,
                toAsset: asset(decimals: 6),
                jsonObject: ["message": "Amount is too low for bridge, try at least 100000000"]
            )
            Issue.record("expected a throw")
        } catch let SwapAndPayClient.EndpointError.message(msg) {
            #expect(msg.hasPrefix("Amount is too low for bridge, try at least"))
            #expect(msg.contains("ZEC"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rescalesAmountTooLowToToken() {
        do {
            try Near1Click.amountMessageResolution(
                exactInput: false,
                isSwapToZec: false,
                toAsset: asset(token: "USDC", decimals: 6),
                jsonObject: ["message": "Amount is too low for bridge, try at least 1000000"]
            )
            Issue.record("expected a throw")
        } catch let SwapAndPayClient.EndpointError.message(msg) {
            #expect(msg.contains("USDC"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    private func asset(token: String = "ETH", decimals: Int = 18) -> SwapAsset {
        SwapAsset(provider: "near", chain: "eth", token: token, assetId: "x", usdPrice: 0, decimals: decimals)
    }
}
