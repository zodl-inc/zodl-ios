//
//  MigrationCheckingStatusTests.swift
//  zodlTests
//
//  `MigrationBannerVariant.checkingStatus` — the state that admits the app has not re-established
//  the world yet (MOB-1466).
//
//  WHY THESE TESTS EXIST AS CONTRACT TESTS. Every property pinned here was a deliberate decision
//  that a later reader would otherwise "tidy up" into a bug:
//
//  - `info` is the real checking copy, not a blank placeholder (GROUND_RULES D1, Figma 5679-8225):
//    checking is the SUBTITLE under the standing "Migration Progress" title, so it belongs in
//    `info`, not folded into `title` with an empty `info` and a reserved-blank-line hack. Resist
//    reverting this to `""` — that layout was the pre-D1 workaround, not the design.
//  - grouping with `.preparing`/`.transferSending` for the spinner is a RULE ("the spinner is
//    reserved for states where something is actually spinning"), not a coincidence — here the work
//    is the re-derivation itself.
//
//  STILL OWED, and deliberately not faked here: the reducer-level dwell state machine
//  (raise-on-foreground, hold-during-dwell, apply-after, floor-not-timeout, never-manufacture).
//  Those need a `TestStore` over `SmartBanner`; `MigrationTickDriverTests` is the shape to mirror.
//  Asserting them at this layer would prove nothing about the reducer and would read as coverage
//  that does not exist.
//

import Foundation
import Testing
import ComposableArchitecture
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationCheckingStatusTests {
    /// BUTTONLESS AND UNREACHABLE (Lukas, 2026-08-07 — new team agreement, same frame 5679-8225):
    /// "remove MORE button and disable going into the migration screen completely… it would render
    /// stale data anyway."
    ///
    /// This pin has now flipped twice, so it records WHY rather than just WHAT. The 2026-08-03
    /// round argued the CTA was safe because "More" promises a DESTINATION, not an OUTCOME —
    /// correct about the wording, and irrelevant: the destination itself is stale, because the
    /// screen paints the previous session's snapshot until this session's verdict lands. Never-lie
    /// (AUD-2b) withholds the door, not the label.
    @Test func checkingIsButtonless() {
        #expect(!MigrationBannerVariant.checkingStatus.showsButton)
    }

    /// The button is only half the rule — the banner's whole surface carries a tap gesture, so
    /// hiding the CTA without closing that gesture would leave the stale screen one tap away.
    /// `smartBannerContentTapped` must not emit `migrationScreenRequested` while checking.
    @MainActor @Test func checkingTapDoesNotOpenTheMigrationScreen() async {
        var state = SmartBanner.State()
        state.priorityContent = .priorityMigration
        state.migrationBannerVariant = .checkingStatus
        let store = TestStore(initialState: state) { SmartBanner() }

        // Exhaustive on purpose: an unasserted `.migrationScreenRequested` fails the test, which
        // is the whole point of the pin.
        await store.send(.smartBannerContentTapped)
    }

    /// The complement, so the guard can never widen into "migration is never tappable": the same
    /// tap on any other migration variant still opens the screen.
    @MainActor @Test func nonCheckingTapStillOpensTheMigrationScreen() async {
        var state = SmartBanner.State()
        state.priorityContent = .priorityMigration
        state.migrationBannerVariant = .idle
        let store = TestStore(initialState: state) { SmartBanner() }

        await store.send(.smartBannerContentTapped)
        await store.receive(\.migrationScreenRequested)
    }

    /// The dwell FLOOR is the ratified half second (Lukas, 2026-08-06 — Figma-parity audit, flow
    /// SB): "at least 0.5 s so there is no 50 ms flicker." An engineering pass measured it down to
    /// 0.2 s once (2026-08-03), optimising spinner time — which was never the goal. This pin makes
    /// the next measure-down a deliberate act with a failing test attached, exactly as
    /// `MigrationTickIntervalLivePin` does for the tick interval.
    ///
    /// Renamed 2026-08-07 (SB-D1): the constant now floors EVERY migration banner state, not just
    /// checking — one number, because the rule Lukas stated is one rule.
    @Test func checkingFloorIsTheRatifiedHalfSecond() {
        #expect(SmartBanner.Constants.migrationMinimumDwell >= 0.5)
    }

    /// THE RATIFIED IDLE (Lukas, 2026-08-06 — flow ID): engine `.waiting` ⇒ `.idle` ⇒ the designed
    /// notify line (Figma 35439/10639) under the standing progress title. The full-canvas walk had
    /// left `migrationBanner.idleInfo` orphaned pending exactly this trigger rule; the rule now
    /// exists, so this pin replaces the old "counts is the universal idle line" reading.
    @Test func idleRendersTheRatifiedNotifyLine() {
        #expect(MigrationBannerVariant.idle.title == String(localizable: .migrationBannerProgressTitle))
        #expect(MigrationBannerVariant.idle.info == String(localizable: .migrationBannerIdleInfo))
        #expect(MigrationBannerVariant.idle.showsButton)
        #expect(MigrationBannerVariant.idle.percent == nil)
        #expect(!MigrationBannerVariant.idle.isPreparingVariant)
    }

    /// THE BANNER MAP (Lukas, 2026-08-06): idle2 — the at-open counts idle — renders EXACTLY the
    /// counts line the `.inProgress` family renders (`5139:34962`'s own copy), under the standing
    /// progress title, with the ring fraction the rows imply. Distinct case, identical costume.
    @Test func idleCountsRendersTheCountsLine() {
        let idle2 = MigrationBannerVariant.idleCounts(done: 1, total: 6)
        #expect(idle2.title == String(localizable: .migrationBannerProgressTitle))
        #expect(idle2.info == MigrationBannerVariant.inProgress(done: 1, total: 6, round: nil, totalRounds: nil).info)
        #expect(idle2.percent == 17)
        #expect(!idle2.isPreparingVariant)
    }

    /// THE BANNER MAP's idle1 rule as amended 2026-08-08 (Andrea via Lukas), pinned on the
    /// store's single entry point: `.idle` (the notify line) is TERMINATION — only a finished
    /// PREPARING converts, it is sticky across re-derivations, and nothing else (a finished
    /// SENDING, checking, counts, required, a fresh open) can produce it. A finished SENDING
    /// stays generic — "N of M done" — because the notify promise is about the NEXT send, and
    /// only the prepare-then-wait rhythm has one to promise. The split phase's resting counts
    /// arrive as `.inProgress`, which is deliberately NOT convertible — idle copy over the split
    /// was the 08-01 false promise.
    @Test func idleTerminationEntersOnlyFromPendingStates() {
        let quiet = MigrationBannerVariant.idleCounts(done: 2, total: 6)

        // Preparing → finished ⇒ idle1; sending → finished stays the generic counts (idle2).
        #expect(SmartBanner.resolvingIdleTermination(quiet, previous: .transferSending(number: 2)) == quiet)
        #expect(SmartBanner.resolvingIdleTermination(quiet, previous: .preparing(done: 1, total: 6)) == .idle)
        // Sticky for the rest of the session.
        #expect(SmartBanner.resolvingIdleTermination(quiet, previous: .idle) == .idle)
        // At-open and non-pending predecessors pass the counts through untouched.
        #expect(SmartBanner.resolvingIdleTermination(quiet, previous: .checkingStatus) == quiet)
        #expect(SmartBanner.resolvingIdleTermination(quiet, previous: nil) == quiet)
        #expect(SmartBanner.resolvingIdleTermination(quiet, previous: .inProgress(done: 2, total: 6, round: nil, totalRounds: nil)) == quiet)
        #expect(SmartBanner.resolvingIdleTermination(quiet, previous: .required) == quiet)
        // Only the quiet answer converts — a pending or counts variant is never rewritten.
        #expect(
            SmartBanner.resolvingIdleTermination(.preparing(done: 1, total: 6), previous: .transferSending(number: 2))
                == .preparing(done: 1, total: 6)
        )
        #expect(
            SmartBanner.resolvingIdleTermination(.inProgress(done: 2, total: 6, round: nil, totalRounds: nil), previous: .preparing(done: 1, total: 6))
                == .inProgress(done: 2, total: 6, round: nil, totalRounds: nil)
        )
    }

    /// Every variant EXCEPT `.checkingStatus` offers its action. Written as an enumeration rather
    /// than a spot check so that hiding a button anywhere else becomes a deliberate act with a
    /// failing test attached — the exemption is one named case, not a pattern to copy.
    @Test func everyVariantOffersItsAction() {
        let actionable: [MigrationBannerVariant] = [
            .required,
            .inProgress(done: 1, total: 4, round: nil, totalRounds: nil),
            .preparing(done: 0, total: 4),
            .nextRoundRequired(round: 2, totalRounds: 3),
            .transferSending(number: 1),
            .idleCounts(done: 1, total: 4),
            .updatePlan,
            .transfersExpired(first: 1, last: 2),
            .complete,
            .idle
        ]

        for variant in actionable {
            #expect(variant.showsButton, "\(variant) must keep its button")
        }
    }

    /// The second line is the checking copy itself (GROUND_RULES D1, Figma 5679-8225): checking is
    /// the SUBTITLE under the standing "Migration Progress" title, not an empty line reserved to
    /// hold the banner's height.
    @Test func checkingSubtitleIsTheCheckingCopy() {
        let info = MigrationBannerVariant.checkingStatus.info

        #expect(info == String(localizable: .migrationBannerCheckingInfo))
        #expect(!info.isEmpty)
    }

    /// It does say something, though — silence would be its own kind of lie. Since GROUND_RULES D1
    /// (Figma 5679-8225), that something is the standing "Migration Progress" title shared with
    /// `.inProgress`/`.preparing` — the checking-specific copy now lives in `info` instead (see
    /// `checkingSubtitleIsTheCheckingCopy`). "Migration Progress" still isn't a fresh offer or a
    /// finished run, so these assertions hold unchanged.
    @Test func checkingStillNamesItself() {
        let title = MigrationBannerVariant.checkingStatus.title

        #expect(!title.isEmpty)
        #expect(title != MigrationBannerVariant.required.title, "must not read as a fresh offer")
        #expect(title != MigrationBannerVariant.complete.title, "must not read as a finished run")
    }

    /// A progress ring would claim a completion fraction the app has not established yet, so the
    /// percent must stay nil — `.inProgress` is the only variant that owns a number.
    @Test func checkingClaimsNoProgressFraction() {
        #expect(MigrationBannerVariant.checkingStatus.percent == nil)
    }

    /// Equatable is what the store's hold-and-apply logic compares on; a variant that failed to
    /// distinguish itself would make the dwell untestable and the flicker trace lie.
    @Test func checkingIsDistinctFromEveryOtherState() {
        #expect(!MigrationBannerVariant.checkingStatus.isPreparingVariant)
        #expect(MigrationBannerVariant.checkingStatus != .required)
        #expect(MigrationBannerVariant.checkingStatus != .complete)
        #expect(MigrationBannerVariant.checkingStatus == .checkingStatus)
    }
}
