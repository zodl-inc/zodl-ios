//
//  DeeplinkWarningView.swift
//  Zashi
//
//  Created by Lukáš Korba on 06-12-2024.
//

import SwiftUI
import Combine
import ComposableArchitecture

struct DeeplinkWarningView: View {
    @PlatformBindable var store: StoreOf<DeeplinkWarning>

    init(store: StoreOf<DeeplinkWarning>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Spacer()
                
                Asset.Assets.qrcodeScannerErr.image
                    .resizable()
                    .frame(width: 164, height: 186)
                    .padding(.bottom, 24)
                    .padding(.leading, 12)

                Text(localizable: .deeplinkWarningTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .minimumScaleFactor(0.5)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                
                Text(localizable: .deeplinkWarningDesc)
                    .zFont(size: 14, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .screenHorizontalPadding()
                    .padding(.vertical, 12)

                Spacer()

                ZashiButton(String(localizable: .deeplinkWarningCta)) {
                    store.send(.rescanInZashi)
                }
                .padding(.bottom, 24)
            }
        }
        .zashiNavBarTitleDisplayMode(.inline)
        .screenHorizontalPadding()
        .applyErredScreenBackground()
        .screenTitle(String(localizable: .deeplinkWarningScreenTitle).uppercased())
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        DeeplinkWarningView(store: DeeplinkWarning.initial)
    }
}

// MARK: - Store

extension DeeplinkWarning {
    @MainActor static var initial = StoreOf<DeeplinkWarning>(
        initialState: .initial
    ) {
        DeeplinkWarning()
    }
}

// MARK: - Placeholders

extension DeeplinkWarning.State {
    static var initial: DeeplinkWarning.State { DeeplinkWarning.State() }
}
