//
//  ExchangeRateInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 08-02-2024.
//

import ComposableArchitecture
import Combine

import Models
import ZcashLightClientKit

extension DependencyValues {
    public var exchangeRate: ExchangeRateClient {
        get { self[ExchangeRateClient.self] }
        set { self[ExchangeRateClient.self] = newValue }
    }
}

@DependencyClient
public struct ExchangeRateClient {
    public enum EchangeRateEvent: Equatable {
        case value(FiatCurrencyResult?)
        case refreshEnable(FiatCurrencyResult?)
        case stale(FiatCurrencyResult?)
    }
    
    public enum RateSource: Equatable {
        case coinMarketCap
        case sdk
    }

    public let exchangeRateEventStream: () -> AnyPublisher<EchangeRateEvent, Never>
    public var refreshExchangeRateUSD: () -> Void
    public var selectedCurrency: () -> CurrencyISO4217 = { .usd }
}
