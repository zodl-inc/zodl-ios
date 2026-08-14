//
//  SmartBannerHelpSheet.swift
//  modules
//
//  Created by Lukáš Korba on 04-03-2025.
//

import SwiftUI
import Combine
import ComposableArchitecture

// A standalone view (not a method on SmartBannerView) so it can be presented from the MacSplitView ROOT
// on macOS (MODALS.md Rule #5) — the banner sits in the sidebar, and `.zashiSheet` overlays only the view
// it's attached to. As a real view in the hierarchy it also gets the correct `colorScheme` (dark mode).
// iOS presents it inline from SmartBannerView, unchanged.
struct SmartBannerHelpSheetView: View {
    @Environment(\.colorScheme) private var colorScheme
    @PlatformBindable var store: StoreOf<SmartBanner>
    let tokenName: String

    init(store: StoreOf<SmartBanner>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            switch store.priorityContent {
            case .priority1: disconnectedHelpContent()
            case .priority2: syncingErrorHelpContent()
            case .priority3: restoringHelpContent()
            case .priority4: syncingHelpContent()
            case .priority45: resyncingHelpContent()
            case .priority5: updatingBalanceHelpContent()
            case .priority6: walletBackupHelpContent()
            case .priority7: shieldingHelpContent()
            case .priority9: autoShieldingHelpContent()
            default: EmptyView()
            }
        }
    }
    
    @ViewBuilder func disconnectedHelpContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Asset.Assets.Icons.wifiOff.image
                .zImage(size: 20, color: Design.Text.primary.color(colorScheme))
                .padding(10)
                .background {
                    Circle()
                        .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                        .frame(width: 40, height: 40)
                }
                .padding(.top, 32)
                .padding(.bottom, 12)

            Text(localizable: .smartBannerHelpDiconnectedTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.bottom, 4)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .smartBannerHelpDiconnectedInfo)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 32)
                .fixedSize(horizontal: false, vertical: true)
            
            ZashiButton(String(localizable: .generalOk).uppercased()) {
                store.send(.closeSheetTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }

    @ViewBuilder func syncingErrorHelpContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // A server-validation failure is specific enough to name in the title; every other sync
            // error keeps the generic one, since the sheet is shared by all of them.
            Text(
                localizable: store.lastKnownErrorIsIncompatibleServer
                    ? .smartBannerHelpSyncErrorIncompatibleServerTitle
                    : .smartBannerHelpSyncErrorTitle
            )
            .zFont(.semiBold, size: 20, style: Design.Text.primary)
            .padding(.top, 32)
            .padding(.bottom, 12)

            Text(store.lastKnownErrorMessage)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 32)
                .fixedSize(horizontal: false, vertical: true)

            // A server-validation failure (ZCBPEO0011 & friends) can never resolve itself by
            // retrying, so this is the one sync error where the sheet offers a way out. Mirrors the
            // identical row in the sync-timeout sheet, down to the shared string.
            if store.lastKnownErrorIsIncompatibleServer {
                ActionRow(
                    icon: Asset.Assets.Icons.server.image,
                    title: String(localizable: .sheetSyncTimeoutServer),
                    divider: false,
                    horizontalPadding: Design.Spacing._xl
                ) {
                    store.send(.serverSwitchRequested)
                }
                .padding(.bottom, Design.Spacing._lg)
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                }
                .padding(.bottom, Design.Spacing._2xl)
            }

            ZashiButton(
                String(localizable: .sendReport),
                type: .ghost
            ) {
                store.send(.reportTapped)
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .generalOk).uppercased()) {
                store.send(.closeSheetTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder func restoringHelpContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .smartBannerHelpRestoreTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.top, 32)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .smartBannerHelpRestoreInfo)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
            
#if os(macOS)
            bulletpoint(String(localizable: .smartBannerHelpRestorePoint1Mac))
            bulletpoint(String(localizable: .smartBannerHelpRestorePoint2Mac))
                .padding(.bottom, 32)
#else
            bulletpoint(String(localizable: .smartBannerHelpRestorePoint1))
            bulletpoint(String(localizable: .smartBannerHelpRestorePoint2))
                .padding(.bottom, 32)
#endif

            if !store.areFundsSpendable {
                note(String(localizable: .smartBannerHelpRestoreWarning))
                    .padding(.bottom, 24)
            }

            ZashiButton(String(localizable: .generalOk).uppercased()) {
                store.send(.closeSheetTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder func resyncingHelpContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .smartBannerHelpResyncTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.top, 32)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)

#if os(macOS)
            Text(localizable: .smartBannerHelpSyncInfoMac)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
#else
            Text(localizable: .smartBannerHelpSyncInfo)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
#endif

            ZashiButton(String(localizable: .generalOk).uppercased()) {
                store.send(.closeSheetTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }

    @ViewBuilder func syncingHelpContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .smartBannerHelpSyncTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.top, 32)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)

#if os(macOS)
            Text(localizable: .smartBannerHelpSyncInfoMac)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 32)
                .fixedSize(horizontal: false, vertical: true)
#else
            Text(localizable: .smartBannerHelpSyncInfo)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 32)
                .fixedSize(horizontal: false, vertical: true)
#endif
            
            ZashiButton(String(localizable: .generalOk).uppercased()) {
                store.send(.closeSheetTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }

    @ViewBuilder func updatingBalanceHelpContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Asset.Assets.Icons.loading.image
                .zImage(size: 20, color: Design.Text.primary.color(colorScheme))
                .padding(10)
                .background {
                    Circle()
                        .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                        .frame(width: 40, height: 40)
                }
                .padding(.top, 32)
                .padding(.bottom, 12)

            Text(localizable: .smartBannerHelpUpdatingBalanceTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.bottom, 4)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .smartBannerHelpUpdatingBalanceInfo)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 32)
                .fixedSize(horizontal: false, vertical: true)
            
            ZashiButton(String(localizable: .generalOk).uppercased()) {
                store.send(.closeSheetTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }

    @ViewBuilder func walletBackupHelpContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Asset.Assets.Icons.alertTriangle.image
                .zImage(size: 20, color: Design.Text.primary.color(colorScheme))
                .padding(10)
                .background {
                    Circle()
                        .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                        .frame(width: 40, height: 40)
                }
                .padding(.top, 32)
                .padding(.bottom, 12)

            Text(localizable: .smartBannerHelpBackupTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.bottom, 4)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .smartBannerHelpBackupInfo1)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .smartBannerHelpBackupInfo2)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)

            bulletpoint(String(localizable: .smartBannerHelpBackupPoint1))
            bulletpoint(String(localizable: .smartBannerHelpBackupPoint2))
                .padding(.bottom, 12)

            Text(localizable: .smartBannerHelpBackupInfo3)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 24)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .smartBannerHelpBackupInfo4)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 32)
                .fixedSize(horizontal: false, vertical: true)

            if !store.isWalletBackupAcknowledgedAtKeychain {
                ZashiToggle(
                    isOn: $store.isWalletBackupAcknowledged,
                    label: String(localizable: .smartBannerHelpBackupAcknowledge)
                )
                .padding(.bottom, 24)
                .fixedSize(horizontal: false, vertical: true)
            }

            ZashiButton(
                store.remindMeWalletBackupText,
                type: .ghost
            ) {
                store.send(.remindMeLaterTapped(.priority6))
            }
            .padding(.bottom, 12)
            .disabled(!store.isWalletBackupAcknowledged)

            ZashiButton(String(localizable: .smartBannerContentBackupButton)) {
                store.send(.walletBackupTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }

    @ViewBuilder func shieldingHelpContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Asset.Assets.shieldTick.image
                .zImage(size: 20, color: Design.Text.primary.color(colorScheme))
                .padding(10)
                .background {
                    Circle()
                        .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                        .frame(width: 40, height: 40)
                }
                .padding(.top, 32)
                .padding(.bottom, 12)

            Text(localizable: .smartBannerHelpShieldTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.bottom, 4)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .smartBannerHelpShieldInfo1)
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .smartBannerHelpShieldInfo2("\(String(localizable: .generalFeeShort(store.feeStr))) \(tokenName)"))
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 32)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(localizable: .smartBannerHelpShieldTransparent)
                        .zFont(.medium, size: 16, style: Design.Text.primary)
                        .padding(.trailing, 4)
                    
                    Asset.Assets.Icons.shieldOff.image
                        .zImage(size: 16, style: Design.Text.primary)
                    
                    Spacer()
                }
                .padding(.bottom, 4)

                ZatoshiText(store.transparentBalance, .expanded, store.tokenName)
                    .zFont(.semiBold, size: 20, style: Design.Text.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._2xl)
                            .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                    }
            }
            .padding(.bottom, 24)

            
            ZashiToggle(
                isOn: $store.isShieldingAcknowledged,
                label: String(localizable: .smartBannerHelpShieldDoNotShowAgain)
            )
            .padding(.bottom, 24)
            .fixedSize(horizontal: false, vertical: true)

            ZashiButton(
                String(localizable: .smartBannerHelpShieldNotNow),
                type: .ghost
            ) {
                store.send(.closeSheetTapped)
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .smartBannerContentShieldButton)) {
                store.send(.shieldFundsTapped)
            }
            .disabled(store.isShielding)
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }

    @ViewBuilder func autoShieldingHelpContent() -> some View {
        Text("autoShieldingHelpContent")
            .zFont(size: 14, style: Design.Text.primary)
            .padding(.vertical, 50)
    }
    
    @ViewBuilder private func bulletpoint(_ text: String) -> some View {
        HStack(alignment: .top) {
            Circle()
                .fill(Design.Text.tertiary.color(colorScheme))
                .frame(width: 4, height: 4)
                .padding(.top, 7)
                .padding(.leading, 8)

            Text(text)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 5)
    }
    
    @ViewBuilder private func note(_ text: String) -> some View {
        HintBox(text, iconStyle: Design.Text.tertiary)
    }
}
