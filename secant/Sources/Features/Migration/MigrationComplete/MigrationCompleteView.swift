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
//  MOB-1749: the dust-resolution badge, the callout (with its "Migrate anyway" button and the
//  attributed-text helper) and the explainer sheet content moved VERBATIM to
//  `MigrationLockResolutionViews.swift`, shared with the Remaining Orchard Funds screen. This file
//  keeps only the mapping from its four-state `DustResolution` onto the shared three-state
//  `MigrationLockResolution` (`.none` never renders any of the shared pieces).
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationCompleteView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<MigrationComplete>

    init(store: StoreOf<MigrationComplete>) {
        self.store = store
    }

    /// MOB-1749: the shared views' three-state vocabulary. `.none` never reaches them (every call
    /// site is guarded on `dustResolution != .none`), so it maps to `.offered` only to keep the
    /// switch total.
    private var lockResolution: MigrationLockResolution {
        switch store.dustResolution {
        case .none, .offered:
            return .offered
        case .locking:
            return .locking
        case .locked:
            return .locked
        }
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
        .navigationBarItems(trailing: trailingNavItem)
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
                MigrationLockExplainerSheetContent {
                    store.send(.lockExplainerDismissed)
                }
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

    // MARK: - Header illustration / badge

    @ViewBuilder private var headerIllustration: some View {
        if store.dustResolution == .none {
            Asset.Assets.Illustrations.success1.image
                .resizable()
                .frame(width: 148, height: 148)
        } else {
            MigrationLockBadge()
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

    /// MOB-1749: the shared callout. The offered copy is this screen's own (`migrationComplete
    /// .dustBody`); the disabled rule is MOB-1458 F4's — `.locking` (dust-lock in flight) or
    /// `isMigratingAnyway` (the unlock/propose leg in flight) both park the button.
    @ViewBuilder private var dustCallout: some View {
        MigrationLockCallout(
            resolution: lockResolution,
            amount: store.dust,
            offeredBodyMarkdown: String(localizable: .migrationCompleteDustBody("^[\(amountText)](style: 'boldPrimary')")),
            isMigrateAnywayDisabled: store.dustResolution == .locking || store.isMigratingAnyway,
            onMigrateAnyway: { store.send(.migrateAnywayTapped) }
        )
    }

    private var amountText: String {
        "\(store.dust.decimalString()) ZEC"
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
