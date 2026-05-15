//
//  DeleteWalletView.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-27-2024
//

import SwiftUI
import ComposableArchitecture

struct DeleteWalletView: View {
    @Environment(\.colorScheme) var colorScheme
    
    @Perception.Bindable var store: StoreOf<DeleteWallet>
    
    init(store: StoreOf<DeleteWallet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Text(localizable: .deleteWalletTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 40)

                Text(localizable: .deleteWalletMessage2)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 12)
                    .lineSpacing(2)

                Text(localizable: .deleteWalletMessage3)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 12)
                    .lineSpacing(2)

                Text(localizable: .deleteWalletMessage4)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 12)
                    .lineSpacing(2)

                Spacer()

                HStack(alignment: .top, spacing: 0) {
                    ZashiToggle(isOn: $store.areMetadataPreserved)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(localizable: .deleteWalletMetadataWarn1)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(localizable: .deleteWalletMetadataWarn2)
                            .zFont(.semiBold, size: 12, style: Design.Utility.WarningYellow._500)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(20)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                        .fill(Design.Utility.WarningYellow._50.color(colorScheme))
                }
                .padding(.bottom, 32)

                if store.isProcessing {
                    ZashiButton(
                        String(localizable: .deleteWalletActionButtonTitle),
                        type: .destructive1,
                        accessoryView: ProgressView()
                    ) { }
                    .disabled(true)
                    .padding(.bottom, 24)
                } else {
                    ZashiButton(
                        String(localizable: .deleteWalletActionButtonTitle),
                        type: .destructive1
                    ) {
                        store.send(.deleteRequested)
                    }
                    .disabled(store.isProcessing)
                    .padding(.bottom, 24)
                }
            }
            .zashiBack(store.isProcessing)
            .zashiSheet(isPresented: $store.isSheetUp) {
                helpSheetContent()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .screenHorizontalPadding()
        .applyScreenBackground()
        .screenTitle(String(localizable: .deleteWalletScreenTitle).uppercased())
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
            
            Text(localizable: .deleteWalletSheetMsg)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(
                String(localizable: .settingsDeleteZashi),
                type: .destructive2
            ) {
                store.send(.deleteTappedDelayed(store.areMetadataPreserved))
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .generalCancel)) {
                store.send(.dismissSheet)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

// MARK: - Previews

#Preview {
    DeleteWalletView(store: DeleteWallet.demo)
}

// MARK: - Store

extension DeleteWallet {
    static var demo = StoreOf<DeleteWallet>(
        initialState: .initial
    ) {
        DeleteWallet()
    }
}

// MARK: - Placeholders

extension DeleteWallet.State {
    static let initial = DeleteWallet.State()
}
