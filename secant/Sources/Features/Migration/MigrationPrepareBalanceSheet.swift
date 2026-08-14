//
//  MigrationPrepareBalanceSheet.swift
//  zodl
//
//  "Prepare Your Balance" sheet (Figma 5207:16024), presented from the Transfer Plan's collapsed
//  "Split Balance" row via its "Show details" disclosure.
//
//  Why a sheet at all: a run's note-split can be several transactions that must mine in order, and
//  the earlier inline treatment (one timeline row per preparation) put N rows of a mechanism the
//  user did not ask about ahead of the transfers they did. The plan screen keeps ONE collapsed row
//  carrying the split's real total, and everything per-step — count, order, what each is waiting on
//  — moves behind this disclosure.
//
//  Steps show no per-step amount: the engine reports none (see `MigrationPrepareBalanceRow`), so the
//  sheet shows a single honest total in its footer instead of N invented fractions.
//
//  A plain `View`, not a feature — it holds no state and has one exit. Presented through
//  `zashiSheet`, matching `MigrationBroadcastFailureSheetView`.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationPrepareBalanceSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    let steps: [MigrationPrepareBalanceRow]
    /// The whole split's total. `nil` hides the footer row rather than showing a placeholder zero —
    /// the same honesty rule the timeline's amount column follows.
    let amountBeingSplit: Zatoshi?
    let gotItTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localizable: .migrationPrepareTitle))
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.top, 32)
                .padding(.bottom, 8)

            Text(String(localizable: .migrationPrepareBody(steps.count)))
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .padding(.bottom, 20)

            stepsCard
                .padding(.bottom, 24)

            ZashiButton(String(localizable: .migrationGotIt)) {
                gotItTapped()
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }

    // MARK: - Steps card

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localizable: .migrationPrepareStepsTitle))
                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                .padding(.bottom, 16)

            // THE 104-STEP SHEET (Lukas, 2026-08-07, from nuttycom's wallet): a run's split can be
            // far longer than the four-to-six steps this sheet was drawn for, and a `VStack` of 104
            // rows is ~5,000 pt tall. `zashiSheet` measures its content and hands that height to
            // `.presentationDetents([.height(…)])`, which UIKit clamps to the screen — but the
            // VStack still LAYS OUT at its ideal height and gets CENTRED in the clamped container.
            // The result on his device: rows 45–59 of 104 visible (dead centre of the ladder), the
            // title and "Steps" heading clipped off the top, and the total and the "Got it" button
            // clipped off the bottom — a sheet with no way to read it and no way to dismiss it by
            // its own CTA.
            //
            // Only the ROWS scroll. The card's heading, the total, and the sheet's own title, body
            // and button stay put — scrolling the whole sheet instead would bury the CTA 104 rows
            // down, which is the same bug wearing a scroll bar.
            if let windowHeight = Self.scrollWindowHeight(forStepCount: steps.count) {
                ScrollView {
                    stepRows
                }
                .frame(height: windowHeight)
            } else {
                stepRows
            }

            if let amountBeingSplit {
                Divider()
                    .overlay(Design.Surfaces.strokeTertiary.color(colorScheme))
                    .padding(.top, 4)
                    .padding(.bottom, 12)

                HStack(spacing: 0) {
                    Text(String(localizable: .migrationPrepareAmountBeingSplit))
                        .zFont(size: 14, style: Design.Text.tertiary)

                    Spacer(minLength: 8)

                    Text("\(amountBeingSplit.decimalString()) ZEC")
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                        .strokeBorder(Design.Surfaces.strokeTertiary.color(colorScheme))
                }
        }
    }

    @ViewBuilder private var stepRows: some View {
        ForEach(Array(steps.enumerated()), id: \.element.id) { position, step in
            stepRow(step, isLast: position == steps.count - 1)
        }
    }

    private enum Constants {
        /// At or below this many steps the ladder sizes the sheet, exactly as it always has —
        /// Lukas's own rule ("<5 splits = keep .zashiSheet to resolve its height but >=5 splits,
        /// set max height"). The designed sheet (5207:16024) draws four.
        static let scrollThreshold = 5
        /// The scrolling window — about five rows at 48 pt (badge 24 + connector 20 + gap 4).
        ///
        /// A FIXED height, not a screen fraction and not a measurement: `zashiSheet` re-measures
        /// its content and re-derives its detent whenever that height changes, and on the pre-iOS
        /// 26 path it also re-keys the subtree by that height (`.id(sheetHeight)`) — so a window
        /// that measured itself from inside the sheet would reset its own `@State` and oscillate.
        /// 240 pt also fits the smallest supported screen with the sheet's ~340 pt of chrome
        /// (title, body, card heading, divider, total, CTA, drag indicator) still on screen.
        static let scrollWindowHeight: CGFloat = 240
    }

    /// The window height for `count` steps, or `nil` when the ladder should size itself.
    ///
    /// `internal static` so the threshold is table-testable without a view host — the same reason
    /// `stateCaption(for:)` is. Chosen so the window is ALWAYS full when it applies: the first
    /// scrolling case (6 steps ≈ 288 pt) already exceeds 240 pt, so no count can leave slack
    /// inside the scroller.
    static func scrollWindowHeight(forStepCount count: Int) -> CGFloat? {
        count > Constants.scrollThreshold ? Constants.scrollWindowHeight : nil
    }

    @ViewBuilder private func stepRow(_ step: MigrationPrepareBalanceRow, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                // Field, 2026-08-03: the banner asked "Keep Zodl open" with a spinner while this
                // sheet answered with one quiet word — the keep-open ask had no counterpart where
                // the user went looking for it. A step the app is PROVING right now wears a live
                // spinner in the badge slot (the design's 5139-34627 language: spinner where the
                // number goes); every other state keeps its badge. Spinner strictly for app-work:
                // `.sent` (chain's side) and `.waitsOn`/`.readyToSend` stay static.
                if step.state == .preparing {
                    ZStack {
                        Circle()
                            .fill(Design.Text.primary.color(colorScheme))
                            .frame(width: 24, height: 24)
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.6)
                    }
                    .frame(width: 24, height: 24)
                } else {
                    MigrationStepBadge(number: step.index + 1, style: badgeStyle(for: step.state))
                }

                if !isLast {
                    Rectangle()
                        .fill(Design.Surfaces.strokePrimary.color(colorScheme))
                        .frame(width: 2, height: 20)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localizable: .migrationPrepareTransactionNOfM(step.index + 1, steps.count)))
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                // MOB-1466: `.plan`, not `.inPrefixed` — committal phrasing, matching the Transfer
                // Plan screen this sheet was first built for.
                //
                // NOW CONDITIONAL (field, 2026-08-03). The line used to render unconditionally, on
                // the assumption recorded here that the sheet "only ever opens from the pre-commit
                // Transfer Plan screen" — where every step is still ahead, so a forward ETA is
                // always meaningful. That assumption stopped holding the moment this sheet was also
                // wired behind the Migration Progress screen's disclosure, one day before a
                // screenshot showed "Starts right away" beneath a green checkmark labelled "Done".
                //
                // A finished step has no forward time (`minutesFromNow == nil`) and gets no line.
                // Its trailing "Done" already says everything true about it.
                // MOB-1466: `hasForwardTime` decides whether a line exists at all; the caption then
                // decides what it says — a real ETA, or "Recomputing ETA…" when the tip is unknown.
                // A finished step stays silent either way: its green check and "Done" are the
                // statement, and "Recomputing" over them would be a fresh lie in place of the old one.
                if step.hasForwardTime {
                    Text(MigrationETA.caption(minutesFromNow: step.minutesFromNow, phrasing: .plan))
                        .zFont(size: 12, style: Design.Text.tertiary)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 8)

            Text(Self.stateCaption(for: step.state))
                .zFont(size: 12, style: Design.Text.tertiary)
                .multilineTextAlignment(.trailing)
                .padding(.top, 2)
        }
        .padding(.bottom, isLast ? 0 : 4)
    }

    private func badgeStyle(for state: MigrationPrepareBalanceRow.State) -> MigrationStepBadge.Style {
        switch state {
        case .done:
            return .sent
        case .sent:
            // R11/Andrea's ladder: check-shaped because it IS sent, not green because the wallet
            // has not counted it — the same `.neutral` check the timeline's confirming rows wear.
            return .neutral
        case .readyToSend, .preparing:
            return .active
        case .scheduled, .waitsOn:
            // A future turn and a dependency wait are the same visual weight: nothing is
            // happening yet, and nothing needs to.
            return .pending
        case .invalid:
            // The amber exclamation the timeline already uses for invalid/expired rows — the one
            // badge that says "you have to do something", which is exactly this state's meaning.
            return .warning
        }
    }

    /// The trailing status text. `internal static` so it can be table-tested without a view host —
    /// the dependency-list phrasing (singular / "1 & 2" / "1, 2 & 3") is the only real logic here.
    static func stateCaption(for state: MigrationPrepareBalanceRow.State) -> String {
        switch state {
        case .done:
            return String(localizable: .migrationPrepareStateDone)
        case .readyToSend:
            return String(localizable: .migrationPrepareStateReady)
        case .scheduled:
            // The time line under the row's title carries the WHEN ("Starts in ~12 min");
            // this trailing word only names the state.
            return String(localizable: .migrationPrepareStateScheduled)
        case .sent:
            // The shared one-word caption Andrea's ladder gave the whole on-chain span
            // (`migrationStatus.sent`) — one key, every surface.
            return String(localizable: .migrationStatusSent)
        case .preparing:
            return String(localizable: .migrationPrepareStatePreparing)
        case .invalid:
            return String(localizable: .migrationPrepareStateInvalid)
        case .waitsOn(let steps):
            let sorted = steps.sorted()
            guard let last = sorted.last else {
                // "Waits on nothing" is not an actionable state; fall back to the in-flight caption
                // rather than rendering an empty trailing column.
                return String(localizable: .migrationPrepareStatePreparing)
            }
            guard sorted.count > 1 else {
                return String(localizable: .migrationPrepareWaitsOnStep(last))
            }
            let leading = sorted.dropLast().map(String.init).joined(separator: ", ")
            return String(localizable: .migrationPrepareWaitsOnSteps("\(leading) & \(last)"))
        }
    }
}

// MARK: - Previews

#Preview("Four steps") {
    MigrationPrepareBalanceSheet(
        steps: MigrationPrepareBalanceRow.interimLadder(count: 4),
        amountBeingSplit: Zatoshi(1_245_000_000),
        gotItTapped: { }
    )
    .screenHorizontalPadding()
}

/// The design's own step 3 — a dependency naming two predecessors — plus a completed first step.
#Preview("Mixed states") {
    MigrationPrepareBalanceSheet(
        steps: [
            // `nil`, not 0 — a done step states no forward time, and this preview is where that
            // renders: one row with no second line, three with one.
            MigrationPrepareBalanceRow(id: "0", index: 0, state: .done, minutesFromNow: nil),
            MigrationPrepareBalanceRow(id: "1", index: 1, state: .readyToSend, minutesFromNow: 0),
            MigrationPrepareBalanceRow(id: "2", index: 2, state: .waitsOn([1, 2]), minutesFromNow: 120),
            MigrationPrepareBalanceRow(id: "3", index: 3, state: .waitsOn([3]), minutesFromNow: 180)
        ],
        amountBeingSplit: Zatoshi(1_245_000_000),
        gotItTapped: { }
    )
    .screenHorizontalPadding()
}

/// nuttycom's shape (2026-08-07): a run whose split is far longer than the sheet was drawn for.
/// The ladder scrolls inside its card; the total and "Got it" stay reachable.
#Preview("Long ladder (104 steps)") {
    MigrationPrepareBalanceSheet(
        steps: MigrationPrepareBalanceRow.interimLadder(count: 104),
        amountBeingSplit: Zatoshi(1_245_000_000),
        gotItTapped: { }
    )
    .screenHorizontalPadding()
}

#Preview("Unknown total") {
    MigrationPrepareBalanceSheet(
        steps: MigrationPrepareBalanceRow.interimLadder(count: 2),
        amountBeingSplit: nil,
        gotItTapped: { }
    )
    .screenHorizontalPadding()
}
