//
//  ExchangeRateLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 08-02-2024.
//

import Foundation
@preconcurrency import Combine

import ComposableArchitecture
@preconcurrency import ZODLSwiftWalletSDK

// FiatCurrencyResult is a value type whose stored members (Date, NSDecimalNumber, State enum) are all Sendable;
// the SDK simply hasn't declared the conformance. Swift mandates `@unchecked Sendable` for retroactive conformance —
// a checked variant isn't permitted across module boundaries — so this is the only way to let the value cross from
// Combine's emitting queue into the @MainActor Task below without the SDK shipping the conformance itself.
extension FiatCurrencyResult: @retroactive @unchecked Sendable {}

@MainActor final class ExchangeRateProvider {
    enum Constants {
        static let cmcRateBaseURL = "https://pro-api.coinmarketcap.com/v1/cryptocurrency/quotes/latest?symbol=ZEC&convert="
        static let zecKey = "ZEC"
    }

    private var cancellable: AnyCancellable? = nil
    nonisolated let eventStream = CurrentValueSubject<ExchangeRateClient.EchangeRateEvent, Never>(.value(nil, .usd))
    private var latestRate: FiatCurrencyResult? = nil
    private var latestRateCurrency: CurrencyISO4217 = .usd
    private var refreshTimer: Timer? = nil
    private var staleTimer: Timer? = nil
    private var isStale = false
    private var isAwaitingSDKFallback = false
    private var isSetUp = false
    private var cachedCurrency: CurrencyISO4217 = .usd

    // nonisolated init() — empty, so live() can create it without main actor context
    nonisolated init() {}

    func setup() {
        guard !isSetUp else { return }
        isSetUp = true
        if !_XCTIsTesting {
            @Dependency(\.sdkSynchronizer) var sdkSynchronizer

            cancellable = sdkSynchronizer.exchangeRateUSDStream().sink { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.resolveResult(result)
                }
            }
        }
    }

    func selectedCurrency() -> CurrencyISO4217 {
        @Dependency(\.userStoredPreferences) var userStoredPreferences
        let currency = userStoredPreferences.exchangeRate()?.currency ?? .usd
        cachedCurrency = currency
        return currency
    }

    nonisolated func getCMCRate(for currency: CurrencyISO4217 = .usd) async throws -> Double {
        guard let cmcKey = PartnerKeys.cmcKey else {
            throw "CMC API Key missing"
        }

        @Dependency(\.sdkSynchronizer) var sdkSynchronizer
        @Shared(.inMemory(.swapAPIAccess)) var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct

        guard let url = URL(string: Constants.cmcRateBaseURL + currency.code) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cmcKey, forHTTPHeaderField: "X-CMC_PRO_API_KEY")

        let (data, response) = swapAPIAccess == .direct
        ? try await URLSession.shared.data(for: request)
        : try await sdkSynchronizer.httpRequestOverTor(request)

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw "httpStatus \(code)"
        }

        if let result = try? JSONDecoder().decode(CMCPrice.self, from: data) {
            if let zec = result.data[Constants.zecKey],
               let quote = zec.quote[currency.code] {
                return quote.price
            }
        }

        throw "Decode CMCPrice.self failed"
    }

    func refreshExchangeRateUSD(_ rateSource: ExchangeRateClient.RateSource = .coinMarketCap) {
        setup()
        if !_XCTIsTesting {
            // guard the feature is opted-in by a user
            @Dependency(\.userStoredPreferences) var userStoredPreferences

            guard let exchangeRate = userStoredPreferences.exchangeRate(), exchangeRate.automatic else {
                return
            }

            guard refreshTimer == nil else {
                return
            }

            let currency = exchangeRate.currency
            cachedCurrency = currency

            if rateSource == .coinMarketCap {
                Task(priority: .low) { [weak self] in
                    guard let self else { return }
                    do {
                        let price = try await getCMCRate(for: currency)

                        let fiat = FiatCurrencyResult(
                            date: Date(),
                            rate: NSDecimalNumber(value: price),
                            state: .success
                        )

                        self.latestRate = fiat
                        self.latestRateCurrency = currency
                        self.isAwaitingSDKFallback = false
                        eventStream.send(.value(fiat, currency))
                    } catch {
                        coinMarketCapRateFailed(currency: currency)
                    }
                }
            } else if rateSource == .sdk {
                // SDK fallback only provides USD rates
                if currency == .usd {
                    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                    sdkSynchronizer.refreshExchangeRateUSD()
                } else {
                    eventStream.send(.stale(latestRate, currency))
                }
            }
        }
    }

    func coinMarketCapRateFailed(currency: CurrencyISO4217 = .usd) {
        // SDK USD fallback is temporarily disabled: TorClient.getExchangeRateUSD() traps on
        // first use after isolatedClient() bootstrap (filed against zcash-swift-wallet-sdk).
        // Until the SDK is fixed, surface every CMC failure as the unavailable state and let
        // the user retry, instead of crashing the app via the Tor path.
        //
        // Only offer the cached rate as a stale fallback when it was fetched for `currency`;
        // a rate priced in a different currency must never be surfaced under this one.
        let staleRate = latestRateCurrency == currency ? latestRate : nil
        eventStream.send(.stale(staleRate, currency))
    }

    func resolveResult(_ result: FiatCurrencyResult?) {
        // SDK stream only provides USD — ignore when a different currency is selected
        guard cachedCurrency == .usd else { return }

        guard let result else {
            // The SDK pushes nil here only when a fetch we triggered failed without a cached value.
            // Initial CurrentValueSubject nils and unrelated transients are ignored.
            if isAwaitingSDKFallback {
                isAwaitingSDKFallback = false
                eventStream.send(.stale(latestRate, .usd))
            }
            return
        }

        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

        switch result.state {
        case .success:
            isAwaitingSDKFallback = false
            latestRate = result
            latestRateCurrency = .usd

            if isStale
                && Date().timeIntervalSince1970 - result.date.timeIntervalSince1970 > zcashSDKEnvironment.exchangeRateStaleLimit() {
                eventStream.send(.stale(latestRate, .usd))
            } else {
                eventStream.send(.value(latestRate, .usd))
            }

            rescheduleTimer()

        case .fetching:
            // In-flight — propagate so the UI can show a progress indicator. Keep the fallback flag set
            // until SDK delivers a terminal result.
            latestRate = result
            latestRateCurrency = .usd
            eventStream.send(.value(latestRate, .usd))

        case .error:
            isAwaitingSDKFallback = false
            eventStream.send(.stale(latestRate, .usd))
        }
    }

    func rescheduleTimer() {
        guard let latestRate else {
            return
        }

        if latestRate.state == .success {
            @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

            isStale = false

            let diff = Date().timeIntervalSince1970 - latestRate.date.timeIntervalSince1970
            let timeToSchedule = zcashSDKEnvironment.exchangeRateIPRateLimit() - diff

            if timeToSchedule < 0 {
                eventStream.send(.refreshEnable(latestRate, .usd))
            } else {
                refreshTimer?.invalidate()
                refreshTimer = Timer.scheduledTimer(withTimeInterval: timeToSchedule, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshTimer?.invalidate()
                        self?.refreshTimer = nil

                        self?.eventStream.send(.refreshEnable(self?.latestRate, .usd))
                    }
                }

                staleTimer?.invalidate()
                staleTimer = Timer.scheduledTimer(withTimeInterval: zcashSDKEnvironment.exchangeRateStaleLimit(), repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.staleTimer?.invalidate()
                        self?.staleTimer = nil

                        self?.isStale = true
                        self?.refreshExchangeRateUSD()
                    }
                }
            }
        }
    }
}

extension ExchangeRateClient: DependencyKey {
    static let liveValue: ExchangeRateClient = Self.live()

    static func live() -> Self {
        let exchangeRateProvider = ExchangeRateProvider()

        Task { @MainActor in
            exchangeRateProvider.setup()
        }

        return ExchangeRateClient(
            exchangeRateEventStream: { exchangeRateProvider.eventStream.eraseToAnyPublisher() },
            rateAvailability: {
                switch exchangeRateProvider.eventStream.value {
                case .value(nil, _):
                    return .loading
                case .value, .refreshEnable:
                    return .available
                case .stale:
                    return .unavailable
                }
            },
            refreshExchangeRateUSD: {
                Task { @MainActor in
                    exchangeRateProvider.refreshExchangeRateUSD()
                }
            },
            selectedCurrency: {
                @Dependency(\.userStoredPreferences) var userStoredPreferences
                return userStoredPreferences.exchangeRate()?.currency ?? .usd
            }
        )
    }
}
