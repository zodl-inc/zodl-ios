//
//  CurrencyConversionSetupView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-07-10.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents

public struct TorSetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<TorSetup>
    
    public init(store: StoreOf<TorSetup>) {
        self.store = store
    }

    public var body: some View {
        WithPerceptionTracking {
            VStack {
                ScrollView {
                    if store.isSettingsView {
                        settingsLayout()
                    } else {
                        learnMoreLayout()
                    }
                }
                .padding(.vertical, 1)
                
                Spacer()
                
                if store.isSettingsView {
                    settingsFooter()
                } else {
                    learnMoreFooter()
                }
            }
            .onAppear { store.send(.onAppear) }
            .zashiBack() { store.send(.backToHomeTapped) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .applyScreenBackground()
    }
    
    private func settingsLayout() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(desc1: L10n.TorSetup.Settings.desc1, desc2: L10n.TorSetup.Settings.desc2)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

            ForEach(TorSetup.State.SettingsOptions.allCases, id: \.self) { option in
                Button {
                    store.send(.settingsOptionTapped(option))
                } label: {
                    HStack(alignment: .top, spacing: 0) {
                        optionIcon(option.icon().image)
                        optionVStack(option.title(), subtitle: option.subtitle())
                        
                        Spacer()
                        
                        if option == store.currentSettingsOption {
                            Circle()
                                .fill(Design.Checkboxes.onBg.color(colorScheme))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    Circle()
                                        .fill(Design.Checkboxes.onFg.color(colorScheme))
                                        .frame(width: 10, height: 10)
                                }
                        } else {
                            Circle()
                                .fill(Design.Checkboxes.offBg.color(colorScheme))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    Circle()
                                        .stroke(Design.Checkboxes.offStroke.color(colorScheme))
                                        .frame(width: 20, height: 20)
                                }
                        }
                    }
                    .frame(minHeight: 40)
                    .padding(20)
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._xl)
                            .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 8)
    }
    
    private func learnMoreLayout() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(desc1: L10n.TorSetup.Learn.desc, desc2: "")

            ForEach(TorSetup.State.LearnMoreOptions.allCases, id: \.self) { option in
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
 
    private func settingsFooter() -> some View {
        ZashiButton(L10n.CurrencyConversion.saveBtn) {
            store.send(.saveChangesTapped)
        }
        .disabled(store.isSaveButtonDisabled)
        .screenHorizontalPadding()
        .padding(.bottom, 24)
    }
    
    private func learnMoreFooter() -> some View {
        VStack {
            ZashiButton(
                L10n.TorSetup.Learn.btnOut,
                type: .ghost
            ) {
                store.send(.disableTapped)
            }
            
            ZashiButton(L10n.TorSetup.Learn.btnIn) {
                store.send(.enableTapped)
            }
            .padding(.bottom, 24)
        }
        .screenHorizontalPadding()
    }
}

// MARK: - UI components

extension TorSetupView {
    private func icons() -> some View {
        RoundedRectangle(cornerRadius: Design.Radius._full)
            .fill(Design.Text.primary.color(colorScheme))
            .frame(width: 64, height: 64)
            .overlay {
                Asset.Assets.Partners.torLogo.image
                    .zImage(width: 36, height: 24, style: Design.Text.opposite)
            }
            .padding(.top, 24)
    }
    
    private func title() -> some View {
        Text(
            store.isSettingsView
            ? L10n.Settings.private
            : L10n.TorSetup.title
        )
        .zFont(.semiBold, size: 24, style: Design.Text.primary)
    }
    
    private func note() -> some View {
        HStack(alignment: .top, spacing: 0) {
            Asset.Assets.infoCircle.image
                .zImage(size: 20, style: Design.Text.primary)
                .padding(.trailing, 12)

            Text(L10n.CurrencyConversion.note)
                .zFont(size: 12, style: Design.Text.tertiary)
        }
        .screenHorizontalPadding()
    }
    
    private func optionVStack(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .zFont(.semiBold, size: 14, style: Design.Text.primary)

            Text(subtitle)
                .zFont(size: 14, style: Design.Text.tertiary)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
        }
        .padding(.trailing, 16)
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
    
    private func header(desc1: String, desc2: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                icons()
                    .padding(.bottom, 24)
                    .padding(.top, 12)

                Spacer()
            }
            
            title()
                .padding(.bottom, 8)
            
            Text(desc1)
                .zFont(size: 14, style: Design.Text.tertiary)
                .padding(.bottom, store.isSettingsView ? 16 : 12)

            if store.isSettingsView {
                Text(desc2)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .padding(.bottom, 12)
            }
        }
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        TorSetupView(store: TorSetup.initial)
    }
}

// MARK: - Store

extension TorSetup {
    public static var initial = StoreOf<TorSetup>(
        initialState: .init(isSettingsView: false)
    ) {
        TorSetup()
    }
}

// MARK: - Placeholders

extension TorSetup.State {
    public static let initial = TorSetup.State()
}
