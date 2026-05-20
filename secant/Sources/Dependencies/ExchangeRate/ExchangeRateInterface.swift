//
//  ExchangeRateInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 08-02-2024.
//

import ComposableArchitecture
@preconcurrency import Combine

@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var exchangeRate: ExchangeRateClient {
        get { self[ExchangeRateClient.self] }
        set { self[ExchangeRateClient.self] = newValue }
    }
}

@DependencyClient
struct ExchangeRateClient {
    enum EchangeRateEvent: Equatable {
        case value(FiatCurrencyResult?)
        case refreshEnable(FiatCurrencyResult?)
        case stale(FiatCurrencyResult?)
    }
    
    enum RateSource: Equatable {
        case coinMarketCap
        case sdk
    }

    var exchangeRateEventStream: @Sendable () -> AnyPublisher<EchangeRateEvent, Never> = { Empty().eraseToAnyPublisher() }
    var refreshExchangeRateUSD: @Sendable () -> Void = { }
}
