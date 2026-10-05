//
//  CoinMarketCapLiveKey.swift
//  Zashi
//

import ComposableArchitecture
import Foundation

extension CoinMarketCapClient: DependencyKey {
    static let liveValue = CoinMarketCapClient(
        fiatCurrencies: {
            try await CoinMarketCapAPI.live().fiatCurrencies()
        },
        price: { currency in
            try await CoinMarketCapAPI.live().price(currency)
        }
    )
}

private extension CoinMarketCapAPI {
    static func live() -> CoinMarketCapAPI {
        @Dependency(\.sdkSynchronizer)
        var sdkSynchronizer

        return CoinMarketCapAPI(
            apiKey: { PartnerKeys.cmcKey },
            access: {
                @Shared(.inMemory(.swapAPIAccess))
                var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct
                return swapAPIAccess
            },
            direct: { request in
                try await URLSession.shared.data(for: request)
            },
            tor: { request in
                let (data, response) = try await sdkSynchronizer.httpRequestOverTor(request)
                return (data, response as URLResponse)
            }
        )
    }
}
