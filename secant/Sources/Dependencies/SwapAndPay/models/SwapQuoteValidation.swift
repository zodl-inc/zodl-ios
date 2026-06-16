//
//  SwapQuoteValidation.swift
//  Zashi
//

import Foundation

/// Typed failures from validating a swap quote against the request we sent and the user's intent.
/// Each is fail-closed: the caller maps any of these to the existing "quote unavailable" path.
enum SwapQuoteValidationError: Error, Equatable {
    case assetMismatch(field: String)
    case swapTypeMismatch
    case slippageToleranceMismatch
    case amountInconsistency(field: String)
    case nonPositiveAmount(field: String)
    case slippageExceeded
    case requestedAmountMismatch
    case recipientMismatch
    case refundMismatch
}

/// The subset of the swap-quote response the validator inspects: the echoed `quoteRequest` fields plus
/// the `quote` amounts, all already parsed into typed values.
struct SwapQuoteResponseFields: Equatable {
    let depositAddress: String
    let echoedOriginAsset: String
    let echoedDestinationAsset: String
    let echoedSwapType: String
    let echoedSlippageTolerance: Int
    let echoedRecipient: String
    let echoedRefundTo: String
    let amountIn: Decimal
    let amountInFormatted: Decimal
    let minAmountIn: Decimal
    let amountOut: Decimal
    let amountOutFormatted: Decimal
    let minAmountOut: Decimal
}

enum SwapQuoteValidator {
    /// Validates a freshly-received quote against the request we sent. Throws the first failure; the caller
    /// fails closed (maps to the "quote unavailable" path) on any throw.
    static func validate(
        request: SwapQuoteRequest,
        response: SwapQuoteResponseFields,
        originDecimals: Int,
        destinationDecimals: Int
    ) throws {
        try requireMatchingAssetId(field: "originAsset", expected: request.originAsset, actual: response.echoedOriginAsset)
        try requireMatchingAssetId(field: "destinationAsset", expected: request.destinationAsset, actual: response.echoedDestinationAsset)

        if request.swapType != response.echoedSwapType {
            throw SwapQuoteValidationError.swapTypeMismatch
        }
        if request.slippageTolerance != response.echoedSlippageTolerance {
            throw SwapQuoteValidationError.slippageToleranceMismatch
        }
        if request.recipient != response.echoedRecipient {
            throw SwapQuoteValidationError.recipientMismatch
        }
        if request.refundTo != response.echoedRefundTo {
            throw SwapQuoteValidationError.refundMismatch
        }
        // amountInFormatted must be strictly positive (also fail closed on NaN — defends zecExchangeRate-style
        // divisions downstream). It comes from Decimal(string:) which never yields NaN, but guard anyway.
        guard !response.amountInFormatted.isNaN,
              NSDecimalNumber(decimal: response.amountInFormatted).compare(NSDecimalNumber.zero) == ComparisonResult.orderedDescending else {
            throw SwapQuoteValidationError.nonPositiveAmount(field: "amountInFormatted")
        }

        try requireConsistent(name: "amountIn", raw: response.amountIn, formatted: response.amountInFormatted, decimals: originDecimals)
        try requireConsistent(name: "amountOut", raw: response.amountOut, formatted: response.amountOutFormatted, decimals: destinationDecimals)
        try requireWithinSlippage(
            swapType: request.swapType, amountIn: response.amountIn, amountOut: response.amountOut,
            minAmountIn: response.minAmountIn, minAmountOut: response.minAmountOut, slippageToleranceBps: request.slippageTolerance
        )
        try requireMatchesRequestedAmount(swapType: request.swapType, requestedAmount: request.amount, rawAmountIn: response.amountIn, rawAmountOut: response.amountOut)
    }

    /// The signed raw base-unit amount must equal the exact decimal expansion of the displayed
    /// `*Formatted` value. Exact-equality is intentional (the "trust the quote 0% or 100%" stance) and
    /// must not be relaxed to a tolerance.
    static func requireConsistent(name: String, raw: Decimal, formatted: Decimal, decimals: Int) throws {
        guard !raw.isNaN, !formatted.isNaN, (0...32).contains(decimals) else {
            throw SwapQuoteValidationError.amountInconsistency(field: name)
        }
        // A server-controlled `formatted` can be huge (e.g. "1e120"); the default NSDecimalNumber behavior
        // raises an uncatchable NSDecimalNumberOverflowException on overflow, so use the non-raising handler
        // and fail closed on the resulting NaN rather than crash.
        let expected = NSDecimalNumber(decimal: formatted)
            .multiplying(byPowerOf10: Int16(decimals), withBehavior: SwapQuoteValidator.nonRaisingNoScale)
        guard !expected.doubleValue.isNaN else {
            throw SwapQuoteValidationError.amountInconsistency(field: name)
        }
        if NSDecimalNumber(decimal: raw).compare(expected) != ComparisonResult.orderedSame {
            throw SwapQuoteValidationError.amountInconsistency(field: name)
        }
    }

    /// Fail-closed slippage check on the server-determined (floating) side of the quote. Integer base-unit
    /// math with the server's own DOWN/UP truncation so legitimate boundary quotes are accepted. Fails
    /// closed on NaN bounds (server-controlled strings can parse to NaN) and negative slippage.
    static func requireWithinSlippage(
        swapType: String,
        amountIn: Decimal,
        amountOut: Decimal,
        minAmountIn: Decimal,
        minAmountOut: Decimal,
        slippageToleranceBps: Int
    ) throws {
        guard !amountIn.isNaN, !amountOut.isNaN, !minAmountIn.isNaN, !minAmountOut.isNaN,
              slippageToleranceBps >= 0, slippageToleranceBps <= 10_000 else {
            throw SwapQuoteValidationError.slippageExceeded
        }

        let denominator = NSDecimalNumber(value: 10_000)
        let bps = NSDecimalNumber(value: slippageToleranceBps)

        switch swapType {
        case Near1Click.Constants.exactInput, Near1Click.Constants.flexInput:
            // Output floats: minAmountOut must be >= amountOut * (1 - slippage), rounded DOWN.
            let floor = NSDecimalNumber(decimal: amountOut)
                .multiplying(by: denominator.subtracting(bps), withBehavior: SwapQuoteValidator.nonRaisingNoScale)
                .dividing(by: denominator, withBehavior: SwapQuoteValidator.roundDownZeroScale)
            guard !floor.doubleValue.isNaN else {
                throw SwapQuoteValidationError.slippageExceeded
            }
            if NSDecimalNumber(decimal: minAmountOut).compare(floor) == ComparisonResult.orderedAscending {
                throw SwapQuoteValidationError.slippageExceeded
            }

        case Near1Click.Constants.exactOutput:
            // Input floats: minAmountIn (worst-case max input) must be <= amountIn * (1 + slippage), rounded UP.
            let ceiling = NSDecimalNumber(decimal: amountIn)
                .multiplying(by: denominator.adding(bps), withBehavior: SwapQuoteValidator.nonRaisingNoScale)
                .dividing(by: denominator, withBehavior: SwapQuoteValidator.roundUpZeroScale)
            guard !ceiling.doubleValue.isNaN else {
                throw SwapQuoteValidationError.slippageExceeded
            }
            if NSDecimalNumber(decimal: minAmountIn).compare(ceiling) == ComparisonResult.orderedDescending {
                throw SwapQuoteValidationError.slippageExceeded
            }

        default:
            // Unknown swap type has no floating side to validate. swapType is pinned to the request by the
            // validate() orchestrator, so this is unreachable in the integrated path; no-op here is safe.
            break
        }
    }

    /// The returned asset id must exactly equal the asset id we requested (an opaque identifier from the
    /// same token list, so exact-match is correct).
    static func requireMatchingAssetId(field: String, expected: String, actual: String) throws {
        if expected != actual {
            throw SwapQuoteValidationError.assetMismatch(field: field)
        }
    }

    /// The user-fixed side of the swap must equal the amount the user requested (exact, in base units).
    /// EXACT_INPUT / FLEX_INPUT fix the input; EXACT_OUTPUT fixes the output. Fails closed on an
    /// unparseable/NaN requested amount, a NaN quoted amount, or an unknown swap type.
    static func requireMatchesRequestedAmount(swapType: String, requestedAmount: String, rawAmountIn: Decimal, rawAmountOut: Decimal) throws {
        guard let requested = Decimal(string: requestedAmount, locale: Locale(identifier: "en_US_POSIX")), !requested.isNaN else {
            throw SwapQuoteValidationError.requestedAmountMismatch
        }
        let userFixed: Decimal
        switch swapType {
        case Near1Click.Constants.exactInput, Near1Click.Constants.flexInput:
            userFixed = rawAmountIn
        case Near1Click.Constants.exactOutput:
            userFixed = rawAmountOut
        default:
            throw SwapQuoteValidationError.requestedAmountMismatch
        }
        guard !userFixed.isNaN else {
            throw SwapQuoteValidationError.requestedAmountMismatch
        }
        if NSDecimalNumber(decimal: userFixed).compare(NSDecimalNumber(decimal: requested)) != ComparisonResult.orderedSame {
            throw SwapQuoteValidationError.requestedAmountMismatch
        }
    }

    /// Full-precision, non-raising behavior for the consistency/slippage multiplications. A server-controlled
    /// amount can overflow `Decimal`; the default behavior raises an uncatchable NSDecimalNumberOverflowException,
    /// so this returns NaN on overflow and the callers fail closed instead of crashing.
    static let nonRaisingNoScale = NSDecimalNumberHandler(
        roundingMode: NSDecimalNumber.RoundingMode.plain, scale: Int16(NSDecimalNoScale),
        raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false
    )

    static let roundDownZeroScale = NSDecimalNumberHandler(
        roundingMode: NSDecimalNumber.RoundingMode.down, scale: 0,
        raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false
    )

    static let roundUpZeroScale = NSDecimalNumberHandler(
        roundingMode: NSDecimalNumber.RoundingMode.up, scale: 0,
        raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false
    )
}
