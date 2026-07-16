//
//  MigrationCompleteView.swift
//  zodl
//
//  "Migration Complete" screen (MOB-1464, Figma S12 · 2696:7267). Visually complete per Figma; all
//  summary fields are placeholders — wiring the real data lands in MOB-1466. The `gotItTapped`
//  delegate is emitted but consumed by nobody yet.
//
//  MOB-1487 (round 2, Figma offered 3836:8394 / locking 3836:8488 / locked 3836:8643): dust
//  resolution branches most of this screen off `store.dustResolution` rather than off the old
//  `hasDust` flag. `.none` (no dust, or dust already resolved away) keeps EXACTLY today's
//  celebratory rendering (success gradient background, 148pt illustration). Any other case swaps
//  the illustration for a compact coins-swap badge and drops the success gradient for the flat
//  screen background, then renders the dust callout as either an amber "still needs a decision"
//  card (`.offered`/`.locking`, with the "Migrate anyway" escape hatch) or a neutral "done" card
//  (`.locked`, no button, no info icon). The primary CTA slot swaps between "Lock balance",
//  an in-flight "Locking balance" spinner button, and "Got it" accordingly.
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
        .navigationBarBackButtonHidden()
        .alert($store.scope(state: \.alert, action: \.alert))
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
                    .zImage(size: 24, color: .white)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Design.Utility.SuccessGreen._500.color(colorScheme))
                    .frame(width: 18, height: 18)
                    .overlay {
                        Circle()
                            .stroke(.white, lineWidth: 2)
                    }
                    .overlay {
                        Asset.Assets.check.image
                            .zImage(size: 12, color: .white)
                    }
            }
    }

    // MARK: - Summary card

    @ViewBuilder private var summaryCard: some View {
        VStack(spacing: 0) {
            MigrationDetailRow(
                title: String(localizable: .migrationCompleteRowTotal),
                value: "\(store.totalTransferred.decimalString()) ZEC",
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
                value: String(localizable: .migrationPlanEtaHours(store.durationHours)),
                rowAppereance: .bottom
            )
        }
    }

    // MARK: - Dust callout

    @ViewBuilder private var dustCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                Text(calloutTitle)
                    .zFont(.semiBold, size: 14, style: calloutTitleStyle)

                Spacer()

                if store.dustResolution != .locked {
                    Asset.Assets.infoOutline.image
                        .zImage(size: 16, style: Design.Utility.WarningYellow._700)
                }
            }

            calloutBody

            if store.dustResolution == .offered || store.dustResolution == .locking {
                migrateAnywayButton
                    .disabled(store.dustResolution == .locking)
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

    // `ZashiButton`'s `Type` enum has no per-instance color hook, so this reproduces the same
    // custom hybrid the permission screens' Skip button uses (MigrationNotificationsView /
    // MigrationBackgroundDeliveryView, MOB-1478 W8): `Destructive1` background fill with the
    // warning label/border colors swapped in.
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
