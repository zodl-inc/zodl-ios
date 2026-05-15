//
//  File.swift
//
//
//  Created by Lukáš Korba on 22.05.2024.
//

import Foundation
@preconcurrency import ZcashLightClientKit

// Both will be defined in the SDK
enum CurrencyISO4217: String, CaseIterable, Equatable, Codable {
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

        if iso4217.symbol == iso4217.rawValue {
            formatter.currencySymbol = iso4217.code + "\u{00A0}"
        } else {
            formatter.currencySymbol = iso4217.symbol
        }

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
