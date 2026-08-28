//
//  CrossPayForm.swift
//  modules
//
//  Created by Lukáš Korba on 28.08.2025.
//

import SwiftUI
import ComposableArchitecture

extension SwapAndPayForm {
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
                            Text(localizable: .sendTo)
                                .zFont(.medium, size: 14, style: Design.Text.primary)
                            
                            HStack(spacing: 0) {
                                Button {
                                    store.send(.assetSelectRequested)
                                } label: {
                                    ticker(asset: store.selectedAsset, crosspay: true, colorScheme)
                                }
                                .accessibilityIdentifier(AccessibilityID.CrossPayForm.assetSelectButton)

                                Spacer()
                            }
                            
                            addressView()
                            
                            VStack(alignment: .leading, spacing: 0) {
                                // The field's own `title:` is lifted out into this row so the Max
                                // chip can sit opposite it, the same treatment as the Send screen.
                                ZashiTextFieldTitle(String(localizable: .sendAmount)) {
                                    ZashiMaxChip(
                                        title: String(localizable: .generalMax),
                                        style: .standard,
                                        isEnabled: store.isPayMaxButtonEnabled,
                                        isInFlight: store.isMaxRequestInFlight
                                    ) {
                                        store.send(.maxTapped)
                                    }
                                    .accessibilityIdentifier(AccessibilityID.CrossPayForm.maxButton)
                                }
                                .padding(.bottom, 6)

                                HStack(alignment: .top, spacing: 4) {
                                    ZashiTextField(
                                        text: $store.amountAssetText,
                                        placeholder: store.selectedAsset?.tokenName ?? store.zeroPlaceholder,
                                        title: nil,
                                        error: store.isCrossPayInsufficientFunds ? String(localizable: .sendErrorInsufficientFunds) : nil
                                    )
                                    .keyboardType(.decimalPad)
                                    .focused($isAmountFocused)

                                    // No top compensation: with the title lifted out, both fields
                                    // start at the same y as this icon.
                                    Asset.Assets.Icons.switchHorizontal.image
                                        .zImage(size: 24, style: Design.Btns.Ghost.fg)
                                        .padding(8)

                                    ZashiTextField(
                                        text: $store.amountUsdText,
                                        placeholder: String(localizable: .sendCurrencyPlaceholder),
                                        error: store.isCrossPayInsufficientFunds ? "" : nil,
                                        prefixView:
                                            Asset.Assets.Icons.currencyDollar.image
                                            .zImage(size: 20, style: Design.Inputs.Default.text)
                                    )
                                    .keyboardType(.decimalPad)
                                    .focused($isUsdFocused)
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
                                     ? String(localizable: .swapAndPayFailureRetryTitle)
                                     : String(localizable: .swapAndPayFailureLaterTitle)
                                )
                                .zFont(.medium, size: 14, style: Design.Text.error)
                                .padding(.bottom, 8)
                                
                                Text(retryFailure
                                     ? String(localizable: .swapAndPayFailureRetryDesc)
                                     : String(localizable: .swapAndPayFailureLaterDesc)
                                )
                                .zFont(size: 14, style: Design.Text.error)
                                .padding(.bottom, retryFailure ? 32 : 56)
                                
                                if retryFailure {
                                    ZashiButton(
                                        String(localizable: .swapAndPayFailureTryAgain),
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
                                    String(localizable: .sendReview),
                                    accessoryView: ProgressView()
                                ) { }
                                    .disabled(true)
                                    .padding(.top, keyboardVisible ? 40 : 0)
                                    .padding(.bottom, 56)
                            } else {
                                ZashiButton(String(localizable: .sendReview)) {
                                    store.send(.getQuoteTapped)
                                }
                                .accessibilityIdentifier(AccessibilityID.CrossPayForm.reviewButton)
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
            .trackKeyboardVisibility($keyboardVisible)
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
                                    Text(String(localizable: .generalDone).uppercased())
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
                                
                                Text(localizable: .sendAddressNotInBook)
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
                                Text(String(localizable: .generalDone).uppercased())
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
