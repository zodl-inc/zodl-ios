//
//  SafeNumericConversions.swift
//  Zashi
//

import Foundation
@preconcurrency import ZcashLightClientKit

extension NSDecimalNumber {
    /// `int64Value` clamped to the representable range. Never traps — unlike `Int64(self.doubleValue)`,
    /// which traps when the value exceeds `Int64`'s range or is non-finite.
    var clampedInt64Value: Int64 {
        if self.compare(NSDecimalNumber(value: Int64.max)) != ComparisonResult.orderedAscending {
            return Int64.max
        }
        if self.compare(NSDecimalNumber(value: Int64.min)) != ComparisonResult.orderedDescending {
            return Int64.min
        }
        return self.int64Value
    }
}

extension Zatoshi {
    /// Builds a `Zatoshi` from a zatoshi-denominated `Decimal`, returning nil (instead of trapping or
    /// wrapping) when the value is NaN, negative, or above the max ZEC supply. The fractional part is
    /// truncated DOWN.
    init?(safeZatoshiDecimal decimal: Decimal) {
        guard !decimal.isNaN, decimal >= Decimal(0) else {
            return nil
        }
        var rounded = Decimal()
        var value = decimal
        NSDecimalRound(&rounded, &value, 0, NSDecimalNumber.RoundingMode.down)

        let maxZatoshi = Decimal(21_000_000) * Decimal(Zatoshi.Constants.oneZecInZatoshi)
        guard rounded <= maxZatoshi else {
            return nil
        }
        self = Zatoshi(NSDecimalNumber(decimal: rounded).clampedInt64Value)
    }
}
