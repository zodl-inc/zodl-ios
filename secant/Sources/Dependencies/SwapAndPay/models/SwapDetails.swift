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
        case unknown

        var isPending: Bool {
            self == .pending || self == .pendingDeposit || self == .processing
        }

        /// Whether the swap is still in-flight and must keep being polled for status updates.
        /// `.unknown` is included so a transient or unrecognized server status keeps being polled
        /// (it may resolve to a real status on a later poll) instead of being treated as terminal —
        /// while `isPending` stays false for it so it is never shown as a benign pending swap
        /// (MOB-1354 / iOS-Z10).
        var requiresPolling: Bool {
            isPending || self == .unknown
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
            case .unknown: return SwapConstants.unknown
            }
        }

        /// Fail-closed mapping of a server status string. An unrecognized value maps to `.unknown`
        /// rather than silently to `.pending` (MOB-1354 / iOS-Z10), so a garbage or tampered status
        /// can't be presented as a benign "pending" swap.
        static func from(serverStatus: String, isSwapToZec: Bool) -> SwapDetails.Status {
            if isSwapToZec {
                switch serverStatus {
                case SwapConstants.pendingDeposit: return .pendingDeposit
                case SwapConstants.refunded: return .refunded
                case SwapConstants.success: return .success
                case SwapConstants.failed: return .failed
                case SwapConstants.incompleteDeposit: return .incompleteDeposit
                case SwapConstants.processing: return .processing
                default: return .unknown
                }
            } else {
                switch serverStatus {
                case SwapConstants.incompleteDeposit: return .incompleteDeposit
                case SwapConstants.pendingDeposit: return .pending
                case SwapConstants.refunded: return .refunded
                case SwapConstants.success: return .success
                default: return .unknown
                }
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
