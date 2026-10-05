//
//  CoinMarketCapAPI.swift
//  Zashi
//

import Foundation

struct CoinMarketCapAPI: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum APIError: Error, Equatable {
        case missingAPIKey
        case invalidResponse
        case httpStatus(Int)
        case missingQuote
    }

    private enum Constants {
        static let scheme = "https"
        static let host = "pro-api.coinmarketcap.com"
        static let zecSymbol = "ZEC"
    }

    let apiKey: @Sendable () -> String?
    let access: @Sendable () -> WalletStorage.SwapAPIAccess
    let direct: Transport
    let tor: Transport

    func fiatCurrencies() async throws -> [CurrencyISO4217] {
        let data = try await authenticatedGET(path: "/v1/fiat/map")
        return try JSONDecoder().decode(CMCFiatMapResponse.self, from: data).supportedCurrencies()
    }

    func price(_ currency: CurrencyISO4217) async throws -> Double {
        let data = try await authenticatedGET(
            path: "/v1/cryptocurrency/quotes/latest",
            queryItems: [
                URLQueryItem(name: "symbol", value: Constants.zecSymbol),
                URLQueryItem(name: "convert", value: currency.code)
            ]
        )
        let response = try JSONDecoder().decode(CMCPrice.self, from: data)
        guard let price = response.data[Constants.zecSymbol]?.quote[currency.code]?.price else {
            throw APIError.missingQuote
        }
        return price
    }

    private func authenticatedGET(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        guard let apiKey = apiKey(),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.missingAPIKey
        }

        var components = URLComponents()
        components.scheme = Constants.scheme
        components.host = Constants.host
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-CMC_PRO_API_KEY")

        let result = access() == .direct
            ? try await direct(request)
            : try await tor(request)
        guard let response = result.1 as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.httpStatus(response.statusCode)
        }
        return result.0
    }
}
