//
//  MigrationDetailRow.swift
//  zodl
//
//  Shared banded label/value row card for migration screens (MOB-1463): label 14 regular tertiary
//  on the left, value 14 semibold primary on the right, bgSecondary bands with first/last corner
//  rounding and thin 1 pt gaps between rows — the TransactionDetails row pattern
//  (`TransactionDetailsView.RowAppereance` + `CustomRoundedRectangle`) already privately replicated
//  in `MigrationNoteSplitView`. Used by MigrationReviewTransfer and MigrationScheduled.
//  MigrationNoteSplitView keeps its own private copy as-is to avoid churn on its in-review PR.
//
//  `isContinuous` (MOB-1494 W6) suppresses the 1 pt inter-row gap so consecutive rows of the same
//  bgSecondary fill merge into one seamless card instead of a banded stack — opt-in and defaults to
//  `false`, so existing banded call sites are unaffected.
//

import SwiftUI

struct MigrationDetailRow: View {
    enum RowAppereance {
        case bottom
        case full
        case middle
        case top

        var corners: RectCorner {
            switch self {
            case .bottom:
                return [.bottomLeft, .bottomRight]
            case .full:
                return [.allCorners]
            case .middle:
                return []
            case .top:
                return [.topLeft, .topRight]
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let value: String
    var rowAppereance: RowAppereance = .full
    var isContinuous: Bool = false
    /// LOADING SHAPE (MOB-1466, Figma B9's scheduling twin): when set, the row draws a placeholder
    /// bar of this width where the value goes and `value` is ignored — the label is known before
    /// the number is, which is exactly what the design draws while a schedule is being confirmed.
    ///
    /// Lives HERE rather than in a parallel skeleton row so the two states share one set of
    /// paddings, corners and fills: a placeholder that drifts from the real row by a point is worse
    /// than no placeholder, because the card visibly resizes the moment the numbers land.
    var skeletonWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .zFont(size: 14, style: Design.Text.tertiary)

            Spacer()

            if let skeletonWidth {
                // Sized to the type it stands in for (14 pt line box) so the row height is
                // identical in both states.
                RoundedRectangle(cornerRadius: 4)
                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                    .frame(width: skeletonWidth, height: 14)
            } else {
                Text(value)
                    .zFont(.medium, size: 14, style: Design.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background {
            CustomRoundedRectangle(corners: rowAppereance.corners, radius: 12)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
        .padding(.bottom, isContinuous || rowAppereance == .full || rowAppereance == .bottom ? 0 : 1)
    }
}

// MARK: - Previews

#Preview {
    VStack(spacing: 0) {
        MigrationDetailRow(title: "Amount", value: "12.458 ZEC", rowAppereance: .top)
        MigrationDetailRow(title: "Fee", value: "0.001 ZEC", rowAppereance: .bottom)
    }
    .padding()
}

#Preview("Single row") {
    MigrationDetailRow(title: "Pool", value: "Orchard → Ironwood")
        .padding()
}

#Preview("Continuous card") {
    VStack(spacing: 0) {
        MigrationDetailRow(title: "Amount", value: "12.458 ZEC", rowAppereance: .top, isContinuous: true)
        MigrationDetailRow(title: "Pool", value: "Orchard → Ironwood", rowAppereance: .middle, isContinuous: true)
        MigrationDetailRow(title: "Fee", value: "0.001 ZEC", rowAppereance: .bottom, isContinuous: true)
    }
    .padding()
}
