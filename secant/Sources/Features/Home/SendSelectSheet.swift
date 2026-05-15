//
//  SendSelectSheet.swift
//  modules
//
//  Created by Lukáš Korba on 12.05.2025.
//

import SwiftUI
import ComposableArchitecture

extension HomeView {
//    @ViewBuilder func sendSelectContent() -> some View {
//        VStack(spacing: 8) {
//            optionView(
//                icon: Asset.Assets.Brandmarks.brandmarkMax.image,
//                title: String(localizable: .sendSelectZashiSend),
//                subtitle: String(localizable: .sendSelectZashiSendDesc)
//            ) {
//                store.send(.sendTapped)
//            }
//            .padding(.top, 32)
//            
//            optionView(
//                icon: Asset.Assets.Partners.swapAndPay.image,
//                iconOriginalColors: true,
//                title: String(localizable: .sendSelectSwapWithNear),
//                subtitle: String(localizable: .sendSelectSwapWithNearDesc)
//            ) {
//                store.send(.swapWithNearTapped)
//            }
//        }
//        .padding(.bottom, 56)
//    }
    
    @ViewBuilder func optionView(
        icon: Image,
        iconOriginalColors: Bool = false,
        title: String,
        subtitle: String,
        action: (() -> Void)? = nil
    ) -> some View {
        WithPerceptionTracking {
            Button {
                action?()
            } label: {
                HStack(spacing: 0) {
                    if iconOriginalColors {
                        icon
                            .resizable()
                            .frame(width: 40, height: 40)
                            .padding(.trailing, 12)
                    } else {
                        icon
                            .zImage(size: 40, style: Design.Surfaces.brandPrimary)
                            .padding(.trailing, 12)
                    }
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .zFont(.semiBold, size: 16, style: Design.Text.primary)
                        
                        Text(subtitle)
                            .zFont(size: 12, style: Design.Text.tertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    Spacer()
                    
                    Asset.Assets.chevronRight.image
                        .zImage(size: 20, style: Design.Text.tertiary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }
}
