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
//  copy (R2/R12). The R3/R11 off-warning alert this view used to present is GONE (Figma parity
//  A1-2.4, 2026-08-06) — toggling Tor off and tapping "Got it" resolves the sheet directly, as the
//  designs draw it. See `MigrationTorSheetStore`'s header for the decision and its evidence.
//
//  MOB-1497 (T3): the custom-server variant is redesigned per the refreshed canvas (4207:10692 / dark
//  4207:10875) — it now gets its OWN title (`migrationTorSheetUnavailableTitle`, 20pt semibold, vs.
//  the provider variant's unchanged 24pt `migrationTorSheetTitle`), a `MigrationRisksCard` ("What are
//  the risks?") below the body copy, and two buttons in place of the shared "Got it": destructive1
//  "Continue without Tor" (`continueWithoutTorTapped`) and primary "Switch Server"
//  (`switchServerTapped`, wired to the coordinator in T4). `disclosureLine` — the R13 broadcast-host
//  line this view used to render under the provider toggle card, gated on
//  `store.showsBroadcastDisclosure` — is deleted outright for BOTH variants; R13 now surfaces only
//  via the (unchanged) TransferPlan/ReviewTransfer confirm footers.
//

import ComposableArchitecture
import SwiftUI

struct MigrationTorSheetView: View {
    @Environment(\.colorScheme) private var colorScheme
    @PlatformBindable var store: StoreOf<MigrationTorSheet>

    init(store: StoreOf<MigrationTorSheet>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                if store.isCustomServer {
                    unavailableContent
                } else {
                    providerContent
                }
            }
        }
    }

    // MARK: - Provider variant (unchanged besides the deleted R13 `disclosureLine`)

    @ViewBuilder private var providerContent: some View {
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

        toggleCard
            // R9-F11: with the R13 disclosure line deleted, the toggle card itself supplies the
            // full 32pt gap before the button (12pt left a cramped toggle-to-button seam).
            .padding(.bottom, 32)

        ZashiButton(String(localizable: .migrationGotIt)) {
            store.send(.gotItTapped)
        }
        .padding(.bottom, Design.Spacing.sheetBottomSpace)
    }

    // MARK: - Custom-server variant (MOB-1497 T3: risks card + Continue without Tor / Switch Server)

    @ViewBuilder private var unavailableContent: some View {
        torBadge
            .padding(.top, 48)
            .padding(.bottom, 12)

        Text(localizable: .migrationTorSheetUnavailableTitle)
            .zFont(.semiBold, size: 20, style: Design.Text.primary)
            .padding(.bottom, 4)

        Text(bodyText)
            .zFont(size: 14, style: Design.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .padding(.bottom, Design.Spacing._3xl)

        MigrationRisksCard(body: risksBodyText)
            .padding(.bottom, Design.Spacing._3xl)

        VStack(spacing: 12) {
            ZashiButton(String(localizable: .migrationTorSheetContinueWithoutTor), type: .destructive1) {
                store.send(.continueWithoutTorTapped)
            }

            ZashiButton(String(localizable: .migrationTorSheetSwitchServer)) {
                store.send(.switchServerTapped)
            }
        }
        .padding(.bottom, Design.Spacing.sheetBottomSpace)
    }

    // MARK: - Body copy

    /// MOB-1497 (T2, R2/R11/R12): identity-custom users see the no-toggle unavailable-variant copy;
    /// provider users keep the existing toggle-sheet body copy, unchanged.
    private var bodyText: String {
        guard store.isCustomServer else {
            return store.usesFullBalanceCopy
                ? String(localizable: .migrationTorSheetBodyImmediate)
                : String(localizable: .migrationTorSheetBody)
        }
        return store.usesFullBalanceCopy
            ? String(localizable: .migrationTorSheetUnavailableBodyFull)
            : String(localizable: .migrationTorSheetUnavailableBodyGradual)
    }

    /// MOB-1497 (T3): `MigrationRisksCard`'s body — the same full/gradual split as `bodyText` above,
    /// off the same `usesFullBalanceCopy` flag ("full" == immediate, "gradual" == scheduled).
    private var risksBodyText: String {
        store.usesFullBalanceCopy
            ? String(localizable: .migrationTorSheetRisksBodyFull)
            : String(localizable: .migrationTorSheetRisksBodyGradual)
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
}

// MARK: - Previews

#Preview("Provider") {
    MigrationTorSheetView(
        store: StoreOf<MigrationTorSheet>(
            initialState: MigrationTorSheet.State()
        ) {
            MigrationTorSheet()
        }
    )
}

#Preview("Custom server") {
    MigrationTorSheetView(
        store: StoreOf<MigrationTorSheet>(
            initialState: MigrationTorSheet.State(isCustomServer: true)
        ) {
            MigrationTorSheet()
        }
    )
}
