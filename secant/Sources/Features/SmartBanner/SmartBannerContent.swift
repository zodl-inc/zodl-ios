//
//  SmartBannerContent.swift
//  modules
//
//  Created by Lukáš Korba on 04-03-2025.
//

import SwiftUI
import ComposableArchitecture

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
            case .priorityMigration: migrationContent()
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
            default: EmptyView()
            }
        }
    }

    // PROTOTYPE: Ironwood migration CTA. Tapping the banner (or its button) opens the migration flow.
    var migrationBannerTitle: String {
        switch store.migrationState {
        case let .requiresAttention(.transferStalled(transferNumber)): return "Transfer \(transferNumber) waiting"
        case .inProgress: return "Migration in Progress"
        case .requiresAttention: return "Action Needed"
        default: return "Migration Required"
        }
    }

    var migrationBannerInfo: String {
        switch store.migrationState {
        case .requiresAttention(.transferStalled): return "Tap to reschedule or send now"
        case .inProgress: return "Transfers are sending in the background"
        case .requiresAttention: return "A transfer needs your attention"
        default: return "Move your funds to Ironwood"
        }
    }

    var migrationBannerButton: String {
        switch store.migrationState {
        case .requiresAttention(.transferStalled): return "More"
        case .inProgress: return "View"
        case .requiresAttention: return "Resolve"
        default: return "Migrate"
        }
    }

    @ViewBuilder func migrationContent() -> some View {
        HStack(spacing: 0) {
            Asset.Assets.Icons.coinsSwap.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(migrationBannerTitle)
                    .zFont(.medium, size: 14, color: titleStyle())

                Text(migrationBannerInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }

            Spacer()

            ZashiButton(
                migrationBannerButton,
                type: .ghost,
                infinityWidth: false
            ) {
                store.send(.smartBannerContentTapped)
            }
        }
    }

    @ViewBuilder func disconnectedContent() -> some View {
        HStack(spacing: 0) {
            Asset.Assets.Icons.wifiOff.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentDisconnectedTitle)
                    .zFont(.medium, size: 14, color: titleStyle())
                
                Text(localizable: .smartBannerContentDisconnectedInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
            
            Spacer()
        }
    }

    @ViewBuilder func syncingErrorContent() -> some View {
        HStack(spacing: 0) {
            Asset.Assets.Icons.alertTriangle.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentSyncingErrorTitle)
                    .zFont(.medium, size: 14, color: titleStyle())
                
                Text(localizable: .smartBannerContentSyncingErrorInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
            
            Spacer()
        }
    }

    @ViewBuilder func restoringContent() -> some View {
        HStack(spacing: 0) {
            CircularProgressView(progress: store.syncingPercentage)
                .frame(width: 20, height: 20)
                .padding(.trailing, 12)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentRestoreTitle(String(format: "%0.1f%%", store.lastKnownSyncPercentage * 100)))
                    .zFont(.medium, size: 14, color: titleStyle())
                
                Text(store.areFundsSpendable
                     ? String(localizable: .smartBannerContentRestoreInfoSpendable)
                     : String(localizable: .smartBannerContentRestoreInfo)
                )
                .zFont(.medium, size: 12, color: infoStyle())
            }
            
            Spacer()
        }
    }

    @ViewBuilder func resyncingContent() -> some View {
        HStack(spacing: 0) {
            ProgressView()
                .frame(width: 20, height: 20)
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentResyncing)
                    .zFont(.medium, size: 14, color: titleStyle())
                
                Text(localizable: .smartBannerContentRestoreInfo)
                .zFont(.medium, size: 12, color: infoStyle())
            }
            
            Spacer()
        }
    }

    @ViewBuilder func syncingContent() -> some View {
        HStack(spacing: 0) {
            CircularProgressView(progress: store.syncingPercentage)
                .frame(width: 20, height: 20)
                .padding(.trailing, 12)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentSyncTitle(String(format: "%0.1f%%", store.lastKnownSyncPercentage * 100)))
                    .zFont(.medium, size: 14, color: titleStyle())
                
                Text(localizable: .smartBannerContentSyncInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
            
            Spacer()
        }
    }

    @ViewBuilder func updatingBalanceContent() -> some View {
        HStack(spacing: 0) {
            Asset.Assets.Icons.loading.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentUpdatingBalanceTitle)
                    .zFont(.medium, size: 14, color: titleStyle())
                
                Text(localizable: .smartBannerContentUpdatingBalanceInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
            
            Spacer()
        }
    }

    @ViewBuilder func walletBackupContent() -> some View {
        HStack(spacing: 0) {
            Asset.Assets.Icons.alertTriangle.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentBackupTitle)
                    .zFont(.medium, size: 14, color: titleStyle())
                
                Text(localizable: .smartBannerContentBackupInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
            
            Spacer()
            
            ZashiButton(
                String(localizable: .smartBannerContentBackupButton),
                type: .ghost,
                infinityWidth: false
            ) {
                store.send(.walletBackupTapped)
            }
        }
    }

    @ViewBuilder func shieldingContent() -> some View {
        HStack(spacing: 0) {
            Asset.Assets.Icons.shieldOff.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentShieldTitle)
                    .zFont(.medium, size: 14, color: titleStyle())
                
                ZatoshiText(store.transparentBalance, .expanded, store.tokenName)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
            
            Spacer()
            
            ZashiButton(
                String(localizable: .smartBannerContentShieldButton),
                type: .ghost,
                infinityWidth: false
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
        HStack(spacing: 0) {
            Asset.Assets.Icons.shieldZap.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentTorTitle)
                    .zFont(.medium, size: 14, color: titleStyle())
                
                Text(localizable: .smartBannerContentTorInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
            
            Spacer()
            
            ZashiButton(
                String(localizable: .smartBannerContentTorButton),
                type: .ghost,
                infinityWidth: false
            ) {
                store.send(.torSetupTapped)
            }
        }
    }
    
    @ViewBuilder func currencyConversionContent() -> some View {
        HStack(spacing: 0) {
            Asset.Assets.Icons.coinsSwap.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentCurrencyConversionTitle)
                    .zFont(.medium, size: 14, color: titleStyle())
                
                Text(localizable: .smartBannerContentCurrencyConversionInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
            
            Spacer()
            
            ZashiButton(
                String(localizable: .smartBannerContentCurrencyConversionButton),
                type: .ghost,
                infinityWidth: false
            ) {
                store.send(.currencyConversionTapped)
            }
        }
    }

    @ViewBuilder func autoShieldingContent() -> some View {
        HStack(spacing: 0) {
            Asset.Assets.Icons.shieldZap.image
                .zImage(size: 20, color: titleStyle())
                .padding(.trailing, 12)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .smartBannerContentAutoShieldingTitle)
                    .zFont(.medium, size: 14, color: titleStyle())
                
                Text(localizable: .smartBannerContentAutoShieldingInfo)
                    .zFont(.medium, size: 12, color: infoStyle())
            }
            
            Spacer()
            
            ZashiButton(
                String(localizable: .smartBannerContentAutoShieldingButton),
                type: .ghost,
                infinityWidth: false
            ) {
                store.send(.autoShieldingTapped)
            }
        }
    }
}
