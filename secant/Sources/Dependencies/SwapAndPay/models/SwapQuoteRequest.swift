//
//  SwapQuoteRequest.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-05-30.
//

struct AppFee: Codable, Equatable, Hashable {
    let recipient: String
    let fee: Int
}

/// Codable struct for JSON serialization
/// Request a quote of Near's Swap
/// https://docs.near-intents.org/near-intents/integration/distribution-channels/1click-api#post-v0-quote
struct SwapQuoteRequest: Codable, Equatable, Hashable {
    let dry: Bool
    let swapType: String
    let slippageTolerance: Int
    let originAsset: String
    let depositType: String
    let destinationAsset: String
    let amount: String
    let refundTo: String
    let refundType: String
    let recipient: String
    let recipientType: String
    let deadline: String
    let referral: String?
    let quoteWaitingTimeMs: Int
    let appFees: [AppFee]?
    
    init(
        dry: Bool,
        swapType: String,
        slippageTolerance: Int,
        originAsset: String,
        depositType: String,
        destinationAsset: String,
        amount: String,
        refundTo: String,
        refundType: String,
        recipient: String,
        recipientType: String,
        deadline: String,
        referral: String? = nil,
        quoteWaitingTimeMs: Int,
        appFees: [AppFee]? = nil
    ) {
        self.dry = dry
        self.swapType = swapType
        self.slippageTolerance = slippageTolerance
        self.originAsset = originAsset
        self.depositType = depositType
        self.destinationAsset = destinationAsset
        self.amount = amount
        self.refundTo = refundTo
        self.refundType = refundType
        self.recipient = recipient
        self.recipientType = recipientType
        self.deadline = deadline
        self.referral = referral
        self.quoteWaitingTimeMs = quoteWaitingTimeMs
        self.appFees = appFees
    }
}
