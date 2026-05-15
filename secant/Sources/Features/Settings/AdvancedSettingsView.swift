//
//  AdvancedSettingsView.swift
//
//
//  Created by Lukáš Korba on 2024-02-12.
//

import SwiftUI
import ComposableArchitecture

struct AdvancedSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    @Perception.Bindable var store: StoreOf<AdvancedSettings>
    @Shared(.inMemory(.walletStatus)) var walletStatus: WalletStatus = .none
    
    init(store: StoreOf<AdvancedSettings>) {
        self.store = store
    }
    
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                List {
                    Group {
                        ActionRow(
                            icon: Asset.Assets.Icons.key.image,
                            title: String(localizable: .settingsRecoveryPhrase)
                        ) {
                            store.send(.operationAccessGranted(.recoveryPhrase))
                        }
                        
                        ActionRow(
                            icon: Asset.Assets.Icons.downloadCloud.image,
                            title: String(localizable: .settingsExportPrivateData)
                        ) {
                            store.send(.operationAccessCheck(.exportPrivateData))
                        }

                        ActionRow(
                            icon: Asset.Assets.Icons.file.image,
                            title: String(localizable: .taxExportTaxFile)
                        ) {
                            store.send(.operationAccessCheck(.exportTaxFile))
                        }
                        .disabled(walletStatus.isNotReadyForFullySyncedOperation)

                        if store.isEnoughFreeSpaceMode {
                            ActionRow(
                                icon: Asset.Assets.Icons.server.image,
                                title: String(localizable: .settingsChooseServer)
                            ) {
                                store.send(.operationAccessCheck(.chooseServer))
                            }
                        }

//                        ActionRow(
//                            icon: Asset.Assets.refreshCCW.image,
//                            title: String(localizable: .resyncWalletTitle)
//                        ) {
//                            store.send(.operationAccessCheck(.resyncWallet))
//                        }
//                        .disabled(walletStatus.isNotReadyForFullySyncedOperation)

                        ActionRow(
                            icon: Asset.Assets.Icons.shieldZap.image,
                            title: String(localizable: .settingsPrivate)
                        ) {
                            store.send(.operationAccessCheck(.torSetup))
                        }

                        if store.isKeystoneConnected {
                            ActionRow(
                                icon: Asset.Assets.Icons.hardDrive.image,
                                title: String(localizable: .disconnectHWWalletCta),
                                divider: false
                            ) {
                                store.send(.operationAccessCheck(.disconnectHWWallet))
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Asset.Colors.background.color)
                    .listRowSeparator(.hidden)
                }
                .padding(.top, 24)
                .padding(.horizontal, 4)

                Spacer()

                HStack(spacing: 0) {
                    Asset.Assets.infoOutline.image
                        .zImage(size: 20, style: Design.Text.tertiary)
                        .padding(.trailing, 12)

                    Text(localizable: .settingsDeleteZashiWarning)
                }
                .zFont(size: 12, style: Design.Text.tertiary)
                .padding(.bottom, 20)

                Button {
                    store.send(.operationAccessCheck(.resetZashi))
                } label: {
                    Text(localizable: .settingsDeleteZashi)
                        .zFont(.semiBold, size: 16, style: Design.Btns.Destructive1.fg)
                        .frame(height: 24)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                .fill(Design.Btns.Destructive1.bg.color(colorScheme))
                                .overlay {
                                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                                        .stroke(Design.Btns.Destructive1.border.color(colorScheme))
                                }
                        }
                }
                .screenHorizontalPadding()
                .padding(.bottom, 24)
            }
        }
        .applyScreenBackground()
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .zashiBack()
        .screenTitle(String(localizable: .settingsAdvanced))
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        AdvancedSettingsView(store: .initial)
    }
}

// MARK: Placeholders

extension AdvancedSettings.State {
    static let initial = AdvancedSettings.State()
}

extension StoreOf<AdvancedSettings> {
    static let initial = StoreOf<AdvancedSettings>(
        initialState: .initial
    ) {
        AdvancedSettings()
    }
}
