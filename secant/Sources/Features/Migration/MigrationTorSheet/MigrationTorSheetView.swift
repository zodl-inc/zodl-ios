//
//  MigrationTorSheetView.swift
//  zodl
//
//  "Enable Tor Protection" bottom sheet (MOB-1478 W2). Presented by `MigrationCoordFlowView` via the
//  `zashiSheet` pattern; hosted by both Entry (immediate) and How This Works (scheduled) through the
//  coordinator's shared gate. Ports the circular Tor badge composition from the deleted
//  `MigrationNetworkPrivacyView`.
//
//  MOB-1497 (T2): `store.isCustomServer` swaps the toggle card for the no-toggle "unavailable" body
//  copy (R2/R12) — badge and title stay the same in both variants (no new title string exists for
//  the unavailable case; flagged for a product/design pass). Within the toggle variant,
//  `store.showsBroadcastDisclosure` (R7-T2 fix-wave 1, Important-1) independently gates the R13
//  disclosure line — testnet and the defensive same-server fallback keep the toggle but must not
//  show a "different server" claim that isn't true. The off-warning alert (R3/R11) is presented via
//  the standard `.alert(store:)` binding — see `MigrationTorSheetStore`'s `AlertState.offWarning`.
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

                Text(bodyText)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.bottom, Design.Spacing._3xl)

                if !store.isCustomServer {
                    toggleCard
                        .padding(.bottom, 12)

                    if store.showsBroadcastDisclosure {
                        disclosureLine
                            .padding(.bottom, 32)
                    }
                }

                ZashiButton(String(localizable: .migrationGotIt)) {
                    store.send(.gotItTapped)
                }
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            }
            .alert($store.scope(state: \.alert, action: \.alert))
        }
    }

    // MARK: - Body copy

    /// MOB-1497 (T2, R2/R11/R12): identity-custom users see the no-toggle unavailable-variant copy
    /// (the formed snapshot's host, plus the path-specific R11 exposure line — combined into one
    /// string per path, since design has no split-line frame for this variant); provider users keep
    /// the existing toggle-sheet body copy, unchanged.
    private var bodyText: String {
        guard store.isCustomServer else {
            return store.usesFullBalanceCopy
                ? String(localizable: .migrationTorSheetBodyImmediate)
                : String(localizable: .migrationTorSheetBody)
        }
        return store.usesFullBalanceCopy
            ? String(localizable: .migrationTorSheetUnavailableBodyFull(store.broadcastHost))
            : String(localizable: .migrationTorSheetUnavailableBodyGradual(store.broadcastHost))
    }

    // MARK: - Tor badge

    @ViewBuilder private var torBadge: some View {
        Circle()
            // Dark mock samples #333A41 (no exact token) — fixed obsidian is the nearest safe fix;
            // bgAlt inverts (MOB-1487 R3 dark pass).
            .fill(Asset.Colors.ZDesign.Base.obsidian.color)
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

    // MARK: - Disclosure (MOB-1497 T2, R13)

    @ViewBuilder private var disclosureLine: some View {
        Text(String(localizable: .migrationTorSheetDisclosure(store.broadcastHost)))
            .zFont(size: 12, style: Design.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
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
