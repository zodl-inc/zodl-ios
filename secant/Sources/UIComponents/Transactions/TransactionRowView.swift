//
//  TransactionRowView.swift
//
//
//  Created by Lukáš Korba on 05.11.2023.
//

import SwiftUI
import ComposableArchitecture

struct TransactionRowView: View {
    @Environment(\.colorScheme) private var colorScheme

    let transaction: TransactionState
    let divider: Bool
    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false
    let isUnread: Bool
    let isSwap: Bool
    let tokenName: String

    init(
        transaction: TransactionState,
        tokenName: String = "ZEC",
        isUnread: Bool = false,
        isSwap: Bool = false,
        divider: Bool = false
    ) {
        self.transaction = transaction
        self.tokenName = tokenName
        self.isUnread = isUnread
        self.isSwap = isSwap
        self.divider = divider
    }
    
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ZStack {
                        transaction.transationIcon
                            .zImage(size: 20, color: transaction.iconColor(colorScheme))
                            .background {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            gradient: Gradient(colors: [
                                                transaction.iconGradientStartColor(colorScheme),
                                                transaction.iconGradientEndColor(colorScheme)
                                            ]),
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: 40, height: 40)
                            }
                            .frame(width: 40, height: 40)
                            .padding(.trailing, 16)
                        
                        if isUnread {
                            Circle()
                                .fill(Design.Avatars.badgeBg.color(colorScheme))
                                .frame(width: 9, height: 9)
                                .background {
                                    Circle()
                                        .fill(Design.Avatars.profileBorder.color(colorScheme))
                                        .frame(width: 14, height: 14)
                                }
                                .offset(x: 9, y: 11)
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Text(transaction.isPending
                                 ? String(localizable: .transactionHistoryThreeDots(transaction.title()))
                                 : transaction.title()
                            )
                            .zFont(.semiBold, size: 14, style: Design.Text.primary)
                            
                            if !transaction.hasTransparentOutputs && !transaction.isShieldingTransaction {
                                Asset.Assets.shieldTick.image
                                    .zImage(size: 16, style: Design.Text.tertiary)
                                    .padding(.leading, 4)
                            }
                        }

                        Text(transaction.daysAgo)
                            .font(.custom(FontFamily.Inter.regular.name, size: 13))
                            .foregroundColor(Asset.Colors.shade47.color)
                    }

                    Spacer()
                    
                    balanceView()
                }
                .screenHorizontalPadding()
                .padding(.vertical, 12)

                Divider()
                    .padding(.horizontal, 4)
                    .opacity(divider ? 1.0 : 0.0)
            }
        }
    }

    @ViewBuilder private func balanceView() -> some View {
        Group {
            if isSensitiveContentHidden {
                Text(localizable: .generalHideBalancesMost)
                    .foregroundColor(Design.Text.primary.color(colorScheme))
            } else if let swapToZecAmount = transaction.swapToZecAmount {
                if !swapToZecAmount.isEmpty {
                    Text(swapToZecAmount)
                    + Text(" \(tokenName)")
                }
            } else {
                Text(transaction.isSpending ? "- " : "")
                + Text(transaction.netValue)
                + Text(" \(tokenName)")
            }
        }
        .font(.custom(FontFamily.Inter.regular.name, size: 14))
        .foregroundColor(transaction.titleColor(colorScheme))
        .lineLimit(1)
    }
}

#Preview {
    VStack(spacing: 0) {
        TransactionRowView(
            transaction: .mockedFailed
        )
        .listRowSeparator(.hidden)

        TransactionRowView(
            transaction: .mockedFailedReceive
        )
        .listRowSeparator(.hidden)

        TransactionRowView(
            transaction: .mockedSent
        )
        .listRowSeparator(.hidden)

        TransactionRowView(
            transaction: .mockedReceived
        )
        .listRowSeparator(.hidden)
        
        TransactionRowView(
            transaction: .mockedSending
        )
        .listRowSeparator(.hidden)

        TransactionRowView(
            transaction: .mockedShielded
        )
        .listRowSeparator(.hidden)

        TransactionRowView(
            transaction: .mockedReceiving
        )
        .listRowSeparator(.hidden)
    }
    .listStyle(.plain)
}

