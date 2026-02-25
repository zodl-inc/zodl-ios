//
//  GlobalNavBar.swift
//  Zashi
//
//  Created by Lukáš Korba on 26.11.2024.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents
import Settings

extension HomeView {
    func settingsButton() -> some View {
        Button {
            if store.selectedWalletAccount?.vendor == .keystone {
                store.send(.settingsTapped)
            } else {
                store.send(.moreTapped)
            }
        } label: {
            Asset.Assets.Icons.dotsMenu.image
                .zImage(size: 24, style: Design.Text.primary)
                .padding(8)
                .tint(Asset.Colors.primary.color)
                .onTapGesture(count: 2) {
                    store.send(.settingsTapped)
                }
        }
    }
    
    @ViewBuilder func hideBalancesButton() -> some View {
        Button {
            $isSensitiveContentHidden.withLock { $0.toggle() }
        } label: {
            let image = isSensitiveContentHidden ? Asset.Assets.eyeOff.image : Asset.Assets.eyeOn.image
            image
                .zImage(size: 24, color: Asset.Colors.primary.color)
                .padding(8)
        }
    }
    
    @ViewBuilder func walletAccountSwitcher() -> some View {
        if !store.walletAccounts.isEmpty {
            Button {
                store.send(.accountSwitchTapped)
            } label: {
                HStack(spacing: 0) {
                    if let selectedWalletAccount = store.selectedWalletAccount {
                        selectedWalletAccount.vendor.icon()
                            .resizable()
                            .frame(width: 19, height: 19)
                            .offset(y: -1)
                            .background {
                                Circle()
                                    .fill(Design.Surfaces.bgAlt.color(colorScheme))
                                    .frame(width: 30, height: 30)
                            }
                        
                        Text(selectedWalletAccount.vendor.name())
                            .zFont(.semiBold, size: 19, style: Design.Text.primary)
                            .padding(.leading, 14)
                            .padding(.bottom, 2)
                    }

                    Asset.Assets.chevronDown.image
                        .zImage(size: 24, style: Design.Text.primary)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                }
                .padding(.leading, {
                    if #available(iOS 26, *) {
                        return 2
                    } else {
                        return 12
                    }
                }()
                )
                .padding(.trailing, {
                    if #available(iOS 26, *) {
                        return 0
                    } else {
                        return 4
                    }
                }()
                )
            }
        }
    }
}
