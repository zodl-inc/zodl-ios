//
//  WalletBirthdayEstimatedHeightView.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-31-2025.
//

import SwiftUI
import ComposableArchitecture

struct WalletBirthdayEstimatedHeightView: View {
    @Environment(\.colorScheme) var colorScheme
    
    @Perception.Bindable var store: StoreOf<WalletBirthday>
    
    init(store: StoreOf<WalletBirthday>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                if store.isKeystoneFlow {
                    Asset.Assets.Partners.keystoneTitleLogo.image
                        .resizable()
                        .frame(width: 193, height: 32)
                        .padding(.top, 16)
                }

                Text(localizable: .restoreWalletBirthdayEstimatedTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 40)
                    .padding(.bottom, 8)

                if store.isResyncFlow {
                    if let attrText = try? AttributedString(
                        markdown: String(localizable: .resyncEstimatedBlockHeightInfo(store.selectedDateString, store.estimatedHeightString)),
                        including: \.zashiApp
                    ) {
                        ZashiText(withAttributedString: attrText, colorScheme: colorScheme)
                            .zFont(size: 14, style: Design.Text.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 56)
                    }
                } else {
                    Text(localizable: .restoreWalletBirthdayEstimatedInfo)
                        .zFont(size: 14, style: Design.Text.primary)
                        .padding(.bottom, 56)
                }

                VStack {
                    Text(store.estimatedHeightString)
                        .zFont(.semiBold, size: 48, style: Design.Text.primary)
                        .padding(.bottom, 12)

                    ZashiButton(
                        String(localizable: .receiveCopy),
                        type: .tertiary,
                        infinityWidth: false,
                        prefixView:
                            Asset.Assets.copy.image
                                .zImage(size: 20, style: Design.Btns.Tertiary.fg)
                    ) {
                        store.send(.copyBirthdayTapped)
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer()

                ZashiButton(
                    store.isKeystoneFlow
                    ? String(localizable: .keystoneAddHWWalletConnect)
                    : store.isResyncFlow
                    ? String(localizable: .generalConfirm)
                    : String(localizable: .importWalletButtonRestoreWallet)
                ) {
                    store.send(.restoreTapped)
                }
                .padding(.bottom, 24)
            }
            .zashiBack()
            .navigationBarTitleDisplayMode(.inline)
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
            .screenHorizontalPadding()
            .applyScreenBackground()
            .screenTitle(
                store.isKeystoneFlow ? "" :
                    store.isResyncFlow
                ? String(localizable: .resyncWalletTitle)
                : String(localizable: .importWalletButtonRestoreWallet)
            )
        }
    }
}

// MARK: - Previews

#Preview {
    WalletBirthdayEstimateDateView(store: WalletBirthday.initial)
}
