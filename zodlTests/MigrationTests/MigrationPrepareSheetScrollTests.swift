//
//  MigrationPrepareSheetScrollTests.swift
//  zodlTests
//
//  The "Prepare Your Balance" sheet's scrolling window (MOB-1466, Lukas 2026-08-07).
//
//  THE FIELD BUG, from nuttycom's wallet: a run whose split is 104 steps. `zashiSheet` measures its
//  content and hands that height to `.presentationDetents([.height(…)])`; UIKit clamps a detent
//  taller than the screen, but the `VStack` still lays out at its ideal ~5,000 pt and gets CENTRED
//  in the clamped container. The screenshot showed rows 45–59 of 104 — dead centre of the ladder —
//  with the sheet's title clipped off the top and the total and "Got it" clipped off the bottom.
//  Unreadable, and undismissable by its own CTA.
//
//  WHY A FIXED WINDOW AND NOT A MEASUREMENT. `zashiSheet` re-derives its detent whenever the
//  measured content height changes, and on the pre-iOS 26 path it re-keys the subtree by that
//  height (`.id(sheetHeight)`). A window that measured itself from inside the sheet would reset its
//  own `@State` on every re-key and oscillate. The threshold is Lukas's own ("<5 splits = keep
//  .zashiSheet to resolve its height but >=5 splits, set max height").
//

import Foundation
import Testing
@testable import zodl_internal

@Suite struct MigrationPrepareSheetScrollTests {
    /// Short ladders are untouched — the designed sheet (5207:16024) draws four steps and must keep
    /// sizing itself exactly as it did before this fix existed. `nil` is "no window", not "zero".
    @Test func shortLaddersSizeThemselves() {
        for count in 0...5 {
            #expect(
                MigrationPrepareBalanceSheet.scrollWindowHeight(forStepCount: count) == nil,
                "\(count) steps must size the sheet, not scroll"
            )
        }
    }

    /// Everything above the threshold gets the same fixed window — including the 104 that started
    /// this. The window does NOT grow with the count: that is the whole point, since growing is
    /// what produced a 5,000 pt VStack.
    @Test func longLaddersGetTheWindow() {
        for count in [6, 7, 12, 40, 104, 500] {
            #expect(
                MigrationPrepareBalanceSheet.scrollWindowHeight(forStepCount: count) == 240,
                "\(count) steps must scroll inside a fixed window"
            )
        }
    }

    /// NO SLACK, BY CONSTRUCTION. The first scrolling case is 6 steps; at ~48 pt per row (badge 24 +
    /// connector 20 + gap 4) that is ~288 pt of content inside a 240 pt window. So every count the
    /// window applies to already overflows it, and the scroller can never render short content in a
    /// tall frame with dead space under the last row.
    ///
    /// If someone raises the threshold or lowers the window and breaks that relationship, this is
    /// the test that says so.
    @Test func theWindowIsAlwaysFullWhenItApplies() {
        let firstScrollingCount = 6
        let approximateRowHeight = 48.0

        #expect(MigrationPrepareBalanceSheet.scrollWindowHeight(forStepCount: firstScrollingCount - 1) == nil)

        guard let window = MigrationPrepareBalanceSheet.scrollWindowHeight(forStepCount: firstScrollingCount) else {
            Issue.record("the first scrolling count must have a window")
            return
        }
        #expect(Double(firstScrollingCount) * approximateRowHeight > window)
    }

    /// The window has to leave the sheet's own chrome on screen on the SMALLEST supported device —
    /// title, body, card heading, divider, total, CTA and drag indicator run to roughly 340 pt, and
    /// an iPhone SE sheet has about 640 pt to give. This pins the headroom the number was chosen
    /// for, so a later "let's show more rows" change has to confront the arithmetic.
    @Test func theWindowLeavesRoomForTheSheetsChrome() {
        guard let window = MigrationPrepareBalanceSheet.scrollWindowHeight(forStepCount: 104) else {
            Issue.record("104 steps must have a window")
            return
        }
        let approximateChrome = 340.0
        let smallestSheetHeight = 640.0

        #expect(window + approximateChrome <= smallestSheetHeight)
    }
}
