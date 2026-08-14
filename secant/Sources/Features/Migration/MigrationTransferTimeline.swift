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
    /// D14: the "Split Balance" rows a caller opts into ahead of `rows` — see this file's header
    /// doc. Empty renders none at all (e.g. before any rows have loaded).
    ///
    /// This was a single optional row until D14. A run's note-split is not necessarily ONE
    /// transaction: the engine reports `preparationTransactions` across `preparationLayers`, and a
    /// large balance genuinely splits in several steps (Android has always shown these separately —
    /// "Split balance 1..4"). One row for an N-transaction split under-reported the work the user
    /// is approving and the time it takes.
    ///
    /// Titles follow the count, so the overwhelmingly common single-split case is untouched: one
    /// row still reads "Split Balance", several read "Split Balance 1", "Split Balance 2", …
    var splitRows: IdentifiedArrayOf<MigrationTransferRow> = []
    /// Opts a "Show details" disclosure onto the split row, opening the caller's own
    /// "Prepare Your Balance" sheet (Figma 5207:16024). Set only by a caller that COLLAPSES a
    /// multi-transaction split into one row and has somewhere to put the per-step detail; `nil`
    /// (the default) leaves every existing call site — including the ones that still render one
    /// row per preparation — exactly as it was.
    var onSplitDetailsTapped: (() -> Void)?
    var skeletonPendingCaptions = false
    /// MOB-1511 (W4): per-row caption tone — `nil` keeps the historical tertiary everywhere;
    /// `MigrationStatusView` uses it to render the completed Split Balance row's "Done" in green.
    var captionStyle: ((MigrationTransferRow) -> Colorable)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Only the LAST split row can be the list's last row, and only when no transfers
            // follow it — every earlier split still needs its trailing connector.
            ForEach(Array(splitRows.enumerated()), id: \.element.id) { index, row in
                timelineRow(row, isLast: rows.isEmpty && index == splitRows.count - 1)
            }

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                timelineRow(row, isLast: index == rows.count - 1)
            }
        }
    }

    @ViewBuilder private func timelineRow(_ row: MigrationTransferRow, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                MigrationStepBadge(number: row.index + 1, style: Self.badgeStyle(for: row))

                if !isLast {
                    Rectangle()
                        .fill(connectorColor(for: row).color(colorScheme))
                        .frame(width: 2, height: 28)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle(for: row))
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                captionOrSkeleton(for: row)

                if row.kind == .splitBalance, let onSplitDetailsTapped {
                    Button {
                        onSplitDetailsTapped()
                    } label: {
                        HStack(spacing: 4) {
                            Text(String(localizable: .migrationPlanShowDetails))
                                .zFont(.medium, size: 12, style: Design.Text.primary)

                            Asset.Assets.chevronDown.image
                                .zImage(size: 16, style: Design.Text.primary)
                        }
                    }
                    .padding(.top, 2)
                }
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

    /// A split row reads "Split Balance" when it is the only one and "Split Balance N" when the run
    /// has several (D14 — see `splitRows`); every other row is a genuine transfer, always
    /// "Transfer `index + 1`" — no index-0 exception. See this file's header doc.
    private func rowTitle(for row: MigrationTransferRow) -> String {
        guard row.kind == .splitBalance else {
            return String(localizable: .migrationPlanTransferN(row.index + 1))
        }
        return splitRows.count > 1
            ? String(localizable: .migrationPlanSplitBalanceN(row.index + 1))
            : String(localizable: .migrationPlanSplitBalance)
    }

    @ViewBuilder private func captionOrSkeleton(for row: MigrationTransferRow) -> some View {
        if skeletonPendingCaptions && row.status != .sent && row.status != .confirming {
            RoundedRectangle(cornerRadius: 4)
                .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                .frame(width: 60, height: 16)
        } else {
            // MOB-1466 (smart-banner pass, Figma C5 / B10): a row whose work is running RIGHT NOW —
            // being proven, or being broadcast — carries a live spinner beside its caption. A row
            // property, so every screen that renders this timeline gets it for free, and the one
            // signal the user needs (something is moving, don't leave) is never only in the banner.
            // A static caption alone reads the same whether the app is working or idle.
            HStack(spacing: 6) {
                Text(caption(row))
                    .zFont(size: 12, style: captionStyle?(row) ?? Design.Text.tertiary)

                if row.isInFlight {
                    ProgressView()
                        .progressViewStyle(
                            CircularProgressViewStyle(tint: Design.Text.tertiary.color(colorScheme))
                        )
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
            }
        }
    }

    /// A split row is never a numbered circle — while it still has work to do it carries the
    /// `.splitBalance` coins-swap glyph, and only its two terminal outcomes fall through to the
    /// shared status mapping (green check when `.sent`, amber warning when `.invalid`/`.expired`).
    /// Supersedes MOB-1513 (A2)'s check-style rule, which relied on `.neutral` drawing a checkmark —
    /// MOB-1466 later made `.neutral` render the step number instead. Every element of `rows` is a
    /// genuine transfer and still uses the plain status mapping below unchanged.
    ///
    /// `static` so `MigrationTransferTimelineBadgeStyleTests` can exercise the mapping directly:
    /// it is a pure `MigrationTransferRow -> MigrationStepBadge.Style` function that reads no view
    /// state, and the "1"-instead-of-glyph regression this pins was invisible to every other test
    /// in the suite precisely because the rule lived inside a `View`.
    static func badgeStyle(for row: MigrationTransferRow) -> MigrationStepBadge.Style {
        // A split row is identified by its coins-swap glyph, never by a step number — the numbering
        // in this timeline belongs to the transfers. Every non-terminal split row gets
        // `.splitBalance` at ANY index (a run's note-split can be several transactions — D14, see
        // `splitRows`), leaving only the two terminal outcomes to the shared status mapping:
        // `.sent` keeps the green check and `.invalid`/`.expired` keep the amber warning.
        //
        // Previously this was scoped to `row.index == 0` and `.pending`/`.active` only, so a split
        // row that was `.confirming`, `.overdue`, or simply not the first of a multi-transaction
        // split fell through to `.neutral`/`.active`/`.pending` — all of which render the step
        // NUMBER since MOB-1466 dropped `.neutral`'s checkmark, showing "1" where the glyph belongs.
        if row.kind == .splitBalance {
            switch row.status {
            case .pending, .active, .confirming, .overdue:
                return .splitBalance
            case .sent, .invalid, .expired:
                break
            }
        }

        return badgeStyle(for: row.status)
    }

    /// The status-only mapping every `.transfer` row uses, and the fallback a split row's two
    /// terminal outcomes reach. `static` for the same reason as the overload above.
    static func badgeStyle(for status: MigrationTransferRow.Status) -> MigrationStepBadge.Style {
        switch status {
        case .sent:
            return .sent
        case .confirming:
            // R11: on the chain's side but not yet wallet-confirmed — the `.neutral` "ready, not
            // yet done" check (MOB-1497 T8): check-shaped because it IS sent, not green because
            // the wallet has not counted it yet.
            return .neutral
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
    /// to `rows` only, excluding `splitRows` — a transfer's own connector cares whether ANOTHER
    /// TRANSFER has sent, not whether the split has (unchanged visual behavior from before this
    /// task; the split's own trailing segment, rendered via the same `timelineRow`, still reads its
    /// OWN `status` regardless).
    private var hasSentRow: Bool {
        rows.contains { $0.status == .sent }
    }

    private func connectorColor(for row: MigrationTransferRow) -> Colorable {
        Self.connectorColor(for: row, hasSentRow: hasSentRow)
    }

    /// A row's trailing connector segment, derived from the SAME badge style the row draws — so the
    /// two can never disagree about what kind of row this is.
    ///
    /// This used to take a bare `Status` and call the status-only `badgeStyle` overload, which threw
    /// away `kind`. A `.splitBalance` row therefore resolved as a transfer: `.active` with nothing
    /// sent yet took `Design.Text.primary` and drew a BLACK segment under the Split Balance row on
    /// the Confirm Transfer Plan screen, where the design has every segment gray. The dark segment
    /// MOB-1487 introduced belongs to the active TRANSFER, which is what `hasSentRow` gates; the
    /// split is a precondition, never transfer N, so it never earns it.
    ///
    /// `static` (with `hasSentRow` passed in) so `MigrationTransferTimelineBadgeStyleTests` can
    /// exercise it without building a `View`.
    static func connectorColor(for row: MigrationTransferRow, hasSentRow: Bool) -> Colorable {
        switch badgeStyle(for: row) {
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
        case .neutral, .splitBalance:
            // A confirming row's trailing segment reads as pending gray: the chain is working,
            // nothing green yet. `.splitBalance` lands here for the same reason — gray until the
            // split actually sends, at which point `.sent` takes the green above.
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
            splitRows: [
                MigrationTransferRow(
                    id: "split-balance",
                    index: 0,
                    amount: Zatoshi(1_245_800_000),
                    status: .active,
                    hoursFromNow: 0,
                    minutesFromNow: 0,
                    kind: .splitBalance
                )
            ]
        )
        .padding()
    }
}

/// Every split status side by side — the four non-terminal ones must all render the coins-swap
/// glyph (never a step number), while `.sent` shows the green check and `.expired` the amber
/// warning. `.confirming`, `.overdue` and any index past 0 are the cases that regressed to "1".
#Preview("Split row badge, every status") {
    ScrollView {
        MigrationTransferTimeline(
            rows: [],
            caption: { row in "\(row.status)" },
            splitRows: IdentifiedArrayOf(
                uniqueElements: [
                    MigrationTransferRow.Status.pending,
                    .active,
                    .confirming,
                    .overdue,
                    .sent,
                    .expired
                ].enumerated().map { index, status in
                    MigrationTransferRow(
                        id: "split-balance-\(index)",
                        index: index,
                        amount: nil,
                        status: status,
                        hoursFromNow: 0,
                        minutesFromNow: 0,
                        kind: .splitBalance
                    )
                }
            )
        )
        .padding()
    }
}

/// D14: a multi-transaction split — titles become "Split Balance 1..N" and no per-row amount is
/// shown, because a preparation transaction genuinely has none to show (see
/// `MigrationTransactionStatus`: "status rows carry no amount").
#Preview("With several split rows") {
    ScrollView {
        MigrationTransferTimeline(
            rows: .previewRows,
            caption: { row in row.kind == .splitBalance ? "Ready now" : "hoursFromNow: \(row.hoursFromNow)" },
            splitRows: IdentifiedArrayOf(
                uniqueElements: (0..<4).map { index in
                    MigrationTransferRow(
                        id: "split-balance-\(index)",
                        index: index,
                        amount: nil,
                        status: index == 0 ? .sent : .active,
                        hoursFromNow: 0,
                        minutesFromNow: 0,
                        kind: .splitBalance
                    )
                }
            )
        )
        .padding()
    }
}
