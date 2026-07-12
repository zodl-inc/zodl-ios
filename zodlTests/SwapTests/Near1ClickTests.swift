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

    // MARK: - curated(_:) source-level allow-list (MOB-1472)

    @Test func curatedKeepsSupportedAndDropsRest() {
        let kept = Near1Click.curated([
            swapAsset(assetId: "nep141:btc.omft.near"),                                     // supported
            swapAsset(assetId: "nep141:eth.omft.near"),                                     // supported
            swapAsset(assetId: "nep245:v2_1.omni.hot.tg:137_qiStmoQJDQPTebaPjgx5VBxZv6L"),  // pol.usdc — dropped
            swapAsset(assetId: "nep141:doge.omft.near")                                     // dropped
        ])
        let ids = kept.map(\.assetId)
        #expect(kept.count == 2)
        #expect(ids.contains("nep141:btc.omft.near"))
        #expect(ids.contains("nep141:eth.omft.near"))
        #expect(!ids.contains("nep141:doge.omft.near"))
    }

    @Test func curatedKeepsNativeZecAndDropsWrappedZec() {
        let kept = Near1Click.curated([
            // native ZEC — the swap-to-ZEC representation, must survive
            swapAsset(assetId: Near1Click.Constants.nearZecAssetId, token: "ZEC", chain: "zec"),
            // wrapped ZEC on another chain — same symbol, different assetId, must drop
            swapAsset(assetId: "1cs_v1:sol:spl:A7bdiYdS5GjqGFtxf17ppRHtDKPkkRqbKtR27dxvQXaS", token: "ZEC", chain: "sol")
        ])
        #expect(kept.count == 1)
        #expect(kept.first?.assetId == Near1Click.Constants.nearZecAssetId)
    }

    @Test func curatedPreservesEverySupportedAsset() {
        let all = Near1Click.Constants.supportedAssetIds.map { swapAsset(assetId: $0) }
        let kept = Near1Click.curated(all)
        #expect(Set(kept.map(\.assetId)) == Near1Click.Constants.supportedAssetIds)
    }

    @Test func curatedEmptyStaysEmpty() {
        #expect(Near1Click.curated([]).isEmpty)
    }

    private func asset(token: String = "ETH", decimals: Int = 18) -> SwapAsset {
        SwapAsset(provider: "near", chain: "eth", token: token, assetId: "x", usdPrice: 0, decimals: decimals)
    }

    private func swapAsset(assetId: String, token: String = "TKN", chain: String = "eth") -> SwapAsset {
        SwapAsset(provider: "near", chain: chain, token: token, assetId: assetId, usdPrice: 1, decimals: 6)
    }
}
