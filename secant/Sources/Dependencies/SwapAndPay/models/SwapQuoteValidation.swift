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

enum SwapQuoteValidator {
    /// The signed raw base-unit amount must equal the exact decimal expansion of the displayed
    /// `*Formatted` value. Exact-equality is intentional (the "trust the quote 0% or 100%" stance) and
    /// must not be relaxed to a tolerance.
    static func requireConsistent(name: String, raw: Decimal, formatted: Decimal, decimals: Int) throws {
        guard !raw.isNaN, !formatted.isNaN, (0...32).contains(decimals) else {
            throw SwapQuoteValidationError.amountInconsistency(field: name)
        }
        let expected = NSDecimalNumber(decimal: formatted).multiplying(byPowerOf10: Int16(decimals))
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
                .multiplying(by: denominator.subtracting(bps))
                .dividing(by: denominator, withBehavior: SwapQuoteValidator.roundDownZeroScale)
            if NSDecimalNumber(decimal: minAmountOut).compare(floor) == ComparisonResult.orderedAscending {
                throw SwapQuoteValidationError.slippageExceeded
            }

        case Near1Click.Constants.exactOutput:
            // Input floats: minAmountIn (worst-case max input) must be <= amountIn * (1 + slippage), rounded UP.
            let ceiling = NSDecimalNumber(decimal: amountIn)
                .multiplying(by: denominator.adding(bps))
                .dividing(by: denominator, withBehavior: SwapQuoteValidator.roundUpZeroScale)
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

    static let roundDownZeroScale = NSDecimalNumberHandler(
        roundingMode: NSDecimalNumber.RoundingMode.down, scale: 0,
        raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false
    )

    static let roundUpZeroScale = NSDecimalNumberHandler(
        roundingMode: NSDecimalNumber.RoundingMode.up, scale: 0,
        raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false
    )
}
