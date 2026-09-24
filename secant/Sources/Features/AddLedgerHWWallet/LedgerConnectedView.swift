//
//  LedgerConnectedView.swift
//  Zashi
//
//  MOB-2020 Phase 1.3. Mirrors KeystoneConnectedView with the Ledger-specific description.
//

import SwiftUI
import ComposableArchitecture

struct LedgerConnectedView: View {
    @Perception.Bindable var store: StoreOf<AddLedgerHWWallet>

    init(store: StoreOf<AddLedgerHWWallet>) {
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

                Text(localizable: .ledgerAddHWWalletConnectedDesc)
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
