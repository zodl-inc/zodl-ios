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

        var corners: UIRectCorner {
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

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .zFont(size: 14, style: Design.Text.tertiary)

            Spacer()

            Text(value)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.trailing)
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
