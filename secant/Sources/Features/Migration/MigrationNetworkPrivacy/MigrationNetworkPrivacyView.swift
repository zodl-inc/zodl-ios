//
//  MigrationNetworkPrivacyView.swift
//  zodl
//
//  "Network Privacy" (Tor toggle). Figma nodes 2673:4621 / 4744.
//

import ComposableArchitecture
import SwiftUI

struct MigrationNetworkPrivacyView: View {
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
                            Text("Network Privacy")
                                .zFont(.semiBold, size: 24, style: Design.Text.primary)

                            Text("Enable Tor to broadcast privately through the Tor network. This prevents your IP address from being linked to the transfer.")
                                .zFont(.regular, size: 14, style: Design.Text.tertiary)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            Text("What Happens Next")
                                .zFont(.semiBold, size: 16, style: Design.Text.primary)

                            outcomeRow(
                                icon: "lock.shield",
                                title: "With Tor",
                                detail: "IP hidden from the network."
                            )

                            outcomeRow(
                                icon: "eye",
                                title: "Without Tor or a VPN",
                                detail: "Transfers are still de-correlated in time, but your IP is visible to network operators."
                            )
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Route via Tor")
                                        .zFont(.semiBold, size: 16, style: Design.Text.primary)

                                    Text("Use Tor for transaction submission")
                                        .zFont(.regular, size: 14, style: Design.Text.tertiary)
                                }

                                Spacer(minLength: 8)

                                Toggle("", isOn: $store.useTor)
                                    .labelsHidden()
                            }

                            if store.torUnavailable {
                                Text("Tor is not available on this network. Consider a trusted VPN, or continue without.")
                                    .zFont(.regular, size: 13, style: Design.Text.tertiary)
                                    .foregroundStyle(Color.orange)
                            }
                        }
                    }
                    .padding(.vertical, 24)
                }

                Spacer(minLength: 0)

                ZashiButton("Next") {
                    store.send(.nextTapped)
                }
                .padding(.bottom, 24)
                .padding(.top, 8)
            }
            .screenHorizontalPadding()
        }
        .applyScreenBackground()
    }

    private func outcomeRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Design.Text.primary.color(.light))
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
