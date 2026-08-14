//
//  SmartBannerMigrationContent.swift
//  zodl
//
//  Ironwood migration content for the SmartBanner's `priorityMigration` case (MOB-1464), triggered
//  live via the `.evaluatePriorityMigration` walk step and the `migrationManager.stateEvents(_:)`
//  subscription (MOB-1466 — see SmartBannerStore.swift). `MigrationBannerVariant` is a pure, testable mapping
//  (see MigrationBannerVariantTests); `migrationContent()` mirrors `shieldingContent()`'s structure.
//

import SwiftUI
import ComposableArchitecture

enum MigrationBannerVariant: Equatable {
    case required
    /// The ACTIVE-arms counts render — the split phase between work bursts and the engine-complete
    /// window whose last rows are still confirming (R11). Renders the designed counts line
    /// (`N of M transfers done ~ X% complete`, the `34962`-family string) under the progress ring.
    ///
    /// THE BANNER MAP (Lukas, 2026-08-06): the at-open "nothing to do" answer is NOT this case —
    /// it is the distinct `.idleCounts` below (same rendering, different meaning), so the store
    /// can tell "quiet run, status readout" from "split phase resting between bursts" when it
    /// decides whether a pending state just TERMINATED (→ `.idle`). An earlier era rendered the
    /// notify promise here instead of counts; the map ended that ambiguity by splitting the idles.
    ///
    /// MOB-1511 (W2): `round`/`totalRounds` carry the multi-round context — non-nil only when the
    /// display rule says a round label belongs on the banner (round ≥ 2, or a known total > 1);
    /// `totalRounds` additionally carries the SDK's real run-count estimate — `nil` when the
    /// estimate is unavailable.
    case inProgress(done: Int, total: Int, round: Int?, totalRounds: Int?)
    /// Figma 5139:35270 — the run is PREPARING transfers: one or more transactions are ready to be
    /// proven and this app-open is what proves them. Run-level, not per-transfer, because a single
    /// prove sweep proves the whole run at once (`C5` shows Transfer 1 and Transfer 2 preparing
    /// together).
    ///
    /// Shares its second line with `.transferSending` for a reason: both are the app doing work
    /// that only survives while it is on screen, and "Keep Zodl open on active phone screen" is the
    /// one thing either state needs from the user. Distinct from `.inProgress` above, which is the
    /// opposite — nothing is running, leaving is free, and we will notify.
    ///
    /// Proving is the LONGEST phase of a run and, until this case existed, the phase where the
    /// banner said the least: a run mid-prove rendered `.transferWaiting`'s alert-circle and
    /// "Tap to reschedule or send now", which is an invitation to act on a transfer that cannot
    /// move yet — and, on iOS, an invitation to leave.
    ///
    /// REVERTED to a payload-free case 2026-08-01, hours after gaining one. The `isWorkingNow`
    /// flag existed to give the split phase a calmer non-working state, and it bought that with two
    /// costs the field named immediately: it introduced copy ("Preparing your balance…") that
    /// appears NOWHERE in Figma, and it kept the spinner lit while the timeline one tap away showed
    /// no spinners at all — reintroducing, in a new place, the exact banner-vs-list contradiction
    /// this whole pass exists to remove.
    ///
    /// The measurement it was meant to fix turned out not to need fixing: the transitions it was
    /// smoothing held for 78 s and 12 s in the field, neither anywhere near a flicker. The real
    /// complaint was latency, not churn — see the 18 s blocked reads in the same log.
    ///
    /// The split phase now uses the two DESIGNED states and nothing else: `.preparing` while the
    /// app can genuinely prove or submit, `.inProgress` while it waits. Where the designed
    /// vocabulary is thin, that is a gap to take to the designers, not one to fill by inventing a
    /// string.
    ///
    /// COUNTS RESTORED 2026-08-05 (FIND-6, campaign 7) — and this is NOT the `isWorkingNow`
    /// mistake again, so read before reverting. The payload-free case obeyed "don't invent copy"
    /// and, in the field, violated a rule that outranks it: MONOTONE INFORMATION. A run at
    /// "1 of 11 transfers · 9%" flipped to this variant the moment the next transfer went
    /// prove-pending, and the banner REPLACED the numbers with a numberless spinner — for 12
    /// straight minutes in the marathon session, over the copy "Keep Zodl open". The user watched
    /// known progress vanish and read it as the run breaking ("I don't think this works").
    /// Numbers, once shown, must never be taken back by a lower-information costume.
    ///
    /// So the case carries the same `done`/`total` the `.inProgress` banner shows, and `info`
    /// renders the DESIGNED counts line whenever `done > 0` — both strings already in the catalog,
    /// nothing invented. Before any transfer is done (`done == 0`, the split phase and the first
    /// prove) nothing was ever shown that could regress, and the designed keep-open ask stands
    /// unchanged. The spinner icon stays in both shapes: since FIND-5 the tick lane proves and
    /// serves unconditionally, so work genuinely runs (or is seconds from running) whenever this
    /// variant shows. A designed counts-plus-working frame remains Andrea's to draw
    /// (SMART_BANNER_STATES §8); this is the honest composition of what exists today.
    case preparing(done: Int, total: Int)
    /// MOB-1511 (W2): the post-completion "more funds to migrate" re-offer, round-aware — replaces
    /// the plain `.required` reuse for an acknowledged completion with a pending remainder.
    case nextRoundRequired(round: Int, totalRounds: Int?)
    /// Figma 5139:34287 — a BROADCAST session in flight. The engine's `next_step` returned
    /// `Broadcast`, so this app-open spends its window on the submission and deliberately does NOT
    /// sync: ZIP 318 wants a wake window used either to sync or to broadcast, never both, so a
    /// network observer cannot correlate the two.
    ///
    /// (`.transferWaiting` — the old "overdue, tap to reschedule or send now" counterpart — was
    /// REMOVED by THE BANNER MAP, Lukas 2026-08-06: overdue is iOS reality awaiting the next open,
    /// and the open auto-serves; nothing waits on a CTA, so the state had no trigger left. Frame
    /// `5139:17202` retired with it.)
    ///
    /// The "keep the app open" line is not a nicety. With no background lane on iOS, backgrounding
    /// mid-broadcast is exactly what strands it — so the banner asks for the one thing that keeps
    /// the session alive.
    case transferSending(number: Int)
    case updatePlan
    case transfersExpired(first: Int, last: Int)
    /// (`.transferReady` — the manual lane's "Transfer N is ready · Review" pre-consent state —
    /// was REMOVED 2026-08-07 with the whole manual-tap send surface, Lukas: "there is no send
    /// now anymore… never waiting on manual tap". Its sole setter was the derivation's manual
    /// arm, and the manual-delivery flag never had a production setter; the ready frames' fate
    /// closes ad-2 the same way.)
    case complete
    /// IDLE 1 — TERMINATION (THE BANNER MAP, Lukas 2026-08-06). Figma `5139:35439` / `10639`:
    /// coins-swap glyph, "Migration Progress" / `We'll notify you when to send`
    /// (`migrationBanner.idleInfo`), the ordinary More.
    ///
    /// The map's rule, verbatim: *"a special state for termination — NEVER rendered as a result of
    /// any next_step calls or zodl open; always the transition from some ongoing state to idle:
    /// pending state A → finished = IDLE 1. For example Tx SENDING when done flips to IDLE 1 —
    /// 'ok, I finished, now you can leave zodl'."*
    ///
    /// AMENDED 2026-08-08 (Andrea via Lukas), reversing the quote's own SENDING example: *"if
    /// preparation of send is in progress and finishes, we say we'll notify you when to send,
    /// while if we're sending and that finishes, we stay generic — N of M done."* Termination
    /// into the notify promise is therefore exclusive to `.preparing`; a finished
    /// `.transferSending` settles on `.idleCounts`.
    ///
    /// So this case is STORE-ENTERED, never derivation-entered: `MigrationDerivations
    /// .bannerVariant` never returns it (its nothing-actionable arm answers `.idleCounts` — the
    /// AT-OPEN idle). `SmartBannerStore` presents `.idle` when `.preparing` resolves to
    /// `.idleCounts` within one foreground session,
    /// and holds it (sticky) until a non-idle variant or the next session's Evaluating resets it.
    ///
    /// HISTORY, third and final flip, each with its ruling: SP1 wired the notify line universally →
    /// the full-canvas walk reversed to counts pending a trigger rule → flow ID ratified
    /// `.waiting ⇒ notify` (every idle entry) → THE BANNER MAP split the idles by entry path,
    /// scoping the notify line to termination only. The pin is the store-level termination test;
    /// the split-phase is deliberately EXCLUDED from termination (its preparing↔counts alternation
    /// is not "finished", and idle copy over the split was the field-caught false promise of
    /// 2026-08-01 — twice).
    case idle
    /// IDLE 2 — AT-OPEN (THE BANNER MAP, Lukas 2026-08-06). Figma `5139:34962`: progress ring,
    /// "Migration Progress" / the counts line (`N of M transfers done ~ X% complete`). The map,
    /// verbatim: *"playing the role of idle based on the `.waiting` next_step case — typically the
    /// result of zodl open: I open zodl, call next_step, it says 'nothing to do', we render this."*
    ///
    /// A DISTINCT case rather than a reuse of `.inProgress`, deliberately: it renders identically
    /// (counts + ring) but means "quiet run, status readout", which is the ONLY shape the store may
    /// convert to `.idle` on a pending→finished transition. Folding it into `.inProgress` would
    /// make the split phase's resting counts eligible for that conversion — reintroducing the
    /// 08-01 false-promise churn the split arm's own doc records.
    case idleCounts(done: Int, total: Int)
    /// MOB-1466 (staleness pass): the banner does not KNOW yet. Every other case on this enum is an
    /// assertion about the world; this is the one that admits the app has not re-established the
    /// world yet, and it exists because iOS foregrounding renders the previous frame.
    ///
    /// THE PROBLEM. Background Zodl on "We'll notify you when to send", return twenty minutes later,
    /// and iOS paints that same sentence before a line of our code runs. `willEnterForeground` DOES
    /// re-derive — it routes to `retryStart`/`initialSetups`, which reach `advance(.beforeSync)` —
    /// but the answer takes seconds (the field saw idle held ~3 s before flipping to a sending
    /// state), and for those seconds the banner states last session's conclusion with full
    /// confidence. The user reads a promise that is no longer true, then watches it silently
    /// rewrite itself. That is the "outdated feeling" reported through the whole first end-to-end
    /// migration, and no amount of speed fixes it: the gap is where knowledge does not exist yet,
    /// not where it is slow to render.
    ///
    /// WHY NOT DISMISS THE BANNER INSTEAD (the other candidate, rejected). Presence/absence is a
    /// LAYOUT event where a label swap is only a paint: closing and reopening reflows everything
    /// below on EVERY foreground, including the majority where nothing changed. It also lies in the
    /// other direction — mid-migration, an absent banner reads as "done, nothing here" — and it
    /// does nothing for cold launch, where there is no banner to dismiss and the same gap exists.
    ///
    /// NOT A REPEAT OF `isWorkingNow`. The `.preparing` note above records a payload reverted for
    /// inventing copy Figma does not contain, and prescribes the remedy: take the gap to the
    /// designers. That is exactly what happened here — the copy below is PROVISIONAL, added on
    /// Lukas's explicit instruction (2026-08-02) and going to Andrea for the real wording. Do not
    /// revert this case on the `isWorkingNow` precedent; it is the sanctioned path, not the same
    /// mistake. Do reword it the moment design answers.
    ///
    /// GROUND_RULES D1: the checking copy is the SECOND LINE under the standing "Migration
    /// Progress" title — Figma 5679-8225 draws it that way, and the blank-line hack that existed
    /// only because the copy sat in the title slot is gone with it. It DOES carry the button: the
    /// same frame draws the ordinary "More", and the design is the authority.
    ///
    /// BUTTONLESS, and the migration screen is UNREACHABLE while this state stands (Lukas,
    /// 2026-08-07, new team agreement against the same frame 5679-8225): "remove MORE button and
    /// disable going into the migration screen completely… it would render stale data anyway."
    ///
    /// This reverses the 2026-08-03 reversal, on a ground that argument never addressed. That round
    /// weighed the CTA's honesty — "More" promises a DESTINATION, not an OUTCOME, so it cannot go
    /// stale the way "Send now" on an expired transfer does — and concluded the button was safe.
    /// True as far as it goes, and beside the point: the DESTINATION is what is stale. The screen
    /// renders the previous session's snapshot until this session's verdict lands, so arriving
    /// during checking shows numbers the app is in the middle of disproving. Withholding the door
    /// is the same never-lie rule the reschedule CTA already lives under (AUD-2b) — not a claim
    /// about the button's wording.
    ///
    /// The layout objection (button vanishes for the checking window, then regrows) stands and is
    /// accepted: with the ≥0.5s checking floor it is a visible change, and the design ruled anyway.
    case checkingStatus

    /// False ONLY for `.checkingStatus` — the one state whose destination is knowably stale (see
    /// its doc). Every other variant offers its action. Kept as a named property rather than
    /// inlined: it is the seam where a state that must not offer an action says so, and the tap
    /// guard in `SmartBannerStore.smartBannerContentTapped` is its enforcement half — hiding the
    /// button alone would leave the banner's own tap gesture as an open door.
    var showsButton: Bool {
        self != .checkingStatus
    }

    /// SB-D1: the STATE identity, blind to payload. Two variants sharing a key are the same
    /// thing to a reader — `.idleCounts(1, 6)` and `.idleCounts(2, 6)` are both "counting up" —
    /// so the dwell queue coalesces them instead of spending a half second on each.
    var dwellKey: String {
        switch self {
        case .required: return "required"
        case .inProgress: return "inProgress"
        case .preparing: return "preparing"
        case .nextRoundRequired: return "nextRoundRequired"
        case .transferSending: return "transferSending"
        case .updatePlan: return "updatePlan"
        case .transfersExpired: return "transfersExpired"
        case .complete: return "complete"
        case .idle: return "idle"
        case .idleCounts: return "idleCounts"
        case .checkingStatus: return "checkingStatus"
        }
    }

    /// Membership test for the preparing SHAPE, payload-blind — what the row-truth tests assert
    /// ("this run reads as PREPARING") without pinning counts those tests are not about. Prefer
    /// this over `== .preparing(...)` anywhere the counts are incidental.
    var isPreparingVariant: Bool {
        if case .preparing = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .required, .nextRoundRequired:
            return String(localizable: .migrationBannerRequiredTitle)
        case .inProgress, .preparing, .checkingStatus, .idle, .idleCounts:
            return String(localizable: .migrationBannerProgressTitle)
        case .transferSending(let number):
            return String(localizable: .migrationBannerSendingTitle(number))
        case .updatePlan:
            return String(localizable: .migrationBannerUpdatePlanTitle)
        case .transfersExpired(let first, let last):
            return String(localizable: .migrationBannerExpiredTitle(first, last))
        case .complete:
            return String(localizable: .migrationBannerCompleteTitle)
        }
    }

    var info: String {
        switch self {
        case .required:
            return String(localizable: .migrationBannerRequiredInfo)
        // THE BANNER MAP (Lukas, 2026-08-06): `.idle` = the termination notify line (idle1);
        // `.idleCounts` = the at-open status readout (idle2) — same counts string the active
        // `.inProgress` arms render. See both cases' docs for the entry-path rule.
        case .idle:
            return String(localizable: .migrationBannerIdleInfo)
        case let .idleCounts(done, total):
            let percent = total > 0 ? (done * 100) / total : 0
            return String(localizable: .migrationBannerProgressCountsInfo(done, total, percent))
        case let .inProgress(done, total, round, totalRounds):
            let percent = total > 0 ? (done * 100) / total : 0
            if let round {
                if let totalRounds {
                    return String(localizable: .migrationBannerProgressRoundCountsInfo(round, totalRounds, done, total))
                }
                return String(localizable: .migrationBannerProgressRoundCountsInfoNoTotal(round, done, total))
            }
            return String(localizable: .migrationBannerProgressCountsInfo(done, total, percent))
        case let .preparing(done, total):
            // FIND-6: monotone information — once real progress exists, the counts line (the same
            // designed string `.inProgress` renders) stays on screen through the preparing phases;
            // the spinner icon alone carries "work is running". Only a run with nothing yet done
            // shows the keep-open ask in this slot, because there are no numbers to take back.
            if done > 0 && total > 0 {
                let percent = (done * 100) / total
                return String(localizable: .migrationBannerProgressCountsInfo(done, total, percent))
            }
            return String(localizable: .migrationBannerKeepOpenInfo)
        case .nextRoundRequired(let round, let totalRounds):
            if let totalRounds {
                return String(localizable: .migrationBannerNextRoundInfoTotal(round, totalRounds))
            }
            return String(localizable: .migrationBannerNextRoundInfo(round))
        case .transferSending:
            return String(localizable: .migrationBannerKeepOpenInfo)
        case .updatePlan:
            return String(localizable: .migrationBannerUpdatePlanInfo)
        case .transfersExpired:
            return String(localizable: .migrationBannerExpiredInfo)
        case .complete:
            return String(localizable: .migrationBannerCompleteInfo)
        case .checkingStatus:
            // Figma 5679-8225: checking is the SUBTITLE under the standing "Migration Progress"
            // title — GROUND_RULES D1.
            return String(localizable: .migrationBannerCheckingInfo)
        }
    }

    /// "More" everywhere except `transferSending`, which reads "Review".
    var buttonLabel: String {
        switch self {
        case .transferSending:
            return String(localizable: .sendReview)
        default:
            return String(localizable: .generalMore)
        }
    }

    var percent: Int? {
        switch self {
        case let .inProgress(done, total, _, _):
            return Int((Double(done) / Double(max(total, 1)) * 100).rounded())
        case let .idleCounts(done, total):
            return Int((Double(done) / Double(max(total, 1)) * 100).rounded())
        default:
            return nil
        }
    }
}

extension SmartBannerView {
    @ViewBuilder func migrationContent() -> some View {
        MigrationBannerContentView(variant: store.migrationBannerVariant) {
            store.send(.smartBannerContentTapped)
        }
    }
}

/// Standalone rendering of the `priorityMigration` banner content, extracted from
/// `SmartBannerView.migrationContent()` (MOB-1465) so the DEBUG migration gallery can render every
/// `MigrationBannerVariant` without hosting a live `SmartBannerView` (whose `onAppear` starts real
/// dependency subscriptions). Tints use the Gray ramp (`utility-gray-50`/`-200`), matching the
/// Figma migration-banner tokens — deliberately NOT `SmartBannerView.titleStyle()`/`infoStyle()`,
/// which still use the pre-rebrand Purple ramp. Resolved by MOB-1466 (per-priority gradient, not an
/// app-wide restyle): `SmartBannerView`'s background `LinearGradient` swaps to this same Gray._700
/// → ._950 pair only while `store.priorityContent == .priorityMigration`; every other banner keeps
/// the Purple._700 → ._950 pair unchanged.
struct MigrationBannerContentView: View {
    let variant: MigrationBannerVariant
    let onButtonTap: () -> Void

    private var titleStyle: Color {
        Design.Utility.Gray._50.color(.light)
    }

    private var infoStyle: Color {
        Design.Utility.Gray._200.color(.light)
    }

    var body: some View {
        HStack(spacing: 0) {
            migrationIcon()
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(variant.title)
                    .zFont(.medium, size: 14, color: titleStyle)

                Text(variant.info)
                    .zFont(.medium, size: 12, color: infoStyle)
            }

            Spacer()

            // `.checkingStatus` renders buttonless (2026-08-07 agreement, Figma 5679-8225); every
            // other variant keeps its action. See `showsButton`'s doc — and note that hiding the
            // button is only half of it: the store's tap guard closes the banner's own gesture.
            if variant.showsButton {
                ZashiButton(
                    variant.buttonLabel,
                    type: .ghost,
                    infinityWidth: false
                ) {
                    onButtonTap()
                }
                .environment(\.colorScheme, .light)
            }
        }
    }

    @ViewBuilder private func migrationIcon() -> some View {
        switch variant {
        case .required, .nextRoundRequired, .idle:
            // `.idle` joins the coins-swap group per its Figma frames (35439/10639) — nothing is
            // spinning, so the spinner rule below excludes it by construction.
            Asset.Assets.Icons.coinsSwap.image
                .zImage(size: 20, color: titleStyle)
        case .inProgress, .idleCounts:
            // THE BANNER MAP (Lukas, 2026-08-06): the counts family draws the ring — and the
            // at-open idle's own frame agrees (`5139:34962` shows the ring beside the counts
            // line), so what began as a deliberate deviation (the old note argued a ring over
            // coins-swap so "in progress" ≠ "not started", MOB-1513 B4's confusion class) is now
            // simply the frame.
            migrationProgressRing()
        case .preparing, .transferSending, .checkingStatus:
            // `.checkingStatus` joins these two because it satisfies the same rule stated below —
            // something IS actually spinning. Here the work is the re-derivation itself
            // (`advance(.beforeSync)`), which is running for exactly as long as this state shows.
            //
            // No static "working" glyph in the catalogue, and a live spinner says the thing both
            // states are asking for (a session is running, keep it running) better than one would.
            // Figma draws `loading-01` here in both frames — an animated spinner is that glyph's
            // whole intent.
            //
            // The spinner is now reserved for states where something is ACTUALLY spinning. A banner
            // spinner over a timeline with no spinners is a contradiction the user can see in two
            // taps, and it was reported as one within the hour.
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: titleStyle))
                .frame(width: 20, height: 20)
        case .updatePlan, .transfersExpired:
            Asset.Assets.Icons.alertCircleOutline.image
                .zImage(size: 20, color: titleStyle)
        case .complete:
            Asset.Assets.infoCircle.image
                .zImage(size: 20, color: titleStyle)
        }
    }

    @ViewBuilder private func migrationProgressRing() -> some View {
        let percent = variant.percent ?? 0

        ZStack {
            Circle()
                .stroke(titleStyle.opacity(0.3), lineWidth: 2)

            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(titleStyle, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
    }
}
