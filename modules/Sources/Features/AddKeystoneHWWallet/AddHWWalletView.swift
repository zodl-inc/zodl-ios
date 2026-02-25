//
//  AddKeystoneHWWalletView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-11-26.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents

public struct AddKeystoneHWWalletView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<AddKeystoneHWWallet>
    
    public init(store: StoreOf<AddKeystoneHWWallet>) {
        self.store = store
    }
    
    public var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Asset.Assets.Partners.keystoneTitleLogo.image
                            .resizable()
                            .frame(width: 193, height: 32)
                            .padding(.top, 16)

                        Text(L10n.Keystone.connect)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.top, 24)
                        
                        Text(L10n.Keystone.AddHWWallet.scan)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .lineSpacing(1.5)
                            .padding(.top, 8)

                        #if DEBUG
                        Button {
                            store.send(.viewTutorialTapped)
                        } label: {
                            Text(L10n.Keystone.AddHWWallet.tutorial)
                                .font(.custom(FontFamily.Inter.semiBold.name, size: 14))
                                .foregroundColor(Design.Utility.HyperBlue._700.color(colorScheme))
                                .underline()
                                .padding(.top, 4)
                        }
                        #endif

                        Text(L10n.Keystone.AddHWWallet.howTo)
                            .zFont(.semiBold, size: 18, style: Design.Text.primary)
                            .padding(.top, 24)
                        
                        InfoRow(
                            icon: Asset.Assets.Icons.lockUnlocked.image,
                            title: L10n.Keystone.AddHWWallet.step1
                        )
                        .padding(.top, 16)
                        
                        InfoRow(
                            icon: Asset.Assets.Icons.dotsMenu.image,
                            title: L10n.Keystone.AddHWWallet.step2
                        )
                        .padding(.top, 16)

                        InfoRow(
                            icon: Asset.Assets.Icons.connectWallet.image,
                            title: L10n.Keystone.AddHWWallet.step3
                        )
                        .padding(.top, 16)

                        InfoRow(
                            icon: Asset.Assets.Icons.zashiLogoSqBold.image,
                            title: L10n.Keystone.AddHWWallet.step4
                        )
                        .padding(.top, 16)
                    }
                }
                .padding(.vertical, 1)
                
                Spacer()
                
                ZashiButton(
                    L10n.Keystone.AddHWWallet.readyToScan
                ) {
                    store.send(.readyToScanTapped)
                }
                .padding(.vertical, 24)
            }
            .screenHorizontalPadding()
            .onAppear { store.send(.onAppear) }
            .zashiBack() {
                store.send(.backToHomeTapped)
            }
            .sheet(isPresented: $store.isInAppBrowserOn) {
                if let url = URL(string: store.inAppBrowserURL) {
                    InAppBrowserView(url: url)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .applyScreenBackground()
    }
}

// MARK: Placeholders

extension AddKeystoneHWWallet.State {
    public static let initial = AddKeystoneHWWallet.State()
}

extension AddKeystoneHWWallet {
    public static let initial = StoreOf<AddKeystoneHWWallet>(
        initialState: .initial
    ) {
        AddKeystoneHWWallet()
    }
}

#Preview {
    NavigationView {
        AddKeystoneHWWalletView(store: AddKeystoneHWWallet.initial)
    }
}
