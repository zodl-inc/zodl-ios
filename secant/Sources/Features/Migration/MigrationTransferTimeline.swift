//
//  MigrationTransferTimeline.swift
//  zodl
//
//  Shared badge+connector+title/caption+amount/fiat timeline rows, extracted from
//  `MigrationTransferPlanView` (MOB-1463) for MOB-1464's Status/Recovery screens — the third
//  consumer of this row list. Screens own their own caption copy via the `caption` closure;
//  everything else (badge mapping, connector color, amount + fiat display) lives here.
//
//  MOB-1487: restyled to the "Final Designs" canvas (frame 3508:11442 family + 3480:7638 +
//  3491:10311/10426/10549) — title/amount drop to 14pt medium, caption/fiat to 12pt regular, the
//  connector thickens 1.5 -> 2pt, and the connector coloring rule changes: the active row's
//  trailing segment is dark only until some row in the list has sent (confirmed across the mock
//  frames — Confirm Transfer Plan's untouched list keeps a dark segment under Transfer 1, while
//  Resume's stalled Transfer 3 — also badge-active via `.overdue` — renders its segment
//  pending-gray once Transfers 1-2 are sent). The reschedule skeleton placeholder resizes
//  72x12 -> 60x16 (corner radius unchanged, confirmed against the Figma skeleton Rectangle).
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationTransferTimeline: View {
    @Environment(\.colorScheme) private var colorScheme
    @Shared(.inMemory(.exchangeRate)) private var currencyConversion: CurrencyConversion?

    let rows: IdentifiedArrayOf<MigrationTransferRow>
    let caption: (MigrationTransferRow) -> String
    var skeletonPendingCaptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                timelineRow(row, isLast: index == rows.count - 1)
            }
        }
    }

    @ViewBuilder private func timelineRow(_ row: MigrationTransferRow, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                MigrationStepBadge(number: row.index + 1, style: badgeStyle(for: row.status))

                if !isLast {
                    Rectangle()
                        .fill(connectorColor(for: row.status).color(colorScheme))
                        .frame(width: 2, height: 28)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localizable: .migrationPlanTransferN(row.index + 1)))
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                captionOrSkeleton(for: row)
            }
            .padding(.top, 2)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(row.amount.decimalString()) ZEC")
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                if let currencyConversion {
                    Text(currencyConversion.convert(row.amount))
                        .zFont(size: 12, style: Design.Text.tertiary)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder private func captionOrSkeleton(for row: MigrationTransferRow) -> some View {
        if skeletonPendingCaptions && row.status != .sent {
            RoundedRectangle(cornerRadius: 4)
                .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                .frame(width: 60, height: 16)
        } else {
            Text(caption(row))
                .zFont(size: 12, style: Design.Text.tertiary)
        }
    }

    private func badgeStyle(for status: MigrationTransferRow.Status) -> MigrationStepBadge.Style {
        switch status {
        case .sent:
            return .sent
        case .active, .overdue:
            return .active
        case .pending:
            return .pending
        case .invalid, .expired:
            return .warning
        }
    }

    /// MOB-1487: whether any row in the list has already sent — gates the active row's trailing
    /// connector segment (see `connectorColor(for:)`).
    private var hasSentRow: Bool {
        rows.contains { $0.status == .sent }
    }

    private func connectorColor(for status: MigrationTransferRow.Status) -> Colorable {
        switch badgeStyle(for: status) {
        case .sent:
            return Design.Utility.SuccessGreen._500
        case .active:
            // Dark only while nothing has sent yet; once a row is sent, the active row's segment
            // renders the same pending gray as a queued row.
            return hasSentRow ? Design.Surfaces.strokeSecondary : Design.Text.primary
        case .pending:
            return Design.Surfaces.strokeSecondary
        case .warning:
            return Design.Utility.WarningYellow._500
        }
    }
}

// MARK: - Previews

private extension IdentifiedArray where ID == MigrationTransferRow.ID, Element == MigrationTransferRow {
    static var previewRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(351_220_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(287_410_000), status: .active, hoursFromNow: 0),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(243_100_000), status: .overdue, hoursFromNow: 5),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(199_830_000), status: .pending, hoursFromNow: 12),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(164_240_000), status: .expired, hoursFromNow: 18)
        ]
    }
}

#Preview {
    ScrollView {
        MigrationTransferTimeline(
            rows: .previewRows,
            caption: { row in "hoursFromNow: \(row.hoursFromNow)" }
        )
        .padding()
    }
}

#Preview("Skeleton pending captions") {
    ScrollView {
        MigrationTransferTimeline(
            rows: .previewRows,
            caption: { row in "hoursFromNow: \(row.hoursFromNow)" },
            skeletonPendingCaptions: true
        )
        .padding()
    }
}
