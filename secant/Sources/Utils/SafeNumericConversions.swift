//
//  SafeNumericConversions.swift
//  Zashi
//

import Foundation
@preconcurrency import ZcashLightClientKit

extension NSDecimalNumber {
    private static let int64MaxValue = NSDecimalNumber(value: Int64.max)
    private static let int64MinValue = NSDecimalNumber(value: Int64.min)
    /// Truncates the fractional part DOWN before the `Int64` conversion. `NSDecimalNumber.int64Value`
    /// returns 0 for any value with a fractional part, so it must be rounded to integer scale first.
    private static let truncatingBehavior = NSDecimalNumberHandler(
        roundingMode: NSDecimalNumber.RoundingMode.down, scale: 0,
        raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false
    )

    /// `Int64` value clamped to the representable range, with any fractional part truncated DOWN. Never
    /// traps — unlike `Int64(self.doubleValue)`, which traps when the value exceeds `Int64`'s range or is
    /// non-finite. A NaN maps to `0`. `NSDecimalNumber.int64Value` returns `0` for any non-integer value,
    /// so the value is rounded to integer scale before that conversion.
    var clampedInt64Value: Int64 {
        if self.doubleValue.isNaN {
            return 0
        }
        if self.compare(NSDecimalNumber.int64MaxValue) != ComparisonResult.orderedAscending {
            return Int64.max
        }
        if self.compare(NSDecimalNumber.int64MinValue) != ComparisonResult.orderedDescending {
            return Int64.min
        }
        return self.rounding(accordingToBehavior: NSDecimalNumber.truncatingBehavior).int64Value
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

        let maxZatoshi = Decimal(Zatoshi.Constants.maxZatoshi)
        guard rounded <= maxZatoshi else {
            return nil
        }
        self = Zatoshi(NSDecimalNumber(decimal: rounded).clampedInt64Value)
    }
}
