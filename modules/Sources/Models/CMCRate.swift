//
//  CMCRate.swift
//  Zashi
//
//  Created by Lukáš Korba on 26.11.2025.
//

import Foundation

public struct CMCPrice: Codable {
    public let data: [String: CMCAsset]
}

public struct CMCAsset: Codable {
    public let quote: [String: CMCCurrencyQuote]
}

public struct CMCCurrencyQuote: Codable {
    public let price: Double
}
