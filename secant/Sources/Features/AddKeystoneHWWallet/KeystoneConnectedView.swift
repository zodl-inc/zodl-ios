//
//  KeystoneConnectedView.swift
//  Zodl
//
//  Created by Lukáš Korba on 2025-03-27.
//

import SwiftUI
import ComposableArchitecture

struct KeystoneConnectedView: View {
    @Perception.Bindable var store: StoreOf<AddKeystoneHWWallet>

    init(store: StoreOf<AddKeystoneHWWallet>) {
        self.store = store
    }
    
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Spacer()
                
                store.successIlustration
                    .resizable()
                    .frame(width: 148, height: 148)
                
                Text(localizable: .keystoneAddHWWalletConnected)
                    .zFont(.semiBold, size: 28, style: Design.Text.primary)
                    .padding(.top, 16)

                Text(localizable: .keystoneAddHWWalletConnectedDesc)
                    .zFont(size: 14, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.5)
                    .padding(.top, 8)
                    .screenHorizontalPadding()

                Spacer()

                ZashiButton(String(localizable: .keystoneAddHWWalletClose)) {
                    store.send(.closeTapped)
                }
                .padding(.bottom, 24)
            }
        }
        .navigationBarBackButtonHidden()
        .padding(.vertical, 1)
        .screenHorizontalPadding()
        .applySuccessScreenBackground()
    }
}
