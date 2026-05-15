//
//  KeystoneDeviceReadyView.swift
//  Zodl
//
//  Created by Lukáš Korba on 2025-03-27.
//

import SwiftUI
import ComposableArchitecture

struct KeystoneDeviceReadyView: View {
    @Perception.Bindable var store: StoreOf<AddKeystoneHWWallet>

    init(store: StoreOf<AddKeystoneHWWallet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Asset.Assets.Partners.keystoneTitleLogo.image
                    .resizable()
                    .frame(width: 193, height: 32)
                    .padding(.top, 16)

                Text(localizable: .keystoneAddHWWalletDeviceQuestion)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 24)

                Text(localizable: .keystoneAddHWWalletDeviceDesc)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .lineSpacing(1.5)
                    .padding(.top, 8)

                Spacer()

                ZashiButton(
                    String(localizable: .keystoneAddHWWalletConnectActive),
                    type: .ghost
                ) {
                    store.send(.setBirthdayTapped)
                }
                .padding(.bottom, 12)

                ZashiButton(
                    String(localizable: .keystoneAddHWWalletConnectNew)
                ) {
                    store.send(.unlockTapped(nil))
                }
                .padding(.bottom, 24)
            }
            .screenHorizontalPadding()
            .zashiBackV2(background: false) {
                store.send(.forgetThisDeviceTapped)
            }
        }
        .applyScreenBackground()
    }
}
