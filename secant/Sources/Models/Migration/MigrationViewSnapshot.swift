//
//  MigrationViewSnapshot.swift
//  Zodl
//
//  THE SINGLE SOURCE OF TRUTH for what a migration looks like right now (MOB-1466).
//
//  WHY THIS EXISTS. The smart banner and the migration screen each derived migration state
//  independently, from the same manager, at different moments. That is two clocks, and two clocks
//  produce exactly what the field reported all week: the banner shows A, the screen has not caught
//  up and shows nothing; the screen resolves to B; back on the banner it is still A until it
//  re-derives. Neither surface is wrong — they are at different points in time, and no amount of
//  per-surface patching fixes that, because there is nothing to fix in either one.
//
//  Lukas's framing, 2026-08-03, and it is the correct one: there is code, logic, persistence and
//  in-memory state that KEEPS the data; the banner and the screen are just renderings of it. One
//  derivation, many observers, and a kick from anywhere to say "recompute".
//
//  THE INVARIANT THIS BUYS, and the reason the pool header waited for it: every observer sees one
//  coherent snapshot. Pool values still come from the wallet summary while timeline rows describe
//  migration progress; neither is derived from or used to correct the other.
//
//  Validated before building: on the 08-02 field wallet the DONE crossings summed to 949,000,000
//  zatoshi and the Ironwood pool held 949,000,000 — exact. The accounting was never the problem;
//  the *timing* was, and that is what one snapshot removes.
//
//  R9 + R11 (2026-08-03, final): the header's bubbles show `orchardRemaining`/`ironwoodHeld` — the
//  wallet's REAL per-pool balances, the same chain-derived source the home balance sheet reads
//  ("if pool X has Y zec, must use Y"; derived green-sums were rejected for contradicting the home
//  sheet). Timeline status is deliberately independent: the pinned SDK stores wallet accounting at
//  broadcast, while a row renders Done only after the wallet observes it mined (`.sent` versus
//  `.confirming`). A pool may therefore advance before its row turns green, without either value
//  being rewritten to manufacture agreement.
//

import Foundation
import ZcashLightClientKit

/// One coherent answer to "what does this migration look like", produced by a single derivation.
///
/// Grows as the banner and the screen migrate onto it — today it carries the pool flow the header
/// needs. Every field must come from the SAME derivation pass; adding one that is fetched
/// separately would reintroduce the second clock this type exists to remove.
struct MigrationViewSnapshot: Equatable, Sendable {
    /// Orchard value still in the source pool — the SOURCE bubble. This includes advisory-locked
    /// inputs of proved transactions; those funds remain in Orchard until the wallet transaction
    /// is stored at the broadcast seam.
    let orchardRemaining: Zatoshi

    /// Ironwood value the wallet currently holds — the DESTINATION bubble.
    ///
    /// Read from the wallet's own per-pool balance, NOT inferred from the transfer rows. The two
    /// agreeing is the point; deriving one from the other would make the agreement vacuous and hide
    /// exactly the lag we are trying to surface.
    let ironwoodHeld: Zatoshi

    /// Σ of the transfers the timeline shows as done (`.sent` rows only; `.confirming` rows are
    /// excluded). This is migration progress, not an input to pool accounting.
    let movedByDoneTransfers: Zatoshi

    /// How many transfers the timeline shows as done (wallet-confirmed, R11), and out of how many.
    let doneTransfers: Int
    let totalTransfers: Int

    /// R13 Brick 2: the transfer rows themselves — THE list every timeline renders, carried here so
    /// the status screen stops pulling `migrationTransfers()` on its own clock (the 30-second pulse
    /// existed precisely because that pull had no push). Stamped with the live submit overlay at
    /// build time; the broadcast session republishes at both edges, so a stale "Sending now" can
    /// never outlive the submit that raised it.
    let transfers: [MigrationTransferRow]

    /// R13 Brick 2: the run's summary (duration estimate, counts, dust) from the SAME pass — the
    /// status screen's `totalDurationHours` and the coordinator's hydrations read it here instead
    /// of a second `migrationSummary()` call at a second moment.
    let summary: MigrationSummary

    /// R13 Brick 2b: the banner's ladder position, decided IN THE SAME PASS as the rows it
    /// describes. The banner's derivation was the last second-pass truth reader — its own mirror
    /// row derivation at its own moment, the original two-clocks shape (R2's "one position, one
    /// value, two renderings" is finally executable: this IS the one value). `nil` means "no
    /// migration banner" (pre-activation, no account, offer held while not caught up, no run).
    let banner: MigrationBannerVariant?

    /// The split's parts, as the engine reports them. Carried here — rather than fetched again by
    /// the sheet — because the "Show details" sheet is the FOURTH observer of this state (banner,
    /// timeline, pool header, sheet) and a fourth independent read is a fourth clock.
    let preparations: [MigrationTransferRow]

    /// Σ of ALL transfer amounts in the plan — a RECONCILIATION figure for the POOLS trace (plan vs
    /// green vs pools), nil when any row's amount is unknown (W1 fallback).
    ///
    /// NOT rendered anywhere (R9, amended 2026-08-03): an earlier cut derived the header's bubbles
    /// from this (X = plan − Σ green), and Lukas rejected it before the first test — "it should not
    /// sum up numbers floating in memory or some 'future values'.. if pool X has Y zec, must use
    /// Y". Bubbles labelled with POOL NAMES must show the same chain-derived values the home
    /// balance sheet shows, or the app contradicts itself between two screens.
    let planTotal: Zatoshi?

    /// R13 Brick 2 (R7 §G): whether the account's most recent broadcast failure was a mid-run Tor
    /// hold — the `.resume` presentation's Tor footer, read in the same pass as everything else.
    let isTorHoldActive: Bool

    /// MOB-1497 (T5) / E2E harness F#9 (2026-08-04): TRUE while a HEADLESS broadcast attempt has
    /// routed `.torFirstRunChoice` (R14) and no surface has resolved the choice. The Status screen
    /// presents the designed first-run Tor sheet from exactly this flag; the banner joins it to
    /// `isTorHoldActive` for its Tor line. Cleared by resolution (`resolveMigrationTorPrompt`), a
    /// landed broadcast (`markHadBroadcast`), or run-end (`clear`). Without this flag the scheduled
    /// lane discarded the routed choice and a Tor-unreachable migration stalled silently forever.
    let needsTorFirstRunChoice: Bool

    /// Whether a migration transaction is ON THE WIRE as this snapshot is taken — see
    /// `MigrationTransferRow.isSubmitting`.
    ///
    /// Lives here rather than being read separately by each surface for the reason everything else
    /// does: the banner says "keep Zodl open" and the timeline spins its row from ONE fact, so they
    /// cannot contradict each other for the ~7 s it is true. The last time these were separate the
    /// banner span a spinner over a list that showed none, which is the complaint that started this
    /// whole pass.
    let isSubmitting: Bool

    /// The app-open that produced this. `nil` outside a session.
    ///
    /// Freshness is ONE stamp on ONE value now, consumed identically by every observer, rather than
    /// each surface deciding for itself. That is the simplification the single source buys.
    let sessionOrdinal: Int?


    /// Whether this snapshot was produced by the live app-open.
    func isFresh(currentSessionOrdinal: Int?) -> Bool {
        guard let sessionOrdinal, let currentSessionOrdinal else { return false }
        return sessionOrdinal == currentSessionOrdinal
    }

    /// TRACE-ONLY diagnostic (R11 demoted it from render gate): whether the destination pool's
    /// balance covers the Σ of wallet-confirmed transfers.
    ///
    /// Wallet accounting may advance at broadcast before a row becomes Done, so this is a coverage
    /// check rather than an equality claim. It can legitimately go false when the user spends
    /// Ironwood funds mid-migration (the balance is current holdings; the checkmarks are history),
    /// which is why it must never gate rendering.
    var isPoolFlowSettled: Bool {
        ironwoodHeld >= movedByDoneTransfers
    }

    /// Whether the split detail is worth offering. A one-part split has no detail to show — the
    /// timeline row already says everything the sheet would.
    var hasSplitDetail: Bool { preparations.count > 1 }

    static let empty = MigrationViewSnapshot(
        orchardRemaining: .zero,
        ironwoodHeld: .zero,
        movedByDoneTransfers: .zero,
        doneTransfers: 0,
        totalTransfers: 0,
        transfers: [],
        summary: MigrationSummary.zero,
        banner: nil,
        preparations: [],
        planTotal: nil,
        isTorHoldActive: false,
        needsTorFirstRunChoice: false,
        isSubmitting: false,
        sessionOrdinal: nil,
    )
}
