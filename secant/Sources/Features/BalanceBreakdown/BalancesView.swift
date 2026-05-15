//
//  BalancesView.swift
//  Zashi
//
//  Created by Lukáš Korba on 04.08.2022.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@preconcurrency import Combine

struct BalancesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<Balances>
    let tokenName: String
    
    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false

    init(store: StoreOf<Balances>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Text(localizable: .balancesSpendableBalanceTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 40)

                if store.spendability == .everything || store.isPendingInProcess {
                    Text(
                        store.spendability == .everything
                        ? String(localizable: .balancesEverythingDone)
                        : store.isPendingChange
                        ? String(localizable: .balancesInfoPending)
                        : String(localizable: .balancesInfoSyncing)
                    )
                    .zFont(size: 16, style: Design.Text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                }

                if store.isShieldableBalanceAvailable {
                    Text(localizable: .balancesInfoShielding("\(String(localizable: .generalFeeShort(store.feeStr))) \(tokenName)"))
                    .zFont(size: 16, style: Design.Text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 24)
                }
                
                balancesBlock()
                    .padding(.top, 32)
                    .padding(.bottom, store.isShieldableBalanceAvailable ? 0: 32)
                
                if store.isShieldableBalanceAvailable {
                    transparentBlock()
                        .padding(.vertical, 32)
                }
                
                ZashiButton(String(localizable: .balancesDismiss)) {
                    store.send(.dismissTapped)
                }
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            }
            .onAppear { store.send(.onAppear) }
            .onDisappear { store.send(.onDisappear) }
        }
    }
}

extension BalancesView {
    @ViewBuilder func balancesBlock() -> some View {
        VStack(spacing: 20) {
            HStack(spacing: 0) {
                Text(localizable: .balancesSpendableBalance)
                    .zFont(size: 14, style: Design.Text.tertiary)
                
                Spacer()

                Asset.Assets.shield.image
                    .zImage(width: 11, height: 14, color: Asset.Colors.primary.color)
                    .padding(.trailing, 10)

                ZatoshiText(store.shieldedBalance, .expanded, tokenName)
                    .zFont(.medium, size: 14, style: Design.Text.primary)
            }
            
            if store.isPendingInProcess {
                HStack(spacing: 0) {
                    Text(localizable: .balancesPending)
                        .zFont(size: 14, style: Design.Text.tertiary)

                    Spacer()
                    
                    progressViewLooping()
                        .padding(.trailing, 10)

                    ZatoshiText(
                        store.changePending + store.pendingTransactions, .expanded, tokenName
                    )
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
                }
            }
        }
    }
    
    @ViewBuilder func transparentBlock() -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(localizable: .smartBannerHelpShieldTransparent)
                        .zFont(.medium, size: 16, style: Design.Text.primary)
                        .padding(.trailing, 4)
                    
                    Asset.Assets.Icons.shieldOff.image
                        .zImage(size: 16, style: Design.Text.primary)
                }
                .padding(.bottom, 4)
                
                ZatoshiText(store.transparentBalance, .expanded, tokenName)
                    .zFont(.semiBold, size: 20, style: Design.Text.primary)
            }
            
            Spacer()
            
            ZashiButton(
                String(localizable: .smartBannerContentShieldButton),
                infinityWidth: false
            ) {
                store.send(.shieldFundsTapped)
            }
            .disabled(store.isShielding)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                        .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                }
        }
    }

    @ViewBuilder func progressViewLooping() -> some View {
        ProgressView()
            .scaleEffect(0.7)
            .frame(width: 11, height: 14)
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        BalancesView(
            store: StoreOf<Balances>(
                initialState: Balances.State(
                    autoShieldingThreshold: Zatoshi(1_000_000),
                    changePending: Zatoshi(25_234_000),
                    isShielding: true,
                    pendingTransactions: Zatoshi(25_234_000)
                )
            ) {
                Balances()
            },
            tokenName: "ZEC"
        )
    }
    .navigationViewStyle(.stack)
}

// MARK: - Placeholders

extension Balances.State {
    static let placeholder = Balances.State(
        autoShieldingThreshold: .zero,
        changePending: .zero,
        isShielding: false,
        pendingTransactions: .zero
    )
    
    static let initial = Balances.State(
        autoShieldingThreshold: .zero,
        changePending: .zero,
        isShielding: false,
        pendingTransactions: .zero
    )
}

extension StoreOf<Balances> {
    static let placeholder = StoreOf<Balances>(
        initialState: .placeholder
    ) {
        Balances()
    }
}
