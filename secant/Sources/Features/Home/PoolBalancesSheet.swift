//
//  PoolBalancesSheet.swift
//  modules
//
//  Created by Michal Fousek on 25.07.2026.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension HomeView {
    @ViewBuilder func poolBalancesContent() -> some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Text(localizable: .poolBalancesTitle)
                    .zFont(.semiBold, size: 20, style: Design.Text.primary)
                    .padding(.top, 32)

                Text(localizable: .poolBalancesDesc)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 4)
                    .padding(.bottom, 24)

                poolCard(
                    title: String(localizable: .poolBalancesTotalBalance),
                    balance: store.walletBalancesState.totalBalance,
                    dimmedToken: true
                )
                .padding(.bottom, 8)

                HStack(spacing: 8) {
                    poolCard(title: String(localizable: .poolBalancesIronwood), balance: store.walletBalancesState.ironwoodPoolBalance)
                    poolCard(title: String(localizable: .poolBalancesOrchard), balance: store.walletBalancesState.orchardPoolBalance)
                }
                .padding(.bottom, 8)

                HStack(spacing: 8) {
                    poolCard(title: String(localizable: .poolBalancesSapling), balance: store.walletBalancesState.saplingPoolBalance)
                    poolCard(title: String(localizable: .poolBalancesTransparent), balance: store.walletBalancesState.transparentPoolBalance)
                }
                .padding(.bottom, 32)

                ZashiButton(String(localizable: .poolBalancesGotIt)) {
                    store.send(.poolBalancesDismissTapped)
                }
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            }
        }
    }

    @ViewBuilder private func poolCard(title: String, balance: Zatoshi, dimmedToken: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .zFont(.medium, size: 14, style: Design.Text.tertiary)
                .padding(.bottom, 4)

            HStack(spacing: 4) {
                // .expanded keeps every zatoshi visible: first three fraction digits at full size,
                // remaining five smaller.
                ZatoshiRepresentationView(
                    balance: balance,
                    fontName: FontFamily.Inter.semiBold.name,
                    mostSignificantFontSize: 16,
                    leastSignificantFontSize: 12,
                    format: .expanded,
                    couldBeHidden: true
                )
                .zForegroundColor(Design.Text.primary)

                if !isSensitiveContentHidden {
                    Text(tokenName)
                        .zFont(.semiBold, size: 16, style: dimmedToken ? Design.Text.tertiary : Design.Text.primary)
                }
            }

            if store.walletBalancesState.isFiatAvailable {
                Text(store.walletBalancesState.fiatValue(balance))
                    .hiddenIfSet()
                    .zFont(size: 12, style: Design.Text.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }
}

// MARK: - Previews

#Preview {
    HomeView(store: Home.placeholder, tokenName: "ZEC")
        .poolBalancesContent()
}
