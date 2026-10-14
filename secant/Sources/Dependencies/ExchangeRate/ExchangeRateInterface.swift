//
//  ExchangeRateInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 08-02-2024.
//

import ComposableArchitecture
@preconcurrency import Combine

@preconcurrency import ZODLSwiftWalletSDK

extension DependencyValues {
    var exchangeRate: ExchangeRateClient {
        get { self[ExchangeRateClient.self] }
        set { self[ExchangeRateClient.self] = newValue }
    }
}

@DependencyClient
struct ExchangeRateClient: Sendable {
    enum EchangeRateEvent: Equatable, Sendable {
        // Each event carries the currency the rate was fetched for, so consumers never have to
        // re-derive it (which would mislabel a rate when the selection changes mid-flight).
        case value(FiatCurrencyResult?, CurrencyISO4217)
        case refreshEnable(FiatCurrencyResult?, CurrencyISO4217)
        case stale(FiatCurrencyResult?, CurrencyISO4217)
    }
    
    enum RateSource: Equatable, Sendable {
        case coinMarketCap
        case sdk
    }

    enum RateAvailability: Equatable, Sendable {
        // No event consumed yet (or only the CurrentValueSubject's seed nil). The rate may
        // still arrive — callers should not surface "unavailable" UX in this state.
        case loading
        // Most recent event delivered a rate.
        case available
        // Most recent event was `.stale`, i.e. the provider has given up on the current fetch
        // attempt and there is no rate to show.
        case unavailable
    }

    var exchangeRateEventStream: @Sendable () -> AnyPublisher<EchangeRateEvent, Never> = { Empty().eraseToAnyPublisher() }
    var rateAvailability: @Sendable () -> RateAvailability = { .loading }
    var refreshExchangeRateUSD: @Sendable () -> Void = { }
    var selectedCurrency: @Sendable () -> CurrencyISO4217 = { .usd }
}
