//
//  FiatCurrencyCatalogInterface.swift
//  Zashi
//

import ComposableArchitecture

struct FiatCurrencyCatalogState: Equatable, Sendable {
    var currencies: [CurrencyISO4217] = []
    var isLoading = false
    var hasError = false
}

extension DependencyValues {
    var fiatCurrencyCatalog: FiatCurrencyCatalogClient {
        get { self[FiatCurrencyCatalogClient.self] }
        set { self[FiatCurrencyCatalogClient.self] = newValue }
    }
}

@DependencyClient
struct FiatCurrencyCatalogClient: Sendable {
    var observe: @Sendable () async -> AsyncStream<FiatCurrencyCatalogState> = {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
    var ensureLoaded: @Sendable () async -> Void = {}
    var refresh: @Sendable () async -> Void = {}
}
