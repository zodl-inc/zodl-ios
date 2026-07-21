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
//  MOB-1497 (T8, Q3'26 canvas, Figma 4207:7394): two changes, both to row 0 specifically.
//  - Title: row 0 always reads "Split Balance" instead of "Transfer 1" — applied here (not in each
//    caller) so Plan and Status stay consistent per the task's own instruction, covering row 0 for
//    its whole lifecycle (pre-confirmation through fully sent, on either screen). `migrationPlan
//    .transferN` stays in use for every other row (index >= 1), so it's not orphaned.
//  - Badge: `usesNeutralCheckForReadyFirstStep` (opted into by `MigrationTransferPlanView` only —
//    see that view's header doc) swaps row 0's badge for the new `.neutral` check while it's still
//    `.active` (ready, not yet sent) instead of the numbered dark circle every other `.active` row
//    gets; a `.sent` row 0 keeps the ordinary green check either way. Defaults `false`, so
//    `MigrationStatusView` (which never opts in) is byte-for-byte unchanged.
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
    /// MOB-1497 (T8): opts row 0 into the neutral "ready, not yet done" check while `.active`. See
    /// this file's header doc.
    var usesNeutralCheckForReadyFirstStep = false
    /// MOB-1511 (W4): per-row caption tone — `nil` keeps the historical tertiary everywhere;
    /// `MigrationStatusView` uses it to render the completed Split Balance row's "Done" in green.
    var captionStyle: ((MigrationTransferRow) -> Colorable)?

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
                MigrationStepBadge(number: row.index + 1, style: badgeStyle(for: row))

                if !isLast {
                    Rectangle()
                        .fill(connectorColor(for: row.status).color(colorScheme))
                        .frame(width: 2, height: 28)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle(for: row))
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

    /// MOB-1497 (T8): row 0 always reads "Split Balance" — every other row keeps its "Transfer N"
    /// title. See this file's header doc.
    private func rowTitle(for row: MigrationTransferRow) -> String {
        row.index == 0
            ? String(localizable: .migrationPlanSplitBalance)
            : String(localizable: .migrationPlanTransferN(row.index + 1))
    }

    @ViewBuilder private func captionOrSkeleton(for row: MigrationTransferRow) -> some View {
        if skeletonPendingCaptions && row.status != .sent {
            RoundedRectangle(cornerRadius: 4)
                .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                .frame(width: 60, height: 16)
        } else {
            Text(caption(row))
                .zFont(size: 12, style: captionStyle?(row) ?? Design.Text.tertiary)
        }
    }

    /// MOB-1497 (T8): row-aware entry point — layers the opt-in neutral-first-step rule (see this
    /// file's header doc) on top of the plain status mapping below, which every other row (and
    /// every row when the opt-in is off) still uses unchanged.
    private func badgeStyle(for row: MigrationTransferRow) -> MigrationStepBadge.Style {
        if usesNeutralCheckForReadyFirstStep, row.index == 0, row.status == .active {
            return .neutral
        }
        return badgeStyle(for: row.status)
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
            return Design.Utility.SuccessGreen._600
        case .active:
            // Dark only while nothing has sent yet; once a row is sent, the active row's segment
            // renders the same pending gray as a queued row.
            return hasSentRow ? Design.Surfaces.strokePrimary : Design.Text.primary
        case .pending:
            // strokePrimary per the dark mocks (5/7 sampled; Confirm-Plan mock internally
            // inconsistent, majority followed — MOB-1487 R3).
            return Design.Surfaces.strokePrimary
        case .warning:
            return Design.Utility.WarningYellow._500
        case .neutral:
            // MOB-1497 (T8): structurally unreachable here — this switch is fed by the status-only
            // `badgeStyle(for:)` overload above, which never returns `.neutral` (only the row-aware
            // overload, driving the badge itself, can); `connectorColor` is only ever called with
            // `row.status` (never the row), so it can't observe the opt-in either. Handled only for
            // exhaustiveness, falling back to the same tone as `.pending`.
            return Design.Surfaces.strokePrimary
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
