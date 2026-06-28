//
//  MigrationFiat.swift
//  zodl
//
//  PROTOTYPE-ONLY mock fiat conversion for the migration screens. The Figma mockups show a USD value
//  next to each transfer/amount; the production app already has a real exchange-rate source. This is a
//  fixed placeholder rate so the prototype visually matches the designs — it is NOT a real quote and
//  goes away with the dummy engine.
//

import Foundation
@preconcurrency import ZcashLightClientKit

enum MigrationFiat {
    /// Derived from the Figma mock (12.458 ZEC ≈ $1,248.32).
    static let usdPerZec = 100.2

    /// Formats a zatoshi amount as a mock USD string, e.g. "$135.22".
    static func string(for amount: Zatoshi) -> String {
        let zec = Double(amount.amount) / 100_000_000.0
        let usd = zec * usdPerZec
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: usd as NSNumber) ?? "$\(usd)"
    }
}
