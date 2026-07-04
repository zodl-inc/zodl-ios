//
//  WalletAccountsSheet.swift
//  modules
//
//  Created by Lukáš Korba on 26.11.2024.
//

import SwiftUI
import Combine
import ComposableArchitecture

/// The account-switch sheet content (account list + Keystone connect). Extracted from `HomeView`
/// into a standalone view so both iOS (`HomeView`) and macOS (`MacSplitView`) present the same UI.
struct WalletAccountsSheetView: View {
    @Environment(\.colorScheme) private var colorScheme
    let store: StoreOf<Home>

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Text(localizable: .keystoneDrawerTitle)
                    .zFont(.semiBold, size: 20, style: Design.Text.primary)
                    .padding(.top, 32)
                    .padding(.bottom, 24)
                    .padding(.horizontal, 20)

                ForEach(store.walletAccounts, id: \.self) { walletAccount in
                    walletAccountView(
                        icon: walletAccount.vendor.icon(),
                        title: walletAccount.vendor.name(),
                        address: walletAccount.unifiedAddress ?? String(localizable: .receiveErrorCantExtractUnifiedAddress),
                        selected: store.selectedWalletAccount == walletAccount
                    ) {
                        store.send(.walletAccountTapped(walletAccount))
                    }
                }

                if store.walletAccounts.count == 1 {
                    addKeystoneBannerView()
                        .padding(.top, 8)
                        .onTapGesture {
                            store.send(.keystoneBannerTapped)
                        }

                    ZashiButton(
                        String(localizable: .keystoneConnect),
                        type: .secondary
                    ) {
                        store.send(.addKeystoneHWWalletTapped)
                    }
                    .padding(.top, 32)
                    #if !os(macOS)
                    .padding(.horizontal, 20)
                    #endif
                    .padding(.bottom, Design.Spacing.sheetBottomSpace)
                } else {
                    Color.clear
                        .frame(height: 1)
                        .padding(.bottom, 23)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private func walletAccountView(
        icon: Image,
        title: String,
        address: String,
        selected: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        WithPerceptionTracking {
            Button {
                action?()
            } label: {
                HStack(spacing: 0) {
                    icon
                        .resizable()
                        .frame(width: 24, height: 24)
                        .padding(8)
                        .background {
                            Circle()
                                .fill(Design.Surfaces.bgAlt.color(colorScheme))
                        }
                        .padding(.trailing, 12)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .zFont(.semiBold, size: 16, style: Design.Text.primary)

                        Text(address.zip316)
                            .zFont(fontFamily: .robotoMono, size: 12, style: Design.Text.tertiary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Design.Radius._2xl)
                            .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    }
                }
            }
        }
    }

    @ViewBuilder private func addKeystoneBannerView() -> some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(localizable: .keystoneDrawerBannerTitle)
                        .zFont(.semiBold, size: 18, style: Design.Text.primary)

                    Text(localizable: .keystoneDrawerBannerDesc)
                        .zFont(size: 12, style: Design.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                        .padding(.top, 2)
                        .padding(.trailing, 80)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)

                Asset.Assets.Partners.keystonePromo.image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 280, height: 120)
                    .clipped()
            }
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._4xl)
                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))
            }
        }
    }
}

extension HomeView {
    @ViewBuilder func accountSwitchContent() -> some View {
        WalletAccountsSheetView(store: store)
    }
}
