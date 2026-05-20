//
//  AboutView.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-13-2023.
//

import SwiftUI
import ComposableArchitecture

struct AboutView: View {
    @Perception.Bindable var store: StoreOf<About>
    
    init(store: StoreOf<About>) {
        self.store = store
    }
    
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(localizable: .aboutTitle)
                        .zFont(.semiBold, size: 24, style: Design.Text.primary)
                        .padding(.top, 40)
                    
                    Text(localizable: .aboutInfo)
                        .zFont(size: 14, style: Design.Text.primary)
                        .padding(.top, 12)
                    
                    Text(localizable: .aboutAdditionalInfo)
                        .zFont(size: 14, style: Design.Text.primary)
                        .padding(.top, 8)
                }

                ActionRow(
                    icon: Asset.Assets.infoCircle.image,
                    title: String(localizable: .aboutPrivacyPolicy),
                    divider: true,
                    horizontalPadding: 4
                ) {
                    store.send(.privacyPolicyButtonTapped)
                }
                .padding(.top, 32)

                ActionRow(
                    icon: Asset.Assets.Icons.terms.image,
                    title: String(localizable: .aboutTermsOfUse),
                    divider: false,
                    horizontalPadding: 4
                ) {
                    store.send(.termsOfUseButtonTapped)
                }

                Spacer()

                Asset.Assets.zashiLogo.image
                    .zImage(width: 41, height: 41, color: Asset.Colors.primary.color)
                    .padding(.bottom, 7)

                Asset.Assets.zashiTitle.image
                    .zImage(width: 73, height: 20, color: Asset.Colors.primary.color)
                    .padding(.bottom, 16)
                
                Text(localizable: .settingsVersion(store.appVersion, store.appBuild))
                    .zFont(size: 16, style: Design.Text.tertiary)
                    .padding(.bottom, 24)
            }
            .onAppear { store.send(.onAppear) }
            .sheet(isPresented: $store.isInAppBrowserPolicyOn) {
                if let url = URL(string: "https://zodl.com/privacy-policy/#policy") {
                    InAppBrowserView(url: url)
                }
            }
            .sheet(isPresented: $store.isInAppBrowserTermsOn) {
                if let url = URL(string: "https://zodl.com/privacy-policy/") {
                    InAppBrowserView(url: url)
                }
            }
            .zashiBack()
            .screenTitle(String(localizable: .settingsAbout))
        }
        .screenHorizontalPadding()
        .applyScreenBackground()
    }
}

// MARK: Placeholders

extension About.State {
    static let initial = About.State()
}

extension About {
    @MainActor static let initial = StoreOf<About>(
        initialState: .initial
    ) {
        About()
    }
}

#Preview {
    NavigationView {
        AboutView(store: About.initial)
    }
}
