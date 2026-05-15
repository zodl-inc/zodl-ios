//
//  SwapDetails.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-06-23.
//

import Foundation

/// Codable struct for JSON serialization
/// Check the status of a swap.
/// https://docs.near-intents.org/near-intents/integration/distribution-channels/1click-api#get-v0-status
struct SwapDetails: Codable, Equatable, Hashable {
    enum Status: Codable, Equatable, Hashable {
        case failed
        case pending
        case incompleteDeposit
        case pendingDeposit
        case processing
        case refunded
        case success
        case expired

        var isPending: Bool {
            self == .pending || self == .pendingDeposit || self == .processing
        }
        
        var rawName: String {
            switch self {
            case .failed: return SwapConstants.failed
            case .pending: return SwapConstants.pendingDeposit
            case .pendingDeposit: return SwapConstants.pendingDeposit
            case .incompleteDeposit: return SwapConstants.incompleteDeposit
            case .processing: return SwapConstants.processing
            case .refunded: return SwapConstants.refunded
            case .success: return SwapConstants.success
            case .expired: return SwapConstants.expired
            }
        }
    }
    
    let amountInFormatted: Decimal?
    let amountInUsd: String?
    let amountOutFormatted: Decimal?
    let amountOutUsd: String?
    let fromAsset: String?
    let toAsset: String?
    let isSwap: Bool
    let slippage: Decimal?
    let status: Status
    let refundedAmountFormatted: Decimal?
    let swapRecipient: String?
    let addressToCheckShield: String
    let whenInitiated: String
    let deadline: String
    let depositedAmountFormatted: Decimal?

    var isSwapToZec: Bool {
        toAsset == "nep141:zec.omft.near"
    }
    
    init(
        amountInFormatted: Decimal?,
        amountInUsd: String?,
        amountOutFormatted: Decimal?,
        amountOutUsd: String?,
        fromAsset: String?,
        toAsset: String?,
        isSwap: Bool,
        slippage: Decimal?,
        status: Status,
        refundedAmountFormatted: Decimal?,
        swapRecipient: String?,
        addressToCheckShield: String,
        whenInitiated: String,
        deadline: String,
        depositedAmountFormatted: Decimal?
    ) {
        self.amountInFormatted = amountInFormatted
        self.amountInUsd = amountInUsd
        self.amountOutFormatted = amountOutFormatted
        self.amountOutUsd = amountOutUsd
        self.fromAsset = fromAsset
        self.toAsset = toAsset
        self.isSwap = isSwap
        self.slippage = slippage
        self.status = status
        self.refundedAmountFormatted = refundedAmountFormatted
        self.swapRecipient = swapRecipient
        self.addressToCheckShield = addressToCheckShield
        self.whenInitiated = whenInitiated
        self.deadline = deadline
        self.depositedAmountFormatted = depositedAmountFormatted
    }
}
