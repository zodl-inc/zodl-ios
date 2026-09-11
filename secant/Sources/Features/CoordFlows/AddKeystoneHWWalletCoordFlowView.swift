//
//  AddKeystoneHWWalletCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-03-19.
//

import SwiftUI
import ComposableArchitecture

struct AddKeystoneHWWalletCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<AddKeystoneHWWalletCoordFlow>
    let tokenName: String

    init(store: StoreOf<AddKeystoneHWWalletCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                AddKeystoneHWWalletView(
                    store:
                        store.scope(
                            state: \.addKeystoneHWWalletState,
                            action: \.addKeystoneHWWallet
                        )
                )
                .zashiSheet(isPresented: $store.isHelpSheetPresented) {
                    helpSheetContent()
                }
                .zashiSheet(isPresented: $store.isFailureSheetPresented) {
                    failureSheetContent()
                }
                .overlay {
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

                    if let message = store.messageToBeShared {
                        UIShareDialogView(activityItems: [message]) {
                            store.send(.shareFinished)
                        }
                        // UIShareDialogView only wraps UIActivityViewController presentation
                        // so frame is set to 0 to not break SwiftUI's layout
                        .frame(width: 0, height: 0)
                    }
                }
            } destination: { store in
                switch store.case {
                case let .accountHWWalletSelection(store):
                    AccountsSelectionView(store: store)
                case let .estimateBirthdaysDate(store):
                    WalletBirthdayEstimateDateView(store: store)
                case let .estimatedBirthday(store):
                    WalletBirthdayEstimatedHeightView(store: store)
                case let .keystoneConnected(store):
                    KeystoneConnectedView(store: store)
                case let .keystoneDeviceReady(store):
                    KeystoneDeviceReadyView(store: store)
                case let .restoreInfo(store):
                    RestoreInfoView(store: store)
                case let .scan(store):
                    ScanView(store: store)
                case let .walletBirthday(store):
                    WalletBirthdayView(store: store)
                }
            }
        }
        .applyScreenBackground()
        .zashiBack()
    }
    
    @ViewBuilder private func helpSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .restoreWalletHelpTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 8) {
                Asset.Assets.infoCircle.image
                    .zImage(size: 20, style: Design.Text.primary)

                ZashiText(markdown: String(localizable: .walletBirthdayHelpDesc), colorScheme: colorScheme)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 32)
            
            ZashiButton(String(localizable: .restoreInfoGotIt)) {
                store.send(.closeHelpSheetTapped)
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

            Text(localizable: .keystoneAddHWWalletFailureTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Text(localizable: .keystoneAddHWWalletFailureDesc)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(
                String(localizable: .keystoneAddHWWalletContactSupport),
                type: .secondary
            ) {
                store.send(.contactSupportTapped)
            }
            .padding(.bottom, 12)

            ZashiButton(
                String(localizable: .generalCancel),
                type: .primary
            ) {
                store.send(.cancelFailureTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

#Preview {
    NavigationView {
        AddKeystoneHWWalletCoordFlowView(store: AddKeystoneHWWalletCoordFlow.placeholder, tokenName: "ZEC")
    }
}

// MARK: - Placeholders

extension AddKeystoneHWWalletCoordFlow.State {
    static var initial: AddKeystoneHWWalletCoordFlow.State { AddKeystoneHWWalletCoordFlow.State() }
}

extension AddKeystoneHWWalletCoordFlow {
    @MainActor static let placeholder = StoreOf<AddKeystoneHWWalletCoordFlow>(
        initialState: .initial
    ) {
        AddKeystoneHWWalletCoordFlow()
    }
}
