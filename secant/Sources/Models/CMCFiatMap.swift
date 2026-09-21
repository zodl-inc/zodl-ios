//
//  CMCFiatMap.swift
//

import Foundation

struct CMCFiatMapResponse: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let id: Int
        let symbol: String
    }

    enum ValidationError: Error {
        case noSupportedCurrencies
    }

    static let excludedCodes: Set<String> = ["CUP", "IRR", "RUB"]
    static let knownCodes = Set(Locale.Currency.isoCurrencies.map(\.identifier))

    let data: [Entry]

    func supportedCurrencies(knownCodes: Set<String> = Self.knownCodes) throws -> [CurrencyISO4217] {
        var seen = Set<String>()
        let currencies = data.compactMap { entry -> CurrencyISO4217? in
            let code = entry.symbol.uppercased()
            guard !Self.excludedCodes.contains(code),
                  knownCodes.contains(code),
                  let currency = CurrencyISO4217(rawValue: code),
                  seen.insert(code).inserted else {
                return nil
            }
            return currency
        }
        guard !currencies.isEmpty else {
            throw ValidationError.noSupportedCurrencies
        }
        return currencies
    }
}
