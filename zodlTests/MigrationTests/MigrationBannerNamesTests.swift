//
//  MigrationBannerNamesTests.swift
//  zodlTests
//
//  WHICH transfer the banner names — "Transfer N is ready" / "Transfer N is sending" (MOB-1466;
//  the waiting flavor retired with THE BANNER MAP, 2026-08-06 — the naming judgment these pin
//  survives on the remaining per-transfer arms). (the `.transferReady` pins were removed
//  2026-08-07 with the manual-tap send surface)
//
//  WHY THIS SUITE EXISTS, and why it is a different bug class from every other two-surface
//  disagreement in this pass. From ONE field log line:
//
//      BANNER → transferWaiting(number: 4)
//      ROWS: T1:done T2:done T3:done T4:broadcast T5:ready …
//
//  The timeline captioned T4 "Sent recently", off that same row's `isBroadcasting`. The banner
//  asked the user to send a transaction that was already on the network.
//
//  Every earlier disagreement was TWO CLOCKS: the same question answered at different moments, and
//  `MigrationViewSnapshot` fixed those by construction. This one is TWO VOCABULARIES. Both surfaces
//  read the same row, in the same pass, from the single source — and still contradicted each other,
//  because `nextTransferNumber` recognised two row states (sent / not sent) while the row model has
//  three: sent, SUBMITTED-AWAITING-MINING, and actually waiting on the user. A submitted row is
//  `.active`, so the two-state reading swept it up as "next".
//
//  One source of truth guarantees the readers see the same DATA. It cannot make them draw the same
//  CONCLUSION — that takes the derived judgment being shared too, not just the fields it is
//  computed from. These tests pin the judgment.
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationBannerNamesTests {
    private static func progress(completed: Int, total: Int) -> MigrationProgress {
        MigrationProgress(
            completedTransfers: completed,
            totalTransfers: total,
            remainingOrchard: Zatoshi(500_000_000),
            nextTransferReadyAtHeight: 3_000_000,
            isImmediate: false
        )
    }

    private static func row(
        index: Int,
        status: MigrationTransferRow.Status,
        isBroadcasting: Bool = false
    ) -> MigrationTransferRow {
        MigrationTransferRow(
            id: "\(index)",
            index: index,
            amount: Zatoshi(100_000_000),
            status: status,
            hoursFromNow: 0,
            isBroadcasting: isBroadcasting
        )
    }

    private static func variant(
        completed: Int,
        total: Int,
        rows: [MigrationTransferRow]
    ) -> MigrationBannerVariant? {
        MigrationDerivations.bannerVariant(
            isIronwoodActivated: true,
            state: .inProgress(progress(completed: completed, total: total)),
            orchardBalance: Zatoshi(500_000_000),
            isCompleteAcknowledged: false,
            isMigrationRemainderPending: false,
            transferRows: rows
        )
    }
}

/// H-FORK (Lukas, 2026-08-07): the Status header's paragraph is ONE stem with three tails, chosen
/// by the same `MigrationBannerVariant` the banner renders from. The stem is what makes the fork
/// legible as a fork rather than three unrelated sentences, so it is pinned: if someone edits one
/// variant's opening, this fails and they have to edit all three deliberately.
///
/// Pinned as full separate keys, not a stem plus a swapped verb — a verb slotted into a sentence
/// does not survive a language that reorders clauses, and a stem-plus-tail split hands translators
/// half-sentences and needs interpolation to dodge SwiftLint's `string_concatenation`.
@Suite struct MigrationStatusDescriptionForkTests {
    private static let idle = String(localizable: .migrationStatusDesc(6, 36, 3))
    private static let preparing = String(localizable: .migrationStatusDescPreparing(6, 36, 3))
    private static let broadcasting = String(localizable: .migrationStatusDescBroadcasting(6, 36, 3))

    /// The shared opening — counts, duration, remaining — is identical across all three.
    @Test func allThreeShareTheStem() {
        let stem = "Your balance is split into 6 transfers over ~36 hours. There are 3 remaining transfers."
        #expect(Self.idle.hasPrefix(stem))
        #expect(Self.preparing.hasPrefix(stem))
        #expect(Self.broadcasting.hasPrefix(stem))
    }

    /// Three DISTINCT tails: the fork exists precisely because these say different things about
    /// what the app is doing right now.
    @Test func eachVariantEndsDifferently() {
        #expect(Self.idle != Self.preparing)
        #expect(Self.idle != Self.broadcasting)
        #expect(Self.preparing != Self.broadcasting)
    }

    /// The two working states carry the keep-open ask; the idle one carries the notify promise and
    /// must NOT ask the user to stay — nothing is running for them to stay for.
    @Test func onlyTheWorkingVariantsAskToStayOpen() {
        #expect(Self.preparing.contains("Keep Zodl open"))
        #expect(Self.broadcasting.contains("Keep Zodl open"))
        #expect(!Self.idle.contains("Keep Zodl open"))
        #expect(Self.idle.contains("notify"))
    }
}

/// F6 (Lukas, 2026-08-07): the Status footer follows the BANNER, not a condition of its own —
/// "the info is tied to what banner says or is doing… the info should not have independent
/// conditions." Three sentences, one per state family. Pinned so the mapping cannot quietly
/// collapse back to one string the way it stood before today.
@Suite struct MigrationStatusFooterForkTests {
    private static let preparing = String(localizable: .migrationStatusFooterPreparing)
    private static let broadcasting = String(localizable: .migrationStatusFooterBroadcasting)
    private static let idle = String(localizable: .migrationStatusFooterIdle)

    @Test func theThreeSentencesAreDistinct() {
        #expect(Self.preparing != Self.broadcasting)
        #expect(Self.preparing != Self.idle)
        #expect(Self.broadcasting != Self.idle)
    }

    /// The two WORKING states warn that leaving pauses the run; the idle one must not — nothing is
    /// running to pause, and saying otherwise would make the warning meaningless where it matters.
    @Test func onlyTheWorkingSentencesWarnAboutLeaving() {
        #expect(Self.preparing.contains("pause if you leave"))
        #expect(Self.broadcasting.contains("pause if you leave"))
        #expect(!Self.idle.contains("pause if you leave"))
    }

    /// The footer no longer borrows the banner's terse line. That stand-in was correct in exactly
    /// two states and wrong in the rest, which is the defect this fork exists to close.
    @Test func noSentenceIsTheBorrowedBannerString() {
        let borrowed = String(localizable: .migrationBannerKeepOpenInfo)
        #expect(Self.preparing != borrowed)
        #expect(Self.broadcasting != borrowed)
        #expect(Self.idle != borrowed)
    }
}
