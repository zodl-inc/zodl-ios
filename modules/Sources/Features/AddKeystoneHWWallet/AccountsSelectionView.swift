//
//  AccountsSelectionView.swift
//  modules
//
//  Created by Lukáš Korba on 2024-11-27.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents

public struct AccountsSelectionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<AddKeystoneHWWallet>
    
    public init(store: StoreOf<AddKeystoneHWWallet>) {
        self.store = store
    }
    
    public var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Asset.Assets.Partners.keystoneTitleLogo.image
                    .resizable()
                    .frame(width: 193, height: 32)
                    .padding(.top, 16)
                
                Text(L10n.Keystone.AddHWWallet.title)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 24)
                
                Text(L10n.Keystone.AddHWWallet.desc)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .lineSpacing(1.5)
                    .padding(.top, 8)
                
                accountView()
                    .padding(.top, 48)
                
                Spacer()

                ZashiButton(
                    L10n.Keystone.AddHWWallet.connect
                ) {
                    store.send(.unlockTapped)
                }
                .padding(.bottom, 24)
                .disabled(!store.isKSAccountSelected)
            }
            .screenHorizontalPadding()
            .zashiBackV2(background: false) {
                store.send(.forgetThisDeviceTapped)
            }
        }
        .applyScreenBackground()
    }
    
    @ViewBuilder func accountView() -> some View {
        WithPerceptionTracking {
            Button {
                store.send(.accountTapped)
            } label: {
                HStack(spacing: 0) {
                    Asset.Assets.Partners.keystoneLogo.image
                        .resizable()
                        .frame(width: 24, height: 24)
                        .padding(8)
                        .background {
                            Circle()
                                .fill(Design.Surfaces.bgAlt.color(colorScheme))
                        }
                        .padding(.trailing, 8)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L10n.Keystone.wallet)
                            .zFont(.semiBold, size: 14, style: Design.Text.primary)
                        
                        Text(store.keystoneAddress.zip316)
                            .zFont(fontFamily: .robotoMono, size: 12, style: Design.Text.tertiary)
                    }
                    
                    Spacer()
                    
                    ZashiToggle(
                        isOn: $store.isKSAccountSelected
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._3xl)
                        .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                }
            }
        }
    }
}
