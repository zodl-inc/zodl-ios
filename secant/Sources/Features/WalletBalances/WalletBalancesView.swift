//
//  WalletBalancesView.swift
//  Zashi
//
//  Created by Lukáš Korba on 04-02-2024
//

import SwiftUI
import Combine
import ComposableArchitecture
 import ZcashLightClientKit

struct WalletBalancesView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    @PlatformBindable var store: StoreOf<WalletBalances>
    let tokenName: String
    let couldBeHidden: Bool
    let shortened: Bool
    let balanceTappable: Bool
    /// macOS sidebar: align the amount + currency to the leading edge (and drop the large top
    /// padding) instead of the default centered layout. Default false → iOS unchanged.
    let leadingAligned: Bool
    /// macOS sidebar: an optional view rendered INSIDE the abbreviated amount row, right after the
    /// currency — used for the hide-balances eye so it sits flush against the value and tracks its
    /// width. It must live in the amount row (which hugs its content), NOT wrapped around the whole
    /// view, so the full-width exchange-rate row below can't fight it for width and blow up the height.
    /// Default nil → iOS / other call sites unchanged.
    let trailingAccessory: AnyView?

    init(
        store: StoreOf<WalletBalances>,
        tokenName: String,
        couldBeHidden: Bool = false,
        shortened: Bool = false,
        balanceTappable: Bool = false,
        leadingAligned: Bool = false,
        trailingAccessory: AnyView? = nil
    ) {
        self.store = store
        self.tokenName = tokenName
        self.couldBeHidden = couldBeHidden
        self.shortened = shortened
        self.balanceTappable = balanceTappable
        self.leadingAligned = leadingAligned
        self.trailingAccessory = trailingAccessory
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: leadingAligned ? .leading : .center, spacing: 0) {
                tappableBalanceContent()
                    .padding(.top, leadingAligned ? 0 : 40)
                    .anchorPreference(
                        key: ExchangeRateFeaturePreferenceKey.self,
                        value: .bounds
                    ) { $0 }

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
#if os(macOS)
                    // macOS: don't RESERVE the spendable row's space when it isn't shown (spendability ==
                    // .everything). The empty 30pt left a gap between the balance and the form; macOS wants
                    // the content hugging the top. iOS keeps the reservation (avoids a scroll-layout jump).
                    EmptyView()
#else
                    Color.clear
                        .padding(.bottom, 30)
#endif
                }
            }
            .foregroundColor(Asset.Colors.primary.color)
            .onAppear { store.send(.onAppear) }
            .onDisappear { store.send(.onDisappear) }
        }
    }
    
    @ViewBuilder private func tappableBalanceContent() -> some View {
        if balanceTappable {
            Button {
                store.send(.balanceTapped)
            } label: {
                balanceContent()
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier(AccessibilityID.Home.totalBalanceButton)
        } else {
            balanceContent()
        }
    }

    @ViewBuilder private func balanceContent() -> some View {
        HStack(spacing: 0) {
#if !os(macOS)
            ZcashSymbol()
                .frame(width: 32, height: 32)
                .zForegroundColor(Design.Text.primary)
#endif
            
            if shortened {
#if os(macOS)
                HStack(spacing: 8) {
                    ZatoshiText(store.totalBalance, .abbreviated)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(height: 28)

                    Text(tokenName)

                    // Optional trailing accessory (macOS sidebar: the hide-balances eye). The row hugs
                    // its content, so the eye sits flush after the currency and tracks the amount's width.
                    if let trailingAccessory {
                        trailingAccessory
                    }
                }
                .zFont(.semiBold, size: 16, style: Design.Text.primary)
#else
                ZatoshiText(store.totalBalance, .abbreviated)
                    .zFont(.semiBold, size: 48, style: Design.Text.primary)
#endif
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

                        ZashiSpinner()
                    }
                    .frame(height: 36)
                    .padding(.top, 10)
                    .padding(.vertical, 5)
                }
                
                if store.currencyConversion == nil && store.isExchangeRateStale {
                    Button {
                        store.send(.exchangeRateRefreshTapped)
                    } label: {
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
                    }
                    .frame(height: 36)
                    .padding(.top, 10)
                    .padding(.vertical, 5)
                }

                if store.currencyConversion != nil {
                    Button {
                        store.send(.exchangeRateRefreshTapped)
                    } label: {
                        if store.isExchangeRateRefreshEnabled {
                            HStack {
                                Text(store.currencyValue)
                                    .hiddenIfSet()
                                    .font(.custom(FontFamily.Inter.semiBold.name, size: 14))
                                    .foregroundColor(Asset.Colors.primary.color)

                                if store.isExchangeRateUSDInFlight {
                                    ZashiSpinner()
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
                                    ZashiSpinner()
                                        .scaleEffect(0.7)
                                        .frame(width: 11, height: 14)
                                } else {
                                    Asset.Assets.refreshCCW.image
                                        .zImage(size: 20, color: Asset.Colors.shade72.color)
                                }
                            }
                            .padding(.vertical, 8)
                            #if !os(macOS)
                            .padding(.horizontal, 6)
                            #endif
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
    @MainActor static var initial = StoreOf<WalletBalances>(
        initialState: .initial
    ) {
        WalletBalances()
    }
}

// MARK: - Placeholders

extension WalletBalances.State {
    static var initial: WalletBalances.State {
        WalletBalances.State(shieldedBalance: .zero)
    }
}
