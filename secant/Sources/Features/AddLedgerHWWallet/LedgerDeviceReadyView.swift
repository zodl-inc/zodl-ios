//
//  LedgerDeviceReadyView.swift
//  Zashi
//
//  MOB-2020 Phase 1.3. Mirrors KeystoneDeviceReadyView with the Ledger logo.
//

import SwiftUI
import ComposableArchitecture

struct LedgerDeviceReadyView: View {
    @Perception.Bindable var store: StoreOf<AddLedgerHWWallet>

    init(store: StoreOf<AddLedgerHWWallet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Asset.Assets.Partners.ledgerTitleLogo.image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 32)
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
                .disabled(store.isImportingAccount)
                .padding(.bottom, 12)

                if store.isImportingAccount {
                    ZashiButton(
                        String(localizable: .keystoneAddHWWalletConnectNew),
                        accessoryView: ProgressView()
                    ) {
                        store.send(.unlockTapped(nil))
                    }
                    .disabled(true)
                    .padding(.bottom, 24)
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
