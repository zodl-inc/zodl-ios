//
//  WalletAccountsSheet.swift
//  modules
//
//  Created by Lukáš Korba on 26.11.2024.
//

import SwiftUI
import ComposableArchitecture

extension HomeView {
    /// The horizontal inset from the sheet's edge to the title, every row's outer edge and the
    /// button. Combined with `accountSwitchContent()`'s own 4 pt container padding and
    /// `zashiSheet`'s `edgeToEdgeSpacing` (12 pt on iOS 26, 0 before), this totals 24 pt on every
    /// OS version.
    private var accountSwitchElementHorizontalPadding: CGFloat {
        if #available(iOS 26, *) {
            return 8
        } else {
            return 20
        }
    }

    @ViewBuilder func accountSwitchContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .keystoneDrawerTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.top, 32)
                .padding(.bottom, 16)
                .padding(.horizontal, accountSwitchElementHorizontalPadding)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.walletAccounts, id: \.self) { walletAccount in
                    walletAccountView(
                        icon: walletAccount.vendor.icon(),
                        title: walletAccount.vendor.name(),
                        address: walletAccount.unifiedAddress ?? String(localizable: .receiveErrorCantExtractUnifiedAddress),
                        selected: store.selectedWalletAccount == walletAccount,
                        showsSelectedBadge: store.walletAccounts.count > 1
                    ) {
                        store.send(.walletAccountTapped(walletAccount))
                    }
                }
            }
            .padding(.horizontal, accountSwitchElementHorizontalPadding)

            if store.canConnectHWWallet {
                ZashiButton(
                    String(localizable: .keystoneConnect),
                    type: .secondary
                ) {
                    store.send(.connectHWWalletTapped)
                }
                .padding(.top, 24)
                .padding(.horizontal, accountSwitchElementHorizontalPadding)
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            } else {
                Color.clear
                    .frame(height: 1)
                    .padding(.bottom, 23)
            }
        }
        .padding(.horizontal, 4)
    }

    /// The 40 x 40 vendor logo: every vendor's mark, drawn at 24 x 24 with 8 pt padding on a
    /// `Design.Surfaces.bgAlt` circle. Kept separate so `walletAccountView` can overlay the
    /// selected badge on top of it.
    @ViewBuilder private func walletAccountLogo(icon: Image) -> some View {
        icon
            .resizable()
            .frame(width: 24, height: 24)
            .padding(8)
            .background {
                Circle()
                    .fill(Design.Surfaces.bgAlt.color(colorScheme))
            }
    }

    /// The selected-account badge overlaid on the bottom-trailing corner of the logo.
    @ViewBuilder private func selectedWalletAccountBadge() -> some View {
        Asset.Assets.check.image
            .zImage(size: 14, style: Design.Surfaces.bgPrimary)
            .frame(width: 20, height: 20)
            .background {
                Circle()
                    .fill(Design.Avatars.status.color(colorScheme))
            }
            .overlay {
                Circle()
                    .stroke(Design.Surfaces.bgPrimary.color(colorScheme), lineWidth: 1.5)
            }
    }

    @ViewBuilder func walletAccountView(
        icon: Image,
        title: String,
        address: String,
        selected: Bool = false,
        showsSelectedBadge: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        WithPerceptionTracking {
            Button {
                action?()
            } label: {
                HStack(spacing: 12) {
                    walletAccountLogo(icon: icon)
                        .overlay(alignment: .bottomTrailing) {
                            if selected && showsSelectedBadge {
                                selectedWalletAccountBadge()
                                    .offset(x: 4, y: 4)
                            }
                        }

                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .zFont(.medium, size: 14, style: Design.Text.primary)

                        Text(address.zip316)
                            .zFont(size: 12, style: Design.Text.tertiary)
                    }

                    Spacer()

                    Asset.Assets.chevronRight.image
                        .zImage(size: 20, style: Design.Text.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                        .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                        .overlay {
                            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1)
                        }
                }
            }
        }
    }
}
