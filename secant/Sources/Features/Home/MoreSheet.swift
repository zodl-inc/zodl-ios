//
//  MoreSheet.swift
//  modules
//
//  Created by Lukáš Korba on 04.03.2025.
//

import SwiftUI
import ComposableArchitecture

extension HomeView {
    @ViewBuilder func moreContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.isKeystoneAccountActive {
                ActionRow(
                    icon: walletStatus.isNotReadyForFullySyncedOperation
                    ? Asset.Assets.Partners.flexaDisabled.image
                    : Asset.Assets.Partners.flexa.image,
                    title: String(localizable: .settingsFlexa),
                    desc: String(localizable: .settingsFlexaDesc),
                    customIcon: true,
                    divider: store.featureFlags.flexa && !store.isKeystoneAccountActive
                ) {
                    store.send(.flexaTapped)
                }
                .disabled(walletStatus.isNotReadyForFullySyncedOperation)
                .padding(.top, 32)
                .padding(.bottom, store.isKeystoneAccountActive ? 24 : 0)
            }

            if !store.isKeystoneConnected {
                ActionRow(
                    icon: Asset.Assets.Partners.keystone.image,
                    title: String(localizable: .settingsKeystone),
                    desc: String(localizable: .settingsKeystoneDesc),
                    customIcon: true,
                    divider: true
                ) {
                    store.send(.addKeystoneHWWalletTapped)
                }
                .padding(.bottom, 12)
            }
            
            ActionRow(
                icon: Asset.Assets.Icons.settings.image,
                title: String(localizable: .homeScreenMoreDotted),
                divider: false
            ) {
                store.send(.moreInMoreTapped)
            }
            .padding(.bottom, 24)

            HStack(alignment: .top, spacing: 0) {
                Asset.Assets.infoOutline.image
                    .zImage(size: 20, style: Design.Text.tertiary)
                    .padding(.trailing, 12)

                Text(localizable: .homeScreenMoreWarning)
                    .zFont(size: 12, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
            .padding(.top, 16)
            .screenHorizontalPadding()
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder func payRequestContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ActionRow(
                icon: walletStatus.isNotReadyForFullySyncedOperation
                ? Asset.Assets.Partners.payWithNearDisabled.image
                : Asset.Assets.Partners.payWithNear.image,
                title: String(localizable: .sendSelectPayWithNear),
                desc: String(localizable: .sendSelectPayWithNearDesc),
                customIcon: true,
                divider: !store.isKeystoneAccountActive
            ) {
                store.send(.payWithNearTapped)
            }
            .disabled(walletStatus.isNotReadyForFullySyncedOperation)
            .padding(.top, 32)
            .padding(.bottom, 8)

            if !store.isKeystoneAccountActive {
                ActionRow(
                    icon: walletStatus.isNotReadyForFullySyncedOperation
                    ? Asset.Assets.Partners.flexaDisabled.image
                    : Asset.Assets.Partners.flexa.image,
                    title: String(localizable: .settingsFlexa),
                    desc: String(localizable: .settingsFlexaDesc),
                    customIcon: true,
                    divider: false
                ) {
                    store.send(.flexaTapped)
                }
                .disabled(walletStatus.isNotReadyForFullySyncedOperation)
                .padding(.bottom, 24)
            }

            HStack(alignment: .top, spacing: 0) {
                Asset.Assets.infoOutline.image
                    .zImage(size: 20, style: Design.Text.tertiary)
                    .padding(.trailing, 12)

                Text(localizable: .homeScreenMoreWarning)
                    .zFont(size: 12, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
            .padding(.top, 16)
            .screenHorizontalPadding()
        }
        .padding(.horizontal, 4)
    }
}
