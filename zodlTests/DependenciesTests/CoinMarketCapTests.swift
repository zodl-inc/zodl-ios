//
//  CoinMarketCapTests.swift
//  zodlTests
//

import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

@Suite struct CoinMarketCapTests {
    private static let catalogData = Data(#"{"data":[{"id":1,"symbol":"CZK"},{"id":2,"symbol":"USD"}]}"#.utf8)

    @Test func directCatalogRequestIsAuthenticatedAndDecoded() async throws {
        let directCalls = LockIsolated(0)
        let api = CoinMarketCapAPI(
            apiKey: { "fixture-key" },
            access: { .direct },
            direct: { request in
                directCalls.withValue { $0 += 1 }
                #expect(request.url?.absoluteString == "https://pro-api.coinmarketcap.com/v1/fiat/map")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                #expect(request.value(forHTTPHeaderField: "X-CMC_PRO_API_KEY") == "fixture-key")
                return (Self.catalogData, try Self.response(for: request, statusCode: 200))
            },
            tor: { _ in
                Issue.record("Unexpected Tor request")
                throw URLError(.badServerResponse)
            }
        )

        #expect(try await api.fiatCurrencies().map(\.code) == ["CZK", "USD"])
        #expect(directCalls.value == 1)
    }

    @Test func protectedCatalogRequestUsesOnlyTor() async throws {
        let directCalls = LockIsolated(0)
        let torCalls = LockIsolated(0)
        let api = CoinMarketCapAPI(
            apiKey: { "fixture-key" },
            access: { .protected },
            direct: { _ in
                directCalls.withValue { $0 += 1 }
                throw URLError(.cannotConnectToHost)
            },
            tor: { request in
                torCalls.withValue { $0 += 1 }
                return (Self.catalogData, try Self.response(for: request, statusCode: 200))
            }
        )

        #expect(try await api.fiatCurrencies().map(\.code) == ["CZK", "USD"])
        #expect(torCalls.value == 1)
        #expect(directCalls.value == 0)
    }

    @Test func protectedTransportErrorNeverFallsBackToDirect() async {
        let directCalls = LockIsolated(0)
        let torCalls = LockIsolated(0)
        let api = CoinMarketCapAPI(
            apiKey: { "fixture-key" },
            access: { .protected },
            direct: { _ in
                directCalls.withValue { $0 += 1 }
                return (Data(), URLResponse())
            },
            tor: { _ in
                torCalls.withValue { $0 += 1 }
                throw URLError(.cannotConnectToHost)
            }
        )

        await #expect(throws: URLError.self) {
            _ = try await api.fiatCurrencies()
        }
        #expect(torCalls.value == 1)
        #expect(directCalls.value == 0)
    }

    @Test func eachRequestReadsTheCurrentAccessRoute() async throws {
        let access = LockIsolated<WalletStorage.SwapAPIAccess>(.direct)
        let directCalls = LockIsolated(0)
        let torCalls = LockIsolated(0)
        let api = CoinMarketCapAPI(
            apiKey: { "fixture-key" },
            access: { access.value },
            direct: { request in
                directCalls.withValue { $0 += 1 }
                return (Self.catalogData, try Self.response(for: request, statusCode: 200))
            },
            tor: { request in
                torCalls.withValue { $0 += 1 }
                return (Self.catalogData, try Self.response(for: request, statusCode: 200))
            }
        )

        _ = try await api.fiatCurrencies()
        access.setValue(.protected)
        _ = try await api.fiatCurrencies()

        #expect(directCalls.value == 1)
        #expect(torCalls.value == 1)
    }

    @Test func missingKeyRejectsBeforeChoosingATransport() async {
        await Self.assertMissingKeyIsRejected(nil)
    }

    @Test func whitespaceOnlyKeyRejectsBeforeChoosingATransport() async {
        await Self.assertMissingKeyIsRejected(" \n\t ")
    }

    @Test func nonHTTPResponseIsRejected() async throws {
        let api = Self.api(returning: (Data(), URLResponse(
            url: try #require(URL(string: "https://example.com")),
            mimeType: nil,
            expectedContentLength: 0,
            textEncodingName: nil
        )))

        do {
            _ = try await api.fiatCurrencies()
            Issue.record("Expected invalidResponse")
        } catch CoinMarketCapAPI.APIError.invalidResponse {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func unsuccessfulHTTPStatusIsRejected() async throws {
        let url = try #require(URL(string: "https://example.com"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: nil))
        let api = Self.api(returning: (Data(), response))

        do {
            _ = try await api.fiatCurrencies()
            Issue.record("Expected httpStatus")
        } catch CoinMarketCapAPI.APIError.httpStatus(let statusCode) {
            #expect(statusCode == 429)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func malformedCatalogJSONPropagatesDecodingError() async {
        let api = Self.api(returningJSON: #"{"data":[{"id":"invalid","symbol":"USD"}]}"#)

        await #expect(throws: DecodingError.self) {
            _ = try await api.fiatCurrencies()
        }
    }

    @Test func emptyFilteredCatalogPropagatesValidationError() async {
        let api = Self.api(returningJSON: #"{"data":[{"id":1,"symbol":"CUP"},{"id":2,"symbol":"ZZZ"}]}"#)

        await #expect(throws: CMCFiatMapResponse.ValidationError.self) {
            _ = try await api.fiatCurrencies()
        }
    }

    @Test func unknownProviderFieldsDoNotPreventCatalogDecoding() async throws {
        let api = Self.api(returningJSON: #"{"data":[{"id":1,"symbol":"USD","name":"United States Dollar"}],"status":{"error_code":0}}"#)

        #expect(try await api.fiatCurrencies() == [.usd])
    }

    @Test func priceRequestsTheSelectedCurrencyAndReturnsItsQuote() async throws {
        let czk = try #require(CurrencyISO4217(rawValue: "CZK"))
        let json = #"{"data":{"ZEC":{"quote":{"USD":{"price":12.5},"CZK":{"price":321.75}}}}}"#
        let api = CoinMarketCapAPI(
            apiKey: { "fixture-key" },
            access: { .direct },
            direct: { request in
                let url = try #require(request.url)
                let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                #expect(components.scheme == "https")
                #expect(components.host == "pro-api.coinmarketcap.com")
                #expect(components.path == "/v1/cryptocurrency/quotes/latest")
                #expect(components.queryItems == [
                    URLQueryItem(name: "symbol", value: "ZEC"),
                    URLQueryItem(name: "convert", value: "CZK")
                ])
                return (Data(json.utf8), try Self.response(for: request, statusCode: 200))
            },
            tor: { _ in
                Issue.record("Unexpected Tor request")
                throw URLError(.badServerResponse)
            }
        )

        #expect(try await api.price(czk) == 321.75)
    }

    @Test func missingRequestedQuoteDoesNotReturnUSD() async throws {
        let czk = try #require(CurrencyISO4217(rawValue: "CZK"))
        let api = Self.api(returningJSON: #"{"data":{"ZEC":{"quote":{"USD":{"price":12.5}}}}}"#)

        do {
            _ = try await api.price(czk)
            Issue.record("Expected missingQuote")
        } catch CoinMarketCapAPI.APIError.missingQuote {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func exchangeRateProviderDelegatesTheRequestedCurrency() async throws {
        let czk = try #require(CurrencyISO4217(rawValue: "CZK"))
        let requestedCurrency = LockIsolated<CurrencyISO4217?>(nil)

        let result = try await withDependencies {
            $0.coinMarketCap.price = { currency in
                requestedCurrency.setValue(currency)
                return 321.75
            }
        } operation: {
            try await ExchangeRateProvider().getCMCRate(for: czk)
        }

        #expect(result == 321.75)
        #expect(requestedCurrency.value == czk)
    }

    private static func assertMissingKeyIsRejected(_ key: String?) async {
        let directCalls = LockIsolated(0)
        let torCalls = LockIsolated(0)
        let api = CoinMarketCapAPI(
            apiKey: { key },
            access: { .direct },
            direct: { _ in
                directCalls.withValue { $0 += 1 }
                return (Data(), URLResponse())
            },
            tor: { _ in
                torCalls.withValue { $0 += 1 }
                return (Data(), URLResponse())
            }
        )

        do {
            _ = try await api.fiatCurrencies()
            Issue.record("Expected missingAPIKey")
        } catch CoinMarketCapAPI.APIError.missingAPIKey {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(directCalls.value == 0)
        #expect(torCalls.value == 0)
    }

    private static func api(returningJSON json: String) -> CoinMarketCapAPI {
        Self.api(returning: (
            Data(json.utf8),
            HTTPURLResponse(
                url: URL(fileURLWithPath: "/"),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ) ?? URLResponse()
        ))
    }

    private static func api(returning result: (Data, URLResponse)) -> CoinMarketCapAPI {
        CoinMarketCapAPI(
            apiKey: { "fixture-key" },
            access: { .direct },
            direct: { _ in result },
            tor: { _ in
                Issue.record("Unexpected Tor request")
                throw URLError(.badServerResponse)
            }
        )
    }

    private static func response(for request: URLRequest, statusCode: Int) throws -> HTTPURLResponse {
        let url = try #require(request.url)
        return try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
    }
}
