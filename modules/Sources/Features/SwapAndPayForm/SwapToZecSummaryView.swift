//
//  SwapToZecSummaryView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-09-12.
//

import SwiftUI
import ComposableArchitecture
import Generated
import SwapAndPay

import UIComponents
import Utils

public struct SwapToZecSummaryView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false

    @Perception.Bindable var store: StoreOf<SwapAndPay>
    let tokenName: String
    
    public init(store: StoreOf<SwapAndPay>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    public var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Button {
                    store.send(.copySwapToZecAmountTapped)
                } label: {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Text(L10n.SwapToZec.deposit)
                                .zFont(.medium, size: 16, style: Design.Text.primary)
                            
                            Asset.Assets.copy.image
                                .zImage(size: 20, style: Design.Btns.Ghost.fg)
                        }
                        .padding(.top, 24)
                        
                        HStack(spacing: 8) {
                            tokenTicker(asset: store.selectedAsset, colorScheme)
                            
                            Text(store.swapToZecAmountInQuotePreciseCopy)
                                .zFont(.semiBold, size: 48, style: Design.Text.primary)
                                .minimumScaleFactor(0.1)
                                .lineLimit(1)
                        }
                        
                        Text(store.zecUsdToBeSpendInQuote)
                            .zFont(.medium, size: 18, style: Design.Text.tertiary)
                            .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity)
                }

                Button {
                    store.send(.qrCodeTapped)
                } label: {
                    qrCode(store.quote?.depositAddress ?? "")
                        .frame(width: 216, height: 216)
                        .onAppear {
                            store.send(.generateQRCode(colorScheme == .dark ? true : false))
                        }
                        .padding(24)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                .fill(store.isQRCodeAppreanceFlipped
                                      ? Asset.Colors.ZDesign.Base.bone.color
                                      : Design.screenBackground.color(colorScheme)
                                )
                        }
                }
                
                if let depositAddress = store.quote?.depositAddress {
                    Text(depositAddress.truncateMiddle10)
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._full)
                                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                        }
                        .padding(.bottom, 12)
                }
                
                HStack(spacing: 8) {
                    button(
                        L10n.Receive.copy,
                        icon: Asset.Assets.copy.image
                    ) {
                        store.send(.copyDepositAddressToPastboard)
                    }
                    
                    button(
                        L10n.SwapToZec.shareQR,
                        icon: Asset.Assets.Icons.qr.image
                    ) {
                        store.send(.shareQR)
                    }
                }
                .zFont(.medium, size: 12, style: Design.Text.primary)
                .padding(.bottom, 32)
                
                Group {
                    Text(L10n.SwapToZec.info1)
                    + Text(L10n.SwapToZec.info2(store.selectedAsset?.token ?? "", store.selectedAsset?.chainName ?? "")).bold()
                    + Text(L10n.SwapToZec.info3)
                }
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 12)
                
                Spacer()
                
                ZashiButton(L10n.SwapToZec.sentTheFunds) {
                    store.send(.sentTheFundsButtonTapped)
                }
                .padding(.bottom, 32)
                
                shareView()
            }
            .screenHorizontalPadding()
            .navigationBarItems(
                trailing:
                    Button {
                        store.send(.helpSheetRequested(3))
                    } label: {
                        Asset.Assets.infoCircle.image
                            .zImage(size: 24, style: Design.Text.primary)
                            .padding(Design.Spacing.navBarButtonPadding)
                    }
            )
            .zashiBack()
            .screenTitle(L10n.SwapAndPay.swap.uppercased())
            .applyScreenBackground()
        }
    }
    
    @ViewBuilder func tokenTicker(asset: SwapAsset?, _ colorScheme: ColorScheme) -> some View {
        if let asset {
            asset.tokenIcon
                .resizable()
                .frame(width: 40, height: 40)
                .padding(.trailing, 8)
                .overlay {
                    ZStack {
                        Circle()
                            .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                            .frame(width: 20, height: 20)
                            .offset(x: 12, y: 12)
                        
                        asset.chainIcon
                            .resizable()
                            .frame(width: 18, height: 18)
                            .offset(x: 12, y: 12)
                    }
                }
        }
    }
    
    @ViewBuilder public func qrCode(_ qrText: String = "") -> some View {
        Group {
            if let storedImg = store.storedQR {
                Image(storedImg, scale: 1, label: Text(L10n.qrCodeFor(qrText)))
                    .resizable()
            } else {
                ProgressView()
            }
        }
    }
    
    @ViewBuilder func shareView() -> some View {
        if let addressToShare = store.addressToShare,
           let cgImg = QRCodeGenerator.generateCode(
            from: addressToShare.data,
            vendor: .zashi,
            color: .black,
            overlayedWithZcashLogo: false
           ) {
            UIShareDialogView(activityItems: [
                ShareableImage(
                    image: UIImage(cgImage: cgImg),
                    title: L10n.SwapToZec.Share.title,
                    reason: L10n.SwapToZec.Share.msg(store.swapToZecAmountInQuotePreciseCopy, store.shareAssetName)
                ), L10n.SwapToZec.Share.msg(store.swapToZecAmountInQuotePreciseCopy, store.shareAssetName)
            ]) {
                store.send(.shareFinished)
            }
            // UIShareDialogView only wraps UIActivityViewController presentation
            // so frame is set to 0 to not break SwiftUI's layout
            .frame(width: 0, height: 0)
        } else {
            EmptyView()
        }
    }
    
    @ViewBuilder private func button(
        _ title: String,
        icon: Image,
        action: @escaping () -> Void
    ) -> some View {
        if colorScheme == .light {
            Button {
                action()
            } label: {
                VStack(spacing: 4) {
                    icon
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 24, height: 24)
                    
                    Text(title)
                }
                .frame(height: 80)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._3xl)
                        .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                                .stroke(Design.Utility.Gray._100.color(colorScheme))
                        }
                }
                .shadow(color: .black.opacity(0.02), radius: 0.66667, x: 0, y: 1.33333)
                .shadow(color: .black.opacity(0.08), radius: 1.33333, x: 0, y: 1.33333)
                .padding(.bottom, 4)
            }
        } else {
            Button {
                action()
            } label: {
                VStack(spacing: 4) {
                    icon
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 24, height: 24)
                    
                    Text(title)
                }
                .frame(height: 80)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._3xl)
                        .fill(
                            LinearGradient(
                                stops: [
                                    Gradient.Stop(color: Asset.Colors.ZDesign.sharkShades12dp.color, location: 0.00),
                                    Gradient.Stop(color: Asset.Colors.ZDesign.sharkShades01dp.color, location: 1.00)
                                ],
                                startPoint: UnitPoint(x: 0.5, y: 0.0),
                                endPoint: UnitPoint(x: 0.5, y: 1.0)
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                                .stroke(
                                    LinearGradient(
                                        stops: [
                                            Gradient.Stop(color: Design.Utility.Gray._200.color(colorScheme), location: 0.00),
                                            Gradient.Stop(color: Design.Utility.Gray._200.color(colorScheme).opacity(0.15), location: 1.00)
                                        ],
                                        startPoint: UnitPoint(x: 0.5, y: 0.0),
                                        endPoint: UnitPoint(x: 0.5, y: 1.0)
                                    )
                                )
                        }
                }
                .shadow(color: .black.opacity(0.02), radius: 0.66667, x: 0, y: 1.33333)
                .shadow(color: .black.opacity(0.08), radius: 1.33333, x: 0, y: 1.33333)
                .padding(.bottom, 4)
            }
        }
    }
}
