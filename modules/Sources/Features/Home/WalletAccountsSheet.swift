//
//  WalletAccountsSheet.swift
//  modules
//
//  Created by Lukáš Korba on 26.11.2024.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents

extension HomeView {
    @ViewBuilder func accountSwitchContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.Keystone.Drawer.title)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .padding(.horizontal, 20)
            
            ForEach(store.walletAccounts, id: \.self) { walletAccount in
                walletAccountView(
                    icon: walletAccount.vendor.icon(),
                    title: walletAccount.vendor.name(),
                    address: walletAccount.unifiedAddress ?? L10n.Receive.Error.cantExtractUnifiedAddress,
                    selected: store.selectedWalletAccount == walletAccount
                ) {
                    store.send(.walletAccountTapped(walletAccount))
                }
            }
            
            if store.walletAccounts.count == 1 {
                addKeystoneBannerView()
                    .padding(.top, 8)
                    .onTapGesture {
                        store.send(.keystoneBannerTapped)
                    }

                ZashiButton(
                    L10n.Keystone.connect,
                    type: .secondary
                ) {
                    store.send(.addKeystoneHWWalletTapped)
                }
                .padding(.top, 32)
                .padding(.horizontal, 20)
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            } else {
                Color.clear
                    .frame(height: 1)
                    .padding(.bottom, 23)
            }
        }
        .padding(.horizontal, 4)
    }
    
    @ViewBuilder func walletAccountView(
        icon: Image,
        title: String,
        address: String,
        selected: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        WithPerceptionTracking {
            Button {
                action?()
            } label: {
                HStack(spacing: 0) {
                    icon
                        .resizable()
                        .frame(width: 24, height: 24)
                        .padding(8)
                        .background {
                            Circle()
                                .fill(Design.Surfaces.bgAlt.color(colorScheme))
                        }
                        .padding(.trailing, 12)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .zFont(.semiBold, size: 16, style: Design.Text.primary)
                        
                        Text(address.zip316)
                            .zFont(addressFont: true, size: 12, style: Design.Text.tertiary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Design.Radius._2xl)
                            .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    }
                }
            }
        }
    }
    
    @ViewBuilder func addKeystoneBannerViewOldDesign() -> some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    Asset.Assets.Partners.keystoneLogo.image
                        .resizable()
                        .frame(width: 32, height: 32)
                        .padding(4)
                        .background {
                            Circle()
                                .fill(Design.Surfaces.bgAlt.color(colorScheme))
                        }
                        .padding(.trailing, 12)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L10n.Keystone.Drawer.Banner.title)
                            .zFont(.semiBold, size: 14, style: Design.Text.primary)
                        
                        Text(L10n.Keystone.Drawer.Banner.desc)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                            .padding(.top, 2)
                    }
                    .padding(.trailing, 12)
                }

                Spacer()
                
                Asset.Assets.chevronRight.image
                    .zImage(size: 24, style: Design.Text.primary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._4xl)
                    .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
            }
        }
    }
    
    @ViewBuilder func addKeystoneBannerView() -> some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.Keystone.Drawer.Banner.title)
                        .zFont(.semiBold, size: 18, style: Design.Text.primary)
                    
                    Text(L10n.Keystone.Drawer.Banner.desc)
                        .zFont(size: 12, style: Design.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                        .padding(.top, 2)
                        .padding(.trailing, 80)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)

                Asset.Assets.Partners.keystonePromo.image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 346, height: 148)
                    .clipped()
            }
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._4xl)
                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))
            }
        }
    }
}
