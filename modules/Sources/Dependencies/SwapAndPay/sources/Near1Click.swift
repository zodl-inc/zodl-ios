//
//  Near1Click.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-05-23.
//

import Foundation
import ComposableArchitecture
import ZcashLightClientKit
import SDKSynchronizer
import WalletStorage
import Utils
import PartnerKeys
import Generated
import Models

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
        static let refundTo = "refundTo"

        // params
        static let exactInput = "EXACT_INPUT"
        static let exactOutput = "EXACT_OUTPUT"
        static let originChain = "ORIGIN_CHAIN"
        static let destinationChain = "DESTINATION_CHAIN"

        // zec asset
        static let nearZecAssetId = "nep141:zec.omft.near"
    }
    
    let submitDepositTxId: (String, String) async throws -> Void
    let swapAssets: () async throws -> IdentifiedArrayOf<SwapAsset>
    let quote: (Bool, Bool, Bool, Int, SwapAsset, SwapAsset, String, String, String) async throws -> SwapQuote
    let status: (String, Bool) async throws -> SwapDetails
    
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
                errorMsgConverted = exactInput ? L10n.Swap.quoteUnavailableSwap : L10n.Swap.quoteUnavailable
            }
            
            throw SwapAndPayClient.EndpointError.message(errorMsgConverted)
        } else {
            throw SwapAndPayClient.EndpointError.message("Unknown error")
        }
    }
}

extension Near1Click {
    public static let liveValue = Self(
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
            let (data, _) = try await Near1Click.getCall(urlString: Constants.tokensUrl)
            
            guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw URLError(.cannotParseResponse)
            }
            
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .decimal
            
            let chainAssets = jsonObject.compactMap { dict -> SwapAsset? in
                guard let chain = dict[Constants.blockchain] as? String,
                      let symbol = dict[Constants.symbol] as? String,
                      let assetId = dict[Constants.assetId] as? String,
                      let usdPrice = dict[Constants.price] as? Double,
                      let decimals = dict[Constants.decimals] as? Int else {
                    return nil
                }

                return SwapAsset(
                    provider: L10n.Swap.nearProvider,
                    chain: chain,
                    token: symbol,
                    assetId: assetId,
                    usdPrice: Decimal(usdPrice),
                    decimals: decimals
                )
            }
            
            return IdentifiedArrayOf(uniqueElements: chainAssets)
        },
        quote: { dry, isSwapToZec, exactInput, slippageTolerance, zecAsset, toAsset, refundTo, destination, amount in
            // Deadline in ISO 8601 UTC format
            let now = Date()
            let twoHoursLater = now.addingTimeInterval(120 * 60)
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            
            let deadline = isoFormatter.string(from: twoHoursLater)
            
            let requestData = SwapQuoteRequest(
                dry: dry,
                swapType: isSwapToZec ? Constants.exactInput : exactInput ? Constants.exactInput : Constants.exactOutput,
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
                        recipient: exactInput
                        ? SwapAndPayClient.Constants.affiliateFeeDepositAddress
                        : SwapAndPayClient.Constants.affiliateCrossPayFeeDepositAddress,
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
            let (data, response) = try await Near1Click.getCall(urlString: "\(Constants.statusUrl)\(depositAddress)", includeJwtKey: true)

            guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SwapAndPayClient.EndpointError.message("Check status: Cannot parse response")
            }
            
            guard let statusStr = jsonObject[Constants.status] as? String else {
                throw SwapAndPayClient.EndpointError.message("Check status: Missing `status` parameter.")
            }
            
            var status: SwapDetails.Status
            
            if isSwapToZec {
                status = switch statusStr {
                case SwapConstants.pendingDeposit: .pendingDeposit
                case SwapConstants.refunded: .refunded
                case SwapConstants.success: .success
                case SwapConstants.failed: .failed
                case SwapConstants.incompleteDeposit: .pendingDeposit
                case SwapConstants.processing: .processing
                default: .pending
                }
            } else {
                status = switch statusStr {
                case SwapConstants.pendingDeposit: .pending
                case SwapConstants.refunded: .refunded
                case SwapConstants.success: .success
                default: .pending
                }
            }
            
            guard let quoteResponseDict = jsonObject[Constants.quoteResponse] as? [String: Any],
                  let quoteRequestDict = quoteResponseDict[Constants.quoteRequest] as? [String: Any] else {
                throw SwapAndPayClient.EndpointError.message("Check status: Missing `quoteRequest` parameter.")
            }
            
            guard let swapType = quoteRequestDict[Constants.swapType] as? String else {
                throw SwapAndPayClient.EndpointError.message("Check status: Missing `swapType` parameter.")
            }

            guard var fromAsset = quoteRequestDict[Constants.originAsset] as? String else {
                throw SwapAndPayClient.EndpointError.message("Check status: Missing `originAsset` parameter.")
            }

            guard var toAsset = quoteRequestDict[Constants.destinationAsset] as? String else {
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

            if status == .pending || status == .refunded || status == .pendingDeposit || status == .failed || status == .processing {
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
                isSwap: swapType == Constants.exactInput,
                slippage: slippage,
                status: status,
                refundedAmountFormatted: refundedAmountFormattedDecimal,
                swapRecipient: swapRecipient,
                addressToCheckShield: (isSwapToZec ? swapRecipient : refundTo) ?? ""
            )
        }
    )
}
