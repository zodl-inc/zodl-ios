//
//  SwapSubmitHash.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-06-19.
//

/// Codable struct for JSON serialization
/// Submit transaction hash to speed up the process of swap on Near's side.
/// https://docs.near-intents.org/near-intents/integration/distribution-channels/1click-api#post-v0-deposit-submit
struct SwapSubmitHash: Codable, Equatable, Hashable {
    let txHash: String
    let depositAddress: String
}
