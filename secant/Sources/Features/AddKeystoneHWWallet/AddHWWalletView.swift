//
//  AddKeystoneHWWalletView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-11-26.
//

import SwiftUI
import ComposableArchitecture

struct AddKeystoneHWWalletView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<AddKeystoneHWWallet>
    
    init(store: StoreOf<AddKeystoneHWWallet>) {
        self.store = store
    }
    
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Asset.Assets.Partners.keystoneTitleLogo.image
                            .resizable()
                            .frame(width: 193, height: 32)
                            .padding(.top, 16)

                        Text(localizable: .keystoneConnect)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.top, 24)
                        
                        Text(localizable: .keystoneAddHWWalletScan)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .lineSpacing(1.5)
                            .padding(.top, 8)

                        #if DEBUG
                        Button {
                            store.send(.viewTutorialTapped)
                        } label: {
                            Text(localizable: .keystoneAddHWWalletTutorial)
                                .font(.custom(FontFamily.Inter.semiBold.name, size: 14))
                                .foregroundColor(Design.Utility.HyperBlue._700.color(colorScheme))
                                .underline()
                                .padding(.top, 4)
                        }
                        #endif

                        Text(localizable: .keystoneAddHWWalletHowTo)
                            .zFont(.semiBold, size: 18, style: Design.Text.primary)
                            .padding(.top, 24)
                        
                        InfoRow(
                            icon: Asset.Assets.Icons.lockUnlocked.image,
                            title: String(localizable: .keystoneAddHWWalletStep1)
                        )
                        .padding(.top, 16)
                        
                        InfoRow(
                            icon: Asset.Assets.Icons.dotsMenu.image,
                            title: String(localizable: .keystoneAddHWWalletStep2)
                        )
                        .padding(.top, 16)

                        InfoRow(
                            icon: Asset.Assets.Icons.connectWallet.image,
                            title: String(localizable: .keystoneAddHWWalletStep3)
                        )
                        .padding(.top, 16)

                        InfoRow(
                            icon: Asset.Assets.Icons.zashiLogoSqBold.image,
                            title: String(localizable: .keystoneAddHWWalletStep4)
                        )
                        .padding(.top, 16)
                    }
                }
                .padding(.vertical, 1)
                
                Spacer()
                
                ZashiButton(String(localizable: .keystoneAddHWWalletReadyToScan)) {
                    store.send(.readyToScanTapped)
                }
                .padding(.vertical, 24)
            }
            .screenHorizontalPadding()
            .onAppear { store.send(.onAppear) }
            .zashiBack() {
                store.send(.backToHomeTapped)
            }
            .zashiSheet(isPresented: $store.isHelpSheetPresented) {
                helpSheetContent()
            }
            .sheet(isPresented: $store.isInAppBrowserOn) {
                if let url = URL(string: store.inAppBrowserURL) {
                    InAppBrowserView(url: url)
                }
            }
            .navigationBarItems(
                trailing:
                    Button {
                        store.send(.helpSheetRequested)
                    } label: {
                        Asset.Assets.Icons.help.image
                            .zImage(size: 24, style: Design.Text.primary)
                            .padding(Design.Spacing.navBarButtonPadding)
                    }
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .applyScreenBackground()
    }
    
    @ViewBuilder private func helpSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .hardwareWalletExplainerTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)

            Text(localizable: .hardwareWalletExplainerDescription)
                .zFont(size: 14, style: Design.Text.primary)
                .padding(.bottom, Design.Spacing._2xl)
                .fixedSize(horizontal: false, vertical: true)

            infoContent(
                Asset.Assets.Icons.chainLink.image,
                title: String(localizable: .hardwareWalletExplainerFeatureTitle1),
                desc: String(localizable: .hardwareWalletExplainerFeatureDescription1)
            )
            .padding(.bottom, Design.Spacing._xl)

            infoContent(
                Asset.Assets.Icons.shieldTick.image,
                title: String(localizable: .hardwareWalletExplainerFeatureTitle2),
                desc: String(localizable: .hardwareWalletExplainerFeatureDescription2)
            )
            .padding(.bottom, Design.Spacing._xl)

            infoContent(
                Asset.Assets.Icons.crypto.image,
                title: String(localizable: .hardwareWalletExplainerFeatureTitle3),
                desc: String(localizable: .hardwareWalletExplainerFeatureDescription3)
            )
            .padding(.bottom, Design.Spacing._4xl)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Asset.Assets.Partners.keystoneSeekLogo.image
                        .resizable()
                        .frame(width: 24, height: 24)
                        .padding(.trailing, Design.Spacing._md)

                    Text(localizable: .hardwareWalletExplainerInfoBoxTitle)
                        .zFont(.semiBold, size: 16, style: Design.Text.primary)
                }
                .padding(.bottom, Design.Spacing._md)

                Text(localizable: .hardwareWalletExplainerInfoBoxDescription)
                    .zFont(size: 14, style: Design.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Design.Spacing._2xl)
            .padding(.vertical, Design.Spacing._xl)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
            }
            .padding(.bottom, Design.Spacing._4xl)

            ZashiButton(String(localizable: .hardwareWalletExplainerCta)) {
                store.send(.helpSheetRequested)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder private func infoContent(_ icon: Image, title: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                icon
                    .zImage(size: 16, style: Design.Text.primary)
                    .padding(.trailing, Design.Spacing._md)

                Text(title)
                    .zFont(.medium, size: 14, style: Design.Text.primary)
            }
            .padding(.bottom, Design.Spacing._xs)

            Text(desc)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Placeholders

extension AddKeystoneHWWallet.State {
    static let initial = AddKeystoneHWWallet.State()
}

extension AddKeystoneHWWallet {
    @MainActor static let initial = StoreOf<AddKeystoneHWWallet>(
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
