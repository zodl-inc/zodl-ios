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
            HStack(spacing: 1) {
                VStack(alignment: .leading, spacing: 0) {
                    if reversed {
                        assetContent()
                    } else {
                        zecContent()
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
                
                VStack(alignment: .leading, spacing: 0) {
                    if reversed {
                        zecContent()
                    } else {
                        assetContent()
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
    }
    
    @ViewBuilder func zecContent() -> some View {
        zecTickerBadge(colorScheme)
            .padding(.bottom, 4)
        
        Text(tokenName.uppercased())
            .zFont(.medium, size: 14, style: Design.Text.primary)
        
        Text(zcashNameInQuote)
            .zFont(.medium, size: 12, style: Design.Text.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        
        Color.clear.frame(height: Design.Spacing._md)
            .frame(maxWidth: .infinity)
        
        Text(zecToBeSpendInQuote)
            .zFont(.medium, size: 14, style: Design.Text.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.1)
        
        Text(zecUsdToBeSpendInQuote)
            .zFont(.medium, size: 10, style: Design.Text.tertiary)
    }
    
    @ViewBuilder func assetContent() -> some View {
        tokenTickerSelector(asset: selectedAsset, colorScheme)
            .padding(.bottom, 4)
        
        if let selectedAsset {
            Text(selectedAsset.token)
                .zFont(.medium, size: 14, style: Design.Text.primary)
        }
        
        Text(assetNameInQuote)
            .zFont(.medium, size: 12, style: Design.Text.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        
        Color.clear.frame(height: Design.Spacing._md)
            .frame(maxWidth: .infinity)
        
        Text(tokenToBeReceivedInQuote)
            .zFont(.medium, size: 14, style: Design.Text.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.1)
        
        Text(tokenUsdToBeReceivedInQuote)
            .zFont(.medium, size: 10, style: Design.Text.tertiary)
    }

    @ViewBuilder func zecTickerBadge(_ colorScheme: ColorScheme, shield: Bool = true) -> some View {
        Asset.Assets.Brandmarks.brandmarkMax.image
            .zImage(size: 24, style: Design.Text.primary)
            .padding(.trailing, 6)
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
            .scaleEffect(0.8)
    }
    
    @ViewBuilder func tokenTickerSelector(asset: SwapAsset?, _ colorScheme: ColorScheme) -> some View {
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
                .scaleEffect(0.8)
        }
    }
}
