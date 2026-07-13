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

import SwiftUI

struct MigrationStepBadge: View {
    enum Style: Equatable {
        /// Completed — green filled check.
        case sent
        /// The next/current step — dark filled circle with the number.
        case active
        /// A future step — outlined circle with the number.
        case pending
        /// Needs attention — amber filled exclamation (invalid/expired timeline rows).
        case warning
    }

    @Environment(\.colorScheme) private var colorScheme

    let number: Int
    let style: Style
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            switch style {
            case .sent:
                Circle().fill(Design.Utility.SuccessGreen._500.color(colorScheme))
                Asset.Assets.check.image
                    .zImage(size: 12, color: .white)
            case .active:
                Circle().fill(Design.Text.primary.color(colorScheme))
                Text("\(number)")
                    .zFont(.semiBold, size: 13, style: Design.Surfaces.bgPrimary)
            case .pending:
                Circle().stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1.5)
                Text("\(number)")
                    .zFont(.medium, size: 13, style: Design.Text.tertiary)
            case .warning:
                Circle().fill(Design.Utility.WarningYellow._500.color(colorScheme))
                Asset.Assets.Icons.alertCircle.image
                    .zImage(size: 12, color: .white)
            }
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
