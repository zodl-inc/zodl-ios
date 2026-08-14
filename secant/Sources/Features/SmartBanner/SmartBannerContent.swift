//
//  SmartBannerContent.swift
//  modules
//
//  Created by Lukáš Korba on 04-03-2025.
//

import SwiftUI
import Combine
import ComposableArchitecture
import Foundation

extension SmartBannerView {
    func titleStyle() -> Color {
        Design.Utility.Purple._50.color(.light)
    }

    func infoStyle() -> Color {
        Design.Utility.Purple._200.color(.light)
    }

    @ViewBuilder func priorityContent() -> some View {
        WithPerceptionTracking {
            switch store.priorityContent {
            case .priority1: disconnectedContent()
            case .priority2: syncingErrorContent()
            case .priority3: restoringContent()
            case .priority4: syncingContent()
            case .priority45: resyncingContent()
            case .priority5: updatingBalanceContent()
            case .priority6: walletBackupContent()
            case .priority7: shieldingContent()
            case .priority75: torSetupContent()
            case .priority8: currencyConversionContent()
            case .priority9: autoShieldingContent()
            case .priorityMigration: migrationContent()
            default: EmptyView()
            }
        }
    }

    /// Banner row layout. iOS: an HStack — icon + labels on the left, CTA on the right. macOS: the rail
    /// is narrow, so everything stacks in a 3-row VStack — icon, then labels, then the (full-width) CTA.
    @ViewBuilder
    func bannerCTALayout<Icon: View, Content: View, CTA: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder content: () -> Content,
        @ViewBuilder cta: () -> CTA
    ) -> some View {
#if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            icon()
            content()
            cta()
        }
#else
        HStack(spacing: 0) {
            icon()
            content()
            Spacer()
            cta()
        }
#endif
    }

    /// Status-banner row layout (icon + labels, NO CTA). iOS: an HStack — icon then labels, pushed
    /// left by a trailing Spacer. macOS: the rail is narrow, so the icon (or the circular progress ring
    /// on the sync / restore banners) sits on its OWN first row above the labels — matching
    /// `bannerCTALayout`'s icon slot so every banner stacks consistently.
    @ViewBuilder
    func bannerStatusLayout<Icon: View, Content: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder content: () -> Content
    ) -> some View {
#if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            icon()
            content()
        }
#else
        HStack(spacing: 0) {
            icon()
            content()
            Spacer()
        }
#endif
    }

    /// On macOS the CTA stacks below the labels (VStack) so it should fill the width; on iOS it sits
    /// inline (HStack) at intrinsic width.
    var bannerCTAFullWidth: Bool {
#if os(macOS)
        true
#else
        false
#endif
    }

    @ViewBuilder func disconnectedContent() -> some View {
        bannerStatusLayout {
            Asset.Assets.Icons.wifiOff.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentDisconnectedTitle)
                    .zFont(.medium, size: 14, color: titleStyle())

                Text(localizable: .smartBannerContentDisconnectedInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
        }
    }

    @ViewBuilder func syncingErrorContent() -> some View {
        bannerStatusLayout {
            Asset.Assets.Icons.alertTriangle.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentSyncingErrorTitle)
                    .zFont(.medium, size: 14, color: titleStyle())

                Text(localizable: .smartBannerContentSyncingErrorInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
        }
    }

    @ViewBuilder func restoringContent() -> some View {
        bannerStatusLayout {
            CircularProgressView(progress: store.syncingPercentage)
                .frame(width: 20, height: 20)
                .padding(.trailing, 12)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentRestoreTitle(String(format: "%0.1f%%", store.lastKnownSyncPercentage * 100)))
                    .zFont(.medium, size: 14, color: titleStyle())

#if os(macOS)
                Text(store.areFundsSpendable
                     ? String(localizable: .smartBannerContentRestoreInfoSpendable)
                     : String(localizable: .smartBannerContentRestoreInfoMac)
                )
                .zFont(.medium, size: 12, color: infoStyle())
#else
                Text(store.areFundsSpendable
                     ? String(localizable: .smartBannerContentRestoreInfoSpendable)
                     : String(localizable: .smartBannerContentRestoreInfo)
                )
                .zFont(.medium, size: 12, color: infoStyle())
#endif
            }
        }
    }

    @ViewBuilder func resyncingContent() -> some View {
        bannerStatusLayout {
            ZashiSpinner()
                .frame(width: 20, height: 20)
                .padding(.trailing, 12)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentResyncing)
                    .zFont(.medium, size: 14, color: titleStyle())

#if os(macOS)
                Text(localizable: .smartBannerContentRestoreInfoMac)
                    .zFont(.medium, size: 12, color: infoStyle())
#else
                Text(localizable: .smartBannerContentRestoreInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
#endif
            }
        }
    }

    @ViewBuilder func syncingContent() -> some View {
        bannerStatusLayout {
            CircularProgressView(progress: store.syncingPercentage)
                .frame(width: 20, height: 20)
                .padding(.trailing, 12)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentSyncTitle(String(format: "%0.1f%%", store.lastKnownSyncPercentage * 100)))
                    .zFont(.medium, size: 14, color: titleStyle())

                Text(localizable: .smartBannerContentSyncInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
        }
    }

    @ViewBuilder func updatingBalanceContent() -> some View {
        bannerStatusLayout {
            Asset.Assets.Icons.loading.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentUpdatingBalanceTitle)
                    .zFont(.medium, size: 14, color: titleStyle())

                Text(localizable: .smartBannerContentUpdatingBalanceInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
        }
    }

    @ViewBuilder func walletBackupContent() -> some View {
        bannerCTALayout {
            Asset.Assets.Icons.alertTriangle.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentBackupTitle)
                    .zFont(.medium, size: 14, color: titleStyle())

                Text(localizable: .smartBannerContentBackupInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
        } cta: {
            ZashiButton(
                String(localizable: .smartBannerContentBackupButton),
                type: .ghost,
                infinityWidth: bannerCTAFullWidth
            ) {
                store.send(.walletBackupTapped)
            }
        }
    }

    @ViewBuilder func shieldingContent() -> some View {
        bannerCTALayout {
            Asset.Assets.Icons.shieldOff.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentShieldTitle)
                    .zFont(.medium, size: 14, color: titleStyle())

                ZatoshiText(store.transparentBalance, .expanded, store.tokenName)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
        } cta: {
            ZashiButton(
                String(localizable: .smartBannerContentShieldButton),
                type: .ghost,
                infinityWidth: bannerCTAFullWidth
            ) {
                if store.isShieldingAcknowledgedAtKeychain {
                    store.send(.shieldFundsTapped)
                } else {
                    store.send(.smartBannerContentTapped)
                }
            }
            .disabled(store.isShielding)
        }
    }

    @ViewBuilder func torSetupContent() -> some View {
        bannerCTALayout {
            Asset.Assets.Icons.shieldZap.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentTorTitle)
                    .zFont(.medium, size: 14, color: titleStyle())

                Text(localizable: .smartBannerContentTorInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
        } cta: {
            ZashiButton(
                String(localizable: .smartBannerContentTorButton),
                type: .ghost,
                infinityWidth: bannerCTAFullWidth
            ) {
                store.send(.torSetupTapped)
            }
        }
    }
    
    @ViewBuilder func currencyConversionContent() -> some View {
        bannerCTALayout {
            Asset.Assets.Icons.coinsSwap.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentCurrencyConversionTitle)
                    .zFont(.medium, size: 14, color: titleStyle())

                Text(localizable: .smartBannerContentCurrencyConversionInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
        } cta: {
            ZashiButton(
                String(localizable: .smartBannerContentCurrencyConversionButton),
                type: .ghost,
                infinityWidth: bannerCTAFullWidth
            ) {
                store.send(.currencyConversionTapped)
            }
        }
    }

    @ViewBuilder func autoShieldingContent() -> some View {
        bannerCTALayout {
            Asset.Assets.Icons.shieldZap.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentAutoShieldingTitle)
                    .zFont(.medium, size: 14, color: titleStyle())

                Text(localizable: .smartBannerContentAutoShieldingInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
        } cta: {
            ZashiButton(
                String(localizable: .smartBannerContentAutoShieldingButton),
                type: .ghost,
                infinityWidth: bannerCTAFullWidth
            ) {
                store.send(.autoShieldingTapped)
            }
        }
    }
}
