//
//  AdvancedSettingsView.swift
//
//
//  Created by Lukáš Korba on 2024-02-12.
//

import SwiftUI
import ComposableArchitecture

import Generated
import UIComponents

public struct AdvancedSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    @Perception.Bindable var store: StoreOf<AdvancedSettings>
    @Shared(.inMemory(.walletStatus)) public var walletStatus: WalletStatus = .none
    
    public init(store: StoreOf<AdvancedSettings>) {
        self.store = store
    }
    
    public var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                List {
                    Group {
                        ActionRow(
                            icon: Asset.Assets.Icons.key.image,
                            title: L10n.Settings.recoveryPhrase
                        ) {
                            store.send(.operationAccessGranted(.recoveryPhrase))
                        }
                        
                        ActionRow(
                            icon: Asset.Assets.Icons.downloadCloud.image,
                            title: L10n.Settings.exportPrivateData
                        ) {
                            store.send(.operationAccessCheck(.exportPrivateData))
                        }

                        ActionRow(
                            icon: Asset.Assets.Icons.file.image,
                            title: L10n.TaxExport.taxFile
                        ) {
                            store.send(.operationAccessCheck(.exportTaxFile))
                        }
                        .disabled(walletStatus == .restoring)

                        if store.isEnoughFreeSpaceMode {
                            ActionRow(
                                icon: Asset.Assets.Icons.server.image,
                                title: L10n.Settings.chooseServer
                            ) {
                                store.send(.operationAccessCheck(.chooseServer))
                            }
                        }

                        ActionRow(
                            icon: Asset.Assets.Icons.shieldZap.image,
                            title: L10n.Settings.private,
                            divider: false
                        ) {
                            store.send(.operationAccessCheck(.torSetup))
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

                    Text(L10n.Settings.deleteZashiWarning)
                }
                .zFont(size: 12, style: Design.Text.tertiary)
                .padding(.bottom, 20)

                Button {
                    store.send(.operationAccessCheck(.resetZashi))
                } label: {
                    Text(L10n.Settings.deleteZashi)
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
        .screenTitle(L10n.Settings.advanced)
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
    public static let initial = AdvancedSettings.State()
}

extension StoreOf<AdvancedSettings> {
    public static let initial = StoreOf<AdvancedSettings>(
        initialState: .initial
    ) {
        AdvancedSettings()
    }
}
