//
//  SwapForm.swift
//  modules
//
//  Created by Lukáš Korba on 28.08.2025.
//

import SwiftUI
import ComposableArchitecture
import Generated
import SwapAndPay

import UIComponents

public extension SwapAndPayForm {
    @ViewBuilder func swapFormView(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            ScrollView {
                VStack(spacing: 0) {
                    if store.isSwapExperienceEnabled {
                        fromView(colorScheme)
                            .padding(.top, 36)
                        
                        dividerView(colorScheme)
                        
                        toView(colorScheme)
                        
                        addressView()
                    } else {
                        toView(colorScheme)
                            .padding(.top, 36)

                        addressView()

                        dividerView(colorScheme)
                        
                        fromView(colorScheme)
                    }
                    
                    slippageView()
                        .padding(.top, 24)
                        .padding(.bottom, 16)

                    HStack(spacing: 0) {
                        Text(L10n.SwapAndPay.rate)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        
                        Spacer()
                        
                        if let rateValue = store.rateToOneZec, let selectedToken = store.selectedAsset?.token {
                            Text(L10n.SwapAndPay.oneZecRate(rateValue, selectedToken))
                                .zFont(.medium, size: 14, style: Design.Text.primary)
                        } else {
                            RoundedRectangle(cornerRadius: Design.Radius._sm)
                                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                                .shimmer(true).clipShape(RoundedRectangle(cornerRadius: 6))
                                .frame(width: 120, height: 18)
                        }
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
                        VStack(spacing: 0) {
                            if store.isQuoteRequestInFlight {
                                ZashiButton(
                                    L10n.SwapAndPay.getQuote,
                                    accessoryView: ProgressView()
                                ) { }
                                    .disabled(true)
                                    .padding(.bottom, 56)
                            } else {
                                ZashiButton(L10n.SwapAndPay.getQuote) {
                                    store.send(.getQuoteTapped)
                                }
                                .padding(.bottom, 56)
                                .disabled(!store.isValidForm)
                            }
                        }
                        .padding(.top, keyboardVisible ? 40 : 0)
                    }
                }
                .ignoresSafeArea()
                .frame(minHeight: keyboardVisible ? 0 : safeAreaHeight)
                .screenHorizontalPadding()
            }
            .padding(.top, 1)
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
            .overlay(
                VStack(spacing: 0) {
                    Spacer()

                    Asset.Colors.primary.color
                        .frame(height: 1)
                        .opacity(keyboardVisible ? 0.1 : 0)
                    
                    HStack(alignment: .center) {
                        Spacer()
                        
                        Button {
                            isAmountFocused = false
                            isAddressFocused = false
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
            .zashiSheet(isPresented: $store.isQuotePresented) {
                quoteContent(colorScheme)
            }
            .zashiSheet(isPresented: $store.isQuoteToZecPresented) {
                quoteToZecContent(colorScheme)
            }
            .zashiSheet(isPresented: $store.isQuoteUnavailablePresented) {
                quoteUnavailableContent(colorScheme)
            }
            .zashiSheet(isPresented: $store.isCancelSheetVisible) {
                cancelSheetContent(colorScheme)
            }
            .zashiSheet(isPresented: $store.isRefundAddressExplainerEnabled) {
                refundAddressSheetContent(colorScheme)
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
    
    @ViewBuilder private func fromView(_ colorScheme: ColorScheme) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(
                        store.isSwapToZecExperienceEnabled
                        ? L10n.SwapAndPay.to
                        : L10n.SwapAndPay.from
                    )
                    .zFont(.medium, size: 14, style: Design.Text.primary)
                    .padding(.bottom, 4)
                    
                    Spacer()
                    
                    if !store.isSwapToZecExperienceEnabled {
                        HStack(spacing: 0) {
                            Text(
                                (store.isSensitiveContentHidden && store.spendability != .nothing)
                                ? L10n.SwapAndPay.max(L10n.General.hideBalancesMost)
                                : store.spendability == .nothing
                                ? L10n.SwapAndPay.max("")
                                : L10n.SwapAndPay.max(store.maxLabel)
                            )
                            .zFont(
                                .medium,
                                size: 14,
                                style: store.isInsufficientFunds
                                ? Design.Text.error
                                : Design.Text.tertiary
                            )
                            
                            if store.spendability == .nothing {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 11, height: 14)
                            }
                        }
                    }
                }
                
                HStack(spacing: 0) {
                    zecTicker(colorScheme)
                        .frame(maxWidth: .infinity)

                    if store.isSwapExperienceEnabled {
                        HStack(spacing: 0) {
                            if store.isInputInUsd {
                                Asset.Assets.Icons.currencyDollar.image
                                    .zImage(
                                        size: 20,
                                        style: store.amountText.isEmpty
                                        ? Design.Text.tertiary
                                        : Design.Text.primary
                                    )
                            } else {
                                Asset.Assets.Icons.currencyZec.image
                                    .zImage(
                                        size: 20,
                                        style: store.amountText.isEmpty
                                        ? Design.Text.tertiary
                                        : Design.Text.primary
                                    )
                            }
                            
                            Spacer()
                            
                            TextField(
                                "",
                                text: $store.amountText,
                                prompt:
                                    Text(isAmountFocused ? "" : store.localePlaceholder)
                                    .font(.custom(FontFamily.Inter.semiBold.name, size: 24))
                                    .foregroundColor(Design.Text.tertiary.color(colorScheme))
                            )
                            .disabled(store.isQuoteRequestInFlight)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .autocapitalization(.none)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .keyboardType(.decimalPad)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .lineLimit(1)
                            .multilineTextAlignment(.trailing)
                            .accentColor(Design.Text.primary.color(colorScheme))
                            .focused($isAmountFocused)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    isAmountFocused = true
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Design.Radius._lg)
                                .fill(Design.Inputs.Default.bg.color(colorScheme))
                                .background(
                                    RoundedRectangle(cornerRadius: Design.Radius._lg)
                                        .stroke(
                                            store.isInsufficientFunds
                                            ? Design.Inputs.ErrorFilled.stroke.color(colorScheme)
                                            : Design.Inputs.Default.bg.color(colorScheme)
                                        )
                                )
                        )
                    } else {
                        HStack(spacing: 0) {
                            Spacer()
                            
                            Text(store.primaryLabelFrom)
                                .zFont(.semiBold, size: 24, style: Design.Text.tertiary)
                                .multilineTextAlignment(.trailing)
                                .minimumScaleFactor(0.1)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                    }
                }
                .padding(.vertical, 8)

                HStack(spacing: 0) {
                    Spacer()

                    Text(store.secondaryLabelFrom)
                        .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        .padding(.trailing, 4)
                    
                    if store.isSwapExperienceEnabled {
                        Button {
                            store.send(.switchInputTapped)
                        } label: {
                            Asset.Assets.Icons.switchHorizontal.image
                                .zImage(size: 14, style: Design.Btns.Tertiary.fg)
                                .padding(5)
                                .background {
                                    RoundedRectangle(cornerRadius: Design.Radius._md)
                                        .fill(Design.Btns.Tertiary.bg.color(colorScheme))
                                }
                                .rotationEffect(Angle(degrees: 90))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if store.isInsufficientFunds && store.isSwapExperienceEnabled {
                HStack {
                    Spacer()
                    
                    Text(L10n.Send.Error.insufficientFunds)
                        .zFont(size: 14, style: Design.Inputs.ErrorFilled.hint)
                }
                .padding(.top, 6)
            }
        }
    }
    
    @ViewBuilder private func toView(_ colorScheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(
                store.isSwapToZecExperienceEnabled
                ? L10n.SwapAndPay.from
                : L10n.SwapAndPay.to
            )
            .zFont(.medium, size: 14, style: Design.Text.primary)
            .padding(.bottom, 4)
            
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button {
                        store.send(.assetSelectRequested)
                    } label: {
                        ticker(asset: store.selectedAsset, crosspay: false, colorScheme)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .disabled(store.isQuoteRequestInFlight)

                if store.isSwapExperienceEnabled {
                    HStack(spacing: 0) {
                        Spacer()
                        
                        Text(store.primaryLabelTo)
                            .zFont(.semiBold, size: 24, style: Design.Text.tertiary)
                            .multilineTextAlignment(.trailing)
                            .minimumScaleFactor(0.1)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                } else {
                    HStack(spacing: 0) {
                        if store.isInputInUsd {
                            Asset.Assets.Icons.currencyDollar.image
                                .zImage(
                                    size: 20,
                                    style: store.amountText.isEmpty
                                    ? Design.Text.tertiary
                                    : Design.Text.primary
                                )
                        }
                        
                        Spacer()
                        
                        TextField(
                            "",
                            text: $store.amountText,
                            prompt:
                                Text(isAmountFocused ? "" : store.localePlaceholder)
                                    .font(.custom(FontFamily.Inter.semiBold.name, size: 24))
                                    .foregroundColor(Design.Text.tertiary.color(colorScheme))
                        )
                        .disabled(store.isQuoteRequestInFlight)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .autocapitalization(.none)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.decimalPad)
                        .zFont(.semiBold, size: 24, style: Design.Text.primary)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .accentColor(Design.Text.primary.color(colorScheme))
                        .focused($isAmountFocused)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Design.Radius._lg)
                            .fill(Design.Inputs.Default.bg.color(colorScheme))
                            .background(
                                RoundedRectangle(cornerRadius: Design.Radius._lg)
                                    .stroke(
                                        store.isInsufficientFunds
                                        ? Design.Inputs.ErrorFilled.stroke.color(colorScheme)
                                        : Design.Inputs.Default.bg.color(colorScheme)
                                    )
                            )
                    )
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isAmountFocused = true
                        }
                    }
                }
            }
            .padding(.vertical, 8)

            HStack(spacing: 0) {
                Spacer()
                
                Text(store.secondaryLabelTo)
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
                
                if !store.isSwapExperienceEnabled {
                    Button {
                        store.send(.switchInputTapped)
                    } label: {
                        Asset.Assets.Icons.switchHorizontal.image
                            .zImage(size: 14, style: Design.Btns.Tertiary.fg)
                            .padding(8)
                            .background {
                                RoundedRectangle(cornerRadius: Design.Radius._md)
                                    .fill(Design.Btns.Tertiary.bg.color(colorScheme))
                            }
                            .rotationEffect(Angle(degrees: 90))
                    }
                    .padding(.leading, 4)
                }
            }

            if store.isInsufficientFunds && !store.isSwapExperienceEnabled {
                HStack {
                    Spacer()
                    
                    Text(L10n.Send.Error.insufficientFunds)
                        .zFont(size: 14, style: Design.Inputs.ErrorFilled.hint)
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func dividerView(_ colorScheme: ColorScheme) -> some View {
        HStack(spacing: 5) {
            Design.Utility.Gray._100.color(colorScheme)
                .frame(height: 1)
            
            Button {
                store.send(.enableSwapToZecExperience)
            } label: {
                Asset.Assets.Icons.switchHorizontal.image
                    .zImage(size: 20, style: Design.Text.primary)
                    .padding(8)
                    .rotationEffect(.degrees(90))
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._md)
                            .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                            .overlay {
                                RoundedRectangle(cornerRadius: Design.Radius._md)
                                    .stroke(Design.Surfaces.strokePrimary.color(colorScheme))
                            }
                    }
            }
            .disabled(store.isQuoteRequestInFlight)
            
            Design.Utility.Gray._100.color(colorScheme)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
