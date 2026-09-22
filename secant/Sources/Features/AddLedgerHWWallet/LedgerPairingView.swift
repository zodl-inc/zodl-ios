//
//  LedgerPairingView.swift
//  Zashi
//
//  MOB-2020 Phase 1.3: shown while the device exports the account's viewing key for the user to
//  approve. A device refusal (wrong app, app too old, user declined) leaves the transport open,
//  so "Try again" just resends `startPairing` on the same connection — see LedgerErrorText.
//

import SwiftUI
import ComposableArchitecture

struct LedgerPairingView: View {
    @Perception.Bindable var store: StoreOf<AddLedgerHWWallet>

    init(store: StoreOf<AddLedgerHWWallet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Spacer()

                Text(localizable: .ledgerPairingTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .screenHorizontalPadding()

                if let scanError = store.scanError {
                    Text(scanError)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(1.5)
                        .padding(.top, 16)
                        .screenHorizontalPadding()

                    ZashiButton(String(localizable: .disconnectHWWalletTryAgain), type: .secondary) {
                        store.send(.retryPairingTapped)
                    }
                    .padding(.top, 24)
                    .screenHorizontalPadding()
                } else {
                    Text(localizable: .ledgerPairingDesc)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(1.5)
                        .padding(.top, 16)
                        .screenHorizontalPadding()

                    if store.isPairing {
                        ProgressView()
                            .padding(.top, 24)
                    }
                }

                Spacer()
            }
        }
        .applyScreenBackground()
    }
}
