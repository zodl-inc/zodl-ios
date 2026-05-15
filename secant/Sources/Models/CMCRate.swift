//
//  CMCRate.swift
//  Zashi
//
//  Created by Lukáš Korba on 26.11.2025.
//

import Foundation

struct CMCPrice: Codable {
    let data: [String: CMCAsset]
}

struct CMCAsset: Codable {
    let quote: [String: CMCCurrencyQuote]
}

struct CMCCurrencyQuote: Codable {
    let price: Double
}
