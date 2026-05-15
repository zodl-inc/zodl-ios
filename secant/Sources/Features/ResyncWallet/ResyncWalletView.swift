//
//  ResyncWalletView.swift
//  Zashi
//
//  Created by Lukáš Korba on 04-09-2025.
//

import SwiftUI
import ComposableArchitecture

struct ResyncWalletView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Perception.Bindable var store: StoreOf<ResyncWallet>

    init(store: StoreOf<ResyncWallet>) {
        self.store = store
    }
    
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Text(localizable: .resyncWalletConfirmTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 40)

                Text(localizable: .resyncWalletDescription)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 12)
                    .lineSpacing(2)

                Text(localizable: .resyncWalletDateInfo)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 12)

                Spacer()
                
                bdBadge()
                    .padding(.bottom, Design.Spacing._3xl)

                ZashiButton(String(localizable: .generalConfirm)) {
                    store.send(.startResyncTapped)
                }
                .padding(.bottom, 24)

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
            .zashiSheet(isPresented: $store.isFailureSheetUp) {
                failureSheetContent()
            }
        }
        .screenHorizontalPadding()
        .applyScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .zashiBack()
        .screenTitle(String(localizable: .resyncWalletTitle))
    }
    
    @ViewBuilder func bdBadge() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let attrText = try? AttributedString(
                markdown: String(localizable: .resyncWalletCurrentHeightInfo(store.birthdayDate, store.birthdayBlocks)),
                including: \.zashiApp
            ) {
                ZashiText(withAttributedString: attrText, colorScheme: colorScheme)
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Design.Spacing._xl)
            }

            ZashiButton(
                String(localizable: .resyncWalletChange),
                type: .secondary
            ) {
                store.send(.changeBirthdayTapped)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Design.Spacing._2xl)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }
    
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

            Text(localizable: .resyncWalletFailedTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 16)
                .padding(.bottom, 12)
            
            Text(localizable: .resyncWalletFailedDescription)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(
                String(localizable: .disconnectHWWalletTryAgain),
                type: .secondary
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

// MARK: - Previews

#Preview {
    ResyncWalletView(store: ResyncWallet.initial)
}

// MARK: - Store

extension ResyncWallet {
    static var initial = StoreOf<ResyncWallet>(
        initialState: .initial
    ) {
        ResyncWallet()
    }
}

// MARK: - Placeholders

extension ResyncWallet.State {
    static let initial = ResyncWallet.State()
}
