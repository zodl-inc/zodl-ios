//
//  SuccessView.swift
//  Zashi
//
//  Created by Lukáš Korba on 10-28-2024.
//

import SwiftUI
import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct SuccessView: View {
    @PlatformBindable var store: StoreOf<SendConfirmation>
    let tokenName: String
    
    init(store: StoreOf<SendConfirmation>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Spacer()

                store.successIlustration
                    .resizable()
                    .frame(width: 148, height: 148)

                Text(store.isShielding ? String(localizable: .sendSuccessShielding) : String(localizable: .sendSuccess))
                    .zFont(.semiBold, size: 28, style: Design.Text.primary)
                    .padding(.top, 16)

                Text(store.successInfo)
                    .zFont(size: 14, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.5)
                    .padding(.top, 8)
                    .screenHorizontalPadding()

                if !store.isShielding && store.type == .regular {
                    Text(store.address.zip316)
                        .zFont(fontFamily: .robotoMono, size: 14, style: Design.Text.primary)
                        .padding(.top, 4)
                }

                // B4-7: "View transaction" and "Check status" are mutually exclusive — every
                // non-regular (Near Intents swap/pay) flow shows Check status below, so View
                // transaction is regular-only (previously both rendered for swaps with a txid).
                if store.type == .regular {
                    ZashiButton(
                        String(localizable: .sendViewTransaction),
                        type: .tertiary,
                        infinityWidth: false
                    ) {
                        store.send(.viewTransactionTapped)
                    }
                    .padding(.top, 16)
                }

                Spacer()
                
                ZashiButton(
                    String(localizable: .generalClose),
                    type: store.type != .regular ? .ghost : .primary
                ) {
                    store.send(.closeTapped)
                }
                .padding(.bottom, store.type != .regular ? 12 : 24)

                if store.type != .regular {
                    ZashiButton(String(localizable: .swapAndPayCheckStatus)) {
                        store.send(.checkStatusTapped)
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationBarBackButtonHidden()
        .padding(.vertical, 1)
        .screenHorizontalPadding()
        .applySuccessScreenBackground()
    }
}

#Preview {
    NavigationView {
        SuccessView(
            store: SendConfirmation.initial,
            tokenName: "ZEC"
        )
    }
}
