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
    }
    .padding()
}
