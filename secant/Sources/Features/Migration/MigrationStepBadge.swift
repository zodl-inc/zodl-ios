//
//  MigrationStepBadge.swift
//  zodl
//
//  Small numbered/checkmark badge used by the migration transfer lists (Figma A2 / B4 / B8). Shared so
//  the Transfer Plan, Status, and Review screens render identical step indicators.
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
        /// Needs attention — amber filled exclamation.
        case warning
    }

    @Environment(\.colorScheme) private var colorScheme

    let number: Int
    let style: Style

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
                    .foregroundStyle(Design.Surfaces.bgPrimary.color(colorScheme))
            case .pending:
                Circle().stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1.5)
                Text("\(number)")
                    .zFont(.medium, size: 13, style: Design.Text.tertiary)
                    .foregroundStyle(Design.Text.tertiary.color(colorScheme))
            case .warning:
                Circle().fill(Design.Utility.WarningYellow._500.color(colorScheme))
                Asset.Assets.Icons.alertCircle.image
                    .zImage(size: 12, color: .white)
            }
        }
        .frame(width: 28, height: 28)
    }
}
