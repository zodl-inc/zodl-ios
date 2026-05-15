//
//  WalletBalancesView.swift
//  Zashi
//
//  Created by Lukáš Korba on 04-02-2024
//

import SwiftUI
import ComposableArchitecture

struct WalletBalancesView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    @Perception.Bindable var store: StoreOf<WalletBalances>
    let tokenName: String
    let couldBeHidden: Bool
    let shortened: Bool

    init(
        store: StoreOf<WalletBalances>,
        tokenName: String,
        couldBeHidden: Bool = false,
        shortened: Bool = false
    ) {
        self.store = store
        self.tokenName = tokenName
        self.couldBeHidden = couldBeHidden
        self.shortened = shortened
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                balanceContent()
                    .padding(.top, 40)
                    .anchorPreference(
                        key: ExchangeRateFeaturePreferenceKey.self,
                        value: .bounds
                    ) { $0 }
#if !SECANT_DISTRIB
                    .accessDebugMenuWithHiddenGesture {
                        store.send(.debugMenuStartup)
                    }
#endif

                if shortened {
                    exchangeRate()
                }

                if store.migratingDatabase {
                    Text(localizable: .homeMigratingDatabases)
                        .font(.custom(FontFamily.Inter.regular.name, size: 14))
                        .foregroundColor(Asset.Colors.primary.color)
                        .padding(.top, 12)
                        .padding(.bottom, 30)
                } else if store.spendability != .everything && !shortened {
                    Button {
                        store.send(.availableBalanceTapped)
                    } label: {
                        AvailableBalanceView(
                            balance: store.shieldedBalance,
                            showIndicator: store.isProcessingZeroAvailableBalance
                        )
                        .padding(.top, 12)
                        .padding(.bottom, 30)
                    }
                } else if !shortened {
                    Color.clear
                        .padding(.bottom, 30)
                }
            }
            .foregroundColor(Asset.Colors.primary.color)
            .onAppear { store.send(.onAppear) }
            .onDisappear { store.send(.onDisappear) }
        }
    }
    
    @ViewBuilder private func balanceContent() -> some View {
        HStack(spacing: 0) {
            ZcashSymbol()
                .frame(width: 32, height: 32)
                .zForegroundColor(Design.Text.primary)
            
            if shortened {
                ZatoshiText(store.totalBalance, .abbreviated)
                    .zFont(.semiBold, size: 48, style: Design.Text.primary)
            } else {
                ZatoshiRepresentationView(
                    balance: store.totalBalance,
                    fontName: FontFamily.Inter.semiBold.name,
                    mostSignificantFontSize: 48,
                    leastSignificantFontSize: 20,
                    format: .expanded,
                    couldBeHidden: couldBeHidden
                )
            }
        }
    }
    
    private func exchangeRate() -> some View {
        Group {
            if store.isExchangeRateFeatureOn {
                if store.currencyConversion == nil && !store.isExchangeRateStale {
                    HStack(spacing: 8) {
                        Text(localizable: .generalLoading)
                            .font(.custom(FontFamily.Inter.semiBold.name, size: 14))
                            .foregroundColor(Asset.Colors.primary.color)

                        ProgressView()
                    }
                    .frame(height: 36)
                    .padding(.top, 10)
                    .padding(.vertical, 5)
                }
                
                if store.currencyConversion != nil || store.isExchangeRateStale {
                    Button {
                        store.send(.exchangeRateRefreshTapped)
                    } label: {
                        if store.isExchangeRateStale {
                            HStack {
                                Text(localizable: .tooltipExchangeRateTitle)
                                    .font(.custom(FontFamily.Inter.semiBold.name, size: 14))
                                    .foregroundColor(Asset.Colors.primary.color)

                                Asset.Assets.infoCircle.image
                                    .zImage(size: 20, color: Asset.Colors.primary.color)
                            }
                            .frame(maxWidth: .infinity)
                            .anchorPreference(
                                key: ExchangeRateStaleTooltipPreferenceKey.self,
                                value: .bounds
                            ) { $0 }
                        } else if store.isExchangeRateRefreshEnabled {
                            HStack {
                                Text(store.currencyValue)
                                    .hiddenIfSet()
                                    .font(.custom(FontFamily.Inter.semiBold.name, size: 14))
                                    .foregroundColor(Asset.Colors.primary.color)

                                if store.isExchangeRateUSDInFlight {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 20, height: 20)
                                } else {
                                    Asset.Assets.refreshCCW.image
                                        .zImage(size: 20, color: Asset.Colors.primary.color)
                                }
                            }
                            .padding(8)
                            .padding(.horizontal, 6)
                            .background {
                                RoundedRectangle(cornerRadius: Design.Radius._lg)
                                    .stroke(Design.Surfaces.strokePrimary.color(colorScheme))
                                    .background {
                                        Design.Surfaces.bgSecondary.color(colorScheme)
                                            .cornerRadius(10)
                                    }
                            }
                        } else {
                            HStack {
                                Text(store.currencyValue)
                                    .hiddenIfSet()
                                    .font(.custom(FontFamily.Inter.semiBold.name, size: 14))
                                    .foregroundColor(Asset.Colors.primary.color)

                                if store.isExchangeRateUSDInFlight {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 11, height: 14)
                                } else {
                                    Asset.Assets.refreshCCW.image
                                        .zImage(size: 20, color: Asset.Colors.shade72.color)
                                }
                            }
                            .padding(8)
                            .padding(.horizontal, 6)
                        }
                    }
                    .frame(height: 36)
                    .padding(.top, 10)
                    .padding(.vertical, 5)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview {
    WalletBalancesView(store: WalletBalances.initial, tokenName: "ZEC")
}

// MARK: - Store

extension WalletBalances {
    static var initial = StoreOf<WalletBalances>(
        initialState: .initial
    ) {
        WalletBalances()
    }
}

// MARK: - Placeholders

extension WalletBalances.State {
    static let initial = WalletBalances.State(
        shieldedBalance: .zero
    )
}
