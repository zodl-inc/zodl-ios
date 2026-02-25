//
//  SwapFromToView.swift
//  modules
//
//  Created by Lukáš Korba on 14.02.2026.
//

import SwiftUI
import Generated
import Models

public struct SwapFromToView: View {
    @Environment(\.colorScheme) var colorScheme
    
    let reversed: Bool
    let tokenName: String
    let zcashNameInQuote: String
    let zecToBeSpendInQuote: String
    let zecUsdToBeSpendInQuote: String
    let selectedAsset: SwapAsset?
    let assetNameInQuote: String
    let tokenToBeReceivedInQuote: String
    let tokenUsdToBeReceivedInQuote: String
    
    public init(
        reversed: Bool = false,
        tokenName: String,
        zcashNameInQuote: String,
        zecToBeSpendInQuote: String,
        zecUsdToBeSpendInQuote: String,
        selectedAsset: SwapAsset?,
        assetNameInQuote: String,
        tokenToBeReceivedInQuote: String,
        tokenUsdToBeReceivedInQuote: String
    ) {
        self.reversed = reversed
        self.tokenName = tokenName
        self.zcashNameInQuote = zcashNameInQuote
        self.zecToBeSpendInQuote = zecToBeSpendInQuote
        self.zecUsdToBeSpendInQuote = zecUsdToBeSpendInQuote
        self.selectedAsset = selectedAsset
        self.assetNameInQuote = assetNameInQuote
        self.tokenToBeReceivedInQuote = tokenToBeReceivedInQuote
        self.tokenUsdToBeReceivedInQuote = tokenUsdToBeReceivedInQuote
    }
    
    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if reversed {
                        assetContent()
                    } else {
                        zecContent()
                    }
                }
                .padding(.horizontal, Design.Spacing._xl)
                .frame(height: 128)
                .background {
                    CustomRoundedRectangle(corners: [.bottomLeft, .topLeft], radius: Design.Radius._3xl)
                        .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                }
                
                VStack(alignment: .trailing, spacing: 0) {
                    if reversed {
                        zecContent(.trailing)
                    } else {
                        assetContent(.trailing)
                    }
                }
                .padding(.horizontal, Design.Spacing._xl)
                .frame(height: 128)
                .background {
                    CustomRoundedRectangle(corners: [.bottomRight, .topRight], radius: Design.Radius._3xl)
                        .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                }
            }
            
            FloatingArrow()
        }
    }
    
    @ViewBuilder func zecContent(_ alignment: HorizontalAlignment = .leading) -> some View {
        HStack(spacing: 0) {
            // right side
            if alignment == .trailing {
                Spacer()

                VStack(alignment: alignment, spacing: 0) {
                    Text(tokenName.uppercased())
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                    
                    Text(zcashNameInQuote)
                        .zFont(.medium, size: 10, style: Design.Text.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                
                zecTickerBadge(colorScheme)
                    .scaleEffect(1.25)
                    .padding(.leading, Design.Spacing._xl)
            } else {
                // left side
                zecTickerBadge(colorScheme)
                    .scaleEffect(1.25)
                    .padding(.trailing, Design.Spacing._xl)
                
                VStack(alignment: alignment, spacing: 0) {
                    Text(tokenName.uppercased())
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                    
                    Text(zcashNameInQuote)
                        .zFont(.medium, size: 10, style: Design.Text.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer()
            }
        }
        .frame(height: 63)
        .frame(maxWidth: .infinity)

        Design.Surfaces.bgTertiary.color(colorScheme)
            .frame(height: 1)
            .padding(alignment == .leading ? .trailing : .leading, Design.Spacing._xl)

        Color.clear.frame(height: 1)
            .frame(maxWidth: .infinity)
        
        VStack(alignment: alignment, spacing: 0) {
            Text(zecToBeSpendInQuote)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.1)

            Color.clear.frame(height: 1)
                .frame(maxWidth: .infinity)

            Text(zecUsdToBeSpendInQuote)
                .zFont(.medium, size: 10, style: Design.Text.tertiary)
        }
        .frame(height: 63)
    }
    
    @ViewBuilder func assetContent(_ alignment: HorizontalAlignment = .leading) -> some View {
        HStack(spacing: 0) {
            // right side
            if alignment == .trailing {
                Spacer()

                VStack(alignment: alignment, spacing: 0) {
                    if let selectedAsset {
                        Text(selectedAsset.token)
                            .zFont(.medium, size: 14, style: Design.Text.primary)
                    }
                    
                    Text(assetNameInQuote)
                        .zFont(.medium, size: 10, style: Design.Text.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                
                tokenTickerSelector(asset: selectedAsset, colorScheme)
                    .scaleEffect(1.25)
                    .padding(.leading, Design.Spacing._xl)
            } else {
                // left side
                tokenTickerSelector(asset: selectedAsset, colorScheme)
                    .scaleEffect(1.25)
                    .padding(.trailing, Design.Spacing._xl)
                
                VStack(alignment: alignment, spacing: 0) {
                    if let selectedAsset {
                        Text(selectedAsset.token)
                            .zFont(.medium, size: 14, style: Design.Text.primary)
                    }
                    
                    Text(assetNameInQuote)
                        .zFont(.medium, size: 10, style: Design.Text.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer()
            }
        }
        .frame(height: 63)
        .frame(maxWidth: .infinity)

        Design.Surfaces.bgTertiary.color(colorScheme)
            .frame(height: 1)
            .padding(alignment == .leading ? .trailing : .leading, Design.Spacing._xl)

        Color.clear.frame(height: 1)
            .frame(maxWidth: .infinity)
        
        VStack(alignment: alignment, spacing: 0) {
            Text(tokenToBeReceivedInQuote)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.1)
            
            Color.clear.frame(height: 1)
                .frame(maxWidth: .infinity)

            Text(tokenUsdToBeReceivedInQuote)
                .zFont(.medium, size: 10, style: Design.Text.tertiary)
        }
        .frame(height: 63)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder func zecTickerBadge(_ colorScheme: ColorScheme, shield: Bool = true) -> some View {
        Asset.Assets.Brandmarks.brandmarkMax.image
            .zImage(size: 24, style: Design.Text.primary)
            .overlay {
                if shield {
                    Asset.Assets.Icons.shieldBcg.image
                        .zImage(size: 15, color: Design.screenBackground.color(colorScheme))
                        .offset(x: 10, y: 8)
                        .overlay {
                            Asset.Assets.Icons.shieldTickFilled.image
                                .zImage(size: 13, color: Design.Text.primary.color(colorScheme))
                                .offset(x: 10, y: 8)
                        }
                } else {
                    Asset.Assets.Icons.shieldOffSolid.image
                        .resizable()
                        .frame(width: 15, height: 15)
                        .offset(x: 10, y: 8)
                }
            }
            .scaleEffect(0.8)
    }
    
    @ViewBuilder func tokenTickerSelector(asset: SwapAsset?, _ colorScheme: ColorScheme) -> some View {
        if let asset {
            asset.tokenIcon
                .resizable()
                .frame(width: 24, height: 24)
                .overlay {
                    ZStack {
                        Circle()
                            .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                            .frame(width: 16, height: 16)
                            .offset(x: 12, y: 8)
                        
                        asset.chainIcon
                            .resizable()
                            .frame(width: 14, height: 14)
                            .offset(x: 12, y: 8)
                    }
                }
                .scaleEffect(0.8)
        }
    }
}
