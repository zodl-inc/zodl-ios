//
//  RecoveryPhraseSecurityView.swift
//  Zashi
//
//  Created by Lukáš Korba on 04-18-2025.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import MnemonicSwift

struct RecoveryPhraseSecurityView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    enum Constants {
        static let blurValue = 15.0
        static let blurBDValue = 10.0
    }
    
    @Perception.Bindable var store: StoreOf<RecoveryPhraseDisplay>
    
    init(store: StoreOf<RecoveryPhraseDisplay>) {
        self.store = store
    }
    
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    learnMoreLayout()
                }
                .padding(.vertical, 1)

                Spacer()
                
                HStack(spacing: 0) {
                    Asset.Assets.infoOutline.image
                        .zImage(size: 20, style: Design.Utility.WarningYellow._500)
                        .padding(.trailing, 12)

                    Text(localizable: .recoveryPhraseDisplayProceedWarning)
                }
                .zFont(size: 12, style: Design.Utility.WarningYellow._700)
                .padding(.bottom, 20)
                .screenHorizontalPadding()

                ZashiButton(String(localizable: .generalNext)) {
                    store.send(.securityWarningNextTapped)
                }
                .padding(.bottom, 24)
                .screenHorizontalPadding()
            }
            .applyScreenBackground()
        }
    }
    
    private func learnMoreLayout() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .recoveryPhraseDisplayWarningTitle)
                .zFont(.semiBold, size: 18, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 8)
            
            Text(localizable: .recoveryPhraseDisplayWarningInfo)
                .zFont(size: 14, style: Design.Text.tertiary)
                .padding(.bottom, 4)

            ForEach(RecoveryPhraseDisplay.State.LearnMoreOptions.allCases, id: \.self) { option in
                HStack(alignment: .top, spacing: 0) {
                    optionIcon(option.icon().image)
                    optionVStack(option.title(), subtitle: option.subtitle())
                }
                .padding(.top, 20)
            }
            .padding(.bottom, 12)
        }
        .screenHorizontalPadding()
    }
    
    private func optionIcon(_ icon: Image) -> some View {
        icon
            .zImage(size: 20, style: Design.Text.primary)
            .padding(10)
            .background {
                Circle()
                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))
            }
            .padding(.trailing, 16)
    }
    
    private func optionVStack(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .zFont(.semiBold, size: 14, style: Design.Text.primary)

            Text(subtitle)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(.trailing, 16)
    }
}
