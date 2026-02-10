//
//  CrossPayConfirmation.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-01-2025.
//

import SwiftUI
import ComposableArchitecture
import Generated
import SwapAndPay

import UIComponents

// FIXME: Candidate for removal from the project
public struct CrossPayConfirmationView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    @Perception.Bindable var store: StoreOf<SwapAndPay>
    let tokenName: String
    
    public init(store: StoreOf<SwapAndPay>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    public var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .center, spacing: 0) {
                ZStack {
                    HStack(spacing: 8) {
                        VStack(spacing: 0) {
                            zecTickerLogo(colorScheme)
                                .scaleEffect(0.8)

                            Text(store.zecToBeSpendInQuote)
                                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.1)

                            Text(store.zecUsdToBeSpendInQuote)
                                .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 94)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                        }
                        
                        VStack(spacing: 0) {
                            tokenTicker(asset: store.selectedAsset, colorScheme)
                                .scaleEffect(0.8)

                            Text(store.tokenToBeReceivedInQuote)
                                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.1)
                            
                            Text(store.tokenUsdToBeReceivedInQuote)
                                .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 94)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                        }
                    }
                    
                    FloatingArrow()
                }
                .padding(.top, 36)
                .padding(.bottom, 28)

                // Send to
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.Send.toSummary)
                            .zFont(.medium, size: 14, style: Design.Text.primary)

                        if let alias = store.selectedContact?.name {
                            Text(alias)
                                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                        }
                        
                        Text(store.address)
                            .zFont(fontFamily: .robotoMono, size: 12, style: Design.Text.primary)
                    }
                    
                    Spacer()
                }
                .padding(.bottom, 20)
                
                // Send from
                if store.walletAccounts.count > 1 {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.Accounts.sendingFrom)
                                .zFont(.medium, size: 14, style: Design.Text.primary)
                            
                            if let selectedWalletAccount = store.selectedWalletAccount {
                                HStack(spacing: 0) {
                                    selectedWalletAccount.vendor.icon()
                                        .resizable()
                                        .frame(width: 24, height: 24)
                                        .background {
                                            Circle()
                                                .fill(Design.Surfaces.bgAlt.color(colorScheme))
                                                .frame(width: 32, height: 32)
                                        }
                                    
                                    Text(selectedWalletAccount.vendor.name())
                                        .zFont(.semiBold, size: 16, style: Design.Text.primary)
                                        .padding(.leading, 16)
                                }
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(.bottom, 20)
                }

                // Amount
                HStack {
                    Text(L10n.Send.amount)
                        .zFont(size: 14, style: Design.Text.tertiary)

                    Spacer()
                    
                    Text("\(store.zecToBeSpendInQuote) \(tokenName)")
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                }
                .padding(.bottom, 12)

                // Fee
                HStack {
                    Text(L10n.Send.feeSummary)
                        .zFont(size: 14, style: Design.Text.tertiary)

                    Spacer()
                    
                    Text("\(store.totalFeesStr) \(tokenName)")
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                }

                Divider()
                    .frame(height: 1)
                    .background(Design.Surfaces.strokeSecondary.color(colorScheme))
                    .padding(.vertical, 12)

                // Total Amount
                HStack {
                    Text(L10n.Crosspay.total)
                        .zFont(size: 14, style: Design.Text.tertiary)

                    Spacer()

                    Text("\(store.totalZecToBeSpendInQuote) \(tokenName)")
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                }

                HStack {
                    Spacer()
                    
                    Text(store.totalZecUsdToBeSpendInQuote)
                        .zFont(size: 12, style: Design.Text.tertiary)
                }
                .padding(.top, 2)
                
                Spacer()
                
                if store.selectedWalletAccount?.vendor == .keystone {
                    ZashiButton(L10n.Keystone.confirmPay) {
                        store.send(.confirmWithKeystoneTapped)
                    }
                    .padding(.bottom, 24)
                } else {
                    ZashiButton(L10n.Crosspay.pay) {
                        store.send(.confirmButtonTapped)
                    }
                    .padding(.bottom, 24)
                }
            }
            .zashiBack {
                store.send(.backFromConfirmationTapped)
            }
            .screenTitle(
                store.selectedWalletAccount?.vendor == .keystone
                ? L10n.Send.review
                : L10n.Send.confirmationTitle
            )
            .screenHorizontalPadding()
            .applyScreenBackground()
        }
    }
    
    @ViewBuilder func payTokenTicker(asset: SwapAsset?, _ colorScheme: ColorScheme) -> some View {
        if let asset {
            asset.tokenIcon
                .resizable()
                .frame(width: 40, height: 40)
                .padding(.trailing, 8)
                .overlay {
                    ZStack {
                        Circle()
                            .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                            .frame(width: 26, height: 26)
                            .offset(x: 13, y: 13)
                        
                        asset.chainIcon
                            .resizable()
                            .frame(width: 22, height: 22)
                            .offset(x: 12, y: 12)
                    }
                }
        }
    }
    
    @ViewBuilder func zashiLogo(_ colorScheme: ColorScheme) -> some View {
        Asset.Assets.zashiLogo.image
            .zImage(width: 14, height: 20, color: Design.Surfaces.bgPrimary.color(colorScheme))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                Circle()
                    .fill(Design.Surfaces.bgAlt.color(colorScheme))
            }
    }
    
    @ViewBuilder func zecTickerLogo(_ colorScheme: ColorScheme) -> some View {
        Asset.Assets.Brandmarks.brandmarkMax.image
            .zImage(size: 24, style: Design.Text.primary)
            .padding(.trailing, 12)
            .overlay {
                Asset.Assets.Icons.shieldBcg.image
                    .zImage(size: 15, color: Design.screenBackground.color(colorScheme))
                    .offset(x: 4, y: 8)
                    .overlay {
                        Asset.Assets.Icons.shieldTickFilled.image
                            .zImage(size: 13, color: Design.Text.primary.color(colorScheme))
                            .offset(x: 4, y: 8)
                    }
            }
    }
}

#Preview {
    NavigationView {
        CrossPayConfirmationView(store: SwapAndPay.initial, tokenName: "ZEC")
    }
}
