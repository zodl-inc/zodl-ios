//
//  MigrationLockResolutionViews.swift
//  zodl
//
//  MOB-1749: the "leftover Orchard balance" decision pieces, extracted VERBATIM from
//  `MigrationCompleteView` (MOB-1487 rounds 2/3, MOB-1494 W5, MOB-1511, MOB-1513) so the new
//  Remaining Orchard Funds screen (`MigrationResidualView`) renders the identical badge, callout,
//  "Migrate anyway" button and explainer sheet without a second copy to drift. Pixel-preserving for
//  Migration Complete: every token, size and padding below is the one that file carried.
//

import SwiftUI

// `MigrationLockResolution` — the vocabulary these views branch on — now lives beside the reducer
// that owns it, in `MigrationLockDecisionStore.swift`.

/// Compact coins-swap badge with the green check mini-badge — Figma 3836:8394 / 6855:25005. The
/// check says the pool move itself is done; it does not track the lock decision. Adaptive fills
/// (MOB-1494 W5): the circle inverts per color scheme, the glyph and the ring invert opposite it.
struct MigrationLockBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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
                        Asset.Assets.check.image
                            .zImage(size: 12, style: Design.Surfaces.bgPrimary)
                    }
            }
    }
}

/// Bold-amount + regular-rest paragraph shared by the callout bodies and the explainer sheet.
/// `boldColor` overrides the `boldPrimary` span's default `Design.Text.primary` (the amber callout
/// wants the whole sentence in `WarningYellow._700`); `nil` keeps the default.
struct MigrationLockAttributedText: View {
    @Environment(\.colorScheme) private var colorScheme

    let markdown: String
    let baseStyle: Colorable
    let boldColor: Color?

    var body: some View {
        if let attrText = try? AttributedString(markdown: markdown, including: \.zashiApp) {
            ZashiText(withAttributedString: attrText, colorScheme: colorScheme, textColor: boldColor)
                .zFont(size: 14, style: baseStyle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The decision callout: an amber "still needs a decision" card (`.offered` / `.locking`) or the
/// neutral "done" card (`.locked`) — both carry the outlined "Migrate anyway" escape hatch (Wave 2:
/// on `.locked` it is the release path, not a dead end). Both the offered and the locked copy
/// differ per screen only in which balance they name, so the caller passes
/// BOTH bodies with the amount span already interpolated (`^[… ZEC](style: 'boldPrimary')`) — one
/// formatting path per screen, so the offered and locked cards can never end up naming the same
/// amount two differently-formatted ways. The info icon shows in every state, tinted tertiary when
/// locked and warning-yellow otherwise.
struct MigrationLockCallout: View {
    @Environment(\.colorScheme) private var colorScheme

    let resolution: MigrationLockResolution
    let offeredBodyMarkdown: String
    let lockedBodyMarkdown: String
    let isMigrateAnywayDisabled: Bool
    let onMigrateAnyway: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                Text(title)
                    .zFont(.medium, size: 14, style: titleStyle)

                Spacer()

                Asset.Assets.infoOutline.image
                    .zImage(size: 16, style: iconStyle)
            }

            bodyText

            // Wave 2: rendered in EVERY state, `.locked` included — on a locked balance this
            // button is the only release path (the coordinator's leg unlocks first). Deviates
            // from the Figma locked frame (6855:25254 draws no button) by decision 2026-08-24.
            migrateAnywayButton
                .disabled(isMigrateAnywayDisabled)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(backgroundStyle.color(colorScheme))
        }
    }

    private var title: String {
        resolution == .locked
            ? String(localizable: .migrationCompleteLockedTitle)
            : String(localizable: .migrationCompleteDustTitle)
    }

    private var titleStyle: Colorable {
        resolution == .locked ? Design.Text.primary : Design.Utility.WarningYellow._700
    }

    private var iconStyle: Colorable {
        resolution == .locked ? Design.Text.tertiary : Design.Utility.WarningYellow._700
    }

    private var backgroundStyle: Colorable {
        resolution == .locked ? Design.Surfaces.bgSecondary : Design.Utility.WarningYellow._50
    }

    @ViewBuilder private var bodyText: some View {
        if resolution == .locked {
            MigrationLockAttributedText(
                markdown: lockedBodyMarkdown,
                baseStyle: Design.Text.tertiary,
                boldColor: nil
            )
        } else {
            MigrationLockAttributedText(
                markdown: offeredBodyMarkdown,
                baseStyle: Design.Utility.WarningYellow._700,
                boldColor: Design.Utility.WarningYellow._700.color(colorScheme)
            )
        }
    }

    // `ZashiButton`'s `Type` enum has no per-instance color hook, so this hand-builds the warning
    // button (MOB-1513, Figma 3836:8394): `Design.Btns.Destructive1.bg` fill — the same adaptive
    // token `.destructive1` uses — with a `WarningYellow._300` border and a `._700` label.
    @ViewBuilder private var migrateAnywayButton: some View {
        Button {
            onMigrateAnyway()
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
}

/// The decision screens' primary CTA — Lock balance (`.offered`), the disabled in-flight
/// Locking… (`.locking`), Got it (`.locked`). Callers with a "nothing to decide" state
/// (Migration Complete's no-dust completion) short-circuit BEFORE this view.
struct MigrationLockPrimaryButton: View {
    let resolution: MigrationLockResolution
    let onLock: () -> Void
    let onGotIt: () -> Void

    var body: some View {
        switch resolution {
        case .offered:
            ZashiButton(String(localizable: .migrationCompleteLockBalance)) {
                onLock()
            }

        case .locking:
            ZashiButton(
                String(localizable: .migrationCompleteLockingBalance),
                type: .tertiary,
                prefixView: ProgressView()
            ) {
                onLock()
            }
            .disabled(true)

        case .locked:
            ZashiButton(String(localizable: .migrationGotIt)) {
                onGotIt()
            }
        }
    }
}

/// The trailing nav-bar help button that opens the shared explainer sheet.
struct MigrationLockHelpButton: View {
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            Asset.Assets.Icons.help.image
                .zImage(size: 24, style: Design.Text.primary)
                .padding(Design.Spacing.navBarButtonPadding)
        }
    }
}

/// "What does locking do?" explainer sheet content — Figma 3925:24209 / 6855:25052. Its "Got it"
/// closes ONLY the sheet; the hosting screen wires `onGotIt` to its own dismiss action.
struct MigrationLockExplainerSheetContent: View {
    let onGotIt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text(localizable: .migrationCompleteLockExplainerTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)

            VStack(alignment: .leading, spacing: 12) {
                MigrationLockAttributedText(
                    markdown: String(localizable: .migrationCompleteLockExplainerBody1),
                    baseStyle: Design.Text.tertiary,
                    boldColor: nil
                )

                MigrationLockAttributedText(
                    markdown: String(localizable: .migrationCompleteLockExplainerBody2),
                    baseStyle: Design.Text.tertiary,
                    boldColor: nil
                )

                MigrationLockAttributedText(
                    markdown: String(localizable: .migrationCompleteLockExplainerBody3),
                    baseStyle: Design.Text.tertiary,
                    boldColor: nil
                )
            }

            ZashiButton(String(localizable: .migrationGotIt)) {
                onGotIt()
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
        .padding(.top, Design.Spacing._3xl)
    }
}

// MARK: - Previews

#Preview("Offered") {
    VStack(spacing: 16) {
        MigrationLockBadge()
        MigrationLockCallout(
            resolution: .offered,
            offeredBodyMarkdown: "^[0.008 ZEC](style: 'boldPrimary') is still in Orchard.",
            lockedBodyMarkdown: "",
            isMigrateAnywayDisabled: false,
            onMigrateAnyway: { }
        )
        MigrationLockCallout(
            resolution: .locked,
            offeredBodyMarkdown: "",
            lockedBodyMarkdown: "^[0.008 ZEC](style: 'boldPrimary') is now locked in Orchard.",
            isMigrateAnywayDisabled: false,
            onMigrateAnyway: { }
        )
    }
    .padding()
}
