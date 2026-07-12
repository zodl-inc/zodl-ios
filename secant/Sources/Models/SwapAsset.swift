//
//  SwapAsset.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-05-14.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Codable struct for JSON serialization
/// Supported Near tokens 
/// https://docs.near-intents.org/near-intents/integration/distribution-channels/1click-api#get-v0-tokens
struct SwapAsset: Equatable, Codable, Identifiable, Hashable {
    var id: String {
        "\(provider).\(chain).\(token)".lowercased()
    }

    var idWithoutProvider: String {
        "\(chain).\(token)".lowercased()
    }

    var chainName: String {
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
    
    var tokenName: String {
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

    var chainIcon: Image {
#if canImport(UIKit)
        guard let icon = PlatformImage(named: "chain_\(chain.lowercased())") else {
            return Asset.Assets.Tickers.none.image
        }
        return Image(platformImage: icon)
#else
        guard let icon = NSImage(named: "chain_\(chain.lowercased())") else {
            return Asset.Assets.Tickers.none.image
        }
        return Image(nsImage: icon)
#endif
    }

    var tokenIcon: Image {
        // USDT0 is Tether's omnichain USDT — reuse the USDT logo (no dedicated art).
        let iconName = token.lowercased() == "usdt0" ? "usdt" : token.lowercased()
#if canImport(UIKit)
        guard let icon = PlatformImage(named: iconName) else {
            return Asset.Assets.Tickers.none.image
        }
        return Image(platformImage: icon)
#else
        guard let icon = NSImage(named: iconName) else {
            return Asset.Assets.Tickers.none.image
        }
        return Image(nsImage: icon)
#endif
    }

    var provider: String
    var chain: String
    let token: String
    let assetId: String
    let usdPrice: Decimal
    let decimals: Int
    
    init(
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

extension SwapAsset {
    /// Fallback chain list for the address book when the live (curated) swap-asset
    /// list hasn't loaded yet. Mirrors the chains behind the curated offering
    /// (`Near1Click.Constants.supportedAssetIds`, MOB-1472) so creating a contact
    /// only offers chains you can actually swap. Keep in sync with that list.
    /// Deliberately excludes "zec": Zcash is recognized automatically from the
    /// address, not a manually-pickable contact chain.
    static func curatedChains() -> [SwapAsset] {
        ["arb", "avax", "base", "bsc", "btc", "eth", "ltc", "near", "pol", "sol", "sui", "tron", "xrp"].map {
            SwapAsset(provider: "", chain: $0, token: "", assetId: "", usdPrice: 0, decimals: 0)
        }
    }
}
