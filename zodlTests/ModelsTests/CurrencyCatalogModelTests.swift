//
//  CurrencyCatalogModelTests.swift
//  zodlTests
//

import Foundation
import Testing
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite
struct CurrencyCatalogModelTests {
    @Test
    func newCurrencyKeepsTheLegacyStringEncoding() throws {
        let currency = try #require(CurrencyISO4217(rawValue: "CZK"))

        #expect(currency.code == "CZK")
        #expect(try JSONEncoder().encode(currency) == Data(#""CZK""#.utf8))
        #expect(try JSONDecoder().decode(CurrencyISO4217.self, from: Data(#""CZK""#.utf8)) == currency)
    }

    @Test
    func oldPreferenceWithoutCurrencyStillDefaultsToUSD() throws {
        let data = Data(#"{"manual":true,"automatic":true}"#.utf8)

        let saved = try JSONDecoder().decode(UserPreferencesStorage.ExchangeRate.self, from: data)

        #expect(saved.currency == .usd)
        #expect(saved.automatic)
    }

    @Test(
        "Invalid raw currency codes are rejected",
        arguments: ["", "US", "ZZZ1", " € ", "ÜSD"]
    )
    func invalidRawCurrencyCodesAreRejected(code: String) {
        #expect(CurrencyISO4217(rawValue: code) == nil)
    }

    @Test
    func lowercaseCurrencyCodeIsCanonicalized() throws {
        let currency = try #require(CurrencyISO4217(rawValue: "czk"))

        #expect(currency.rawValue == "CZK")
    }

    @Test
    func equalityAndHashingUseTheCanonicalCode() throws {
        let uppercase = try #require(CurrencyISO4217(rawValue: "CZK"))
        let lowercase = try #require(CurrencyISO4217(rawValue: "czk"))

        #expect(uppercase == lowercase)
        #expect(Set([uppercase, lowercase]).count == 1)
    }

    @Test
    func newCurrencyRoundTripsThroughExchangeRatePreferences() throws {
        let currency = try #require(CurrencyISO4217(rawValue: "CZK"))
        let saved = UserPreferencesStorage.ExchangeRate(manual: true, automatic: false, currency: currency)

        let encoded = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(UserPreferencesStorage.ExchangeRate.self, from: encoded)

        #expect(decoded == saved)
        #expect(decoded.currency == currency)
    }

    @Test
    func providerOrderAndThreeExclusionsArePreserved() throws {
        let rows: [String] = ["czk", "CUP", "USD", "IRR", "CZK", "RUB", "KWD", "ZZZ", "US", " USD"]
        let response = CMCFiatMapResponse(data: rows.enumerated().map {
            CMCFiatMapResponse.Entry(id: $0.offset, symbol: $0.element)
        })

        let currencies = try response.supportedCurrencies(knownCodes: ["CZK", "USD", "KWD", "CUP", "IRR", "RUB"])

        #expect(currencies.map(\.code) == ["CZK", "USD", "KWD"])
        #expect(CMCFiatMapResponse.excludedCodes == ["CUP", "IRR", "RUB"])
    }

    @Test(
        "Malformed provider responses fail decoding",
        arguments: [
            #"{"data":[{"symbol":"USD"}]}"#,
            #"{"data":[{"id":"1","symbol":"USD"}]}"#,
            #"{"data":[{"id":1}]}"#,
            #"{"data":[{"id":1,"symbol":1}]}"#,
            #"{}"#,
            #"{"data":{}}"#
        ]
    )
    func malformedProviderResponsesFailDecoding(json: String) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CMCFiatMapResponse.self, from: Data(json.utf8))
        }
    }

    @Test
    func extraProviderFieldsAreIgnored() throws {
        let json = #"{"data":[{"id":1,"symbol":"USD","name":"United States Dollar"}],"status":{"error_code":0}}"#

        let response = try JSONDecoder().decode(CMCFiatMapResponse.self, from: Data(json.utf8))

        #expect(response.data.count == 1)
        #expect(response.data.first?.id == 1)
        #expect(response.data.first?.symbol == "USD")
    }

    @Test(
        "Provider results with no supported currencies fail validation",
        arguments: [
            [] as [String],
            ["CUP", "IRR", "RUB"],
            ["ZZZ", "QQQ"]
        ]
    )
    func providerResultsWithNoSupportedCurrenciesFailValidation(symbols: [String]) {
        let response = CMCFiatMapResponse(data: symbols.enumerated().map {
            CMCFiatMapResponse.Entry(id: $0.offset, symbol: $0.element)
        })

        do {
            _ = try response.supportedCurrencies(knownCodes: ["USD", "CUP", "IRR", "RUB"])
            Issue.record("Expected noSupportedCurrencies validation error")
        } catch CMCFiatMapResponse.ValidationError.noSupportedCurrencies {
            // Expected.
        } catch {
            Issue.record("Unexpected validation error: \(error)")
        }
    }

    @Test
    func currencyFormattingUsesISO4217FractionDigits() throws {
        let amount = Zatoshi(100_000_000)
        let value = 12.3456
        let vnd = try #require(CurrencyISO4217(rawValue: "VND"))
        let kwd = try #require(CurrencyISO4217(rawValue: "KWD"))
        let czk = try #require(CurrencyISO4217(rawValue: "CZK"))
        let cases = [
            (currency: vnd, fractionDigits: 0),
            (currency: kwd, fractionDigits: 3),
            (currency: czk, fractionDigits: 2),
            (currency: CurrencyISO4217.usd, fractionDigits: 2)
        ]

        for testCase in cases {
            let conversion = CurrencyConversion(testCase.currency, ratio: value, timestamp: 0)
            let formatted: String = conversion.convert(amount)

            #expect(formatted == expectedFormatting(for: testCase.currency, value: value, fractionDigits: testCase.fractionDigits))
            #expect(visibleFractionDigitCount(in: formatted) == testCase.fractionDigits)
            #expect(formatted != expectedFormatting(
                for: testCase.currency,
                value: value,
                fractionDigits: (testCase.fractionDigits + 1) % 4
            ))
        }
    }

    @Test
    func legacyCurrencySymbolsArePreserved() {
        #expect(CurrencyISO4217.usd.symbol == "$")
        #expect(CurrencyISO4217.eur.symbol == "€")
        #expect(CurrencyISO4217.gbp.symbol == "£")
        #expect(CurrencyISO4217.jpy.symbol == "¥")
        #expect(CurrencyISO4217.cny.symbol == "¥")
        #expect(CurrencyISO4217.krw.symbol == "₩")
        #expect(CurrencyISO4217.inr.symbol == "₹")
        #expect(CurrencyISO4217.ngn.symbol == "₦")
        #expect(CurrencyISO4217.try.symbol == "₺")
        #expect(CurrencyISO4217.thb.symbol == "฿")
        #expect(CurrencyISO4217.cad.symbol == "CAD")
    }

    private func expectedFormatting(
        for currency: CurrencyISO4217,
        value: Double,
        fractionDigits: Int
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.code
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits

        if currency.symbol == currency.rawValue {
            formatter.currencySymbol = "\(currency.code)\u{00A0}"
        } else {
            formatter.currencySymbol = currency.symbol
        }

        return formatter.string(from: NSDecimalNumber(value: value)) ?? ""
    }

    private func visibleFractionDigitCount(in formatted: String) -> Int {
        guard let separator = Locale.current.decimalSeparator,
              let separatorRange = formatted.range(of: separator) else {
            return 0
        }
        return formatted[separatorRange.upperBound...].prefix(while: \.isNumber).count
    }
}
