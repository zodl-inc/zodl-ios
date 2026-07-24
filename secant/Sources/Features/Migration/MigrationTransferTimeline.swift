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
//  MOB-1513 (A2): retires the MOB-1497 (T8) row-0 relabel below — `rows` is 1:1 with
//  `schedule.transfers` again (no row silently becomes "Split Balance"). That relabel let an
//  ORDINARY crossing transfer masquerade as the split: wrong amount (a single transfer's, not the
//  split's), wrong time (its own multi-hour ETA instead of "Ready now"), while the real note-split
//  (a separate broadcast, immediate at commit) had no row of its own and real Transfer 1 was
//  hidden. A caller now opts a SEPARATE, explicit `splitRow` in ahead of `rows` instead — rendered
//  through the exact same row layout, but always check-style (never a numbered badge): `.sent`
//  gets the ordinary green check, anything else the `.neutral` "ready, not yet done" check MOB-1497
//  introduced (still reserved for this one precondition-style row — see `MigrationStepBadge`'s
//  header doc). Every row in `rows` is a genuine transfer now, titled/badged "Transfer `index + 1`"
//  with no exception, so both screens number every real transfer 1..N. Replaces the old opt-in
//  `usesNeutralCheckForReadyFirstStep` flag, which existed only to cover the relabel this retires.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationTransferTimeline: View {
    @Environment(\.colorScheme) private var colorScheme
    @Shared(.inMemory(.exchangeRate)) private var currencyConversion: CurrencyConversion?

    let rows: IdentifiedArrayOf<MigrationTransferRow>
    let caption: (MigrationTransferRow) -> String
    /// MOB-1513 (A2): the synthesized "Split Balance" row a caller opts into ahead of `rows` — see
    /// this file's header doc. `nil` renders no split row at all (e.g. before any rows have
    /// loaded).
    var splitRow: MigrationTransferRow?
    var skeletonPendingCaptions = false
    /// MOB-1511 (W4): per-row caption tone — `nil` keeps the historical tertiary everywhere;
    /// `MigrationStatusView` uses it to render the completed Split Balance row's "Done" in green.
    var captionStyle: ((MigrationTransferRow) -> Colorable)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let splitRow {
                timelineRow(splitRow, isLast: rows.isEmpty)
            }

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

            // MOB-1513 (W1 fallback hydration): `row.amount` is `nil` for a status-only or
            // progress-only fallback row (no persisted schedule to read a real value from) — no
            // amount/fiat text at all rather than a misleading placeholder "0 ZEC". The VStack
            // itself (and its vertical padding, which sets this row's height/spacing to the next
            // one) stays in place either way — only its text content is conditional — so a nil
            // amount collapses just the trailing column's content, not the row's own rhythm.
            VStack(alignment: .trailing, spacing: 2) {
                if let amount = row.amount {
                    Text("\(amount.decimalString()) ZEC")
                        .zFont(.medium, size: 14, style: Design.Text.primary)

                    if let currencyConversion {
                        Text(currencyConversion.convert(amount))
                            .zFont(size: 12, style: Design.Text.tertiary)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 16)
        }
    }

    /// MOB-1513 (A2): the split row always reads "Split Balance"; every other row is a genuine
    /// transfer, always "Transfer `index + 1`" — no more index-0 exception. See this file's header
    /// doc.
    private func rowTitle(for row: MigrationTransferRow) -> String {
        row.kind == .splitBalance
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

    /// MOB-1513 (A2): the split row is always check-style — the ordinary green check once it's
    /// `.sent`, otherwise the `.neutral` "ready, not yet done" check (MOB-1497 T8) — never the
    /// numbered circle every transfer row gets. Replaces the old opt-in
    /// `usesNeutralCheckForReadyFirstStep`, which only ever existed to cover the row-0 relabel this
    /// task retires. Every other row (every element of `rows`) still uses the plain status mapping
    /// below unchanged.
    private func badgeStyle(for row: MigrationTransferRow) -> MigrationStepBadge.Style {
        if row.kind == .splitBalance, row.status == .active {
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

    /// MOB-1487: whether any TRANSFER row has already sent — gates the active transfer row's
    /// trailing connector segment (see `connectorColor(for:)`). MOB-1513 (A2): deliberately scoped
    /// to `rows` only, excluding `splitRow` — a transfer's own connector cares whether ANOTHER
    /// TRANSFER has sent, not whether the split has (unchanged visual behavior from before this
    /// task; the split's own trailing segment, rendered via the same `timelineRow`, still reads its
    /// OWN `status` regardless).
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

/// MOB-1513 (A2): the split row, opted in ahead of `rows` — see this file's header doc.
#Preview("With split row") {
    ScrollView {
        MigrationTransferTimeline(
            rows: .previewRows,
            caption: { row in "hoursFromNow: \(row.hoursFromNow)" },
            splitRow: MigrationTransferRow(
                id: "split-balance",
                index: -1,
                amount: Zatoshi(1_245_800_000),
                status: .active,
                hoursFromNow: 0,
                minutesFromNow: 0,
                kind: .splitBalance
            )
        )
        .padding()
    }
}
