//
//  FiatCurrencyCatalogLiveKey.swift
//  Zashi
//

import ComposableArchitecture

extension FiatCurrencyCatalogClient: DependencyKey {
    static let liveValue: FiatCurrencyCatalogClient = {
        let repository = FiatCurrencyCatalogRepository {
            @Dependency(\.coinMarketCap) var coinMarketCap
            return try await coinMarketCap.fiatCurrencies()
        }

        return FiatCurrencyCatalogClient(
            observe: {
                await repository.observe()
            },
            ensureLoaded: {
                await repository.ensureLoaded()
            },
            refresh: {
                await repository.refresh()
            }
        )
    }()
}
