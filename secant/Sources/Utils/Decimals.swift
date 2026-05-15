//
//  Decimals.swift
//  modules
//
//  Created by Lukáš Korba on 29.06.2025.
//

import Foundation

extension Decimal {
    /// Rounds self to the smallest number of decimal digits ≥ minScale,
    /// such that the relative difference is below the threshold.
    var simplified: Decimal {
        guard self != 0 else { return 0 }

        /// Tolerance 0.5%
        let tolerance: Decimal = 0.005
        /// At least 2 floating points
        let minimumFractionDigits = 2
        /// At most 8 floating points
        let maximumFractionDigits = 8
        
        for scale in minimumFractionDigits...maximumFractionDigits {
            let rounded = self.rounded(scale: scale)
            let relativeDifference = abs((self - rounded) / self)
            if relativeDifference <= tolerance {
                return rounded
            }
        }

        return self.rounded(scale: maximumFractionDigits)
    }

    private func rounded(scale: Int, mode: NSDecimalNumber.RoundingMode = .bankers) -> Decimal {
        var result = self
        var value = self
        NSDecimalRound(&result, &value, scale, mode)
        return result
    }
}
