//
//  File.swift
//
//
//  Created by Lukáš Korba on 22.05.2024.
//

import Foundation
@preconcurrency import ZcashLightClientKit

struct CurrencyISO4217: RawRepresentable, Hashable, Codable, Sendable {
    static let usd = CurrencyISO4217(knownCode: "USD")
    static let eur = CurrencyISO4217(knownCode: "EUR")
    static let gbp = CurrencyISO4217(knownCode: "GBP")
    static let jpy = CurrencyISO4217(knownCode: "JPY")
    static let cad = CurrencyISO4217(knownCode: "CAD")
    static let aud = CurrencyISO4217(knownCode: "AUD")
    static let chf = CurrencyISO4217(knownCode: "CHF")
    static let cny = CurrencyISO4217(knownCode: "CNY")
    static let krw = CurrencyISO4217(knownCode: "KRW")
    static let brl = CurrencyISO4217(knownCode: "BRL")
    static let inr = CurrencyISO4217(knownCode: "INR")
    static let mxn = CurrencyISO4217(knownCode: "MXN")
    static let sgd = CurrencyISO4217(knownCode: "SGD")
    static let hkd = CurrencyISO4217(knownCode: "HKD")
    static let nok = CurrencyISO4217(knownCode: "NOK")
    static let sek = CurrencyISO4217(knownCode: "SEK")
    static let dkk = CurrencyISO4217(knownCode: "DKK")
    static let nzd = CurrencyISO4217(knownCode: "NZD")
    static let ngn = CurrencyISO4217(knownCode: "NGN")
    static let zar = CurrencyISO4217(knownCode: "ZAR")
    static let `try` = CurrencyISO4217(knownCode: "TRY")
    static let pln = CurrencyISO4217(knownCode: "PLN")
    static let thb = CurrencyISO4217(knownCode: "THB")

    let rawValue: String

    var code: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .usd: return "$"
        case .eur: return "€"
        case .gbp: return "£"
        case .jpy, .cny: return "¥"
        case .krw: return "₩"
        case .inr: return "₹"
        case .ngn: return "₦"
        case .`try`: return "₺"
        case .thb: return "฿"
        default: return rawValue
        }
    }

    var displayName: String {
        Locale.current.localizedString(forCurrencyCode: rawValue) ?? rawValue
    }

    init?(rawValue: String) {
        let code = rawValue.uppercased()
        guard code.utf8.count == 3, code.utf8.allSatisfy({ (65...90).contains($0) }) else {
            return nil
        }
        self.rawValue = code
    }

    private init(knownCode: String) {
        rawValue = knownCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let code = try container.decode(String.self)
        guard let currency = CurrencyISO4217(rawValue: code) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid currency code")
        }
        self = currency
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    func formatNumericAmount(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code

        return Decimal(value).formatted(
            .number
                .precision(.fractionLength(formatter.maximumFractionDigits))
                .locale(locale)
        )
    }
}

struct CurrencyConversion: Equatable {
    let iso4217: CurrencyISO4217
    let ratio: Double
    let timestamp: TimeInterval

    init(_ iso4217: CurrencyISO4217, ratio: Double, timestamp: TimeInterval) {
        self.iso4217 = iso4217
        self.ratio = (ratio * Double(1_000_000)).rounded(.down) / Double(1_000_000)
        self.timestamp = timestamp
    }

    func convert(_ zatoshi: Zatoshi) -> Double {
        ratio * (Double(zatoshi.amount) / Double(100_000_000))
    }

    func convert(_ zatoshi: Zatoshi) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = iso4217.code

        // For currencies with a unicode symbol, use it directly.
        // For others (symbol == rawValue), append a non-breaking space for readability.
        if iso4217.symbol == iso4217.rawValue {
            formatter.currencySymbol = iso4217.code + "\u{00A0}"
        } else {
            formatter.currencySymbol = iso4217.symbol
        }

        // Zero-decimal currencies should not show fractional digits
        switch iso4217 {
        case .jpy, .krw:
            formatter.maximumFractionDigits = 0
            formatter.minimumFractionDigits = 0
        default:
            break
        }

        return formatter.string(from: NSDecimalNumber(decimal: Decimal(convert(zatoshi)))) ?? ""
    }

    func convert(_ currency: Double) -> Zatoshi {
        Zatoshi(Int64((currency / ratio) * Double(100_000_000)))
    }
}
