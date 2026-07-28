//
//  TransactionState.swift
//  Zashi
//
//  Created by Lukáš Korba on 26.04.2022.
//

import Foundation
import SwiftUI
@preconcurrency import ZcashLightClientKit

/// Representation of the transaction on the SDK side, used as a bridge to the TCA wallet side. 
struct TransactionState: Equatable, Identifiable {
    enum Status: Equatable {
        case failed
        case paid
        case received
        case receiving
        case sending
        case shielding
        case shielded
    }

    enum `Type`: Equatable {
        case zcash
        case swapToZec
        case swapFromZec
        case crossPay
    }

    var errorMessage: String?
    var expiryHeight: BlockHeight?
    var memoCount: Int
    var minedHeight: BlockHeight?
    var shielded = true
    var zAddress: String?
    var isSentTransaction: Bool
    var isShieldingTransaction: Bool
    var isTransparentRecipient: Bool

    var fee: Zatoshi?
    var id: String
    var status: Status
    var type = `Type`.zcash
    var timestamp: TimeInterval?
    var zecAmount: Zatoshi
    var isMarkedAsRead = false
    var isInAddressBook = false
    var hasTransparentOutputs = false
    var totalSpent: Zatoshi?
    var totalReceived: Zatoshi?
    /// The SDK's per-transaction note counts, carried so the display amount can detect a
    /// self-transfer (see `isSelfTransfer`) for rows whose `fee` isn't recorded yet. Default 0
    /// for the non-SDK inits (a pending send, a swap deposit). The swap-deposit init lands on
    /// the same 0/0 "note-less" shape, but it sets `totalReceived = .zero`; the
    /// `totalReceived.amount > 0` guards keep that (and any other genuinely amount-less state)
    /// on the `zecAmount` path.
    var sentNoteCount = 0
    var receivedNoteCount = 0
    /// Sum of this transaction's outputs that pay an explicit address and are not change
    /// (`recipient == .address` and `isChange == false`); zero when outputs are unavailable. For a
    /// self-transfer this is the deliberately sent portion. Both conditions are needed: shielded
    /// change carries no address (the SDK stores no address row for internal-scope notes), but a
    /// transparent internal or ephemeral output does carry one, so the address check on its own
    /// would fold transparent change back into the total.
    var externalOutputsTotal = Zatoshi.zero

    var rawID: Data? = nil
    
    // Swaps
    var swapToZecAmount: String? = nil
    var swapStatus = UMSwapId.SwapStatus.pending

    var isSwapToZec: Bool {
        type == .swapToZec
    }
    
    var isNonZcashActivity: Bool {
        type != .zcash
    }
    
    var requiresAutoUpdate: Bool {
        isNonZcashActivity && swapStatus == .pending
    }

    // UI Colors
    func balanceColor(_ colorScheme: ColorScheme) -> Color {
        (status == .failed || swapStatus == .failed || swapStatus == .expired || swapStatus == .refunded)
        ? Design.Utility.ErrorRed._600.color(colorScheme)
        : (isSpending || isShieldingTransaction)
        ? Design.Utility.ErrorRed._600.color(colorScheme)
        : Asset.Colors.primary.color
    }

    func titleColor(_ colorScheme: ColorScheme) -> Color {
        (status == .failed || swapStatus == .failed || swapStatus == .expired || swapStatus == .refunded)
        ? Design.Text.error.color(colorScheme)
        : !isSentTransaction
        ? Design.Utility.SuccessGreen._700.color(colorScheme)
        : Design.Text.primary.color(colorScheme)
    }
    
    func iconColor(_ colorScheme: ColorScheme) -> Color {
        (status == .failed || swapStatus == .failed || swapStatus == .expired || swapStatus == .refunded)
        ? Design.Utility.WarningYellow._500.color(colorScheme)
        : isPending
        ? Design.Utility.HyperBlue._500.color(colorScheme)
        : Design.Text.tertiary.color(colorScheme)
    }

    func iconGradientStartColor(_ colorScheme: ColorScheme) -> Color {
        (status == .failed || swapStatus == .failed || swapStatus == .expired || swapStatus == .refunded)
        ? Design.Utility.WarningYellow._50.color(colorScheme)
        : isPending
        ? Design.Utility.HyperBlue._50.color(colorScheme)
        : Design.Surfaces.bgSecondary.color(colorScheme)
    }

    func iconGradientEndColor(_ colorScheme: ColorScheme) -> Color {
        (status == .failed || swapStatus == .failed || swapStatus == .expired || swapStatus == .refunded)
        ? Design.Utility.WarningYellow._100.color(colorScheme)
        : isPending
        ? Design.Utility.HyperBlue._100.color(colorScheme)
        : Design.Surfaces.bgSecondary.color(colorScheme)
    }

    // UI Texts
    var address: String {
        zAddress ?? ""
    }
    
    func title(_ detailScreen: Bool = false) -> String {
        if type == .zcash {
            switch status {
            case .failed:
                return isShieldingTransaction
                ? String(localizable: .transactionFailedShieldedFunds)
                : isSentTransaction
                ? String(localizable: .transactionFailedSend)
                : String(localizable: .transactionFailedReceive)
            case .paid:
                return String(localizable: .transactionSent)
            case .received:
                return String(localizable: .transactionReceived)
            case .receiving:
                return String(localizable: .transactionReceiving)
            case .sending:
                return String(localizable: .transactionSending)
            case .shielding:
                return String(localizable: .transactionShieldingFunds)
            case .shielded:
                return String(localizable: .transactionShieldedFunds)
            }
        } else {
            if swapStatus == .pending || (!detailScreen && swapStatus == .incomplete) {
                switch type {
                case .swapToZec, .swapFromZec: return String(localizable: .swapStatusSwapping)
                case .crossPay: return String(localizable: .swapStatusPaying)
                default: return ""
                }
            } else if detailScreen && swapStatus == .incomplete {
                switch type {
                case .swapToZec, .swapFromZec: return String(localizable: .swapStatusSwapIncomplete)
                case .crossPay: return String(localizable: .swapStatusPaymentIncomplete)
                default: return ""
                }
            } else if swapStatus == .refunded {
                switch type {
                case .swapToZec, .swapFromZec: return String(localizable: .swapStatusSwapRefunded)
                case .crossPay: return String(localizable: .swapStatusPaymentRefunded)
                default: return ""
                }
            } else if swapStatus == .failed {
                switch type {
                case .swapToZec, .swapFromZec: return String(localizable: .swapStatusSwapFailed)
                case .crossPay: return String(localizable: .swapStatusPaymentFailed)
                default: return ""
                }
            } else if swapStatus == .expired {
                switch type {
                case .swapToZec, .swapFromZec: return String(localizable: .swapStatusSwapExpired)
                case .crossPay: return String(localizable: .swapStatusPaymentExpired)
                default: return ""
                }
            } else {
                switch type {
                case .swapToZec, .swapFromZec: return String(localizable: .swapStatusSwapped)
                case .crossPay: return String(localizable: .swapStatusPaid)
                default: return ""
                }
            }
        }
    }

    var dateString: String? {
        guard let timestamp else { return nil }
        
        return Date(timeIntervalSince1970: timestamp).asHumanReadable()
    }

    var listDateString: String? {
        guard let timestamp else { return nil }

        let formatter = DateFormatter()
        let date = Date(timeIntervalSince1970: timestamp)
        formatter.dateFormat = "MMM d '\(String(localizable: .filterAt))' h:mm a"
        return formatter.string(from: date)
    }
    
    var listDateYearString: String? {
        guard let timestamp else { return nil }

        let formatter = DateFormatter()
        let date = Date(timeIntervalSince1970: timestamp)
        formatter.dateFormat = "MMM d, YYYY '\(String(localizable: .filterAt))' h:mm a"
        return formatter.string(from: date)
    }

    var daysAgo: String {
        guard let timestamp else { return "" }
        
        let transactionDate = Date(timeIntervalSince1970: timestamp)
        
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfGivenDate = calendar.startOfDay(for: transactionDate)
        let components = calendar.dateComponents([.day], from: startOfGivenDate, to: startOfToday)
        
        if let daysAgo = components.day {
            if daysAgo == 0 {
                return String(localizable: .filterToday)
            } else if daysAgo == 1 {
                return String(localizable: .filterYesterday)
            } else if daysAgo < 31 {
                return String(localizable: .filterDaysAgo(String(daysAgo)))
            } else {
                return listDateString ?? ""
            }
        } else {
            return ""
        }
    }

    // Helper flags
    var isPending: Bool {
        if type == .zcash {
            switch status {
            case .failed:
                return false
            case .paid:
                return false
            case .received:
                return false
            case .receiving:
                return true
            case .sending:
                return true
            case .shielded:
                return false
            case .shielding:
                return true
            }
        } else {
            return swapStatus == .pending || swapStatus == .incomplete
        }
    }

    /// The purpose of this flag is to help understand if the transaction affected the wallet and a user paid a fee
    var isSpending: Bool {
        if type == .zcash {
            switch status {
            case .paid, .sending:
                return true
            case .received, .receiving:
                return false
            case .shielded, .shielding:
                return false
            case .failed:
                return isSentTransaction
            }
        } else {
            return (type == .crossPay || type == .swapFromZec)
        }
    }

    /// A sent transaction every output of which returned to this account — a manual send to
    /// one's own address, or an Orchard -> Ironwood migration crossing. Detected by the net
    /// balance delta being exactly the fee (nothing left the wallet), with the SDK's note-count
    /// shape as a fallback for rows whose fee is not yet recorded. Detection deliberately does not
    /// consult the DB's `is_change` flag, which upstream documents as unreliable for self-sends
    /// (`externalOutputsTotal` does use it, but only to keep change out of a sum).
    ///
    /// A shielding transaction is excluded even though it has the same fee-collapsed shape: it
    /// moves funds between the user's own pools rather than to an address, and it has its own
    /// display amount (`totalSpent`, see `resolvedAmount`).
    var isSelfTransfer: Bool {
        guard isSentTransaction, !isShieldingTransaction else { return false }
        if let fee, fee.amount > 0, zecAmount.amount == fee.amount {
            return true
        }
        return sentNoteCount == 0 && receivedNoteCount == 0 && (totalReceived?.amount ?? 0) > 0
    }

    var transationIcon: Image {
        if type == .crossPay {
            return Asset.Assets.Icons.trPaid.image
        } else if isSwapToZec {
            return Asset.Assets.Icons.trIn.image
        } else if isShieldingTransaction {
            return Asset.Assets.shieldTick.image
        } else if isSentTransaction {
            return Asset.Assets.Icons.trOut.image
        } else {
            return Asset.Assets.Icons.trIn.image
        }
    }

    // Values
    var totalAmount: Zatoshi {
        Zatoshi(zecAmount.amount + (fee?.amount ?? 0))
    }
    
    var resolvedAmount: Zatoshi {
        if isShieldingTransaction {
            return Zatoshi(totalSpent?.amount ?? 0)
        }
        if isSelfTransfer {
            // A self-transfer's zecAmount is just the fee. Show what actually moved instead:
            // the outputs deliberately addressed to the user's own address (a manual self-send),
            // or — when every output is wallet-internal (the dedicated Orchard -> Ironwood
            // migration) — the full amount that crossed, totalReceived.
            if externalOutputsTotal.amount > 0 {
                return externalOutputsTotal
            }
            if let totalReceived, totalReceived.amount > 0 {
                return totalReceived
            }
        }
        return zecAmount
    }

    var netValue: String {
        resolvedAmount.atLeastThreeDecimalsZashiFormatted()
    }

    var amountWithoutFee: Zatoshi {
        isSelfTransfer
        ? resolvedAmount
        : Zatoshi(zecAmount.amount - (fee?.amount ?? 0))
    }

    init(
        errorMessage: String? = nil,
        expiryHeight: BlockHeight? = nil,
        memoCount: Int = 0,
        minedHeight: BlockHeight? = nil,
        shielded: Bool = true,
        zAddress: String? = nil,
        fee: Zatoshi?,
        id: String,
        status: Status,
        timestamp: TimeInterval? = nil,
        zecAmount: Zatoshi,
        isSentTransaction: Bool = false,
        isShieldingTransaction: Bool = false,
        isTransparentRecipient: Bool = false,
        isMarkedAsRead: Bool = false
    ) {
        self.errorMessage = errorMessage
        self.expiryHeight = expiryHeight
        self.memoCount = memoCount
        self.minedHeight = minedHeight
        self.shielded = shielded
        self.zAddress = zAddress
        self.fee = fee
        self.id = id
        self.status = status
        self.timestamp = timestamp
        self.zecAmount = zecAmount
        self.isSentTransaction = isSentTransaction
        self.isShieldingTransaction = isShieldingTransaction
        self.isTransparentRecipient = isTransparentRecipient
        self.isMarkedAsRead = isMarkedAsRead
    }
    
    init(
        pendingSendId id: String,
        zecAmount: Zatoshi
    ) {
        self.id = id
        self.status = .sending
        self.zecAmount = zecAmount
        self.isSentTransaction = true
        self.fee = nil
        self.memoCount = 0
        self.isShieldingTransaction = false
        self.isTransparentRecipient = false
    }

    func confirmationsWith(_ latestMinedHeight: BlockHeight?) -> BlockHeight {
        guard let minedHeight, let latestMinedHeight, minedHeight > 0, latestMinedHeight > 0 else {
            return 0
        }
        
        return latestMinedHeight - minedHeight
    }
    
    func transactionListHeight(_ mempoolHeight: BlockHeight) -> BlockHeight {
        var tlHeight = mempoolHeight
        
        if let minedHeight = minedHeight {
            tlHeight = minedHeight
        } else if let expiredHeight = expiryHeight, expiredHeight > 0 {
            tlHeight = expiredHeight
        }
        
        return tlHeight
    }
    
    mutating func checkAndUpdateWith(_ swap: UMSwapId) {
        // crosspay
        if !swap.exactInput && type != .crossPay {
            type = .crossPay
        }
        
        // pending
        if swapStatus != swap.swapStatus {
            swapStatus = swap.swapStatus
        }
    }
}

extension TransactionState {
    init(
        transaction: ZcashTransaction.Overview,
        memos: [Memo]? = nil,
        hasTransparentOutputs: Bool = false,
        currentChainTip: BlockHeight? = nil,
        outputs: [ZcashTransaction.Output] = []
    ) {
        expiryHeight = transaction.expiryHeight
        minedHeight = transaction.minedHeight
        fee = transaction.fee
        id = transaction.rawID.toHexStringTxId()
        timestamp = transaction.blockTime
        isSentTransaction = transaction.isSentTransaction
        isShieldingTransaction = transaction.isShielding
        zecAmount = isSentTransaction ? Zatoshi(-transaction.value.amount) : transaction.value
        isTransparentRecipient = false
        self.hasTransparentOutputs = hasTransparentOutputs
        memoCount = transaction.memoCount
        totalSpent = transaction.totalSpent
        totalReceived = transaction.totalReceived
        sentNoteCount = transaction.sentNoteCount
        receivedNoteCount = transaction.receivedNoteCount
        externalOutputsTotal = Zatoshi(
            outputs.reduce(Int64(0)) { total, output in
                if case .address = output.recipient, !output.isChange {
                    return total + output.value.amount
                }
                return total
            }
        )

        let isPending = isSentTransaction ? minedHeight == nil : transaction.state == .pending
        // Fallback for when the SDK's `expired_unmined` column lags (e.g. an unmined sent tx
        // that was pending across a consensus-rule change keeps reporting `.pending` indefinitely).
        let chainTipPastExpiry: Bool
        if isSentTransaction,
           minedHeight == nil,
           let expiry = transaction.expiryHeight, expiry > 0,
           let tip = currentChainTip,
           tip >= expiry {
            chainTipPastExpiry = true
        } else {
            chainTipPastExpiry = false
        }
        let isExpired = transaction.state == .expired || chainTipPastExpiry
        
        // failed check
        if isExpired {
            status = .failed
        } else if isShieldingTransaction {
            status = isPending ? .shielding : .shielded
        } else {
            switch (isSentTransaction, isPending) {
            case (true, true): status = .sending
            case (true, false): status = .paid
            case (false, true): status = .receiving
            case (false, false): status = .received
            }
        }
    }
    
    init(
        depositAddress: String,
        timestamp: TimeInterval,
        zecAmount: String? = nil,
        swapStatus: UMSwapId.SwapStatus
    ) {
        zAddress = depositAddress
        self.timestamp = timestamp
        swapToZecAmount = zecAmount
            memoCount = 0
        isSentTransaction = true
        isShieldingTransaction = false
        isTransparentRecipient = true
        hasTransparentOutputs = true
        status = .sending
        type = .swapToZec
        self.zecAmount = .zero
        id = depositAddress
        self.swapStatus = swapStatus

        expiryHeight = nil
        minedHeight = nil
        fee = .zero
        totalSpent = .zero
        totalReceived = .zero
    }
}

// MARK: - Placeholders

extension TransactionState {
    static func placeholder(
        amount: Zatoshi = .zero,
        fee: Zatoshi = .zero,
        shielded: Bool = true,
        status: Status = .received,
        timestamp: TimeInterval = 0.0,
        uuid: String = UUID().debugDescription
    ) -> TransactionState {
        .init(
            expiryHeight: -1,
            minedHeight: -1,
            shielded: shielded,
            zAddress: nil,
            fee: fee,
            id: uuid,
            status: status,
            timestamp: timestamp,
            zecAmount: status == .received ? amount : Zatoshi(-amount.amount)
        )
    }
    
    static let mockedSent = TransactionState(
        minedHeight: BlockHeight(1),
        zAddress: "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3",
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .paid,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_000_000)
    )
    
    static let mockedReceived = TransactionState(
        minedHeight: BlockHeight(1),
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .received,
        timestamp: 1699292621,
        zecAmount: Zatoshi(25_000_000)
    )
    
    static let mockedFailed = TransactionState(
        minedHeight: nil,
        zAddress: "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3",
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .failed,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_108_700),
        isSentTransaction: true
    )
    
    static let mockedFailedReceive = TransactionState(
        minedHeight: nil,
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .failed,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_001_000),
        isSentTransaction: false
    )
    
    static let mockedSending = TransactionState(
        minedHeight: nil,
        zAddress: "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3",
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .sending,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_000_000),
        isSentTransaction: true
    )
    
    static let mockedReceiving = TransactionState(
        minedHeight: nil,
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .receiving,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_000_000),
        isSentTransaction: false
    )
    
    static let mockedShielded = TransactionState(
        minedHeight: BlockHeight(1),
        zAddress: "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3",
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .shielded,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_000_000),
        isShieldingTransaction: true
    )
    
    static let mockedShieldedExpanded = TransactionState(
        minedHeight: BlockHeight(1),
        zAddress: "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3",
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .shielded,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_000_000),
        isShieldingTransaction: true
    )
}

struct TransactionStateMockHelper {
    var date: TimeInterval
    var amount: Zatoshi
    var shielded = true
    var status: TransactionState.Status = .received
    var uuid = ""
    
    init(
        date: TimeInterval,
        amount: Zatoshi,
        shielded: Bool = true,
        status: TransactionState.Status = .received,
        uuid: String = ""
    ) {
        self.date = date
        self.amount = amount
        self.shielded = shielded
        self.status = status
        self.uuid = uuid
    }
}
