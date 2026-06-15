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
        let expected = NSDecimalNumber(decimal: formatted).multiplying(byPowerOf10: Int16(decimals))
        if NSDecimalNumber(decimal: raw).compare(expected) != ComparisonResult.orderedSame {
            throw SwapQuoteValidationError.amountInconsistency(field: name)
        }
    }
}
