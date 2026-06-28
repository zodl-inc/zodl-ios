//
//  MigrationNetworkPrivacyView.swift
//  zodl
//
//  "Network Privacy" (Tor toggle). Figma nodes 2673:4621 / 4744.
//

import ComposableArchitecture
import SwiftUI

struct MigrationNetworkPrivacyView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Perception.Bindable var store: StoreOf<MigrationNetworkPrivacy>
    let tokenName: String

    init(store: StoreOf<MigrationNetworkPrivacy>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(localizable: .migrationNetworkPrivacyTitle)
                                .zFont(.semiBold, size: 24, style: Design.Text.primary)

                            Text(localizable: .migrationNetworkPrivacySubtitle)
                                .zFont(.regular, size: 14, style: Design.Text.tertiary)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            Text(localizable: .migrationNetworkPrivacyWhatHappensNext)
                                .zFont(.semiBold, size: 16, style: Design.Text.primary)

                            outcomeRow(
                                icon: Asset.Assets.Icons.shieldTick.image,
                                title: String(localizable: .migrationNetworkPrivacyWithTorTitle),
                                detail: String(localizable: .migrationNetworkPrivacyWithTorDetail)
                            )

                            outcomeRow(
                                icon: Asset.Assets.eyeOn.image,
                                title: String(localizable: .migrationNetworkPrivacyWithoutTorTitle),
                                detail: String(localizable: .migrationNetworkPrivacyWithoutTorDetail)
                            )
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(localizable: .migrationNetworkPrivacyRouteViaTor)
                                        .zFont(.semiBold, size: 16, style: Design.Text.primary)

                                    Text(localizable: .migrationNetworkPrivacyRouteViaTorDetail)
                                        .zFont(.regular, size: 14, style: Design.Text.tertiary)
                                }

                                Spacer(minLength: 8)

                                Toggle("", isOn: $store.useTor)
                                    .labelsHidden()
                            }

                            if store.torUnavailable {
                                Text(localizable: .migrationNetworkPrivacyTorUnavailable)
                                    .zFont(.regular, size: 13, style: Design.Text.tertiary)
                                    .foregroundStyle(Design.Utility.WarningYellow._500.color(colorScheme))
                            }
                        }
                    }
                    .padding(.vertical, 24)
                }

                Spacer(minLength: 0)

                ZashiButton(String(localizable: .generalNext)) {
                    store.send(.nextTapped)
                }
                .padding(.bottom, 24)
                .padding(.top, 8)
            }
            .screenHorizontalPadding()
        }
        .applyScreenBackground()
    }

    private func outcomeRow(icon: Image, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .zImage(size: 18, style: Design.Text.primary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                Text(detail)
                    .zFont(.regular, size: 14, style: Design.Text.tertiary)
            }
        }
    }
}
