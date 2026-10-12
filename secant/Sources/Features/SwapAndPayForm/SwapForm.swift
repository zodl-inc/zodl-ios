//
//  SwapForm.swift
//  modules
//
//  Created by Lukáš Korba on 28.08.2025.
//

import SwiftUI
import ComposableArchitecture

extension SwapAndPayForm {
    @ViewBuilder func swapFormView(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            ScrollView {
                VStack(spacing: 0) {
                    amountInputSection(colorScheme)
                        .padding(.top, 36)

                    refundAddressSlot()

                    dividerView(colorScheme)

                    quoteOutputSection(colorScheme)

                    if store.isSwapExperienceEnabled {
                        addressView()
                    }
                    
                    slippageView()
                        .padding(.top, 24)
                        .padding(.bottom, 16)

                    HStack(spacing: 0) {
                        Text(localizable: .swapAndPayRate)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        
                        Spacer()
                        
                        if let rateValue = store.rateToOneZec, let selectedToken = store.selectedAsset?.token {
                            Text(localizable: .swapAndPayOneZecRate(rateValue, selectedToken))
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
                        VStack(spacing: 0) {
                            if store.isQuoteRequestInFlight {
                                ZashiButton(
                                    String(localizable: .swapAndPayGetQuote),
                                    accessoryView: ProgressView()
                                ) { }
                                    .disabled(true)
                                    .padding(.bottom, 56)
                            } else {
                                ZashiButton(String(localizable: .swapAndPayGetQuote)) {
                                    store.send(.getQuoteTapped(skipRefundWarning: false))
                                }
                                .accessibilityIdentifier(AccessibilityID.SwapForm.reviewButton)
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
            .zashiSheet(isPresented: $store.isRefundWarningPresented) {
                refundWarningSheetContent(colorScheme)
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
    
    @ViewBuilder private func amountInputSection(_ colorScheme: ColorScheme) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(localizable: .swapAndPayFrom)
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                        .padding(.bottom, 4)

                    Spacer()

                    if store.isSwapExperienceEnabled {
                        HStack(spacing: 0) {
                            Text(
                                (store.isSensitiveContentHidden && store.spendability != .nothing)
                                ? String(localizable: .swapAndPayMax(String(localizable: .generalHideBalancesMost)))
                                : store.spendability == .nothing
                                ? String(localizable: .swapAndPayMax(""))
                                : String(localizable: .swapAndPayMax(store.maxLabel))
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
                    Group {
                        if store.isSwapExperienceEnabled {
                            zecTicker(colorScheme)
                        } else {
                            assetSelectButton(colorScheme)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 0) {
                        if store.isInputInUsd {
                            Asset.Assets.Icons.currencyDollar.image
                                .zImage(
                                    size: 20,
                                    style: store.amountText.isEmpty
                                    ? Design.Text.tertiary
                                    : Design.Text.primary
                                )
                        } else if store.isSwapExperienceEnabled {
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
                }
                .padding(.vertical, 8)

                HStack(spacing: 0) {
                    // Swapping INTO ZEC spends no ZEC from this wallet, so no max applies there.
                    // The chip stays laid out (invisible) so the row height is the same in both directions.
                    ZashiMaxChip(
                        title: String(localizable: .generalMax),
                        style: .swap,
                        isEnabled: store.isSwapMaxButtonEnabled,
                        isInFlight: store.isMaxRequestInFlight || store.isSpendabilityBeingDetermined
                    ) {
                        store.send(.maxTapped)
                    }
                    .accessibilityIdentifier(AccessibilityID.SwapForm.maxButton)
                    .opacity(store.isSwapExperienceEnabled ? 1 : 0)
                    .disabled(!store.isSwapExperienceEnabled)
                    .accessibilityHidden(!store.isSwapExperienceEnabled)

                    Spacer()

                    Text(store.isSwapExperienceEnabled ? store.secondaryLabelFrom : store.secondaryLabelTo)
                        .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        .padding(.trailing, 4)

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
            .frame(maxWidth: .infinity, alignment: .leading)

            if store.isInsufficientFunds {
                HStack {
                    Spacer()

                    Text(localizable: .sendErrorInsufficientFunds)
                        .zFont(size: 14, style: Design.Inputs.ErrorFilled.hint)
                }
                .padding(.top, 6)
            }
        }
    }

    /// Reserves the refund address height in both directions so the switch button never moves.
    @ViewBuilder private func refundAddressSlot() -> some View {
        ZStack(alignment: .top) {
            addressView(interactive: false)
                .hidden()

            if store.isSwapToZecExperienceEnabled {
                addressView()
            }
        }
        .padding(.bottom, 16)
    }

    @ViewBuilder private func quoteOutputSection(_ colorScheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .swapAndPayTo)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .padding(.bottom, 4)

            HStack(spacing: 0) {
                Group {
                    if store.isSwapExperienceEnabled {
                        assetSelectButton(colorScheme)
                    } else {
                        zecTicker(colorScheme)
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 0) {
                    Spacer()

                    Text(store.isSwapExperienceEnabled ? store.primaryLabelTo : store.primaryLabelFrom)
                        .zFont(.semiBold, size: 24, style: Design.Text.tertiary)
                        .multilineTextAlignment(.trailing)
                        .minimumScaleFactor(0.1)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
            }
            .padding(.vertical, 8)

            HStack(spacing: 0) {
                Spacer()

                Text(store.isSwapExperienceEnabled ? store.secondaryLabelTo : store.secondaryLabelFrom)
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func assetSelectButton(_ colorScheme: ColorScheme) -> some View {
        HStack(spacing: 0) {
            Button {
                store.send(.assetSelectRequested)
            } label: {
                ticker(asset: store.selectedAsset, crosspay: false, colorScheme)
            }
            .accessibilityIdentifier(AccessibilityID.SwapForm.assetSelectButton)

            Spacer()
        }
        .disabled(store.isQuoteRequestInFlight)
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
            .accessibilityIdentifier(AccessibilityID.SwapForm.changeModeButton)
            .disabled(store.isQuoteRequestInFlight)
            
            Design.Utility.Gray._100.color(colorScheme)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
