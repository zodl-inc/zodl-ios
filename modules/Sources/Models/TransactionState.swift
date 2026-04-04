//
//  TransactionState.swift
//  Zashi
//
//  Created by Lukáš Korba on 26.04.2022.
//

import Foundation
import SwiftUI
import ZcashLightClientKit
import Generated

/// Representation of the transaction on the SDK side, used as a bridge to the TCA wallet side. 
public struct TransactionState: Equatable, Identifiable {
    public enum Status: Equatable {
        case failed
        case paid
        case received
        case receiving
        case sending
        case shielding
        case shielded
    }

    public enum `Type`: Equatable {
        case zcash
        case swapToZec
        case swapFromZec
        case crossPay
    }

    public var errorMessage: String?
    public var expiryHeight: BlockHeight?
    public var memoCount: Int
    public var minedHeight: BlockHeight?
    public var shielded = true
    public var zAddress: String?
    public var isSentTransaction: Bool
    public var isShieldingTransaction: Bool
    public var isTransparentRecipient: Bool

    public var fee: Zatoshi?
    public var id: String
    public var status: Status
    public var type = `Type`.zcash
    public var timestamp: TimeInterval?
    public var zecAmount: Zatoshi
    public var isMarkedAsRead = false
    public var isInAddressBook = false
    public var hasTransparentOutputs = false
    public var totalSpent: Zatoshi?
    public var totalReceived: Zatoshi?

    public var rawID: Data? = nil
    public var isPIRDetectedSpend = false

    // Swaps
    public var swapToZecAmount: String? = nil
    public var swapStatus = UMSwapId.SwapStatus.pending

    public var isSwapToZec: Bool {
        type == .swapToZec
    }
    
    public var isNonZcashActivity: Bool {
        type != .zcash
    }
    
    public var requiresAutoUpdate: Bool {
        isNonZcashActivity && swapStatus == .pending
    }

    // UI Colors
    public func balanceColor(_ colorScheme: ColorScheme) -> Color {
        (status == .failed || swapStatus == .failed || swapStatus == .expired || swapStatus == .refunded)
        ? Design.Utility.ErrorRed._600.color(colorScheme)
        : (isSpending || isShieldingTransaction)
        ? Design.Utility.ErrorRed._600.color(colorScheme)
        : Asset.Colors.primary.color
    }

    public func titleColor(_ colorScheme: ColorScheme) -> Color {
        (status == .failed || swapStatus == .failed || swapStatus == .expired || swapStatus == .refunded)
        ? Design.Text.error.color(colorScheme)
        : !isSentTransaction
        ? Design.Utility.SuccessGreen._700.color(colorScheme)
        : Design.Text.primary.color(colorScheme)
    }
    
    public func iconColor(_ colorScheme: ColorScheme) -> Color {
        (status == .failed || swapStatus == .failed || swapStatus == .expired || swapStatus == .refunded)
        ? Design.Utility.WarningYellow._500.color(colorScheme)
        : isPending
        ? Design.Utility.HyperBlue._500.color(colorScheme)
        : Design.Text.tertiary.color(colorScheme)
    }

    public func iconGradientStartColor(_ colorScheme: ColorScheme) -> Color {
        (status == .failed || swapStatus == .failed || swapStatus == .expired || swapStatus == .refunded)
        ? Design.Utility.WarningYellow._50.color(colorScheme)
        : isPending
        ? Design.Utility.HyperBlue._50.color(colorScheme)
        : Design.Surfaces.bgSecondary.color(colorScheme)
    }

    public func iconGradientEndColor(_ colorScheme: ColorScheme) -> Color {
        (status == .failed || swapStatus == .failed || swapStatus == .expired || swapStatus == .refunded)
        ? Design.Utility.WarningYellow._100.color(colorScheme)
        : isPending
        ? Design.Utility.HyperBlue._100.color(colorScheme)
        : Design.Surfaces.bgSecondary.color(colorScheme)
    }

    // UI Texts
    public var address: String {
        zAddress ?? ""
    }
    
    public func title(_ detailScreen: Bool = false) -> String {
        if isPIRDetectedSpend {
            return L10n.Transaction.pirDetected
        }
        if type == .zcash {
            switch status {
            case .failed:
                return isShieldingTransaction
                ? L10n.Transaction.failedShieldedFunds
                : isSentTransaction
                ? L10n.Transaction.failedSend
                : L10n.Transaction.failedReceive
            case .paid:
                return L10n.Transaction.sent
            case .received:
                return L10n.Transaction.received
            case .receiving:
                return L10n.Transaction.receiving
            case .sending:
                return L10n.Transaction.sending
            case .shielding:
                return L10n.Transaction.shieldingFunds
            case .shielded:
                return L10n.Transaction.shieldedFunds
            }
        } else {
            if swapStatus == .pending || (!detailScreen && swapStatus == .incomplete) {
                switch type {
                case .swapToZec, .swapFromZec: return L10n.SwapStatus.swapping
                case .crossPay: return L10n.SwapStatus.paying
                default: return ""
                }
            } else if detailScreen && swapStatus == .incomplete {
                switch type {
                case .swapToZec, .swapFromZec: return L10n.SwapStatus.swapIncomplete
                case .crossPay: return L10n.SwapStatus.paymentIncomplete
                default: return ""
                }
            } else if swapStatus == .refunded {
                switch type {
                case .swapToZec, .swapFromZec: return L10n.SwapStatus.swapRefunded
                case .crossPay: return L10n.SwapStatus.paymentRefunded
                default: return ""
                }
            } else if swapStatus == .failed {
                switch type {
                case .swapToZec, .swapFromZec: return L10n.SwapStatus.swapFailed
                case .crossPay: return L10n.SwapStatus.paymentFailed
                default: return ""
                }
            } else if swapStatus == .expired {
                switch type {
                case .swapToZec, .swapFromZec: return L10n.SwapStatus.swapExpired
                case .crossPay: return L10n.SwapStatus.paymentExpired
                default: return ""
                }
            } else {
                switch type {
                case .swapToZec, .swapFromZec: return L10n.SwapStatus.swapped
                case .crossPay: return L10n.SwapStatus.paid
                default: return ""
                }
            }
        }
    }

    public var dateString: String? {
        guard let timestamp else { return nil }
        
        return Date(timeIntervalSince1970: timestamp).asHumanReadable()
    }

    public var listDateString: String? {
        guard let timestamp else { return nil }

        let formatter = DateFormatter()
        let date = Date(timeIntervalSince1970: timestamp)
        formatter.dateFormat = "MMM d '\(L10n.Filter.at)' h:mm a"
        return formatter.string(from: date)
    }
    
    public var listDateYearString: String? {
        guard let timestamp else { return nil }

        let formatter = DateFormatter()
        let date = Date(timeIntervalSince1970: timestamp)
        formatter.dateFormat = "MMM d, YYYY '\(L10n.Filter.at)' h:mm a"
        return formatter.string(from: date)
    }

    public var daysAgo: String {
        guard let timestamp, !isPIRDetectedSpend else { return "" }
        
        let transactionDate = Date(timeIntervalSince1970: timestamp)
        
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfGivenDate = calendar.startOfDay(for: transactionDate)
        let components = calendar.dateComponents([.day], from: startOfGivenDate, to: startOfToday)
        
        if let daysAgo = components.day {
            if daysAgo == 0 {
                return L10n.Filter.today
            } else if daysAgo == 1 {
                return L10n.Filter.yesterday
            } else if daysAgo < 31 {
                return L10n.Filter.daysAgo(daysAgo)
            } else {
                return listDateString ?? ""
            }
        } else {
            return ""
        }
    }

    // Helper flags
    public var isPending: Bool {
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
    public var isSpending: Bool {
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
    
    public var transationIcon: Image {
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
    public var totalAmount: Zatoshi {
        Zatoshi(zecAmount.amount + (fee?.amount ?? 0))
    }
    
    public var netValue: String {
        isShieldingTransaction
        ? Zatoshi(totalSpent?.amount ?? 0).atLeastThreeDecimalsZashiFormatted()
        : zecAmount.atLeastThreeDecimalsZashiFormatted()
    }

    public var amountWithoutFee: Zatoshi {
        Zatoshi(zecAmount.amount - (fee?.amount ?? 0))
    }

    public init(
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
    
    public init(
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

    /// Synthetic placeholder for PIR-detected spends, visible until scanning catches up.
    public init(pirDetectedSpentValue: Int64) {
        self.id = "pir-detected-spend"
        self.status = .paid
        self.zecAmount = Zatoshi(-pirDetectedSpentValue)
        self.isPIRDetectedSpend = true
        self.isSentTransaction = true
        self.fee = nil
        self.memoCount = 0
        self.isShieldingTransaction = false
        self.isTransparentRecipient = false
        self.timestamp = Date().timeIntervalSince1970
    }

    public func confirmationsWith(_ latestMinedHeight: BlockHeight?) -> BlockHeight {
        guard let minedHeight, let latestMinedHeight, minedHeight > 0, latestMinedHeight > 0 else {
            return 0
        }
        
        return latestMinedHeight - minedHeight
    }
    
    public func transactionListHeight(_ mempoolHeight: BlockHeight) -> BlockHeight {
        var tlHeight = mempoolHeight
        
        if let minedHeight = minedHeight {
            tlHeight = minedHeight
        } else if let expiredHeight = expiryHeight, expiredHeight > 0 {
            tlHeight = expiredHeight
        }
        
        return tlHeight
    }
    
    public mutating func checkAndUpdateWith(_ swap: UMSwapId) {
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
    public init(
        transaction: ZcashTransaction.Overview,
        memos: [Memo]? = nil,
        hasTransparentOutputs: Bool = false
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
        
        let isPending = isSentTransaction ? minedHeight == nil : transaction.state == .pending
        let isExpired = transaction.state == .expired
        
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
    
    public init(
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
    public static func placeholder(
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
    
    public static let mockedSent = TransactionState(
        minedHeight: BlockHeight(1),
        zAddress: "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3",
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .paid,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_000_000)
    )
    
    public static let mockedReceived = TransactionState(
        minedHeight: BlockHeight(1),
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .received,
        timestamp: 1699292621,
        zecAmount: Zatoshi(25_000_000)
    )
    
    public static let mockedFailed = TransactionState(
        minedHeight: nil,
        zAddress: "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3",
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .failed,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_108_700),
        isSentTransaction: true
    )
    
    public static let mockedFailedReceive = TransactionState(
        minedHeight: nil,
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .failed,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_001_000),
        isSentTransaction: false
    )
    
    public static let mockedSending = TransactionState(
        minedHeight: nil,
        zAddress: "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3",
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .sending,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_000_000),
        isSentTransaction: true
    )
    
    public static let mockedReceiving = TransactionState(
        minedHeight: nil,
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .receiving,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_000_000),
        isSentTransaction: false
    )
    
    public static let mockedShielded = TransactionState(
        minedHeight: BlockHeight(1),
        zAddress: "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3",
        fee: Zatoshi(10_000),
        id: "t1vergg5jkp4wy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzja",
        status: .shielded,
        timestamp: 1699290621,
        zecAmount: Zatoshi(25_000_000),
        isShieldingTransaction: true
    )
    
    public static let mockedShieldedExpanded = TransactionState(
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

public struct TransactionStateMockHelper {
    public var date: TimeInterval
    public var amount: Zatoshi
    public var shielded = true
    public var status: TransactionState.Status = .received
    public var uuid = ""
    
    public init(
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
