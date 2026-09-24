//
//  CoinMarketCapInterface.swift
//  Zashi
//

import ComposableArchitecture

extension DependencyValues {
    var coinMarketCap: CoinMarketCapClient {
        get { self[CoinMarketCapClient.self] }
        set { self[CoinMarketCapClient.self] = newValue }
    }
}

@DependencyClient
struct CoinMarketCapClient: Sendable {
    var fiatCurrencies: @Sendable () async throws -> [CurrencyISO4217]
    var price: @Sendable (CurrencyISO4217) async throws -> Double
}
