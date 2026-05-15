//
//  SwapComponents.swift
//  modules
//
//  Created by Lukáš Korba on 28.08.2025.
//

import UIKit
import SwiftUI
import ComposableArchitecture

extension SwapAndPayForm {
    @ViewBuilder func assetContent(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    VStack {
                        Text(String(localizable: .swapAndPaySelectToken).uppercased())
                            .zFont(.semiBold, size: 16, style: Design.Text.primary)
                            .fixedSize()
                    }
                    
                    HStack {
                        Button {
                            store.send(.closeAssetsSheetTapped)
                        } label: {
                            Asset.Assets.buttonCloseX.image
                                .zImage(size: 24, style: Design.Text.primary)
                                .padding(8)
                        }
                        
                        Spacer()
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
                .padding(.horizontal, 20)
                
                ZashiTextField(
                    text: $store.searchTerm,
                    placeholder: String(localizable: .swapAndPaySearch),
                    eraseAction: { store.send(.eraseSearchTermTapped) },
                    accessoryView: !store.searchTerm.isEmpty ? Asset.Assets.Icons.xClose.image
                        .zImage(size: 16, style: Design.Btns.Tertiary.fg) : nil,
                    prefixView: Asset.Assets.Icons.search.image
                        .zImage(size: 20, style: Design.Dropdowns.Default.text)
                )
                .padding(.bottom, 32)
                .padding(.horizontal, 20)
                
                if let _ = store.swapAssetFailedWithRetry {
                    assetsFailureComposition(colorScheme)
                } else if store.swapAssetsToPresent.isEmpty && !store.searchTerm.isEmpty {
                    assetsEmptyComposition(colorScheme)
                } else if store.swapAssetsToPresent.isEmpty && store.searchTerm.isEmpty {
                    assetsLoadingComposition(colorScheme)
                } else {
                    List {
                        WithPerceptionTracking {
                            ForEach(store.swapAssetsToPresent, id: \.self) { asset in
                                assetView(asset, colorScheme)
                                    .listRowInsets(EdgeInsets())
                                    .listRowBackground(Asset.Colors.background.color)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                    .background(Asset.Colors.background.color)
                    .listStyle(.plain)
                }
            }
        }
    }
}
    
extension SwapAndPayForm {
    @ViewBuilder private func assetView(_ asset: SwapAsset, _ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            Button {
                store.send(.assetTapped(asset))
            } label: {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        asset.tokenIcon
                            .resizable()
                            .frame(width: 40, height: 40)
                            .padding(.trailing, 12)
                            .overlay {
                                ZStack {
                                    Circle()
                                        .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                                        .frame(width: 22, height: 22)
                                        .offset(x: 9, y: 16)
                                    
                                    asset.chainIcon
                                        .resizable()
                                        .frame(width: 18, height: 18)
                                        .offset(x: 9, y: 16)
                                }
                            }
                        
                        VStack(alignment: .leading, spacing: 0) {
                            Text(asset.token)
                                .font(.custom(FontFamily.Inter.semiBold.name, size: 14))
                                .zForegroundColor(Design.Text.primary)
                            
                            Text(asset.chainName)
                                .font(.custom(FontFamily.Inter.regular.name, size: 14))
                                .zForegroundColor(Design.Text.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.top, 2)
                        }
                        .padding(.trailing, 16)
                        
                        Spacer(minLength: 2)
                        
                        Asset.Assets.chevronRight.image
                            .zImage(size: 20, style: Design.Text.tertiary)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    
                    if store.swapAssetsToPresent.last != asset {
                        Design.Surfaces.divider.color(colorScheme)
                            .frame(height: 1)
                    }
                }
            }
        }
    }
    
    @ViewBuilder func slippageContent(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    store.send(.closeSlippageSheetTapped)
                } label: {
                    Asset.Assets.buttonCloseX.image
                        .zImage(size: 24, style: Design.Text.primary)
                        .padding(8)
                }
                .padding(.vertical, 24)
                
                Text(localizable: .swapAndPaySlippage)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.bottom, 8)
                
                Text(localizable: .swapAndPaySlippageDesc)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack(spacing: 0) {
                    slippageChip(index: 0, text: store.slippage05String, colorScheme)
                    slippageChip(index: 1, text: store.slippage1String, colorScheme)
                    slippageChip(index: 2, text: store.slippage2String, colorScheme)
                    
                    if store.selectedSlippageChip == 3 {
                        HStack(spacing: 0) {
                            Spacer()
                            
                            FocusableTextField(
                                text: $store.customSlippage,
                                isFirstResponder: $isSlippageFocused,
                                placeholder: "%",
                                colorScheme: colorScheme
                            )
                            .multilineTextAlignment(.center)
                            .frame(maxWidth:
                                    store.customSlippage.isEmpty
                                   ? .infinity
                                   : (store.customSlippage.contains(".") || store.customSlippage.contains(","))
                                   ? CGFloat(store.customSlippage.count - 1) * 13.0 + 2.0
                                   : CGFloat(store.customSlippage.count) * 13.0
                            )
                            .keyboardType(.decimalPad)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    isSlippageFocused = true
                                }
                            }
                            
                            if !store.customSlippage.isEmpty {
                                Text("%")
                                    .zFont(.medium, size: 16, style: Design.Switcher.selectedText)
                            }
                            
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._lg)
                                .fill(Design.Switcher.selectedBg.color(colorScheme))
                                .background {
                                    RoundedRectangle(cornerRadius: Design.Radius._lg)
                                        .stroke(Design.Switcher.selectedStroke.color(colorScheme))
                                }
                        }
                    } else {
                        Text(localizable: .swapAndPayCustom)
                            .zFont(.medium, size: 16, style: Design.Switcher.defaultText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .onTapGesture {
                                store.send(.slippageChipTapped(3))
                            }
                    }
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._lg)
                        .fill(Design.Switcher.surfacePrimary.color(colorScheme))
                }
                .padding(.top, 24)
                
                slippageInfoText()
                .zFont(size: 12, style: slippageWarnTextStyle())
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._lg)
                        .fill(slippageWarnBcgColor(colorScheme))
                }
                .padding(.vertical, 20)
                
                Spacer()

                if store.slippageInSheet < 2.0 {
                    if let attrText = try? AttributedString(
                        markdown: String(localizable: .swapAndPaySmallSlippageWarn("\(SwapAndPay.Constants.defaultSlippage)", "\(SwapAndPay.Constants.defaultSlippage)")),
                        including: \.zashiApp
                    ) {
                        ZashiText(
                            withAttributedString: attrText,
                            colorScheme: colorScheme,
                            textColor: Design.Utility.WarningYellow._900.color(colorScheme),
                            textSize: 12
                        )
                        .zFont(size: 12, style: Design.Utility.WarningYellow._900)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._lg)
                                .fill(Design.Utility.WarningYellow._100.color(colorScheme))
                        }
                        .padding(.bottom, 24)
                    }
                }

                ZashiButton(String(localizable: .generalConfirm)) {
                    store.send(.slippageSetConfirmTapped)
                }
                .padding(.bottom, keyboardVisible ? 74 : Design.Spacing.sheetBottomSpace)
                .disabled(store.slippageInSheet > 30.0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    @ViewBuilder private func slippageInfoText() -> some View {
        if store.isSwapExperienceEnabled || store.isSwapToZecExperienceEnabled {
            if store.slippageInSheet > 30.0 {
                let part2 = Text(localizable: .swapAndPayMaxAllowedSlippage2(Constants.maxAllowedSlippage)).bold()
                Text(localizable: .swapAndPayMaxAllowedSlippage1) + part2 + Text(store.crosspaySlippageWarning)
            } else if let slippageDiff = store.slippageDiff {
                let part2 = Text(localizable: .swapAndPaySlippageSet2a(store.currentSlippageInSheetString, slippageDiff)).bold()
                Text(localizable: .swapAndPaySlippageSet1) + part2 + Text(localizable: .swapAndPaySlippageSet3) + Text(store.crosspaySlippageWarning)
            } else {
                let part2 = Text(localizable: .swapAndPaySlippageSet2b(store.currentSlippageInSheetString)).bold()
                Text(localizable: .swapAndPaySlippageSet1) + part2 + Text(localizable: .swapAndPaySlippageSet3) + Text(store.crosspaySlippageWarning)
            }
        } else {
            if store.slippageInSheet > 30.0 {
                let part2 = Text(localizable: .swapAndPayMaxAllowedSlippage2(Constants.maxAllowedSlippage)).bold()
                Text(localizable: .swapAndPayMaxAllowedSlippage1) + part2 + Text(store.crosspaySlippageWarning)
            } else if let slippageDiff = store.slippageDiff {
                let part2 = Text(localizable: .crosspaySlippageSet2a(store.currentSlippageInSheetString, slippageDiff)).bold()
                Text(localizable: .crosspaySlippageSet1) + part2 + Text(localizable: .crosspaySlippageSet3) + Text(store.crosspaySlippageWarning)
            } else {
                let part2 = Text(localizable: .crosspaySlippageSet2b(store.currentSlippageInSheetString)).bold()
                Text(localizable: .crosspaySlippageSet1) + part2 + Text(localizable: .crosspaySlippageSet3) + Text(store.crosspaySlippageWarning)
            }
        }
    }

    @ViewBuilder private func slippageChip(index: Int, text: String, _ colorScheme: ColorScheme) -> some View {
        if store.selectedSlippageChip == index {
            Text(text)
                .zFont(.medium, size: 16, style: Design.Switcher.selectedText)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._lg)
                        .fill(Design.Switcher.selectedBg.color(colorScheme))
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._lg)
                                .stroke(Design.Switcher.selectedStroke.color(colorScheme))
                        }
                }
                .onTapGesture {
                    store.send(.slippageChipTapped(index))
                }
        } else {
            Text(text)
                .zFont(.medium, size: 16, style: Design.Switcher.defaultText)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .onTapGesture {
                    store.send(.slippageChipTapped(index))
                }
        }
    }

    @ViewBuilder func quoteUnavailableContent(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Asset.Assets.Icons.alertOutline.image
                    .zImage(size: 24, style: Design.Utility.ErrorRed._500)
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._full)
                            .fill(Design.Utility.ErrorRed._50.color(colorScheme))
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 12)

                Text(localizable: .swapAndPayQuoteUnavailable)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.bottom, 8)

                Text(store.quoteUnavailableErrorMsg)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                ZashiButton(
                    (store.isSwapExperienceEnabled || store.isSwapToZecExperienceEnabled)
                    ? String(localizable: .swapAndPayCancelSwap)
                    : String(localizable: .swapAndPayCancelPayment),
                    type: .destructive1
                ) {
                    store.send(.cancelPaymentTapped)
                }
                .padding(.bottom, 8)

                ZashiButton(
                    (store.isSwapExperienceEnabled || store.isSwapToZecExperienceEnabled)
                    ? String(localizable: .swapAndPayEditSwap)
                    : String(localizable: .swapAndPayEditPayment)
                ) {
                    store.send(.editPaymentTapped)
                }
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            }
        }
    }
    
    @ViewBuilder func quoteContent(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Text(
                    store.isSwapExperienceEnabled
                    ? String(localizable: .swapAndPaySwapNow)
                    : String(localizable: .swapAndPayPayNow)
                )
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.vertical, 24)

                SwapFromToView(
                    tokenName: tokenName,
                    zcashNameInQuote: store.zcashNameInQuote,
                    zecToBeSpendInQuote: store.zecToBeSpendInQuote,
                    zecUsdToBeSpendInQuote: store.zecUsdToBeSpendInQuote,
                    selectedAsset: store.selectedAsset,
                    assetNameInQuote: store.assetNameInQuote,
                    tokenToBeReceivedInQuote: store.tokenToBeReceivedInQuote,
                    tokenUsdToBeReceivedInQuote: store.tokenUsdToBeReceivedInQuote
                )
                .padding(.bottom, 32)

                quoteLineContent(
                    store.isSwapExperienceEnabled
                    ? String(localizable: .swapAndPaySwapFrom)
                    : String(localizable: .swapAndPayPayFrom),
                    store.selectedWalletAccount?.vendor.name() ?? String(localizable: .swapAndPayQuoteZashi)
                )
                .padding(.bottom, 12)
                
                quoteLineContent(
                    store.isSwapExperienceEnabled
                    ? String(localizable: .swapAndPaySwapTo)
                    : String(localizable: .swapAndPayPayTo),
                    store.address.zip316,
                    addressFont: true
                )
                .padding(.bottom, 12)

                quoteLineContent(String(localizable: .swapAndPayTotalFees), "\(store.totalFeesStr) \(tokenName)")
                if !store.isSwapExperienceEnabled {
                    HStack(spacing: 0) {
                        Spacer()
                        
                        Text(store.totalFeesUsdStr)
                            .zFont(.medium, size: 12, style: Design.Text.tertiary)
                    }
                }

                if !store.isSwapExperienceEnabled {
                    quoteLineContent(
                        String(localizable: .swapAndPayMaxSlippage(store.currentSlippageString)),
                        "\(store.swapSlippageStr) \(tokenName)"
                    )
                    .padding(.top, 12)
                    
                    if !store.isSwapExperienceEnabled {
                        HStack(spacing: 0) {
                            Spacer()
                            
                            Text(store.swapSlippageUsdStr)
                                .zFont(.medium, size: 12, style: Design.Text.tertiary)
                        }
                    }
                }
                
                Divider()
                    .frame(height: 1)
                    .background(Design.Surfaces.strokeSecondary.color(colorScheme))
                    .padding(.vertical, 12)
                
                HStack(spacing: 0) {
                    Text(localizable: .swapAndPayTotalAmount)
                        .zFont(.medium, size: 14, style: Design.Text.primary)

                    Spacer()

                    Text("\(store.totalZecToBeSpendInQuote) \(tokenName)")
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                }
                HStack(spacing: 0) {
                    Spacer()

                    Text(store.totalZecUsdToBeSpendInQuote)
                        .zFont(.medium, size: 12, style: Design.Text.tertiary)
                }
                .padding(.bottom, 32)
                
                if store.isSwapExperienceEnabled {
                    HStack(alignment: .top, spacing: 0) {
                        Asset.Assets.infoOutline.image
                            .zImage(size: 16, style: Design.Text.tertiary)
                            .padding(.trailing, 12)
                        
                        Text(localizable: .swapAndPaySwapQuoteSlippageWarn(store.swapQuoteSlippageUsdStr, store.currentSlippageString))
                    }
                    .zFont(size: 12, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }

                if store.selectedWalletAccount?.vendor == .keystone {
                    ZashiButton(String(localizable: .keystoneConfirmSwap)) {
                        store.send(.confirmWithKeystoneTapped)
                    }
                    .padding(.bottom, Design.Spacing.sheetBottomSpace)
                } else {
                    ZashiButton(String(localizable: .generalConfirm)) {
                        store.send(.confirmButtonTapped)
                    }
                    .padding(.bottom, Design.Spacing.sheetBottomSpace)
                }
            }
        }
    }
    
    @ViewBuilder func quoteToZecContent(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Text(localizable: .swapToZecReview)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.vertical, 24)

                SwapFromToView(
                    reversed: true,
                    tokenName: tokenName,
                    zcashNameInQuote: store.zcashNameInQuote,
                    zecToBeSpendInQuote: store.tokenToBeReceivedInQuote,
                    zecUsdToBeSpendInQuote: store.tokenUsdToBeReceivedInQuote,
                    selectedAsset: store.selectedAsset,
                    assetNameInQuote: store.assetNameInQuote,
                    tokenToBeReceivedInQuote: store.swapToZecAmountInQuote,
                    tokenUsdToBeReceivedInQuote: store.zecUsdToBeSpendInQuote
                )
                .padding(.bottom, 32)

                quoteLineContent(String(localizable: .swapAndPayTotalFees), "\(store.swapToZecTotalFees) \(store.selectedAsset?.tokenName ?? "")")

                Divider()
                    .frame(height: 1)
                    .background(Design.Surfaces.strokeSecondary.color(colorScheme))
                    .padding(.vertical, 12)
                
                HStack(spacing: 0) {
                    Text(localizable: .swapAndPayTotalAmount)
                        .zFont(.medium, size: 14, style: Design.Text.primary)

                    Spacer()

                    Text("\(store.swapToZecAmountInQuote) \(store.selectedAsset?.tokenName ?? "")")
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                }
                HStack(spacing: 0) {
                    Spacer()

                    Text(store.zecUsdToBeSpendInQuote)
                        .zFont(.medium, size: 12, style: Design.Text.tertiary)
                }
                .padding(.bottom, 32)
                
                HStack(alignment: .top, spacing: 0) {
                    Asset.Assets.infoOutline.image
                        .zImage(size: 16, style: Design.Text.tertiary)
                        .padding(.trailing, 12)
                    
                    Text(localizable: .swapAndPaySwapQuoteSlippageWarn(store.swapToZecQuoteSlippageUsdStr, store.currentSlippageString))
                }
                .zFont(size: 12, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 24)

                ZashiButton(String(localizable: .generalConfirm)) {
                    store.send(.confirmToZecButtonTapped)
                }
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            }
        }
    }
    
    @ViewBuilder private func quoteLineContent(
        _ info: String,
        _ value: String,
        addressFont: Bool = false
    ) -> some View {
        HStack(spacing: 0) {
            Text(info)
                .zFont(size: 14, style: Design.Text.tertiary)

            Spacer()

            Text(value)
                .zFont(.medium, fontFamily: addressFont ? .robotoMono : .inter, size: 14, style: Design.Text.primary)
        }
    }
    
    @ViewBuilder func cancelSheetContent(_ colorScheme: ColorScheme) -> some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.logOut.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)
                .padding(.bottom, 20)

            Text(localizable: .swapAndPayCanceltitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.bottom, 8)

            Text(localizable: .swapAndPayCancelMsg)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .padding(.bottom, 32)

            ZashiButton(
                String(localizable: .swapAndPayCancelSwap),
                type: .destructive1
            ) {
                store.send(.cancelSwapTapped)
            }
            .padding(.bottom, 8)
            
            ZashiButton(String(localizable: .swapAndPayCancelDont)) {
                store.send(.dontCancelTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder func refundAddressSheetContent(_ colorScheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .swapToZecRefundAddressTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.bottom, 8)
                .padding(.top, 32)

            Text(localizable: .swapToZecRefundAddressMsg1)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            Text(localizable: .swapToZecRefundAddressMsg2)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .padding(.bottom, 32)

            ZashiButton(String(localizable: .generalOk)) {
                store.send(.refundAddressCloseTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}
