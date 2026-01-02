//
//  DeleteWalletView.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-27-2024
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents

public struct DeleteWalletView: View {
    @Environment(\.colorScheme) var colorScheme
    
    @Perception.Bindable var store: StoreOf<DeleteWallet>
    
    public init(store: StoreOf<DeleteWallet>) {
        self.store = store
    }

    public var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.DeleteWallet.title)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 40)

                Text(L10n.DeleteWallet.message2)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 12)
                    .lineSpacing(2)

                Text(L10n.DeleteWallet.message3)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 12)
                    .lineSpacing(2)

                Text(L10n.DeleteWallet.message4)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 12)
                    .lineSpacing(2)

                Spacer()

                HStack(alignment: .top, spacing: 0) {
                    ZashiToggle(isOn: $store.areMetadataPreserved)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.DeleteWallet.metadataWarn1)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(L10n.DeleteWallet.metadataWarn2)
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
                        L10n.DeleteWallet.actionButtonTitle,
                        type: .destructive1,
                        accessoryView: ProgressView()
                    ) { }
                    .disabled(true)
                    .padding(.bottom, 24)
                } else {
                    ZashiButton(
                        L10n.DeleteWallet.actionButtonTitle,
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
        .screenTitle(L10n.DeleteWallet.screenTitle.uppercased())
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

            Text(L10n.DeleteWallet.Sheet.title)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 16)
                .padding(.bottom, 12)
            
            Text(L10n.DeleteWallet.Sheet.msg)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(
                L10n.Settings.deleteZashi,
                type: .destructive2
            ) {
                store.send(.deleteTapped(store.areMetadataPreserved))
            }
            .padding(.bottom, 12)

            ZashiButton(L10n.General.cancel) {
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
    public static var demo = StoreOf<DeleteWallet>(
        initialState: .initial
    ) {
        DeleteWallet()
    }
}

// MARK: - Placeholders

extension DeleteWallet.State {
    public static let initial = DeleteWallet.State()
}
