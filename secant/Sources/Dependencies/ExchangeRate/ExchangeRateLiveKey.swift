//
//  ExchangeRateLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 08-02-2024.
//

import Foundation
@preconcurrency import Combine

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@MainActor final class ExchangeRateProvider {
    enum Constants {
        static let cmcRateURL = "https://pro-api.coinmarketcap.com/v1/cryptocurrency/quotes/latest?symbol=ZEC&convert=USD"
        static let zecKey = "ZEC"
    }

    private var cancellable: AnyCancellable? = nil
    nonisolated let eventStream = CurrentValueSubject<ExchangeRateClient.EchangeRateEvent, Never>(.value(nil))
    private var latestRate: FiatCurrencyResult? = nil
    private var refreshTimer: Timer? = nil
    private var staleTimer: Timer? = nil
    private var isStale = false
    private var nilValuesCounter = 0
    private var isSetUp = false

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

    nonisolated func getCMCRate() async throws -> Double {
        guard let cmcKey = PartnerKeys.cmcKey else {
            throw "CMC API Key missing"
        }

        @Dependency(\.sdkSynchronizer) var sdkSynchronizer
        @Shared(.inMemory(.swapAPIAccess)) var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct

        guard let url = URL(string: Constants.cmcRateURL) else {
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
            if let zec = result.data[Constants.zecKey] {
                return zec.quote.USD.price
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

            if rateSource == .coinMarketCap {
                Task(priority: .low) { [weak self] in
                    guard let self else { return }
                    do {
                        let price = try await getCMCRate()

                        let fiat = FiatCurrencyResult(
                            date: Date(),
                            rate: NSDecimalNumber(value: price),
                            state: .success
                        )

                        eventStream.send(.value(fiat))
                    } catch {
                        coinMarketCapRateFailed()
                    }
                }
            } else if rateSource == .sdk {
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer

                sdkSynchronizer.refreshExchangeRateUSD()
            }
        }
    }

    func coinMarketCapRateFailed() {
        refreshExchangeRateUSD(.sdk)
    }

    func resolveResult(_ result: FiatCurrencyResult?) {
        // retry logic for nil value
        guard let result else {
            nilValuesCounter += 1

            if nilValuesCounter == 2 {
                refreshExchangeRateUSD(.coinMarketCap)
            } else if nilValuesCounter > 2 {
                eventStream.send(.stale(latestRate))
            }

            return
        }

        latestRate = result

        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

        if isStale
            && result.state != .fetching
            && Date().timeIntervalSince1970 - result.date.timeIntervalSince1970 > zcashSDKEnvironment.exchangeRateStaleLimit() {
            eventStream.send(.stale(latestRate))
        } else {
            eventStream.send(.value(latestRate))
        }

        rescheduleTimer()
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
                eventStream.send(.refreshEnable(latestRate))
            } else {
                refreshTimer?.invalidate()
                refreshTimer = Timer.scheduledTimer(withTimeInterval: timeToSchedule, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshTimer?.invalidate()
                        self?.refreshTimer = nil

                        self?.eventStream.send(.refreshEnable(self?.latestRate))
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
            refreshExchangeRateUSD: {
                Task { @MainActor in
                    exchangeRateProvider.refreshExchangeRateUSD()
                }
            }
        )
    }
}
