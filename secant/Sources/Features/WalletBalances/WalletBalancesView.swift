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
    let balanceTappable: Bool

    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false

    init(
        store: StoreOf<WalletBalances>,
        tokenName: String,
        couldBeHidden: Bool = false,
        shortened: Bool = false,
        balanceTappable: Bool = false
    ) {
        self.store = store
        self.tokenName = tokenName
        self.couldBeHidden = couldBeHidden
        self.shortened = shortened
        self.balanceTappable = balanceTappable
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                tappableBalanceContent()
                    .padding(.top, 40)
                    .anchorPreference(
                        key: ExchangeRateFeaturePreferenceKey.self,
                        value: .bounds
                    ) { $0 }

                // MOB-2020: the fiat line is derived from `store.totalBalance`, which is not yet
                // known for the selected account while `!store.hasConcreteBalance` -- hide it
                // alongside the number's own shimmer placeholder rather than showing a fiat value
                // derived from a stale or zeroed total. Hidden balances mask it like the number,
                // so there it renders exactly as it always has.
                if shortened && (isHidden || store.hasConcreteBalance) {
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
                            showIndicator: store.isProcessingZeroAvailableBalance || store.isSpendableMasked
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

    // MOB-2020: `ZatoshiText` (the `shortened` layout) always hides on `isSensitiveContentHidden`,
    // with no gate of its own; `ZatoshiRepresentationView` (the full layout) only hides when it is
    // ALSO passed `couldBeHidden: true` -- mirrored here so hidden balances keep exactly today's
    // precedence over the loading placeholder.
    private var isHidden: Bool {
        isSensitiveContentHidden && (shortened || couldBeHidden)
    }

    @ViewBuilder private func balanceContent() -> some View {
        HStack(spacing: 0) {
            ZcashSymbol()
                .frame(width: 32, height: 32)
                .zForegroundColor(Design.Text.primary)

            if isHidden {
                // 1. Balances are hidden (the privacy setting) -- render exactly what renders
                // today; `ZatoshiText`/`ZatoshiRepresentationView` do their own masking below.
                balanceNumber()
            } else if !store.hasConcreteBalance {
                // 2. Not hidden, but nothing has been published for the SELECTED account yet (a
                // fresh account switch, or first launch) -- a shimmer placeholder in place of the
                // number, rather than a stale or 0.000 figure left over from the previous account.
                RoundedRectangle(cornerRadius: Design.Radius._md)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .shimmer(true)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius._md))
                    .frame(width: 140, height: 40)
                    .padding(.leading, 8)
                    .accessibilityLabel(String(localizable: .generalLoading))
            } else {
                // 3. A concrete balance for the selected account -- render the number as today.
                balanceNumber()
            }
        }
    }

    @ViewBuilder private func balanceNumber() -> some View {
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
