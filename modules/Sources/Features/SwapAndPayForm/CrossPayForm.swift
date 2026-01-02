//
//  CrossPayForm.swift
//  modules
//
//  Created by Lukáš Korba on 28.08.2025.
//

import SwiftUI
import ComposableArchitecture
import Generated
import SwapAndPay

import UIComponents
import WalletBalances
import BalanceBreakdown

public extension SwapAndPayForm {
    @ViewBuilder func crossPayFormView(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            ScrollView {
                VStack(spacing: 0) {
                    WithPerceptionTracking {
                        WalletBalancesView(
                            store: store.scope(
                                state: \.walletBalancesState,
                                action: \.walletBalances
                            ),
                            tokenName: tokenName,
                            couldBeHidden: true
                        )
                        .frame(height: 144)
                        
                        VStack(alignment: .leading) {
                            Text(L10n.Send.to)
                                .zFont(.medium, size: 14, style: Design.Text.primary)
                            
                            HStack(spacing: 0) {
                                Button {
                                    store.send(.assetSelectRequested)
                                } label: {
                                    ticker(asset: store.selectedAsset, crosspay: true, colorScheme)
                                }
                                
                                Spacer()
                            }
                            
                            addressView()
                            
                            VStack(alignment: .leading) {
                                HStack(alignment: .top, spacing: 4) {
                                    ZashiTextField(
                                        text: $store.amountAssetText,
                                        placeholder: store.selectedAsset?.tokenName ?? store.zeroPlaceholder,
                                        title: L10n.Send.amount,
                                        error: store.isCrossPayInsufficientFunds ? L10n.Send.Error.insufficientFunds : nil
                                    )
                                    .keyboardType(.decimalPad)
                                    .focused($isAmountFocused)
                                    
                                    if store.isCurrencyConversionEnabled {
                                        Asset.Assets.Icons.switchHorizontal.image
                                            .zImage(size: 24, style: Design.Btns.Ghost.fg)
                                            .padding(8)
                                            .padding(.top, 24)
                                        
                                        ZashiTextField(
                                            text: $store.amountUsdText,
                                            placeholder: L10n.Send.currencyPlaceholder,
                                            error: store.isCrossPayInsufficientFunds ? "" : nil,
                                            prefixView:
                                                Asset.Assets.Icons.currencyDollar.image
                                                .zImage(size: 20, style: Design.Inputs.Default.text)
                                        )
                                        .keyboardType(.decimalPad)
                                        .focused($isUsdFocused)
                                        .padding(.top, 23)
                                        .disabled(store.currencyConversion == nil)
                                        .opacity(store.currencyConversion == nil ? 0.5 : 1.0)
                                    }
                                }
                            }
                            .disabled(store.isQuoteRequestInFlight)
                            .padding(.vertical, 20)
                            
                            HStack(spacing: 0) {
                                zecTicker(colorScheme)
                                
                                Text("\(store.payZecLabel) \(tokenName)")
                                    .zFont(
                                        .semiBold,
                                        size: 14,
                                        style: store.isCrossPayInsufficientFunds
                                        ? Design.Inputs.ErrorFilled.hint
                                        : Design.Text.primary
                                    )
                            }
                            .padding(.bottom, 16)
                            
                            slippageView()
                                .padding(.bottom, 16)
                        }
                        
                        Spacer()

                        if let retryFailure = store.swapAssetFailedWithRetry {
                            VStack(spacing: 0) {
                                Asset.Assets.infoOutline.image
                                    .zImage(size: 16, style: Design.Text.error)
                                    .padding(.bottom, 8)
                                    .padding(.top, 32)
                                
                                Text(retryFailure
                                     ? L10n.SwapAndPay.Failure.retryTitle
                                     : L10n.SwapAndPay.Failure.laterTitle
                                )
                                .zFont(.medium, size: 14, style: Design.Text.error)
                                .padding(.bottom, 8)
                                
                                Text(retryFailure
                                     ? L10n.SwapAndPay.Failure.retryDesc
                                     : L10n.SwapAndPay.Failure.laterDesc
                                )
                                .zFont(size: 14, style: Design.Text.error)
                                .padding(.bottom, retryFailure ? 32 : 56)
                                
                                if retryFailure {
                                    ZashiButton(
                                        L10n.SwapAndPay.Failure.tryAgain,
                                        type: .destructive1
                                    ) {
                                        store.send(.trySwapsAssetsAgainTapped)
                                    }
                                    .padding(.bottom, 56)
                                }
                            }
                        } else {
                            if store.isQuoteRequestInFlight {
                                ZashiButton(
                                    L10n.Send.review,
                                    accessoryView: ProgressView()
                                ) { }
                                    .disabled(true)
                                    .padding(.top, keyboardVisible ? 40 : 0)
                                    .padding(.bottom, 56)
                            } else {
                                ZashiButton(L10n.Send.review) {
                                    store.send(.getQuoteTapped)
                                }
                                .padding(.top, keyboardVisible ? 40 : 0)
                                .padding(.bottom, 56)
                                .disabled(!store.isValidForm)
                            }
                        }
                    }
                }
                .ignoresSafeArea()
                .frame(minHeight: keyboardVisible ? 0 : safeAreaHeight)
                .screenHorizontalPadding()
            }
            .padding(.vertical, 1)
            .onAppear {
                observeKeyboardNotifications()
            }
            .onChange(of: store.keyboardDismissCounter) { _ in
                isAmountFocused = false
                isAddressFocused = false
            }
            .applyScreenBackground()
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                store.send(.willEnterForeground)
            }
            .popover(isPresented: $store.assetSelectBinding) {
                assetContent(colorScheme)
                    .padding(.horizontal, 4)
                    .applyScreenBackground()
            }
            .zashiSheet(isPresented: $store.isQuotePresented) {
                quoteContent(colorScheme)
            }
            .zashiSheet(isPresented: $store.isQuoteUnavailablePresented) {
                quoteUnavailableContent(colorScheme)
            }
            .zashiSheet(isPresented: $store.isCancelSheetVisible) {
                cancelSheetContent(colorScheme)
            }
            .sheet(isPresented: $store.isSlippagePresented) {
                slippageContent(colorScheme)
                    .screenHorizontalPadding()
                    .applyScreenBackground()
                    .overlay(
                        VStack(spacing: 0) {
                            Spacer()
                            
                            Asset.Colors.primary.color
                                .frame(height: 1)
                                .opacity(keyboardVisible ? 0.1 : 0)
                            
                            HStack(alignment: .center) {
                                Spacer()
                                
                                Button {
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                                    to: nil, from: nil, for: nil)
                                } label: {
                                    Text(L10n.General.done.uppercased())
                                        .zFont(.regular, size: 14, style: Design.Text.primary)
                                }
                                .padding(.bottom, 4)
                            }
                            .applyScreenBackground()
                            .padding(.horizontal, 20)
                            .frame(height: keyboardVisible ? 38 : 0)
                            .frame(maxWidth: .infinity)
                            .opacity(keyboardVisible ? 1 : 0)
                        }
                    )
            }
            .zashiSheet(isPresented: $store.balancesBinding) {
                WithPerceptionTracking {
                    BalancesView(
                        store:
                            store.scope(
                                state: \.balancesState,
                                action: \.balances
                            ),
                        tokenName: tokenName
                    )
                }
            }
            .overlayPreferenceValue(UnknownAddressPreferenceKey.self) { preferences in
                if isAddressFocused && store.isAddressBookHintVisible {
                    GeometryReader { geometry in
                        preferences.map {
                            HStack(alignment: .top, spacing: 0) {
                                Asset.Assets.Icons.userPlus.image
                                    .zImage(size: 20, style: Design.HintTooltips.titleText)
                                    .padding(.trailing, 12)
                                
                                Text(L10n.Send.addressNotInBook)
                                    .zFont(.medium, size: 14, style: Design.HintTooltips.titleText)
                                    .padding(.top, 2)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 40)
                            .background {
                                RoundedRectangle(cornerRadius: Design.Radius._md)
                                    .fill(Design.HintTooltips.surfacePrimary.color(colorScheme))
                            }
                            .frame(width: geometry.size.width - 48)
                            .offset(x: 24, y: geometry[$0].minY + geometry[$0].height + 8)
                        }
                    }
                }
            }
            .overlay {
                if keyboardVisible {
                    VStack(spacing: 0) {
                        Spacer()
                        
                        Asset.Colors.primary.color
                            .frame(height: 1)
                            .opacity(0.1)
                        
                        HStack(alignment: .center) {
                            Spacer()
                            
                            Button {
                                isAmountFocused = false
                                isAddressFocused = false
                                isUsdFocused = false
                            } label: {
                                Text(L10n.General.done.uppercased())
                                    .zFont(.regular, size: 14, style: Design.Text.primary)
                            }
                            .padding(.bottom, 4)
                        }
                        .applyScreenBackground()
                        .padding(.horizontal, 20)
                        .frame(height: keyboardVisible ? 38 : 0)
                        .frame(maxWidth: .infinity)
                        .opacity(keyboardVisible ? 1 : 0)
                    }
                }
            }
        }
        .onAppear {
            store.send(.onAppear)
            if let window = UIApplication.shared.windows.first {
                let safeFrame = window.safeAreaLayoutGuide.layoutFrame
                safeAreaHeight = safeFrame.height
            }
        }
    }
}
