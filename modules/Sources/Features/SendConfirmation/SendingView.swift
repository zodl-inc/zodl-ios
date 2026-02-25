//
//  SendingView.swift
//  Zashi
//
//  Created by Lukáš Korba on 10-28-2024.
//

import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit

import Generated
import UIComponents
import Utils
import Lottie

public struct SendingView: View {
    @Environment(\.colorScheme) var colorScheme
    
    private enum Constants {
        static let lottieNameLight = "sending"
        static let lottieNameDark = "sending-dark"
    }
    
    @Perception.Bindable var store: StoreOf<SendConfirmation>
    let tokenName: String
    
    public init(store: StoreOf<SendConfirmation>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    public var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                LottieView(
                    animation:
                            .named(
                                colorScheme == .light ? Constants.lottieNameLight : Constants.lottieNameDark
                            )
                )
                .resizable()
                .looping()
                .frame(width: 170, height: 170)

                Text(store.isShielding ? L10n.Send.shielding : L10n.Send.sending)
                    .zFont(.semiBold, size: 28, style: Design.Text.primary)
                    .padding(.top, 16)

                Text(store.sendingInfo)
                    .zFont(size: 14, style: Design.Text.primary)
                    .lineLimit(store.type != .regular ? 3 : 1)
                    .minimumScaleFactor(store.type != .regular ? 1.0 : 0.5)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, store.type != .regular ? 30 : 0)

                if !store.isShielding && store.type == .regular {
                    Text(store.address.zip316)
                        .zFont(fontFamily: .robotoMono, size: 14, style: Design.Text.primary)
                        .padding(.top, 4)
                }
            }
            .onAppear { store.send(.sendingScreenOnAppear) }
        }
        .navigationBarBackButtonHidden()
        .screenHorizontalPadding()
        .applyScreenBackground()
    }
}

#Preview {
    NavigationView {
        SendingView(
            store: SendConfirmation.initial,
            tokenName: "ZEC"
        )
    }
}
