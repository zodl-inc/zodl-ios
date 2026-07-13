//
//  KeystoneDeviceReadyView.swift
//  Zodl
//
//  Created by Lukáš Korba on 2025-03-27.
//

import SwiftUI
import Combine
import ComposableArchitecture

struct KeystoneDeviceReadyView: View {
    @PlatformBindable var store: StoreOf<AddKeystoneHWWallet>

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
                .disabled(store.isImportInFlight)

                // [B4-4] importAccount can wait a long time on a restore-busy data.db — show the
                // wait (spinner + disabled) instead of a dead button that ignores clicks.
                if store.isImportInFlight {
                    ZashiButton(
                        String(localizable: .keystoneAddHWWalletConnectNew),
                        accessoryView:
                            ZashiSpinner(iosTint: Asset.Colors.secondary.color, macTint: .buttonAccessory)
                    ) { }
                    .padding(.bottom, 24)
                    .disabled(true)
                } else {
                    ZashiButton(
                        String(localizable: .keystoneAddHWWalletConnectNew)
                    ) {
                        store.send(.unlockTapped(nil))
                    }
                    .padding(.bottom, 24)
                }
            }
            .screenHorizontalPadding()
            .zashiBackV2(background: false) {
                store.send(.forgetThisDeviceTapped)
            }
        }
        .applyScreenBackground()
    }
}
