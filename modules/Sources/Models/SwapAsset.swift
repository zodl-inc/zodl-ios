//
//  SwapAsset.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-05-14.
//

import SwiftUI
import Generated

/// Codable struct for JSON serialization
/// Supported Near tokens 
/// https://docs.near-intents.org/near-intents/integration/distribution-channels/1click-api#get-v0-tokens
public struct SwapAsset: Equatable, Codable, Identifiable, Hashable {
    public var id: String {
        "\(provider).\(chain).\(token)".lowercased()
    }

    public var idWithoutProvider: String {
        "\(chain).\(token)".lowercased()
    }

    public var chainName: String {
        switch chain.lowercased() {
        case "arb": return "Arbitrum"
        case "btc": return "Bitcoin"
        case "eth": return "Ethereum"
        case "xrp": return "Ripple"
        case "sol": return "Solana"
        case "zec": return "Zcash"
        case "avax": return "Avalanche"
        case "bsc": return "Binance Smart Chain"
        case "op": return "Optimism"
        case "pol": return "Polygon"
        case "ada": return "Cardano"
        case "xlm": return "Stellar"
        case "aptos": return "Aptos"
        case "bch": return "Bitcoin Cash"
        case "xlayer": return "X Layer"
        case "ltc": return "Litecoin"
        default: return chain.capitalized
        }
    }
    
    public var tokenName: String {
        switch token.lowercased() {
        case "btc": return "Bitcoin"
        case "eth": return "Ethereum"
        case "near": return "Near"
        case "sol": return "Solana"
        case "tron": return "Tron"
        case "xrp": return "Ripple"
        case "zec": return "Zcash"
        case "avax": return "Avalanche"
        case "bsc": return "Binance Smart Chain"
        case "op": return "Optimism"
        case "pol": return "Polygon"
        case "ada": return "Cardano"
        case "ltc": return "Litecoin"
        case "bch": return "Bitcoin Cash"
        default: return token
        }
    }

    public var chainIcon: Image {
        guard let icon = UIImage(named: "chain_\(chain.lowercased())") else {
            return Asset.Assets.Tickers.none.image
        }

        return Image(uiImage: icon)
    }

    public var tokenIcon: Image {
        guard let icon = UIImage(named: token.lowercased()) else {
            return Asset.Assets.Tickers.none.image
        }

        return Image(uiImage: icon)
    }

    public var provider: String
    public var chain: String
    public let token: String
    public let assetId: String
    public let usdPrice: Decimal
    public let decimals: Int
    
    public init(
        provider: String,
        chain: String,
        token: String,
        assetId: String,
        usdPrice: Decimal,
        decimals: Int
    ) {
        self.provider = provider
        self.chain = chain
        self.token = token
        self.assetId = assetId
        self.usdPrice = usdPrice
        self.decimals = decimals
    }
}

public extension SwapAsset {
    static func hardcodedChains() -> [SwapAsset] {
        var template = SwapAsset(provider: "", chain: "arb", token: "", assetId: "", usdPrice: 0, decimals: 0)
        
        let arb = template; template.chain = "base"
        let base = template; template.chain = "bera"
        let bera = template; template.chain = "btc"
        let btc = template; template.chain = "eth"
        let eth = template; template.chain = "gnosis"
        let gnosis = template; template.chain = "near"
        let near = template; template.chain = "sol"
        let sol = template; template.chain = "tron"
        let tron = template; template.chain = "xrp"
        let xrp = template; template.chain = "doge"
        let doge = template; template.chain = "avax"
        let avax = template; template.chain = "bsc"
        let bsc = template; template.chain = "op"
        let op = template; template.chain = "pol"
        let pol = template; template.chain = "sui"
        let sui = template; template.chain = "ton"
        let ltc = template; template.chain = "ltc"
        let ton = template

        return [
            arb, avax, base, bera, bsc, btc, doge, eth, gnosis, near, op, pol, sol, sui, ton, tron, ltc, xrp
        ]
    }
}
