//
//  MigrationTorSheetView.swift
//  zodl
//
//  "Enable Tor Protection" bottom sheet (MOB-1478 W2). Presented by `MigrationCoordFlowView` via the
//  `zashiSheet` pattern; hosted by both Entry (immediate) and How This Works (scheduled) through the
//  coordinator's shared gate. Ports the circular Tor badge composition from the deleted
//  `MigrationNetworkPrivacyView`.
//

import ComposableArchitecture
import SwiftUI

struct MigrationTorSheetView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<MigrationTorSheet>

    init(store: StoreOf<MigrationTorSheet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                torBadge
                    .padding(.top, 48)
                    .padding(.bottom, 16)

                Text(localizable: .migrationTorSheetTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.bottom, 12)

                Text(localizable: .migrationTorSheetBody)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.bottom, Design.Spacing._3xl)

                toggleCard
                    .padding(.bottom, 32)

                ZashiButton(String(localizable: .migrationGotIt)) {
                    store.send(.gotItTapped)
                }
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            }
        }
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

    // MARK: - Toggle card

    @ViewBuilder private var toggleCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .migrationTorSheetCardTitle)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                Text(localizable: .migrationTorSheetCardDesc)
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

#Preview {
    MigrationTorSheetView(
        store: StoreOf<MigrationTorSheet>(
            initialState: MigrationTorSheet.State()
        ) {
            MigrationTorSheet()
        }
    )
}
