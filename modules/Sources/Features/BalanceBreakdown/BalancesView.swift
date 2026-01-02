//
//  BalancesView.swift
//  Zashi
//
//  Created by Lukáš Korba on 04.08.2022.
//

import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit
import Generated
import UIComponents
import Utils
import Models
import BalanceFormatter
import WalletBalances
import Combine

public struct BalancesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<Balances>
    let tokenName: String
    
    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false
    @Shared(.inMemory(.walletStatus)) public var walletStatus: WalletStatus = .none

    public init(store: StoreOf<Balances>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    public var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Text(L10n.Balances.SpendableBalance.title)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 40)

                if store.spendability == .everything || store.isPendingInProcess {
                    Text(
                        store.spendability == .everything
                        ? L10n.Balances.everythingDone
                        : store.isPendingChange
                        ? L10n.Balances.infoPending
                        : L10n.Balances.infoSyncing
                    )
                    .zFont(size: 16, style: Design.Text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                }

                if store.isShieldableBalanceAvailable {
                    Text(L10n.Balances.infoShielding("\(L10n.General.feeShort(store.feeStr)) \(tokenName)"))
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
                
                ZashiButton(L10n.Balances.dismiss) {
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
                Text(L10n.Balances.spendableBalance)
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
                    Text(L10n.Balances.pending)
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
                    Text(L10n.SmartBanner.Help.Shield.transparent)
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
                L10n.SmartBanner.Content.Shield.button,
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
    public static let placeholder = Balances.State(
        autoShieldingThreshold: .zero,
        changePending: .zero,
        isShielding: false,
        pendingTransactions: .zero
    )
    
    public static let initial = Balances.State(
        autoShieldingThreshold: .zero,
        changePending: .zero,
        isShielding: false,
        pendingTransactions: .zero
    )
}

extension StoreOf<Balances> {
    public static let placeholder = StoreOf<Balances>(
        initialState: .placeholder
    ) {
        Balances()
    }
}
