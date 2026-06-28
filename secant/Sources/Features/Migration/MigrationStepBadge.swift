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
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            case .active:
                Circle().fill(Design.Text.primary.color(colorScheme))
                Text("\(number)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Design.Surfaces.bgPrimary.color(colorScheme))
            case .pending:
                Circle().stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1.5)
                Text("\(number)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Design.Text.tertiary.color(colorScheme))
            case .warning:
                Circle().fill(Color.orange)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
    }
}
