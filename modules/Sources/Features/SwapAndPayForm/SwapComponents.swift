//
//  SwapComponents.swift
//  modules
//
//  Created by Lukáš Korba on 28.08.2025.
//

import UIKit
import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents
import SwapAndPay

import BalanceBreakdown

public extension SwapAndPayForm {
    @ViewBuilder func assetContent(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    VStack {
                        Text(L10n.SwapAndPay.selectToken.uppercased())
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
                    placeholder: L10n.SwapAndPay.search,
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
                
                Text(L10n.SwapAndPay.slippage)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.bottom, 8)
                
                Text(L10n.SwapAndPay.slippageDesc)
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
                        Text(L10n.SwapAndPay.custom)
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
                
                Group {
                    if store.isSwapExperienceEnabled {
                        if store.slippageInSheet > 30.0 {
                            Text(L10n.SwapAndPay.maxAllowedSlippage1)
                            + Text(L10n.SwapAndPay.maxAllowedSlippage2(Constants.maxAllowedSlippage)).bold()
                        } else if let slippageDiff = store.slippageDiff {
                            Text(L10n.SwapAndPay.slippageSet1)
                            + Text(
                                L10n.SwapAndPay.slippageSet2a(
                                    store.currentSlippageInSheetString,
                                    slippageDiff
                                )
                            ).bold()
                            + Text(L10n.SwapAndPay.slippageSet3)
                        } else {
                            Text(L10n.SwapAndPay.slippageSet1)
                            + Text(L10n.SwapAndPay.slippageSet2b(store.currentSlippageInSheetString)).bold()
                            + Text(L10n.SwapAndPay.slippageSet3)
                        }
                    } else {
                        if store.slippageInSheet > 30.0 {
                            Text(L10n.SwapAndPay.maxAllowedSlippage1)
                            + Text(L10n.SwapAndPay.maxAllowedSlippage2(Constants.maxAllowedSlippage)).bold()
                        } else if let slippageDiff = store.slippageDiff {
                            Text(L10n.Crosspay.slippageSet1)
                            + Text(
                                L10n.Crosspay.slippageSet2a(
                                    store.currentSlippageInSheetString,
                                    slippageDiff
                                )
                            ).bold()
                            + Text(L10n.Crosspay.slippageSet3)
                        } else {
                            Text(L10n.Crosspay.slippageSet1)
                            + Text(L10n.Crosspay.slippageSet2b(store.currentSlippageInSheetString)).bold()
                            + Text(L10n.Crosspay.slippageSet3)
                        }
                    }
                }
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
                
                if !store.isSwapExperienceEnabled && !store.isSwapToZecExperienceEnabled {
                    HStack(alignment: .top, spacing: 0) {
                        Asset.Assets.infoOutline.image
                            .zImage(size: 16, style: Design.Text.tertiary)
                            .padding(.trailing, 12)
                        
                        Text(L10n.SwapAndPay.slippageWarn)
                            .zFont(size: 12, style: Design.Text.tertiary)
                    }
                    .padding(.bottom, 24)
                }
                
                ZashiButton(L10n.General.confirm) {
                    store.send(.slippageSetConfirmTapped)
                }
                .padding(.bottom, keyboardVisible ? 74 : Design.Spacing.sheetBottomSpace)
                .disabled(store.slippageInSheet > 30.0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

                Text(L10n.SwapAndPay.quoteUnavailable)
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
                    ? L10n.SwapAndPay.cancelSwap
                    : L10n.SwapAndPay.cancelPayment,
                    type: .destructive1
                ) {
                    store.send(.cancelPaymentTapped)
                }
                .padding(.bottom, 8)

                ZashiButton(
                    (store.isSwapExperienceEnabled || store.isSwapToZecExperienceEnabled)
                    ? L10n.SwapAndPay.editSwap
                    : L10n.SwapAndPay.editPayment
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
                    ? L10n.SwapAndPay.swapNow
                    : L10n.SwapAndPay.payNow
                )
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.vertical, 24)

                // refactored to showcase UI
                ZStack {
                    HStack(spacing: 8) {
                        VStack(spacing: 0) {
                            zecTickerBadge(colorScheme)

                            Text(store.zcashNameInQuote)
                                .zFont(.semiBold, size: 12, style: Design.Text.tertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .padding(.vertical, 6)

                            Text(store.zecToBeSpendInQuote)
                                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.1)

                            Text(store.zecUsdToBeSpendInQuote)
                                .zFont(.medium, size: 12, style: Design.Text.tertiary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 122)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                        }
                        
                        VStack(spacing: 0) {
                            tokenTickerSelector(asset: store.selectedAsset, colorScheme)

                            Text(store.assetNameInQuote)
                                .zFont(.semiBold, size: 12, style: Design.Text.tertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .padding(.vertical, 6)

                            Text(store.tokenToBeReceivedInQuote)
                                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.1)
                            
                            Text(store.tokenUsdToBeReceivedInQuote)
                                .zFont(.medium, size: 12, style: Design.Text.tertiary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 122)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                        }
                    }
                    
                    FloatingArrow()
                }
                .padding(.bottom, 32)
                
//                ZStack {
//                    VStack(spacing: 1) {
//                        HStack(spacing: 0) {
//                            zecTickerBadge(colorScheme)
//
//                            VStack(alignment: .leading, spacing: 0) {
//                                Text(tokenName.uppercased())
//                                    .zFont(.semiBold, size: 14, style: Design.Text.primary)
//
//                                Text(store.zcashNameInQuote)
//                                    .zFont(.semiBold, size: 12, style: Design.Text.tertiary)
//                            }
//                            .lineLimit(1)
//                            .minimumScaleFactor(0.8)
//
//                            Spacer()
//
//                            VStack(alignment: .trailing, spacing: 0) {
//                                Text(store.zecToBeSpendInQuote)
//                                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
//
//                                Text(store.zecUsdToBeSpendInQuote)
//                                    .zFont(.medium, size: 12, style: Design.Text.tertiary)
//                            }
//                            .lineLimit(1)
//                            .minimumScaleFactor(0.1)
//                        }
//                        .padding(.horizontal, 20)
//                        .padding(.vertical, 12)
//                        .frame(maxWidth: .infinity)
//                        .frame(height: 60)
//                        .background {
//                            CustomRoundedRectangle(corners: [.topLeft, .topRight], radius: Design.Radius._3xl)
//                                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
//                        }
//                        
//                        HStack(spacing: 0) {
//                            tokenTickerSelector(asset: store.selectedAsset, colorScheme)
//
//                            VStack(alignment: .leading, spacing: 0) {
//                                if let asset = store.selectedAsset {
//                                    Text(asset.token)
//                                        .zFont(.semiBold, size: 14, style: Design.Text.primary)
//                                }
//
//                                Text(store.assetNameInQuote)
//                                    .zFont(.semiBold, size: 12, style: Design.Text.tertiary)
//                            }
//                            .lineLimit(1)
//                            .minimumScaleFactor(0.1)
//
//                            Spacer()
//                            
//                            VStack(alignment: .trailing, spacing: 0) {
//                                Text(store.tokenToBeReceivedInQuote)
//                                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
//
//                                Text(store.tokenUsdToBeReceivedInQuote)
//                                    .zFont(.medium, size: 12, style: Design.Text.tertiary)
//                            }
//                            .lineLimit(1)
//                            .minimumScaleFactor(0.1)
//                        }
//                        .padding(.horizontal, 20)
//                        .padding(.vertical, 12)
//                        .frame(maxWidth: .infinity)
//                        .frame(height: 60)
//                        .background {
//                            CustomRoundedRectangle(corners: [.bottomLeft, .bottomRight], radius: Design.Radius._3xl)
//                                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
//                        }
//                    }
//                    
//                    FloatingArrow()
//                }
//                .padding(.bottom, 32)

                quoteLineContent(
                    store.isSwapExperienceEnabled
                    ? L10n.SwapAndPay.swapFrom
                    : L10n.SwapAndPay.payFrom,
                    store.selectedWalletAccount?.vendor.name() ?? L10n.SwapAndPay.Quote.zashi
                )
                .padding(.bottom, 12)
                
                quoteLineContent(
                    store.isSwapExperienceEnabled
                    ? L10n.SwapAndPay.swapTo
                    : L10n.SwapAndPay.payTo,
                    store.address.zip316
                )
                .padding(.bottom, 12)

                quoteLineContent(L10n.SwapAndPay.totalFees, "\(store.totalFeesStr) \(tokenName)")
                if !store.isSwapExperienceEnabled {
                    HStack(spacing: 0) {
                        Spacer()
                        
                        Text(store.totalFeesUsdStr)
                            .zFont(.medium, size: 12, style: Design.Text.tertiary)
                    }
                }

                if !store.isSwapExperienceEnabled {
                    quoteLineContent(
                        L10n.SwapAndPay.maxSlippage(store.currentSlippageString),
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
                    Text(L10n.SwapAndPay.totalAmount)
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
                        
                        Text(L10n.SwapAndPay.swapQuoteSlippageWarn(store.swapQuoteSlippageUsdStr, store.currentSlippageString))
                    }
                    .zFont(size: 12, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }

                if store.selectedWalletAccount?.vendor == .keystone {
                    ZashiButton(L10n.Keystone.confirmSwap) {
                        store.send(.confirmWithKeystoneTapped)
                    }
                    .padding(.bottom, Design.Spacing.sheetBottomSpace)
                } else {
                    ZashiButton(L10n.General.confirm) {
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
                Text(L10n.SwapToZec.review)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.vertical, 24)

                ZStack {
                    HStack(spacing: 8) {
                        VStack(spacing: 0) {
                            tokenTickerSelector(asset: store.selectedAsset, colorScheme)

                            Text(store.assetNameInQuote)
                                .zFont(.semiBold, size: 12, style: Design.Text.tertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .padding(.vertical, 6)

                            Text(store.swapToZecAmountInQuote)
                                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.1)
                            
                            Text(store.zecUsdToBeSpendInQuote)
                                .zFont(.medium, size: 12, style: Design.Text.tertiary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 122)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                        }
                        
                        VStack(spacing: 0) {
                            zecTickerBadge(colorScheme)

                            Text(store.zcashNameInQuote)
                                .zFont(.semiBold, size: 12, style: Design.Text.tertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .padding(.vertical, 6)

                            Text(store.tokenToBeReceivedInQuote)
                                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.1)

                            Text(store.tokenUsdToBeReceivedInQuote)
                                .zFont(.medium, size: 12, style: Design.Text.tertiary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 122)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                        }
                    }
                    
                    FloatingArrow()
                }
                .padding(.bottom, 32)

                quoteLineContent(L10n.SwapAndPay.totalFees, "\(store.swapToZecTotalFees) \(store.selectedAsset?.tokenName ?? "")")

                Divider()
                    .frame(height: 1)
                    .background(Design.Surfaces.strokeSecondary.color(colorScheme))
                    .padding(.vertical, 12)
                
                HStack(spacing: 0) {
                    Text(L10n.SwapAndPay.totalAmount)
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
                    
                    Text(L10n.SwapAndPay.swapQuoteSlippageWarn(store.swapToZecQuoteSlippageUsdStr, store.currentSlippageString))
                }
                .zFont(size: 12, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 24)

                ZashiButton(L10n.General.confirm) {
                    store.send(.confirmToZecButtonTapped)
                }
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            }
        }
    }
    
    @ViewBuilder private func quoteLineContent(
        _ info: String,
        _ value: String
    ) -> some View {
        HStack(spacing: 0) {
            Text(info)
                .zFont(size: 14, style: Design.Text.tertiary)

            Spacer()

            Text(value)
                .zFont(.medium, size: 14, style: Design.Text.primary)
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

            Text(L10n.SwapAndPay.canceltitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.bottom, 8)

            Text(L10n.SwapAndPay.cancelMsg)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .padding(.bottom, 32)

            ZashiButton(
                L10n.SwapAndPay.cancelSwap,
                type: .destructive1
            ) {
                store.send(.cancelSwapTapped)
            }
            .padding(.bottom, 8)
            
            ZashiButton(L10n.SwapAndPay.cancelDont) {
                store.send(.dontCancelTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder func refundAddressSheetContent(_ colorScheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.SwapToZec.RefundAddress.title)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.bottom, 8)
                .padding(.top, 32)

            Text(L10n.SwapToZec.RefundAddress.msg1)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            Text(L10n.SwapToZec.RefundAddress.msg2)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .padding(.bottom, 32)

            ZashiButton(L10n.General.ok) {
                store.send(.refundAddressCloseTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}
