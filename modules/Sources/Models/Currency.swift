//
//  File.swift
//
//
//  Created by Lukáš Korba on 22.05.2024.
//

import Foundation
import ZcashLightClientKit

// Both will be defined in the SDK
public enum CurrencyISO4217: String, CaseIterable, Equatable, Codable {
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    case jpy = "JPY"
    case cad = "CAD"
    case aud = "AUD"
    case chf = "CHF"
    case cny = "CNY"
    case krw = "KRW"
    case brl = "BRL"
    case inr = "INR"
    case mxn = "MXN"
    case sgd = "SGD"
    case hkd = "HKD"
    case nok = "NOK"
    case sek = "SEK"
    case dkk = "DKK"
    case nzd = "NZD"
    case ngn = "NGN"
    case zar = "ZAR"
    case `try` = "TRY"
    case pln = "PLN"
    case thb = "THB"

    public var code: String {
        rawValue
    }

    public var symbol: String {
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

    public var displayName: String {
        Locale.current.localizedString(forCurrencyCode: rawValue) ?? rawValue
    }
}

public struct CurrencyConversion: Equatable {
    public let iso4217: CurrencyISO4217
    public let ratio: Double
    public let timestamp: TimeInterval

    public init(_ iso4217: CurrencyISO4217, ratio: Double, timestamp: TimeInterval) {
        self.iso4217 = iso4217
        self.ratio = (ratio * Double(1_000_000)).rounded(.down) / Double(1_000_000)
        self.timestamp = timestamp
    }

    public func convert(_ zatoshi: Zatoshi) -> Double {
        ratio * (Double(zatoshi.amount) / Double(100_000_000))
    }

    public func convert(_ zatoshi: Zatoshi) -> String {
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

    public func convert(_ currency: Double) -> Zatoshi {
        Zatoshi(Int64((currency / ratio) * Double(100_000_000)))
    }
}
