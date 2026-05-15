//
//  FailedView.swift
//  Zashi
//
//  Created by Lukáš Korba on 22.01.2026.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct FailureView: View {
    @Perception.Bindable var store: StoreOf<SendConfirmation>
    let tokenName: String
    
    init(store: StoreOf<SendConfirmation>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Spacer()

                store.failureIlustration
                    .resizable()
                    .frame(width: 148, height: 148)

                Text(store.isShielding ? String(localizable: .sendFailureShielding) : String(localizable: .sendFailure))
                    .zFont(.semiBold, size: 28, style: Design.Text.primary)
                    .padding(.top, 16)

                Text(store.failureInfo)
                    .zFont(size: 14, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.5)
                    .screenHorizontalPadding()

                if store.txIdToExpand != nil || store.type != .regular {
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
                    type: store.type != .regular
                    ? .ghost
                    : .primary
                ) {
                    store.send(.closeTapped)
                }
                .padding(.bottom, 8)

                ZashiButton(
                    String(localizable: .sendReport),
                    type: store.type != .regular
                    ? .primary
                    : .ghost
                ) {
                    store.send(.reportTapped)
                }
                .padding(.bottom, 24)
                
                if let supportData = store.supportData {
                    UIMailDialogView(
                        supportData: supportData,
                        completion: {
                            store.send(.sendSupportMailFinished)
                        }
                    )
                    // UIMailDialogView only wraps MFMailComposeViewController presentation
                    // so frame is set to 0 to not break SwiftUI's layout
                    .frame(width: 0, height: 0)
                }
                
                shareMessageView()
            }
        }
        .navigationBarBackButtonHidden()
        .padding(.vertical, 1)
        .screenHorizontalPadding()
        .applyFailureScreenBackground()
    }
}

extension FailureView {
    @ViewBuilder func shareMessageView() -> some View {
        if let message = store.messageToBeShared {
            UIShareDialogView(activityItems: [message]) {
                store.send(.shareFinished)
            }
            // UIShareDialogView only wraps UIActivityViewController presentation
            // so frame is set to 0 to not break SwiftUI's layout
            .frame(width: 0, height: 0)
        } else {
            EmptyView()
        }
    }
}

#Preview {
    NavigationView {
        FailureView(
            store: SendConfirmation.initial,
            tokenName: "ZEC"
        )
    }
}
