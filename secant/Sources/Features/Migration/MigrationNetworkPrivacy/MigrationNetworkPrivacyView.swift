//
//  MigrationNetworkPrivacyView.swift
//  zodl
//
//  "Network Privacy" screen (MOB-1460, Figma S5 · 2867:5801 immediate / 2867:10835 scheduled).
//  Visually complete per Figma; the delegate emitted by `nextTapped` is consumed by nobody yet —
//  chaining into the rest of the migration flow lands in MOB-1466.
//

import ComposableArchitecture
import SwiftUI

struct MigrationNetworkPrivacyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<MigrationNetworkPrivacy>

    init(store: StoreOf<MigrationNetworkPrivacy>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        torBadge
                            .padding(.bottom, 16)

                        Text(localizable: .migrationNetworkPrivacyTitle)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        Text(localizable: .migrationNetworkPrivacyDesc)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 12)

                        Text(localizable: .migrationNetworkPrivacyVpnNote)
                            .zFont(size: 12, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 24)

                        Text(localizable: .migrationNetworkPrivacyWhatNext)
                            .zFont(.semiBold, size: 16, style: Design.Text.primary)
                            .padding(.bottom, 12)

                        outcomeRows
                    }
                    .padding(.vertical, 1)
                }

                Spacer(minLength: 16)

                toggleCard
                    .padding(.bottom, 16)

                ZashiButton(String(localizable: .generalNext)) {
                    store.send(.nextTapped)
                }
                .padding(.bottom, 24)
            }
            .screenHorizontalPadding()
            .zashiBack()
        }
        .applyScreenBackground()
    }

    // MARK: - Tor badge

    @ViewBuilder private var torBadge: some View {
        Circle()
            .fill(Design.Surfaces.bgAlt.color(colorScheme))
            .frame(width: 48, height: 48)
            .overlay {
                Asset.Assets.Partners.torLogo.image
                    .zImage(width: 28, height: 19, color: .white)
            }
    }

    // MARK: - Outcome rows

    @ViewBuilder private var outcomeRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            outcomeRow(
                icon: Asset.Assets.Icons.shieldTick.image,
                title: String(localizable: .migrationNetworkPrivacyWithTorTitle),
                caption: withTorCaption
            )

            outcomeRow(
                icon: Asset.Assets.Icons.shieldOff.image,
                title: String(localizable: .migrationNetworkPrivacyWithoutTorTitle),
                caption: withoutTorCaption
            )
        }
    }

    private var withTorCaption: String {
        switch store.variant {
        case .immediate:
            return String(localizable: .migrationNetworkPrivacyWithTorImmediate)
        case .scheduled(let transferCount):
            return String(localizable: .migrationNetworkPrivacyWithTorScheduled(transferCount))
        }
    }

    private var withoutTorCaption: String {
        switch store.variant {
        case .immediate:
            return String(localizable: .migrationNetworkPrivacyWithoutTorImmediate)
        case .scheduled:
            return String(localizable: .migrationNetworkPrivacyWithoutTorScheduled)
        }
    }

    @ViewBuilder private func outcomeRow(icon: Image, title: String, caption: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .zImage(size: 20, style: Design.Text.primary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                Text(caption)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Toggle card

    @ViewBuilder private var toggleCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .migrationNetworkPrivacyToggleTitle)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                Text(localizable: .migrationNetworkPrivacyToggleDesc)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $store.isTorOn)
                .labelsHidden()
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                        .strokeBorder(Design.Surfaces.strokeSecondary.color(colorScheme))
                }
        }
    }
}

// MARK: - Previews

#Preview("Immediate") {
    NavigationView {
        MigrationNetworkPrivacyView(
            store: StoreOf<MigrationNetworkPrivacy>(
                initialState: MigrationNetworkPrivacy.State(variant: .immediate)
            ) {
                MigrationNetworkPrivacy()
            }
        )
    }
}

#Preview("Scheduled") {
    NavigationView {
        MigrationNetworkPrivacyView(
            store: StoreOf<MigrationNetworkPrivacy>(
                initialState: MigrationNetworkPrivacy.State(variant: .scheduled(transferCount: 5), isTorOn: true)
            ) {
                MigrationNetworkPrivacy()
            }
        )
    }
}
