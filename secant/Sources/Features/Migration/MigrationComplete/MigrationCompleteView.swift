//
//  MigrationCompleteView.swift
//  zodl
//
//  "Migration Complete" screen (MOB-1464, Figma S12 · 2696:7267). Summary fields are injected by
//  the coordinator's `completeState` (MOB-1466) from the real `migrationSummary`/
//  `migrationLockedAmount` values; a `nil` `totalTransferred`/`durationHours` (MOB-1513, a W1
//  fallback re-entry) renders an em-dash rather than a misleading zero. The `gotItTapped` delegate
//  is consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1487 (round 2, Figma offered 3836:8394 / locking 3836:8488 / locked 3836:8643): dust
//  resolution branches most of this screen off `store.dustResolution` rather than off the old
//  `hasDust` flag. `.none` (no dust, or dust already resolved away) keeps EXACTLY today's
//  celebratory rendering (success gradient background, 148pt illustration). Any other case swaps
//  the illustration for a compact coins-swap badge and drops the success gradient for the flat
//  screen background, then renders the dust callout as either an amber "still needs a decision"
//  card (`.offered`/`.locking`, with the "Migrate anyway" escape hatch) or a neutral "done" card
//  (`.locked`, no button, tertiary-tinted info icon). The primary CTA slot swaps between "Lock
//  balance", an in-flight "Locking balance" spinner button, and "Got it" accordingly.
//
//  MOB-1487 (round 3, Figma 3925:24209 / locked callout 3836:8643): adds a "What does locking do?"
//  explainer sheet, reachable via a trailing nav-bar help button shown whenever `dustResolution !=
//  .none`. The sheet is a plain `zashiSheet` over `store.isLockExplainerPresented` — a manual
//  `Binding(get:set:)` driving `lockExplainerHelpTapped`/`lockExplainerDismissed` (mirroring
//  `MigrationCoordFlow`'s Tor-sheet, not `SwapAndPayCoordFlow`'s `BindableAction` binding, since
//  there's exactly one flag and no cross-screen state) — its three body paragraphs reuse
//  `attributedCalloutText` verbatim against static (unparameterized) localized keys, and its "Got
//  it" button sends `lockExplainerDismissed`, NOT `gotItTapped`, so it closes only the sheet. The
//  dust callout's info icon no longer hides for `.locked`; it now always shows, tinted tertiary
//  when `.locked` and warning-yellow otherwise. The header badge's circle fill switched from the
//  adaptive `Design.Surfaces.bgAlt` to the fixed `obsidian` swatch — `bgAlt` inverts to near-white
//  in dark mode, which hid the white `coinsSwap` glyph; no dark Figma mock exists for this badge,
//  but the bug is objective (the glyph is a fixed white and doesn't depend on colorScheme, so its
//  background can't either).
//
//  MOB-1494 (W5, verified against the new dark Figma mocks): the round 3 fixed-obsidian workaround
//  above turns out to be wrong now that a dark mock for this badge exists — it shows the badge
//  INVERTING in dark mode (white circle + dark glyph), not staying obsidian. The circle fill goes
//  back to the adaptive `Design.Surfaces.bgAlt`; the `coinsSwap` glyph and the green check
//  mini-badge's outer ring both move from fixed `.white` to `Design.Surfaces.bgPrimary` so they
//  invert opposite the circle in each mode; the mini-badge's circle fill moves from
//  `Design.Utility.SuccessGreen._500` (same shade in both modes) to `Design.Avatars.status`, the
//  Figma-matched semantic token for this avatar-status-dot use, which shifts shade per colorScheme.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationCompleteView: View {
    @Environment(\.colorScheme) private var colorScheme
    @PlatformBindable var store: StoreOf<MigrationComplete>

    init(store: StoreOf<MigrationComplete>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            if store.dustResolution == .none {
                screenContent
                    .applySuccessScreenBackground()
            } else {
                screenContent
                    .applyScreenBackground()
            }
        }
    }

    // MARK: - Screen content

    @ViewBuilder private var screenContent: some View {
        VStack(spacing: 0) {
            Spacer()

            headerIllustration

            Text(localizable: .migrationCompleteTitle)
                .zFont(.semiBold, size: 28, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)

            Text(localizable: .migrationCompleteSubtitle)
                .zFont(size: 14, style: Design.Text.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            summaryCard
                .padding(.top, 24)

            if store.dustResolution != .none {
                dustCallout
                    .padding(.top, 16)
            }

            Spacer()

            primaryButton
                .padding(.bottom, 24)
        }
        .padding(.vertical, 1)
        .screenHorizontalPadding()
        .onAppear { store.send(.onAppear) }
        .navigationBarBackButtonHidden()
        .zashiNavigationBarItems(trailing: trailingNavItem)
        .alert($store.scope(state: \.alert, action: \.alert))
        // `$store.<flag>.sending` rather than a hand-rolled `Binding(get:set:)`: SwiftUI invokes a
        // hand-rolled binding's `get` during ITS update cycle, outside the `WithPerceptionTracking`
        // scope this body established, which trips "Perceptible state was accessed but is not being
        // tracked" on every hosted screen — see MigrationCoordFlowView's identical note.
        .zashiSheet(
            isPresented: $store.isLockExplainerPresented.sending(\.lockExplainerPresentedChanged)
        ) {
            // The content builder runs inside the PRESENTATION's hosting body, outside this body's
            // tracking scope, and it reads store state (dust, dustResolution) — so it needs a
            // tracking scope of its own.
            WithPerceptionTracking {
                lockExplainerSheetContent()
            }
        }
    }

    // MARK: - Lock explainer sheet

    /// Trailing nav-bar trigger for the explainer sheet — shown for every dust state that isn't
    /// `.none` (the screen has no back button at all, so this is the only nav-bar item; adding it
    /// doesn't touch `navigationBarBackButtonHidden()` above).
    @ViewBuilder private var trailingNavItem: some View {
        if store.dustResolution != .none {
            Button {
                store.send(.lockExplainerHelpTapped)
            } label: {
                Asset.Assets.Icons.help.image
                    .zImage(size: 24, style: Design.Text.primary)
                    .padding(Design.Spacing.navBarButtonPadding)
            }
        }
    }

    @ViewBuilder private func lockExplainerSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 32) {
            Text(localizable: .migrationCompleteLockExplainerTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)

            VStack(alignment: .leading, spacing: 12) {
                attributedCalloutText(
                    markdown: String(localizable: .migrationCompleteLockExplainerBody1),
                    baseStyle: Design.Text.tertiary,
                    boldColor: nil
                )

                attributedCalloutText(
                    markdown: String(localizable: .migrationCompleteLockExplainerBody2),
                    baseStyle: Design.Text.tertiary,
                    boldColor: nil
                )

                attributedCalloutText(
                    markdown: String(localizable: .migrationCompleteLockExplainerBody3),
                    baseStyle: Design.Text.tertiary,
                    boldColor: nil
                )
            }

            ZashiButton(String(localizable: .migrationGotIt)) {
                store.send(.lockExplainerDismissed)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
        .padding(.top, Design.Spacing._3xl)
    }

    // MARK: - Header illustration / badge

    @ViewBuilder private var headerIllustration: some View {
        if store.dustResolution == .none {
            Asset.Assets.Illustrations.success1.image
                .resizable()
                .frame(width: 148, height: 148)
        } else {
            dustResolutionBadge
        }
    }

    /// Compact coins-swap badge replacing the celebratory illustration whenever dust needs a
    /// decision or has one recorded. The green check mini-badge reflects that the migration
    /// itself completed (this IS the Migration Complete screen) — it doesn't track
    /// `dustResolution`, only whether there's a dust decision to show at all.
    @ViewBuilder private var dustResolutionBadge: some View {
        Circle()
            .fill(Design.Surfaces.bgAlt.color(colorScheme))
            .frame(width: 40, height: 40)
            .overlay {
                Asset.Assets.Icons.coinsSwap.image
                    .zImage(size: 24, style: Design.Surfaces.bgPrimary)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Design.Avatars.status.color(colorScheme))
                    .frame(width: 18, height: 18)
                    .overlay {
                        Circle()
                            .stroke(Design.Surfaces.bgPrimary.color(colorScheme), lineWidth: 2)
                    }
                    .overlay {
                        // MOB-1511 (W5 audit): the MOB-1494 de-hardcoding pass covered the ring and
                        // the coinsSwap glyph but missed this checkmark — same token now.
                        Asset.Assets.check.image
                            .zImage(size: 12, style: Design.Surfaces.bgPrimary)
                    }
            }
    }

    // MARK: - Summary card

    @ViewBuilder private var summaryCard: some View {
        VStack(spacing: 0) {
            MigrationDetailRow(
                title: String(localizable: .migrationCompleteRowTotal),
                // MOB-1513: `nil` on a W1 fallback re-entry (no persisted schedule) — an em-dash
                // rather than a misleading "0 ZEC", matching `store.durationHours`'s treatment below.
                value: store.totalTransferred.map { "\($0.decimalString()) ZEC" } ?? "—",
                rowAppereance: .top
            )

            if store.hasDust {
                MigrationDetailRow(
                    title: String(localizable: .migrationCompleteRowDust),
                    value: "\(store.dust.decimalString()) ZEC",
                    rowAppereance: .middle
                )
            }

            MigrationDetailRow(
                title: String(localizable: .migrationCompleteRowTransfers),
                value: String(localizable: .migrationCompleteRowTransfersValue(store.transfersSent, store.transfersTotal)),
                rowAppereance: .middle
            )

            MigrationDetailRow(
                title: String(localizable: .migrationCompleteRowDuration),
                // MOB-1513: `nil` on a W1 fallback re-entry — an em-dash rather than a misleading
                // "0 hours".
                value: store.durationHours.map { String(localizable: .migrationPlanEtaHours($0)) } ?? "—",
                rowAppereance: .bottom
            )
        }
    }

    // MARK: - Dust callout

    @ViewBuilder private var dustCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                Text(calloutTitle)
                    .zFont(.medium, size: 14, style: calloutTitleStyle)

                Spacer()

                // MOB-1487 (round 3, Figma 3836:8643): the info icon shows in every dust state now
                // (previously hidden for `.locked`) — only the tint still depends on `dustResolution`.
                Asset.Assets.infoOutline.image
                    .zImage(size: 16, style: calloutIconStyle)
            }

            calloutBody

            if store.dustResolution == .offered || store.dustResolution == .locking {
                migrateAnywayButton
                    // MOB-1458 (code review — F4): `.locking` (dust-lock in flight) disabled this
                    // already; `isMigratingAnyway` (the device-authentication gate + unlock/propose
                    // leg in flight, MOB-1458) now does too — previously the ONLY state where this
                    // tap is actually meaningful (`.offered`) left the button live for a double-tap.
                    .disabled(store.dustResolution == .locking || store.isMigratingAnyway)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(calloutBackgroundStyle.color(colorScheme))
        }
    }

    private var calloutTitle: String {
        store.dustResolution == .locked
            ? String(localizable: .migrationCompleteLockedTitle)
            : String(localizable: .migrationCompleteDustTitle)
    }

    private var calloutTitleStyle: Colorable {
        store.dustResolution == .locked ? Design.Text.primary : Design.Utility.WarningYellow._700
    }

    private var calloutIconStyle: Colorable {
        store.dustResolution == .locked ? Design.Text.tertiary : Design.Utility.WarningYellow._700
    }

    private var calloutBackgroundStyle: Colorable {
        store.dustResolution == .locked ? Design.Surfaces.bgSecondary : Design.Utility.WarningYellow._50
    }

    private var amountText: String {
        "\(store.dust.decimalString()) ZEC"
    }

    @ViewBuilder private var calloutBody: some View {
        if store.dustResolution == .locked {
            lockedBody
        } else {
            dustBody
        }
    }

    /// `.offered`/`.locking`: bold amount + regular rest, both `WarningYellow._700` — the explicit
    /// `textColor:` override on `ZashiText` swaps the "boldPrimary" span away from its default
    /// `Design.Text.primary` without needing a new markdown style case.
    @ViewBuilder private var dustBody: some View {
        attributedCalloutText(
            markdown: String(localizable: .migrationCompleteDustBody("^[\(amountText)](style: 'boldPrimary')")),
            baseStyle: Design.Utility.WarningYellow._700,
            boldColor: Design.Utility.WarningYellow._700.color(colorScheme)
        )
    }

    /// `.locked`: bold amount primary, rest tertiary — mirrors the pre-MOB-1487 dust callout body
    /// mechanism exactly, just pointed at the new `lockedBody` copy.
    @ViewBuilder private var lockedBody: some View {
        attributedCalloutText(
            markdown: String(localizable: .migrationCompleteLockedBody("^[\(amountText)](style: 'boldPrimary')")),
            baseStyle: Design.Text.tertiary,
            boldColor: nil
        )
    }

    @ViewBuilder
    private func attributedCalloutText(markdown: String, baseStyle: Colorable, boldColor: Color?) -> some View {
        if let attrText = try? AttributedString(markdown: markdown, including: \.zashiApp) {
            ZashiText(withAttributedString: attrText, colorScheme: colorScheme, textColor: boldColor)
                .zFont(size: 14, style: baseStyle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // `ZashiButton`'s `Type` enum has no per-instance color hook, so this hand-builds the warning
    // button. MOB-1513 (Figma 3836:8394): the fill moves back onto `Design.Btns.Destructive1.bg` —
    // Figma's `btn-destroy1-bg` token (adaptive white/near-black), the same one `ZashiButton`'s own
    // `.destructive1` type uses for its background, and the one this button shares with the
    // Skip buttons on MigrationBackgroundDeliveryView/MigrationNotificationsView. The prior
    // `WarningYellow._50` fill (MOB-1511) blended into the callout's own `WarningYellow._50`
    // background; the border and label stay on `WarningYellow._300`/`._700`.
    @ViewBuilder private var migrateAnywayButton: some View {
        Button {
            store.send(.migrateAnywayTapped)
        } label: {
            Text(localizable: .migrationCompleteMigrateAnyway)
                .zFont(.semiBold, size: 16, style: Design.Utility.WarningYellow._700)
                .fixedSize()
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .fill(Design.Btns.Destructive1.bg.color(colorScheme))
                        .overlay {
                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                .stroke(Design.Utility.WarningYellow._300.color(colorScheme), lineWidth: 1)
                        }
                }
        }
    }

    // MARK: - Primary button

    @ViewBuilder private var primaryButton: some View {
        switch store.dustResolution {
        case .none, .locked:
            ZashiButton(String(localizable: .migrationGotIt)) {
                store.send(.gotItTapped)
            }

        case .offered:
            ZashiButton(String(localizable: .migrationCompleteLockBalance)) {
                store.send(.lockBalanceTapped)
            }

        case .locking:
            ZashiButton(
                String(localizable: .migrationCompleteLockingBalance),
                type: .tertiary,
                prefixView: ProgressView()
            ) {
                store.send(.lockBalanceTapped)
            }
            .disabled(true)
        }
    }
}

// MARK: - Previews

#Preview("Offered") {
    NavigationView {
        MigrationCompleteView(
            store: StoreOf<MigrationComplete>(
                initialState: MigrationComplete.State(
                    totalTransferred: Zatoshi(1_245_800_000),
                    dust: Zatoshi(31_000),
                    transfersSent: 5,
                    transfersTotal: 5,
                    durationHours: 24
                )
            ) {
                MigrationComplete()
            }
        )
    }
}

#Preview("Locking") {
    NavigationView {
        MigrationCompleteView(
            store: StoreOf<MigrationComplete>(
                initialState: MigrationComplete.State(
                    totalTransferred: Zatoshi(1_245_800_000),
                    dust: Zatoshi(31_000),
                    transfersSent: 5,
                    transfersTotal: 5,
                    durationHours: 24,
                    dustResolution: .locking
                )
            ) {
                MigrationComplete()
            }
        )
    }
}

#Preview("Locked") {
    NavigationView {
        MigrationCompleteView(
            store: StoreOf<MigrationComplete>(
                initialState: MigrationComplete.State(
                    totalTransferred: Zatoshi(1_245_800_000),
                    dust: Zatoshi(31_000),
                    transfersSent: 5,
                    transfersTotal: 5,
                    durationHours: 24,
                    dustResolution: .locked
                )
            ) {
                MigrationComplete()
            }
        )
    }
}

#Preview("Clean, no dust") {
    NavigationView {
        MigrationCompleteView(
            store: StoreOf<MigrationComplete>(
                initialState: MigrationComplete.State(
                    totalTransferred: Zatoshi(1_245_800_000),
                    dust: .zero,
                    transfersSent: 5,
                    transfersTotal: 5,
                    durationHours: 24
                )
            ) {
                MigrationComplete()
            }
        )
    }
}
