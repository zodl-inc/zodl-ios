//
//  Near1Click.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-05-23.
//

import Foundation
import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct Near1Click {
    enum Constants {
        static let referral = "zodl"
        
        // urls
        static let submitUrl = "https://1click.chaindefuser.com/v0/deposit/submit"
        static let tokensUrl = "https://1click.chaindefuser.com/v0/tokens"
        static let quoteUrl = "https://1click.chaindefuser.com/v0/quote"
        static let statusUrl = "https://1click.chaindefuser.com/v0/status?depositAddress="

        // keys
        static let blockchain = "blockchain"
        static let symbol = "symbol"
        static let assetId = "assetId"
        static let price = "price"
        static let decimals = "decimals"
        static let message = "message"
        static let quote = "quote"
        static let depositAddress = "depositAddress"
        static let amountIn = "amountIn"
        static let amountInUsd = "amountInUsd"
        static let minAmountIn = "minAmountIn"
        static let amountOut = "amountOut"
        static let amountOutUsd = "amountOutUsd"
        static let timeEstimate = "timeEstimate"
        static let status = "status"
        static let quoteResponse = "quoteResponse"
        static let quoteRequest = "quoteRequest"
        static let swapType = "swapType"
        static let destinationAsset = "destinationAsset"
        static let originAsset = "originAsset"
        static let swapDetails = "swapDetails"
        static let slippage = "slippage"
        static let slippageTolerance = "slippageTolerance"
        static let refundedAmountFormatted = "refundedAmountFormatted"
        static let amountInFormatted = "amountInFormatted"
        static let amountOutFormatted = "amountOutFormatted"
        static let recipient = "recipient"
        static let deadline = "deadline"
        static let timestamp = "timestamp"
        static let refundTo = "refundTo"
        static let depositedAmountFormatted = "depositedAmountFormatted"

        // params
        static let exactInput = "EXACT_INPUT"
        static let exactOutput = "EXACT_OUTPUT"
        static let originChain = "ORIGIN_CHAIN"
        static let destinationChain = "DESTINATION_CHAIN"
        static let flexInput = "FLEX_INPUT"

        // zec asset
        static let nearZecAssetId = "nep141:zec.omft.near"

        // Source-level curated allow-list (MOB-1472).
        // Filters `swapAssets` down to the supported set as close to the provider
        // response as possible, keyed by Near's own `assetId` (provider-specific,
        // so it survives adding other swap providers later). No caller of
        // `swapAssets` can ever receive an uncurated asset. `nearZecAssetId` MUST
        // stay in the set — swap-to-ZEC depends on the native ZEC representation.
        static let supportedAssetIds: Set<String> = [
            nearZecAssetId,                                                     // ZEC (native)
            "nep141:btc.omft.near",                                            // BTC@btc
            "nep141:eth.omft.near",                                            // ETH@eth
            "nep141:sol.omft.near",                                            // SOL@sol
            "nep141:eth-0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48.omft.near", // USDC@eth
            "nep141:eth-0xdac17f958d2ee523a2206206994597c13d831ec7.omft.near", // USDT@eth
            "nep141:arb-0xaf88d065e77c8cc2239327c5edb3a432268e5831.omft.near", // USDC@arb
            "nep141:sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near",   // USDC@sol
            "nep141:sol-c800a4bd850783ccb82c2b2c7e84175443606352.omft.near",   // USDT@sol
            "nep245:v2_1.omni.hot.tg:56_2CMMyVTGZkeyNZTSvS5sarzfir6g",         // USDT@bsc
            "nep141:tron-d28a265909efecdcee7c5028585214ea0b96f015.omft.near",  // USDT@tron
            "nep141:sui-c1b81ecaf27933252d31a963bc5e9458f13c18ce.omft.near",   // USDC@sui
            "nep141:base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near", // USDC@base
            "nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1", // USDC@near
            "nep141:wrap.near", // wNEAR@near
            "nep245:v2_1.omni.hot.tg:137_3hpYoaLtt8MP1Z2GH1U473DMRKgr", // USDT@pol
            "nep141:eth-0x2260fac5e5542a773aa44fbcfedf7c193bc2c599.omft.near", // WBTC@eth
            "nep141:nbtc.bridge.near", // BTC@near
            "nep141:eth-0x6b175474e89094c44da98b954eedeac495271d0f.omft.near", // DAI@eth
            "nep141:ltc.omft.near", // LTC@ltc
            "nep141:tron.omft.near", // TRX@tron
            "nep141:usdt.tether-token.near", // USDT@near
            "nep245:v2_1.omni.hot.tg:56_11111111111111111111", // BNB@bsc
            "nep245:v2_1.omni.hot.tg:43114_11111111111111111111", // AVAX@avax
            "nep141:arb-0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9.omft.near", // USDT0@arb
            "nep141:arb.omft.near", // ETH@arb
            "nep245:v2_1.omni.hot.tg:137_qiStmoQJDQPTebaPjgx5VBxZv6L", // USDC@pol
            "nep141:xrp.omft.near", // XRP@xrp
            "nep141:base.omft.near" // ETH@base
        ]
    }
    
    let submitDepositTxId: @Sendable (String, String) async throws -> Void
    /// The curated offering — only the supported assets a user can select/swap.
    let swapAssets: @Sendable () async throws -> IdentifiedArrayOf<SwapAsset>
    /// The full provider catalog — every asset, uncurated. For resolving/rendering
    /// historical or exotic assets that are no longer offered for swaps (MOB-1472).
    let swapAssetsCatalog: @Sendable () async throws -> IdentifiedArrayOf<SwapAsset>
    let quote: @Sendable (Bool, Bool, Bool, Int, SwapAsset, SwapAsset, String, String, String) async throws -> SwapQuote
    let status: @Sendable (String, Bool) async throws -> SwapDetails

    static func getCall(urlString: String, includeJwtKey: Bool = false) async throws -> (Data, URLResponse) {
        @Dependency(\.sdkSynchronizer) var sdkSynchronizer
        @Shared(.inMemory(.swapAPIAccess)) var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct
        
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if let jwtToken = PartnerKeys.nearKey, includeJwtKey {
            request.addValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = swapAPIAccess == .direct
            ? try await URLSession.shared.data(for: request)
            : try await sdkSynchronizer.httpRequestOverTor(request)
            
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NetworkError.httpStatus(code: code)
            }
            
            return (data, response)
        } catch let urlError as URLError {
            throw NetworkError.transport(urlError)
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.unknown(error)
        }
    }
    
    static func postCall(urlString: String, jsonData: Data, includeJwtKey: Bool = true) async throws -> (Data, URLResponse) {
        @Dependency(\.sdkSynchronizer) var sdkSynchronizer
        @Shared(.inMemory(.swapAPIAccess)) var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        if let jwtToken = PartnerKeys.nearKey, includeJwtKey {
            request.addValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
        }
        
        return swapAPIAccess == .direct
        ? try await URLSession.shared.data(for: request)
        : try await sdkSynchronizer.httpRequestOverTor(request)
    }
    
    static func amountMessageResolution(exactInput: Bool, isSwapToZec: Bool, toAsset: SwapAsset, jsonObject: [String: Any]) throws {
        // evaluate error
        if let errorMsg = jsonObject[Constants.message] as? String {
            var errorMsgConverted = errorMsg
            
            // insufficient amount transformations
            if errorMsg.contains("Amount is too low for bridge, try at least") {
                if let value = errorMsg.split(separator: "Amount is too low for bridge, try at least ").last {
                    let valueDecimal = NSDecimalNumber(string: String(value)).decimalValue
                    
                    let formatter = NumberFormatter()
                    formatter.numberStyle = .decimal
                    formatter.minimumFractionDigits = 2
                    formatter.maximumFractionDigits = 8
                    formatter.usesGroupingSeparator = false
                    formatter.locale = Locale.current
                    
                    // ZEC asset
                    if exactInput && !isSwapToZec {
                        let zecAmount = (NSDecimalNumber(decimal: valueDecimal / Decimal(Zatoshi.Constants.oneZecInZatoshi))).decimalValue.simplified
                        
                        let localeValue = formatter.string(from: NSDecimalNumber(decimal: zecAmount)) ?? "\(zecAmount)"
                        errorMsgConverted = "Amount is too low for bridge, try at least \(localeValue) ZEC."
                    } else {
                        // selected Asset
                        let tokenAmount = (valueDecimal / Decimal(pow(10.0, Double(toAsset.decimals)))).simplified
                        
                        let localeValue = formatter.string(from: NSDecimalNumber(decimal: tokenAmount)) ?? "\(tokenAmount)"
                        errorMsgConverted = "Amount is too low for bridge, try at least \(localeValue) \(toAsset.token)."
                    }
                }
            } else if errorMsg.contains("Failed to get quote") {
                errorMsgConverted = exactInput ? String(localizable: .swapQuoteUnavailableSwap) : String(localizable: .swapQuoteUnavailable)
            }
            
            throw SwapAndPayClient.EndpointError.message(errorMsgConverted)
        } else {
            throw SwapAndPayClient.EndpointError.message("Unknown error")
        }
    }

    /// Source-level curation (MOB-1472): keep only the supported assets, matched
    /// by Near's own `assetId`. Pure and synchronous so it can be unit-tested
    /// independently of the networking in the `swapAssets` closure.
    static func curated(_ assets: [SwapAsset]) -> [SwapAsset] {
        assets.filter { Constants.supportedAssetIds.contains($0.assetId) }
    }

    /// Maps a 1Click `status` string to `SwapDetails.Status`. Pure so it can be
    /// unit-tested independently of the networking in the `status` closure.
    // [B4-14 root cause — Lukas, 2026-07-02] Any TERMINAL status missing from these
    // switches falls into `default: .pending` and the swap stays "Paying…/Swapping…"
    // FOREVER (the auto-update flip gate requires `!status.isPending`). EXPIRED was
    // missing from both branches (same forever-pending class). Every status the API
    // documents is mapped explicitly in both branches; `default` remains only for
    // statuses Near may add in the future (deliberately non-terminal).
    static func swapStatus(from statusStr: String, isSwapToZec: Bool) -> SwapDetails.Status {
        if isSwapToZec {
            switch statusStr {
            case SwapConstants.pendingDeposit: .pendingDeposit
            case SwapConstants.refunded: .refunded
            case SwapConstants.success: .success
            case SwapConstants.failed: .failed
            case SwapConstants.incompleteDeposit: .incompleteDeposit
            case SwapConstants.processing: .processing
            case SwapConstants.expired: .expired
            default: .pending
            }
        } else {
            switch statusStr {
            case SwapConstants.incompleteDeposit: .incompleteDeposit
            case SwapConstants.pendingDeposit: .pending
            case SwapConstants.refunded: .refunded
            case SwapConstants.success: .success
            case SwapConstants.failed: .failed
            case SwapConstants.processing: .processing
            case SwapConstants.expired: .expired
            default: .pending
            }
        }
    }

    /// Fetches and parses the provider's full token list — every asset, deduped,
    /// before curation. `swapAssets` returns `curated(...)` of this (the offering);
    /// `swapAssetsCatalog` returns this full list (for resolving historical assets).
    static func fetchAllAssets() async throws -> [SwapAsset] {
        // Send the Bearer JWT like every other 1click call (quote/submit/status). /tokens was the
        // only unauthenticated one; 1click sits behind Cloudflare, whose bot-management resets the
        // TLS connection of unauthenticated CFNetwork (URLSession) requests — which surfaced as a
        // transport URLError on macOS while `curl` (different TLS fingerprint) and the authenticated
        // CMC call both worked. Authenticating makes it a trusted request.
        let (data, _) = try await Near1Click.getCall(urlString: Constants.tokensUrl, includeJwtKey: true)

        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }

        let chainAssets = jsonObject.compactMap { dict -> SwapAsset? in
            guard let chain = dict[Constants.blockchain] as? String,
                  let symbol = dict[Constants.symbol] as? String,
                  let assetId = dict[Constants.assetId] as? String,
                  let usdPrice = dict[Constants.price] as? Double,
                  let decimals = dict[Constants.decimals] as? Int else {
                return nil
            }

            return SwapAsset(
                provider: String(localizable: .swapNearProvider),
                chain: chain,
                token: symbol,
                assetId: assetId,
                usdPrice: Decimal(usdPrice),
                decimals: decimals
            )
        }

        return chainAssets.removingDuplicates()
    }
}

extension Near1Click {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            submitDepositTxId: { txId, depositAddress in
            let requestData = SwapSubmitHash(
                txHash: txId,
                depositAddress: depositAddress
            )
            
            guard let jsonData = try? JSONEncoder().encode(requestData) else {
                fatalError("Failed to encode JSON")
            }
            
            let (data, response) = try await Near1Click.postCall(urlString: Constants.submitUrl, jsonData: jsonData)
            
            guard let _ = response as? HTTPURLResponse else {
                throw SwapAndPayClient.EndpointError.message("Submit deposit id: Invalid response")
            }
            
            guard let _ = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SwapAndPayClient.EndpointError.message("Submit deposit id: Cannot parse response")
            }
        },
        swapAssets: {
            IdentifiedArrayOf(uniqueElements: Near1Click.curated(try await Near1Click.fetchAllAssets()))
        },
        swapAssetsCatalog: {
            IdentifiedArrayOf(uniqueElements: try await Near1Click.fetchAllAssets())
        },
        quote: { dry, isSwapToZec, exactInput, slippageTolerance, zecAsset, toAsset, refundTo, destination, amount in
            // Deadline in ISO 8601 UTC format
            let now = Date()
            let twoHoursLater = now.addingTimeInterval(120 * 60)
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            
            let deadline = isoFormatter.string(from: twoHoursLater)
            
            guard let nearFeeDepositAddress = PartnerKeys.nearFeeDepositAddress else {
                throw "nearFeeDepositAddress missing"
            }
            
            let requestData = SwapQuoteRequest(
                dry: dry,
                swapType: isSwapToZec ? Constants.flexInput : exactInput ? Constants.exactInput : Constants.exactOutput,
                slippageTolerance: slippageTolerance,
                originAsset: isSwapToZec ? toAsset.assetId : zecAsset.assetId,
                depositType: Constants.originChain,
                destinationAsset: isSwapToZec ? zecAsset.assetId : toAsset.assetId,
                amount: amount,
                refundTo: isSwapToZec ? destination : refundTo,
                refundType: Constants.originChain,
                recipient: isSwapToZec ? refundTo : destination,
                recipientType: Constants.destinationChain,
                deadline: deadline,
                referral: Constants.referral,
                quoteWaitingTimeMs: 3000,
                appFees: [
                    AppFee(
                        recipient: nearFeeDepositAddress,
                        fee: SwapAndPayClient.Constants.zashiFeeBps
                    )
                ]
            )
            
            guard let jsonData = try? JSONEncoder().encode(requestData) else {
                fatalError("Failed to encode JSON")
            }
            
            let (data, response) = try await Near1Click.postCall(urlString: Constants.quoteUrl, jsonData: jsonData)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SwapAndPayClient.EndpointError.message("Quote: Invalid response")
            }
            
            guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SwapAndPayClient.EndpointError.message("Quote: Cannot parse response")
            }
            
            if httpResponse.statusCode >= 400 {
                try amountMessageResolution(
                    exactInput: exactInput,
                    isSwapToZec: isSwapToZec,
                    toAsset: toAsset,
                    jsonObject: jsonObject
                )
            }
            
            guard let quote = jsonObject[Constants.quote] as? [String: Any],
                  let depositAddress = quote[Constants.depositAddress] as? String,
                  let amountInString = quote[Constants.amountIn] as? String,
                  let amountInUsdString = quote[Constants.amountInUsd] as? String,
                  let minAmountInString = quote[Constants.minAmountIn] as? String,
                  let amountOutString = quote[Constants.amountOut] as? String,
                  let amountOutUsdString = quote[Constants.amountOutUsd] as? String,
                  let timeEstimate = quote[Constants.timeEstimate] as? Int else {
                throw SwapAndPayClient.EndpointError.message("Parse of the quote failed.")
            }
            
            let amountIn = NSDecimalNumber(string: amountInString).decimalValue
            let minAmountIn = NSDecimalNumber(string: minAmountInString).decimalValue
            let amountOut = NSDecimalNumber(string: amountOutString).decimalValue
            
            if isSwapToZec {
                return SwapQuote(
                    depositAddress: depositAddress,
                    amountIn: amountIn / Decimal(pow(10.0, Double(toAsset.decimals))),
                    amountInUsd: amountInUsdString,
                    minAmountIn: minAmountIn / Decimal(pow(10.0, Double(toAsset.decimals))),
                    amountOut: amountOut / Decimal(pow(10.0, Double(zecAsset.decimals))),
                    amountOutUsd: amountOutUsdString,
                    timeEstimate: TimeInterval(timeEstimate)
                )
            }
            
            return SwapQuote(
                depositAddress: depositAddress,
                amountIn: amountIn,
                amountInUsd: amountInUsdString,
                minAmountIn: minAmountIn,
                amountOut: amountOut / Decimal(pow(10.0, Double(toAsset.decimals))),
                amountOutUsd: amountOutUsdString,
                timeEstimate: TimeInterval(timeEstimate)
            )
        },
        status: { depositAddress, isSwapToZec in
            let (data, _) = try await Near1Click.getCall(urlString: "\(Constants.statusUrl)\(depositAddress)", includeJwtKey: true)

            guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SwapAndPayClient.EndpointError.message("Check status: Cannot parse response")
            }
            
            guard let statusStr = jsonObject[Constants.status] as? String else {
                throw SwapAndPayClient.EndpointError.message("Check status: Missing `status` parameter.")
            }
            
            var status = Near1Click.swapStatus(from: statusStr, isSwapToZec: isSwapToZec)
            
            guard let quoteResponseDict = jsonObject[Constants.quoteResponse] as? [String: Any],
                  let quoteRequestDict = quoteResponseDict[Constants.quoteRequest] as? [String: Any] else {
                throw SwapAndPayClient.EndpointError.message("Check status: Missing `quoteRequest` parameter.")
            }
            
            guard let swapType = quoteRequestDict[Constants.swapType] as? String else {
                throw SwapAndPayClient.EndpointError.message("Check status: Missing `swapType` parameter.")
            }

            guard let fromAsset = quoteRequestDict[Constants.originAsset] as? String else {
                throw SwapAndPayClient.EndpointError.message("Check status: Missing `originAsset` parameter.")
            }

            guard let toAsset = quoteRequestDict[Constants.destinationAsset] as? String else {
                throw SwapAndPayClient.EndpointError.message("Check status: Missing `destinationAsset` parameter.")
            }
            
            // swap to zec exchange
//            if destinationAsset == Constants.nearZecAssetId {
//                guard let originAsset = quoteRequestDict[Constants.originAsset] as? String else {
//                    throw SwapAndPayClient.EndpointError.message("Check status: Missing `originAsset` parameter.")
//                }
//
//                destinationAsset = originAsset
//            }
            
            guard let swapDetailsDict = jsonObject[Constants.swapDetails] as? [String: Any] else {
                throw SwapAndPayClient.EndpointError.message("Check status: Missing `swapDetails` parameter.")
            }
            
            var slippage: Decimal?
            if let slippageInt = swapDetailsDict[Constants.slippage] as? Int {
                slippage = Decimal(slippageInt) * 0.01
            } else if status != .success {
                if let slippageInt = quoteRequestDict[Constants.slippageTolerance] as? Int {
                    slippage = Decimal(slippageInt) * 0.01
                }
            }

            var depositedAmountFormattedDecimal: Decimal?
            if let depositedAmountFormatted = swapDetailsDict[Constants.depositedAmountFormatted] as? String, status == .incompleteDeposit {
                depositedAmountFormattedDecimal = depositedAmountFormatted.usDecimal
            }

            var refundedAmountFormattedDecimal: Decimal?
            if let refundedAmountFormatted = swapDetailsDict[Constants.refundedAmountFormatted] as? String, status == .refunded {
                refundedAmountFormattedDecimal = refundedAmountFormatted.usDecimal
            }
            
            var amountInFormattedDecimal: Decimal?
            if let amountInFormatted = swapDetailsDict[Constants.amountInFormatted] as? String {
                amountInFormattedDecimal = amountInFormatted.usDecimal
            }
            
            var amountInUsd = swapDetailsDict[Constants.amountInUsd] as? String
            
            var amountOutFormattedDecimal: Decimal?
            if let amountOutFormatted = swapDetailsDict[Constants.amountOutFormatted] as? String {
                amountOutFormattedDecimal = amountOutFormatted.usDecimal
            }
            
            var amountOutUsd = swapDetailsDict[Constants.amountOutUsd] as? String
            
            var swapRecipient: String?
            if let recipient = quoteRequestDict[Constants.recipient] as? String {
                swapRecipient = recipient
            }

            var refundTo: String?
            if let refundToAddress = quoteRequestDict[Constants.refundTo] as? String {
                refundTo = refundToAddress
            }

            if status == .pending
                || status == .refunded
                || status == .pendingDeposit
                || status == .failed
                || status == .processing
                || status == .incompleteDeposit
            {
                if let quoteDict = quoteResponseDict[Constants.quote] as? [String: Any] {
                    if let amountInFormatted = quoteDict[Constants.amountInFormatted] as? String {
                        amountInFormattedDecimal = amountInFormatted.usDecimal
                    }
                    
                    if let amountOutFormatted = quoteDict[Constants.amountOutFormatted] as? String {
                        amountOutFormattedDecimal = amountOutFormatted.usDecimal
                    }
                    
                    amountInUsd = quoteDict[Constants.amountInUsd] as? String
                    amountOutUsd = quoteDict[Constants.amountOutUsd] as? String
                }
            }
            
            // dates
            var deadline = ""
            
            if let quoteDict = quoteResponseDict[Constants.quote] as? [String: Any] {
                if let deadlineStr = quoteDict[Constants.deadline] as? String {
                    deadline = deadlineStr
                }
            }

            var whenInitiated = ""
            if let whenInitiatedStr = quoteResponseDict[Constants.timestamp] as? String {
                whenInitiated = whenInitiatedStr
            }

            // expired?
            if statusStr == SwapConstants.pendingDeposit {
                if let quoteDict = quoteResponseDict[Constants.quote] as? [String: Any] {
                    if let deadline = quoteDict[Constants.deadline] as? String {
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        
                        if let date = formatter.date(from: deadline) {
                            // 5 minutes earlier than the deadline
                            let adjustedDeadline = date.addingTimeInterval(-5 * 60)
                            if Date() > adjustedDeadline {
                                status = .expired
                            }
                        }
                    }
                }
            }

            return SwapDetails(
                amountInFormatted: amountInFormattedDecimal,
                amountInUsd: amountInUsd,
                amountOutFormatted: amountOutFormattedDecimal,
                amountOutUsd: amountOutUsd,
                fromAsset: fromAsset,
                toAsset: toAsset,
                isSwap: swapType == Constants.exactInput || swapType == Constants.flexInput,
                slippage: slippage,
                status: status,
                refundedAmountFormatted: refundedAmountFormattedDecimal,
                swapRecipient: swapRecipient,
                addressToCheckShield: (isSwapToZec ? swapRecipient : refundTo) ?? "",
                whenInitiated: whenInitiated,
                deadline: deadline,
                depositedAmountFormatted: depositedAmountFormattedDecimal
            )
        }
        )
    }
}
