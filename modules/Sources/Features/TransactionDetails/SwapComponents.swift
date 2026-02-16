//
//  SwapComponents.swift
//  modules
//
//  Created by Lukáš Korba on 24.06.2025.
//

import SwiftUI
import UIComponents
import Generated
import SwapAndPay
import Models

extension TransactionDetailsView {
    @ViewBuilder func swapRefundInfoView() -> some View {
        HStack(alignment: .top, spacing: 0) {
            Asset.Assets.infoOutline.image
                .zImage(size: 20, style: Design.Utility.WarningYellow._500)
                .padding(.trailing, 12)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.SwapAndPay.refundTitle)
                    .zFont(.medium, size: 14, style: Design.Utility.WarningYellow._700)

                Text(L10n.SwapAndPay.refundInfo)
                    .zFont(size: 12, style: Design.Utility.WarningYellow._800)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Utility.WarningYellow._50.color(colorScheme))
        }
        .padding(.horizontal, 16)
    }
    
    @ViewBuilder func swapAssetsView() -> some View {
        ZStack {
            HStack(spacing: 1) {
                // Left side
                VStack(alignment: .leading, spacing: 0) {
                    if let swapAmountIn = store.swapAmountIn {
                        if !store.transaction.isSwapToZec {
                            zecTickerLogo(colorScheme)
                                .scaleEffect(0.8)
                                .padding(.bottom, 4)
                            
                            Text(tokenName.uppercased())
                                .zFont(.medium, size: 14, style: Design.Text.primary)
                            
                            Text("Zcash")
                                .zFont(.medium, size: 12, style: Design.Text.tertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        } else {
                            if let swapFromAsset = store.swapFromAsset {
                                tokenTicker(asset: swapFromAsset, colorScheme)
                                    .scaleEffect(0.8)
                                    .padding(.bottom, 4)
                                
                                Text(swapFromAsset.token)
                                    .zFont(.medium, size: 14, style: Design.Text.primary)
                                
                                Text(swapFromAsset.chainName)
                                    .zFont(.medium, size: 12, style: Design.Text.tertiary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            } else {
                                unknownTickerLogo(colorScheme)
                                    .padding(.bottom, 4)
                                unknownValue()
                                unknownValue()
                            }
                        }

                        Color.clear.frame(height: Design.Spacing._md)
                            .frame(maxWidth: .infinity)

                        Text(
                            store.isSensitiveContentHidden
                            ? L10n.General.hideBalancesMost
                            : swapAmountIn
                        )
                        .zFont(.medium, size: 12, style: Design.Text.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.1)
                        .frame(height: 14)
                    } else {
                        unknownTickerLogo(colorScheme)
                            .padding(.bottom, 4)
                        unknownValue()
                        unknownValue()
                        
                        Color.clear.frame(height: Design.Spacing._md)
                            .frame(maxWidth: .infinity)
                        
                        unknownValue()
                    }
                    
                    if let swapAmountInUsd = store.swapAmountInUsd {
                        Text(
                            store.isSensitiveContentHidden
                            ? L10n.General.hideBalancesMost
                            : swapAmountInUsd
                        )
                        .zFont(.medium, size: 10, style: Design.Text.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.1)
                        .frame(height: 14)
                    } else {
                        unknownValue()
                    }
                }
                .padding(.leading, Design.Spacing._xl)
                .padding(.trailing, Design.Spacing._xl + Design.Spacing._xl)
                .padding(.vertical, Design.Spacing._lg)
                .frame(maxWidth: .infinity)
                .frame(height: 124)
                .background {
                    CustomRoundedRectangle(corners: [.bottomLeft, .topLeft], radius: Design.Radius._3xl)
                        .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                }
                
                // Right side
                VStack(alignment: .leading, spacing: 0) {
                    if store.transaction.isSwapToZec {
                        zecTickerLogo(colorScheme, shield: store.isShielded)
                            .scaleEffect(0.8)
                            .padding(.bottom, 4)
                        
                        Text(tokenName.uppercased())
                            .zFont(.medium, size: 14, style: Design.Text.primary)
                        
                        Text("Zcash")
                            .zFont(.medium, size: 12, style: Design.Text.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        if let swapToAsset = store.swapToAsset {
                            tokenTicker(asset: swapToAsset, colorScheme)
                                .scaleEffect(0.8)
                                .padding(.bottom, 4)
                            
                            Text(swapToAsset.token)
                                .zFont(.medium, size: 14, style: Design.Text.primary)
                            
                            Text(swapToAsset.chainName)
                                .zFont(.medium, size: 12, style: Design.Text.tertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        } else {
                            unknownTickerLogo(colorScheme)
                                .padding(.bottom, 4)
                            unknownValue()
                            unknownValue()
                        }
                    }
                    
                    Color.clear.frame(height: Design.Spacing._md)
                        .frame(maxWidth: .infinity)

                    if let swapAmountOut = store.swapAmountOut {
                        Text(
                            store.isSensitiveContentHidden
                            ? L10n.General.hideBalancesMost
                            : swapAmountOut
                        )
                        .zFont(.medium, size: 12, style: Design.Text.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.1)
                        .frame(height: 14)
                    } else {
                        unknownValue()
                    }

                    if let swapAmountOutUsd = store.swapAmountOutUsd {
                        Text(
                            store.isSensitiveContentHidden
                            ? L10n.General.hideBalancesMost
                            : swapAmountOutUsd
                        )
                        .zFont(.medium, size: 10, style: Design.Text.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.1)
                        .frame(height: 14)
                    } else {
                        unknownValue()
                    }
                }
                .padding(.leading, Design.Spacing._xl + Design.Spacing._xl)
                .padding(.trailing, Design.Spacing._xl)
                .padding(.vertical, Design.Spacing._lg)
                .frame(maxWidth: .infinity)
                .frame(height: 124)
                .background {
                    CustomRoundedRectangle(corners: [.bottomRight, .topRight], radius: Design.Radius._3xl)
                        .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                }
            }
            
            FloatingArrow()
        }
        .screenHorizontalPadding()
    }
    
    @ViewBuilder func tokenTicker(asset: SwapAsset?, _ colorScheme: ColorScheme) -> some View {
        if let asset {
            asset.tokenIcon
                .resizable()
                .frame(width: 24, height: 24)
                .padding(.trailing, 8)
                .overlay {
                    ZStack {
                        Circle()
                            .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                            .frame(width: 16, height: 16)
                            .offset(x: 6, y: 6)
                        
                        asset.chainIcon
                            .resizable()
                            .frame(width: 14, height: 14)
                            .offset(x: 6, y: 6)
                    }
                }
        }
    }
    
    @ViewBuilder func zecTickerLogo(_ colorScheme: ColorScheme, shield: Bool = true) -> some View {
        Asset.Assets.Brandmarks.brandmarkMax.image
            .zImage(size: 24, style: Design.Text.primary)
            .padding(.trailing, 12)
            .overlay {
                if shield {
                    Asset.Assets.Icons.shieldBcg.image
                        .zImage(size: 15, color: Design.screenBackground.color(colorScheme))
                        .offset(x: 4, y: 8)
                        .overlay {
                            Asset.Assets.Icons.shieldTickFilled.image
                                .zImage(size: 13, color: Design.Text.primary.color(colorScheme))
                                .offset(x: 4, y: 8)
                        }
                } else {
                    Asset.Assets.Icons.shieldOffSolid.image
                        .resizable()
                        .frame(width: 15, height: 15)
                        .offset(x: 4, y: 8)
                }
            }
    }
    
    @ViewBuilder func unknownTickerLogo(_ colorScheme: ColorScheme) -> some View {
        Circle()
            .fill(Design.Surfaces.bgTertiary.color(colorScheme))
            .shimmer(true).clipShape(Circle())
            .frame(width: 24, height: 24)
            .overlay {
                Circle()
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .frame(width: 16, height: 16)
                    .offset(x: 8, y: 6)
                    .overlay {
                        Circle()
                            .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                            .shimmer(true).clipShape(Circle())
                            .frame(width: 14, height: 14)
                            .offset(x: 8, y: 6)
                    }
            }
            .scaleEffect(0.8)
    }
    
    @ViewBuilder func unknownValue() -> some View {
        RoundedRectangle(cornerRadius: Design.Radius._sm)
            .fill(Design.Surfaces.bgTertiary.color(colorScheme))
            .shimmer(true).clipShape(RoundedRectangle(cornerRadius: Design.Radius._sm))
            .frame(width: 44, height: 18)
    }
    
    @ViewBuilder func unknownAmount() -> some View {
        RoundedRectangle(cornerRadius: Design.Radius._xl)
            .fill(Design.Surfaces.bgTertiary.color(colorScheme))
            .shimmer(true).clipShape(RoundedRectangle(cornerRadius: Design.Radius._xl))
            .frame(width: 178, height: 44)
    }
    
    @ViewBuilder func unknownAsset() -> some View {
        Circle()
            .fill(Design.Surfaces.bgTertiary.color(colorScheme))
            .shimmer(true).clipShape(Circle())
            .frame(width: 48, height: 48)
    }
    
    @ViewBuilder func unknownTitle() -> some View {
        RoundedRectangle(cornerRadius: Design.Radius._sm)
            .fill(Design.Surfaces.bgTertiary.color(colorScheme))
            .shimmer(true).clipShape(RoundedRectangle(cornerRadius: Design.Radius._sm))
            .frame(width: 120, height: 28)
    }
}
