//
//  MigrationStepBadge.swift
//  zodl
//
//  Small numbered/checkmark badge used by the migration transfer timelines (MOB-1463, Figma S6 ·
//  2867:10211 / 2867:2198 / 2709:3519). Rebuilt from the prototype
//  (`origin/michal/MOB-1451-ironwood-migration-prototype:…/MigrationStepBadge.swift`) so the
//  Transfer Plan screen renders consistent step indicators. `.warning` is used by
//  MigrationTransferTimeline for invalid/expired rows (MOB-1464).
//
//  MOB-1487: restyled to the "Final Designs" canvas (frame 3508:11442 family, verified against the
//  Figma Avatar component directly) — default size 28 -> 24; every state now draws a 2pt
//  `Design.Surfaces.bgPrimary` ring (a cutout against the connector line running behind, in
//  MigrationTransferTimeline); `.pending` becomes a filled `bgTertiary` circle (was stroke-only)
//  with its number in `Design.Text.disabled` (Figma's `text-disabled` is #a6a391; this token's
//  gray300/shark600 mapping is the nearest existing semantic match — not a hex-exact one); the
//  numeral drops to 10pt semibold for both `.active` and `.pending` (Figma's Avatar text style is
//  Semibold in both cases); the sent checkmark now scales to 2/3 of `size` (16pt at the new 24pt
//  default, matching the Figma Icon Buttons component's 16px glyph in a 24px frame). `.active`'s
//  fill/number-color tokens and `.warning`'s construction are unchanged.
//
//  MOB-1497 (T8, Q3'26 canvas, Figma 4207:7394 / dark 4207:7555): adds `.neutral` — a precondition
//  step that's ready to run as part of confirming but hasn't happened yet (MigrationTransferPlan's
//  pre-confirmation "Split Balance" row), rendered as an adaptive circle + inverse checkmark instead
//  of a fixed color. Reuses the EXACT `Design.Surfaces.bgAlt` (circle) / `Design.Surfaces.bgPrimary`
//  (checkmark) pairing `MigrationCompleteView.dustResolutionBadge` already ships — see that view's
//  MOB-1494 (W5) header doc for the dark-mode inversion this mirrors (`bgAlt` is obsidian-on-light /
//  bone-on-dark, `bgPrimary` is bone-on-light / midnight-on-dark, so the pair inverts together
//  across color schemes with no fixed hex). `.sent`'s green check stays reserved for steps that have
//  genuinely completed — never used for a merely-ready precondition.
//
//  MOB-1466 (DROPPABLE — Figma 4207:7394 specifies the checkmark above; pending design sign-off):
//  `.neutral` renders the step NUMBER now (like `.pending`), not the inverse checkmark the MOB-1497
//  paragraph above describes — colors are unchanged. Field finding O5: on the pre-commit Transfer
//  Plan screen, the checkmark read as "already done" on a step that had not run yet, one of several
//  cues that made the whole screen look already in progress before Confirm was ever tapped. Revert
//  this one commit to restore the checkmark exactly, if design does not sign off.
//

import SwiftUI

struct MigrationStepBadge: View {
    enum Style: Equatable {
        /// Completed — green filled check.
        case sent
        /// The next/current step — dark filled circle with the number.
        case active
        /// A future step — filled circle with the number in the disabled-text token.
        case pending
        /// Needs attention — amber filled exclamation (invalid/expired timeline rows).
        case warning
        /// MOB-1497 (T8): a precondition step that's ready to run as part of confirming, but hasn't
        /// happened yet — adaptive neutral circle. MOB-1466 (DROPPABLE — pending design sign-off):
        /// renders the step NUMBER, like `.pending`, instead of the inverse checkmark this case
        /// originally shipped with — a checkmark read as "already done" on a step that had not run
        /// yet. Colors are unchanged. See this file's header doc.
        case neutral
        /// A "Split Balance" row that still has work to do — the coins-swap glyph, not a step
        /// number: the timeline's numbering belongs to the transfers, and a split is a precondition
        /// rather than transfer N. Used for every non-terminal split row at any index; a split that
        /// has `.sent` takes the green check and one that is `.invalid`/`.expired` takes `.warning`.
        case splitBalance
    }

    @Environment(\.colorScheme) private var colorScheme

    let number: Int
    let style: Style
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            switch style {
            case .sent:
                Circle().fill(Design.Utility.SuccessGreen._500.color(colorScheme))
                // MOB-1511 (W5 audit): `.sent`/`.warning` glyphs stay literal white deliberately —
                // their backing circles (`SuccessGreen._500`/`WarningYellow._500`) render the same
                // in both schemes, so a scheme-aware token would resolve to white anyway.
                Asset.Assets.check.image
                    .zImage(size: size * 2 / 3, color: .white)
            case .active:
                Circle().fill(Design.Text.primary.color(colorScheme))
                Text("\(number)")
                    .zFont(.semiBold, size: 10, style: Design.Surfaces.bgPrimary)
            case .pending:
                Circle().fill(Design.Surfaces.bgTertiary.color(colorScheme))
                Text("\(number)")
                    .zFont(.semiBold, size: 10, style: Design.Text.disabled)
            case .warning:
                Circle().fill(Design.Utility.WarningYellow._500.color(colorScheme))
                Asset.Assets.Icons.alertCircle.image
                    .zImage(size: 12, color: .white)
            case .neutral:
                // MOB-1466 (DROPPABLE — pending design sign-off): the step number, like `.pending`,
                // not the checkmark this case originally shipped with — see this file's header doc.
                Circle().fill(Design.Surfaces.bgAlt.color(colorScheme))
                Text("\(number)")
                    .zFont(.semiBold, size: 10, style: Design.Surfaces.bgPrimary)
            case .splitBalance:
                Circle().fill(Design.Surfaces.bgTertiary.color(colorScheme))
                Asset.Assets.Icons.coinsSwap.image
                    .zImage(size: 12, style: Design.Text.quaternary)
            }

            // MOB-1487: 2pt white ring on every state — a "cutout" against the connector line
            // running behind the badge in MigrationTransferTimeline.
            Circle()
                .stroke(Design.Surfaces.bgPrimary.color(colorScheme), lineWidth: 2)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Previews

#Preview {
    HStack(spacing: 12) {
        MigrationStepBadge(number: 1, style: .sent)
        MigrationStepBadge(number: 2, style: .active)
        MigrationStepBadge(number: 3, style: .pending)
        MigrationStepBadge(number: 4, style: .warning)
        MigrationStepBadge(number: 5, style: .neutral)
        MigrationStepBadge(number: 6, style: .splitBalance)
    }
    .padding()
}
