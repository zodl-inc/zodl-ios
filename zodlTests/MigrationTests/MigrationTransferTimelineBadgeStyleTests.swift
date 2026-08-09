//
//  MigrationTransferTimelineBadgeStyleTests.swift
//  zodlTests
//
//  Pins the badge a timeline row gets — `MigrationTransferTimeline.badgeStyle(for:)`.
//
//  The rule this file exists for: A SPLIT ROW IS IDENTIFIED BY ITS GLYPH, NEVER BY A NUMBER. The
//  numbering in the migration timelines belongs to the transfers ("Transfer 1", "Transfer 2", …); a
//  "Split Balance" row is the preparation that comes BEFORE them, so a step number on it claims it
//  is transfer N when it is not one at all.
//
//  Field-caught: a split row rendered a bare "1". The rule was there, but scoped to
//  `index == 0 && (status == .pending || status == .active)`, so three ordinary situations fell
//  through to the transfer mapping — and every style they landed on draws `Text("\(number)")`:
//
//    - `.confirming` -> `.neutral`, which drew a CHECKMARK when the special case was written and
//      has drawn the step number since MOB-1466 dropped it. The narrowing outlived its premise.
//    - `.overdue`    -> `.active`, the dark numbered circle.
//    - index >= 1    -> whatever the status said, for the second and later rows of a balance that
//      genuinely splits in several transactions (D14).
//
//  So the cases below are written per-status and at more than one index deliberately: the bug was
//  never in the happy path that a `.pending` first split row exercises, and a test that only
//  covered that path would have passed throughout.
//
//  `badgeStyle(for:)` is `static` on the view for these tests. It is a pure
//  `MigrationTransferRow -> MigrationStepBadge.Style` function that reads no view state, and it was
//  `private` while the regression shipped — untestable by construction.
//

import SwiftUI
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationTransferTimelineBadgeStyleTests {
    /// The styles that draw `Text("\(number)")` rather than a glyph — see `MigrationStepBadge.body`.
    /// A split row landing on ANY of these is the bug, whichever one it is, so the split cases below
    /// assert against the whole set instead of naming the single style they happened to regress to.
    private static let numberedStyles: [MigrationStepBadge.Style] = [.active, .pending, .neutral]

    private static func row(
        _ status: MigrationTransferRow.Status,
        kind: MigrationTransferRow.Kind,
        index: Int = 0
    ) -> MigrationTransferRow {
        MigrationTransferRow(
            id: "row-\(index)",
            index: index,
            amount: nil,
            status: status,
            hoursFromNow: 0,
            kind: kind
        )
    }

    // MARK: - Split rows

    /// The core rule, across every non-terminal status AND at an index past the first — the two axes
    /// the old `index == 0 && (.pending || .active)` guard got wrong. The four statuses are listed
    /// literally rather than derived, so that adding a `MigrationTransferRow.Status` case is a
    /// deliberate decision about which side of the terminal/non-terminal line it falls on.
    @Test(
        arguments: [
            MigrationTransferRow.Status.pending, .active, .confirming, .overdue
        ], [0, 1, 3]
    )
    func splitRowUsesGlyphWhileItHasWorkToDo(status: MigrationTransferRow.Status, index: Int) {
        let style = MigrationTransferTimeline.badgeStyle(for: Self.row(status, kind: .splitBalance, index: index))

        #expect(style == .splitBalance)
        #expect(!Self.numberedStyles.contains(style))
    }

    /// A split that has genuinely completed takes the ordinary green check — the one thing the glyph
    /// must NOT swallow, because "done" is the only state whose whole job is to look done.
    @Test
    func sentSplitRowKeepsTheGreenCheck() {
        #expect(MigrationTransferTimeline.badgeStyle(for: Self.row(.sent, kind: .splitBalance)) == .sent)
    }

    /// The other terminal outcome: a split that cannot proceed reports as a problem, not as a step
    /// still quietly in progress.
    @Test(arguments: [MigrationTransferRow.Status.invalid, .expired])
    func failedSplitRowKeepsTheWarning(status: MigrationTransferRow.Status) {
        #expect(MigrationTransferTimeline.badgeStyle(for: Self.row(status, kind: .splitBalance)) == .warning)
    }

    // MARK: - Transfer rows

    /// The other half of the contract: widening the split rule must not have leaked into the
    /// transfer mapping. No transfer row is ever `.splitBalance`, at any status.
    @Test(
        arguments: [
            (MigrationTransferRow.Status.sent, MigrationStepBadge.Style.sent),
            (.confirming, .neutral),
            (.active, .active),
            (.overdue, .active),
            (.pending, .pending),
            (.invalid, .warning),
            (.expired, .warning)
        ]
    )
    func transferRowFollowsTheStatusMapping(status: MigrationTransferRow.Status, expected: MigrationStepBadge.Style) {
        #expect(MigrationTransferTimeline.badgeStyle(for: Self.row(status, kind: .transfer)) == expected)
        #expect(MigrationTransferTimeline.badgeStyle(for: status) == expected)
    }

    /// Index carries no meaning for a transfer row's badge — only its status does. Pinned because the
    /// rule this file fixes was itself an index special case, and the previous one (MOB-1513's
    /// row-0 relabel) had to be retired for the same reason.
    @Test(arguments: [0, 1, 7])
    func transferRowBadgeIgnoresIndex(index: Int) {
        #expect(MigrationTransferTimeline.badgeStyle(for: Self.row(.pending, kind: .transfer, index: index)) == .pending)
    }

    // MARK: - Connector segments

    /// The trailing connector is derived from the row's badge style, so it inherits the rule above.
    /// Field-caught from a screenshot of Confirm Transfer Plan: a BLACK segment under Split Balance
    /// while every transfer below it was gray. `connectorColor` took a bare `Status` and called the
    /// status-only `badgeStyle` overload, discarding `kind` — so an `.active` split resolved as an
    /// active TRANSFER and took `Design.Text.primary`.
    ///
    /// `hasSentRow: false` is the condition that made it dark; with a sent row present the old code
    /// would have returned gray by luck, which is exactly why this pins the false case.
    ///
    /// `@MainActor` because `connectorColor` is a static on a `View` and so inherits the main actor,
    /// while `Colorable` is not `Sendable` — reading the result from a nonisolated test would cross
    /// an actor boundary. The badge tests above need no annotation: `MigrationStepBadge.Style` is a
    /// plain enum and crosses freely.
    @MainActor
    @Test(
        arguments: [
            MigrationTransferRow.Status.pending, .active, .confirming, .overdue
        ]
    )
    func splitRowConnectorIsAlwaysGrayWhileItHasWorkToDo(status: MigrationTransferRow.Status) {
        let color = MigrationTransferTimeline.connectorColor(
            for: Self.row(status, kind: .splitBalance),
            hasSentRow: false
        )

        #expect(color.color(.light) == Design.Surfaces.strokePrimary.color(.light))
        #expect(color.color(.dark) == Design.Surfaces.strokePrimary.color(.dark))
    }

    /// The other half: the dark segment MOB-1487 introduced still belongs to the active TRANSFER,
    /// and still switches to gray once any transfer has sent. Widening the split rule must not have
    /// flattened this.
    @MainActor
    @Test(arguments: [false, true])
    func activeTransferConnectorStaysDarkOnlyUntilSomethingHasSent(hasSentRow: Bool) {
        let color = MigrationTransferTimeline.connectorColor(
            for: Self.row(.active, kind: .transfer),
            hasSentRow: hasSentRow
        )
        let expected: Colorable = hasSentRow ? Design.Surfaces.strokePrimary : Design.Text.primary

        #expect(color.color(.light) == expected.color(.light))
    }

    /// A split that has sent takes the green segment like any completed row — the glyph rule governs
    /// what the badge looks like, not whether completion still reads as completion.
    @MainActor
    @Test
    func sentSplitRowConnectorGoesGreen() {
        let color = MigrationTransferTimeline.connectorColor(
            for: Self.row(.sent, kind: .splitBalance),
            hasSentRow: false
        )

        #expect(color.color(.light) == Design.Utility.SuccessGreen._600.color(.light))
    }

    /// Guards the assertions above from becoming vacuous: if these two tokens ever resolved to the
    /// same value, every connector test would pass regardless of the mapping.
    @Test
    func darkAndGrayConnectorTokensAreActuallyDifferent() {
        #expect(Design.Text.primary.color(.light) != Design.Surfaces.strokePrimary.color(.light))
    }
}
