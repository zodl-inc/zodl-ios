//
//  DisconnectHWWalletView.swift
//  Zodl
//
//  Created by Lukáš Korba on 2026-04-02
//

import SwiftUI
import ComposableArchitecture

struct DisconnectHWWalletView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Perception.Bindable var store: StoreOf<DisconnectHWWallet>

    init(store: StoreOf<DisconnectHWWallet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Text(localizable: .deleteKeystoneTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 40)

                Text(localizable: .deleteKeystoneDesc)
                    .zFont(.medium, size: 16, style: Design.Text.primary)
                    .padding(.top, 12)
                    .lineSpacing(2)

                Text(localizable: .disconnectHWWalletMayInclude)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .padding(.top, 12)

                bulletPointText(String(localizable: .disconnectHWWalletBullet1))
                    .padding(.top, 4)
                bulletPointText(String(localizable: .disconnectHWWalletBullet2))
                    .padding(.top, 4)
                bulletPointText(String(localizable: .disconnectHWWalletBullet3))
                    .padding(.top, 4)

                Spacer()
                
                keystoneBadge()
                    .padding(.bottom, Design.Spacing._3xl)

                if store.isProcessing {
                    ZashiButton(
                        String(localizable: .disconnectHWWalletTitle),
                        type: .destructive1,
                        accessoryView: ProgressView()
                    ) { }
                    .disabled(true)
                    .padding(.bottom, 24)
                } else {
                    ZashiButton(
                        String(localizable: .disconnectHWWalletTitle),
                        type: .destructive1
                    ) {
                        store.send(.disconnectTapped)
                    }
                    .padding(.bottom, 24)
                }

                shareView()

                if let supportData = store.supportData {
                    UIMailDialogView(
                        supportData: supportData,
                        completion: {
                            store.send(.sendSupportMailFinished)
                        }
                    )
                    // UIMailDialogView only wraps MFMailComposeViewController presentation
                    // so frame is set to 0 to not break SwiftUI's layout
                    .frame(width: 0, height: 0)
                }
            }
            .onAppear { store.send(.onAppear) }
            .zashiSheet(isPresented: $store.isSheetUp) {
                helpSheetContent()
            }
            .zashiSheet(isPresented: $store.isFailureSheetUp) {
                failureSheetContent()
            }
        }
        .screenHorizontalPadding()
        .applyScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .zashiBack()
        .screenTitle(String(localizable: .disconnectHWWalletTitle))
    }

    @ViewBuilder func keystoneBadge() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Asset.Assets.Partners.keystoneSeekLogo.image
                    .resizable()
                    .frame(width: 44, height: 44)
                    .overlay {
                        Circle()
                            .fill(Design.Avatars.status.color(colorScheme))
                            .frame(width: 14, height: 14)
                            .offset(x: 18, y: 18)
                            .background {
                                Circle()
                                    .fill(Design.Surfaces.fgPrimary.color(colorScheme))
                                    .frame(width: 18, height: 18)
                                    .offset(x: 18, y: 18)
                            }
                    }
                    .padding(.trailing, Design.Spacing._xl)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizable: .keystoneHW)
                        .zFont(.semiBold, size: 16, style: Design.Text.primary)
                    
                    Text(localizable: .currentlyConnected)
                        .zFont(size: 14, style: Design.Text.primary)
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Design.Spacing._2xl)
            .padding(.vertical, Design.Spacing._xl)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._xl)
                    .fill(Design.Surfaces.fgPrimary.color(colorScheme))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius._xl)
                            .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                    }
            }

            HStack(alignment: .top, spacing: 0) {
                Asset.Assets.infoOutline.image
                    .zImage(size: 16, style: Design.Text.tertiary)
                    .padding(.trailing, 12)
                
                Text(localizable: .connectedHWInfo)
                    .zFont(size: 12, style: Design.Text.tertiary)
            }
            .padding(Design.Spacing._md)
        }
        .padding(Design.Spacing._md)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder func bulletPointText(_ text: String) -> some View {
        HStack {
            Circle()
                .frame(width: 4, height: 4)

            Text(text)
                .zFont(size: 14, style: Design.Text.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(1.5)
        }
    }
    
    @ViewBuilder private func helpSheetContent() -> some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.alertOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)

            Text(localizable: .deleteWalletSheetTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 16)
                .padding(.bottom, 12)
            
            Text(localizable: .disconnectHWWalletSheetDesc)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(
                String(localizable: .disconnectHWWalletTitle),
                type: .destructive2
            ) {
                store.send(.disconnectConfirmed)
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .generalCancel)) {
                store.send(.dismissSheet)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder private func failureSheetContent() -> some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.alertOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)

            Text(localizable: .disconnectHWWalletFailureTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 16)
                .padding(.bottom, 12)
            
            Text(localizable: .disconnectHWWalletFailureDesc)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(
                String(localizable: .disconnectHWWalletTryAgain),
                type: .destructive2
            ) {
                store.send(.tryAgain)
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .disconnectHWWalletContactSupport)) {
                store.send(.contactSupport)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

extension DisconnectHWWalletView {
    @ViewBuilder func shareView() -> some View {
        if let message = store.messageToBeShared {
            UIShareDialogView(activityItems: [message]) {
                store.send(.shareFinished)
            }
            // UIShareDialogView only wraps UIActivityViewController presentation
            // so frame is set to 0 to not break SwiftUI's layout
            .frame(width: 0, height: 0)
        } else {
            EmptyView()
        }
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        DisconnectHWWalletView(store: .initial)
    }
}

// MARK: - Placeholders

extension DisconnectHWWallet.State {
    static let initial = DisconnectHWWallet.State()
}

extension StoreOf<DisconnectHWWallet> {
    @MainActor static let initial = StoreOf<DisconnectHWWallet>(
        initialState: .initial
    ) {
        DisconnectHWWallet()
    }
}
