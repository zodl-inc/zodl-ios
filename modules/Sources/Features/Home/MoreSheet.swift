//
//  MoreSheet.swift
//  modules
//
//  Created by Lukáš Korba on 04.03.2025.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents

extension HomeView {
    @ViewBuilder func moreContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.isKeystoneAccountActive {
                ActionRow(
                    icon: walletStatus == .restoring
                    ? Asset.Assets.Partners.flexaDisabled.image
                    : Asset.Assets.Partners.flexa.image,
                    title: L10n.Settings.flexa,
                    desc: L10n.Settings.flexaDesc,
                    customIcon: true,
                    divider: store.featureFlags.flexa && !store.isKeystoneAccountActive
                ) {
                    store.send(.flexaTapped)
                }
                .disabled(walletStatus == .restoring)
                .padding(.top, 32)
                .padding(.bottom, store.isKeystoneAccountActive ? 24 : 0)
            }

            if !store.isKeystoneConnected {
                ActionRow(
                    icon: Asset.Assets.Partners.keystone.image,
                    title: L10n.Settings.keystone,
                    desc: L10n.Settings.keystoneDesc,
                    customIcon: true,
                    divider: true
                ) {
                    store.send(.addKeystoneHWWalletTapped)
                }
                .padding(.bottom, 12)
            }
            
            ActionRow(
                icon: Asset.Assets.Icons.settings.image,
                title: L10n.HomeScreen.moreDotted,
                divider: false
            ) {
                store.send(.moreInMoreTapped)
            }
            .padding(.bottom, 24)

            HStack(alignment: .top, spacing: 0) {
                Asset.Assets.infoOutline.image
                    .zImage(size: 20, style: Design.Text.tertiary)
                    .padding(.trailing, 12)

                Text(L10n.HomeScreen.moreWarning)
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
                icon: walletStatus == .restoring
                ? Asset.Assets.Partners.payWithNearDisabled.image
                : Asset.Assets.Partners.payWithNear.image,
                title: L10n.SendSelect.payWithNear,
                desc: L10n.SendSelect.PayWithNear.desc,
                customIcon: true,
                divider: !store.isKeystoneAccountActive
            ) {
                store.send(.payWithNearTapped)
            }
            .disabled(walletStatus == .restoring)
            .padding(.top, 32)
            .padding(.bottom, 8)

            if !store.isKeystoneAccountActive {
                ActionRow(
                    icon: walletStatus == .restoring
                    ? Asset.Assets.Partners.flexaDisabled.image
                    : Asset.Assets.Partners.flexa.image,
                    title: L10n.Settings.flexa,
                    desc: L10n.Settings.flexaDesc,
                    customIcon: true,
                    divider: false
                ) {
                    store.send(.flexaTapped)
                }
                .disabled(walletStatus == .restoring)
                .padding(.bottom, 24)
            }

            HStack(alignment: .top, spacing: 0) {
                Asset.Assets.infoOutline.image
                    .zImage(size: 20, style: Design.Text.tertiary)
                    .padding(.trailing, 12)

                Text(L10n.HomeScreen.moreWarning)
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
