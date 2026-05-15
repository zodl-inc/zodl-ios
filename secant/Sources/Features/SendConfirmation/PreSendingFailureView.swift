//
//  PreSendingFailureView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-02-04.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct PreSendingFailureView: View {
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

                Text(store.isShielding ? String(localizable: .sendFailureShieldingInfo) : String(localizable: .sendFailureInfo))
                    .zFont(size: 14, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.5)
                    .screenHorizontalPadding()

                Spacer()
                
                ZashiButton(String(localizable: .generalClose)) {
                    store.send(.backFromPCZTFailureTapped)
                }
                .padding(.bottom, 8)

                ZashiButton(
                    String(localizable: .sendReport),
                    type: .ghost
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

extension PreSendingFailureView {
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
        PreSendingFailureView(
            store: SendConfirmation.initial,
            tokenName: "ZEC"
        )
    }
}
