//
//  MigrationStatusView.swift
//  zodl
//
//  "Migration Progress" / "Resume Migration" / "Re-scheduling…" screen (MOB-1464, Figma S10 ·
//  progress 2709:3350 / resume 2696:7133 / re-scheduling 2840:3656). `onAppear` loads live rows via
//  the store; every other delegate emitted here is consumed by `MigrationCoordFlowCoordinator`
//  (phase 3). When `isFlowRoot` is set, the back control closes the flow instead of popping
//  (MOB-1466).
//
//  MOB-1478 (W7): `.rescheduleConfirmed(first:last:)` reuses this same screen for the post-reschedule
//  confirmation — title borrows `migrationPlanTitleConfirm`, body is `migrationStatusRescheduledDesc`,
//  and its "Got it" routes through the same `gotItTapped` exit as `.progress`. Row captions gained
//  two branches: `sentMinutesAgo` (sub-hour "Sent N min ago") ahead of the hours-based sent caption,
//  and `isBroadcasting` ("Sending now") ahead of the `.active` ETA caption — both fall back to
//  today's copy when unset/false.
//
//  2026-08-07 (Lukas): the Send-now surface is GONE — "send is driven only by .broadcast(id)
//  next_step, never waiting on manual tap." The `.resume` presentation keeps the timeline + the
//  Tor-hold note as the overdue re-entry READOUT; its Send-now CTA, the `windowMissedNote`
//  footer ("Sending now will delay…") and the resume description (which instructed "Send it
//  now.") retired with the lane. The B8 frame family's remaining shape is with product
//  (ERROR_HANDLING thread).
//
//  MOB-1513 (A2): the shared timeline no longer relabels `store.rows`' own index 0 as "Split
//  Balance" — an ordinary transfer could be `index == 0` too (and, once actually sent, would have
//  wrongly rendered this screen's "Done"/green treatment below). This screen now passes the store's
//  synthesized `splitRow` in separately, ahead of `rows` (unchanged: every real transfer, numbered
//  1..N, its own status/caption untouched) — always COMPLETED, since post-commit the split has
//  definitely already broadcast.
//
//  The final progress frame (5139-34627) pins an info footer on `.progress` between the timeline
//  and "Got it" (`progressFooterNote` — stand-in key, see its TODO) and reads the row ETAs as
//  "in ~12 hours" where this screen renders the bare "~12 hours" (`MigrationETA` `.bare` vs
//  `.inPrefixed`, both existing keys) — that swap is a copy decision left with Andrea, not taken
//  here.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationStatusView: View {
    /// Passed to every `.color(_:)` on this screen. The retired `updatingNote` spinner shipped
    /// with a hardcoded `.light` and was invisible in dark mode — same defect as the pool header's
    /// bubbles, same fix: the token holds both values, the caller supplies the appearance.
    @Environment(\.colorScheme) private var colorScheme

    /// The header's fiat lines — the same app-wide shared rate the timeline rows self-read
    /// (`MigrationTransferTimeline`), so the card and the rows beneath it can never quote two
    /// different rates in one frame.
    @Shared(.inMemory(.exchangeRate)) private var currencyConversion: CurrencyConversion?

    @PlatformBindable var store: StoreOf<MigrationStatus>

    init(store: StoreOf<MigrationStatus>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                // SCROLLER SHAPE: full-bleed ScrollView, `screenHorizontalPadding()` on its CONTENT
                // and on each pinned footer child — never on the column that holds the scroller, or
                // the indicator is inset by the same 24pt and draws ON TOP of the timeline's
                // amounts and captions. See `MigrationEntryView` for the full note.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        if let description {
                            Text(description)
                                .zFont(size: 14, style: Design.Text.tertiary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 24)
                        }

                        // (R13-3's "Balances as of ~N min ago" age line stood here until
                        // 2026-08-07. Lukas: "asOfLine is wrong and never requested." It was our
                        // answer to a charter question — how to show frozen facts honestly during
                        // ZIP 318's no-sync hold — not a designed element, and it put the freshness
                        // of our own reads in front of a reader who can only act on the facts
                        // themselves. Removed alongside `updatingNote`, the other never-designed
                        // staleness label, in the same wave.)

                        // The ORCHARD→IRONWOOD pool header, RESTORED per Andrea's final design
                        // (Figma 5139-34627) after R9's same-day arc (dropped → record corrected →
                        // restored). The values are the wallet's REAL per-pool balances off the
                        // same snapshot the timeline below renders from. Pool accounting and row
                        // status remain independent SDK facts, so no render gate or app-side
                        // reconciliation is applied. EVERY presentation draws it (re-ruled by
                        // Lukas, 2026-08-08 — omitting it on the resume frame was a bug, not a
                        // design): the pool split is the run's standing fact, true in every frame.
                        // Handover O2: no session has published a snapshot yet (first open of the
                        // process while migration work holds the DB actor). The screen is HERE —
                        // title above, back arrow live — only the data zone waits. Anything is
                        // better than an empty screen with a spinner; this is the smallest
                        // anything: the spinner plus the sentence saying what the wait is.
                        if store.isEvaluating {
                            evaluatingNote
                        } else {
                        MigrationPoolFlowHeader(
                            orchardRemaining: store.poolFlow.orchardRemaining,
                            ironwoodHeld: store.poolFlow.ironwoodHeld,
                            currencyConversion: currencyConversion
                        )
                        .padding(.bottom, 24)

                        MigrationTransferTimeline(
                            rows: store.rows,
                            caption: caption(for:),
                            splitRows: store.splitRows,
                            // GOAL #4 (Figma 5207-16322): "Show details ⌄" belongs to the split row —
                            // under its caption, in its text column — NOT floating above the list as
                            // an unrelated link. `MigrationTransferTimeline` already renders exactly
                            // that affordance for any caller that opts in, so this screen adopts the
                            // same one the Confirm Transfer Plan screen has always shown; nothing new
                            // is drawn here.
                            //
                            // `nil` when the split has one part: the design omits the disclosure
                            // there, and a one-part split has no detail the row does not already say.
                            onSplitDetailsTapped: store.poolFlow.hasSplitDetail
                                ? { store.send(.showSplitDetailTapped) }
                                : nil,
                            skeletonPendingCaptions: store.isRescheduling,
                            captionStyle: { row in
                                // MOB-1511 (W4): a "Done" caption renders green, matching its
                                // check badge. R11/Andrea's ladder extends W4's own rationale from
                                // the split row to EVERY wallet-confirmed row — all `.sent` rows
                                // caption "Done" now, and a Done in tertiary under a green check
                                // would split one state across two tones. `.confirming` rows stay
                                // tertiary: their check is the neutral one and their word is
                                // "Sent", not a success claim.
                                row.status == .sent
                                    ? Design.Utility.SuccessGreen._600 as Colorable
                                    : Design.Text.tertiary
                            }
                        )
                        }
                    }
                    .screenHorizontalPadding()
                    .padding(.vertical, 1)
                }

                // O2: footers make claims about data (ETAs, Tor holds) — while evaluating there
                // is no data to make claims about, and the back arrow is the exit.
                if store.presentation == .resume && !store.isEvaluating && store.isTorHoldActive {
                    torHoldNote
                        .screenHorizontalPadding()
                        .padding(.top, 16)
                }

                if store.presentation == .progress && !store.isEvaluating {
                    progressFooterNote
                        .screenHorizontalPadding()
                        .padding(.top, 16)
                }

                if !store.isEvaluating {
                    buttons
                        .screenHorizontalPadding()
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                }
            }
            .applyPresentationModifier(store: store)
        }
        .applyScreenBackground()
        // `$store.<flag>.sending` rather than a hand-rolled `Binding(get:set:)`: SwiftUI invokes a
        // hand-rolled binding's `get` during ITS update cycle, outside the `WithPerceptionTracking`
        // scope this body established, which trips "Perceptible state was accessed but is not being
        // tracked" on every hosted screen — see MigrationCoordFlowView's identical note.
        .zashiSheet(
            isPresented: $store.isSplitDetailPresented.sending(\.splitDetailPresentedChanged)
        ) {
            // A sheet's content builder runs inside the PRESENTATION's hosting body, outside the
            // screen body's `WithPerceptionTracking` above — exactly the escaping-closure case the
            // Perception runtime warns about (and it did, once per state read per evaluation, on
            // every open of this screen). The wrapper both silences the warning and makes the
            // presented sheet actually re-render when `poolFlow` moves under it mid-sweep.
            WithPerceptionTracking {
                // Steps AND total both from `poolFlow` — one derivation, four observers. The sheet
                // is the fourth (banner, timeline, pool header, this), and the first three already
                // agree.
                MigrationPrepareBalanceSheet(
                    steps: MigrationPrepareBalanceRow.from(preparations: store.poolFlow.preparations),
                    amountBeingSplit: store.splitRows.first?.amount
                ) {
                    store.send(.splitDetailDismissed)
                }
            }
        }
        .onAppear {
            store.send(.onAppear)
        }
        .onDisappear {
            store.send(.onDisappear)
        }
        // F#9 (MOB-1497 T5 completion): the headless-routed first-run Tor choice — same designed
        // sheet the Sending lane presents, from the snapshot's `needsTorFirstRunChoice`. Binding
        // shape and the WithPerceptionTracking wrapper mirror the split-detail sheet above.
        .zashiSheet(
            isPresented: $store.isTorChoicePresented.sending(\.torChoicePresentedChanged)
        ) {
            WithPerceptionTracking {
                MigrationBroadcastFailureSheetView(
                    failureKind: .torFirstRunChoice,
                    cancelTapped: { store.send(.torChoicePresentedChanged(false)) },
                    proceedWithoutTorTapped: { store.send(.torChoiceProceedTapped) },
                    retryTapped: { store.send(.torChoicePresentedChanged(false)) },
                    useSyncServerTapped: { }
                )
            }
        }
        .alert($store.scope(state: \.alert, action: \.alert))
    }

    // MARK: - Title + description

    private var title: String {
        switch store.presentation {
        case .progress:
            return String(localizable: .migrationStatusTitle)
        case .resume:
            return store.isRescheduling
                ? String(localizable: .migrationStatusReschedulingTitle)
                : String(localizable: .migrationStatusResumeTitle)
        case .rescheduleConfirmed:
            return String(localizable: .migrationPlanTitleConfirm)
        }
    }

    /// `nil` hides the description entirely — reached only when `store.totalDurationHours` is
    /// unknown (a W1 fallback re-entry, MOB-1513): the sentence is a
    /// single fixed-shape localized string carrying the duration as a numeric argument, so there is
    /// no in-sentence placeholder ("—") to substitute without inventing new copy: omitting the
    /// whole line is the honest option that doesn't imply a false duration.
    private var description: String? {
        switch store.presentation {
        case .progress, .resume:
            // `.resume` joined this arm 2026-08-08 (Lukas), closing the gap the 08-07 send-now
            // retirement left empty: the resume frame states the SAME standing arrangement as
            // progress — how the balance is split, and that we will call you — while the overdue
            // "why" stays on the timeline's own row caption.
            guard let totalDurationHours = store.totalDurationHours else { return nil }
            // H-FORK (Lukas, 2026-08-07): same stem, three tails, chosen by the SAME
            // `MigrationBannerVariant` the banner renders from — never by a condition of this
            // screen's own. `poolFlow.banner` is that variant, already on the snapshot, so the
            // header and the banner cannot disagree about what is happening.
            //
            // Three full sentences rather than one with a swapped verb: a verb slotted into a
            // sentence does not survive a language that reorders clauses, and the alternative
            // (shared stem + tail) hands translators half-sentences AND needs interpolation to
            // dodge SwiftLint's `string_concatenation`.
            //
            // Only these four variants reach this arm: `.checkingStatus` no longer opens this
            // screen at all, and `hasInvalid` routes to `.recovery` ahead of every state arm, so
            // `.updatePlan`/`.transfersExpired` land there instead. `default` therefore states the
            // standing arrangement — true whenever nothing is running — rather than inventing an
            // ask for a state that cannot get here.
            switch store.poolFlow.banner {
            case .preparing:
                return String(
                    localizable: .migrationStatusDescPreparing(store.rows.count, totalDurationHours, store.remainingCount)
                )
            case .transferSending:
                return String(
                    localizable: .migrationStatusDescBroadcasting(store.rows.count, totalDurationHours, store.remainingCount)
                )
            default:
                break
            }
            // CLOSED 2026-08-07 (Lukas, H9): the paragraph's third sentence is now in
            // `migrationStatus.desc` itself — "We'll notify you when it's time to open Zodl and
            // take the next action." It is NOT the frame's "Keep Zodl open while it is preparing…";
            // that ask moved to the footer, which is state-driven. The division: the HEADER states
            // the standing arrangement (how the balance is split, and that we will call you), the
            // FOOTER says what is happening right now. So the keep-open ask is made once, by
            // whichever surface currently knows it is true.
            return String(
                localizable: .migrationStatusDesc(store.rows.count, totalDurationHours, store.remainingCount)
            )
        case .rescheduleConfirmed(let first, let last):
            return String(localizable: .migrationStatusRescheduledDesc(first, last))
        }
    }

    // MARK: - Caption

    private func caption(for row: MigrationTransferRow) -> String {
        // MOB-1511 (W4, Figma 3480:7638): the completed Split Balance row reads "Done" (green, via
        // `captionStyle` below) instead of a sent-ago timestamp — split completion is a state, not
        // an event the user tracks by time. MOB-1513 (A2): keyed off `kind` now, not `index == 0` —
        // an ordinary sent Transfer 1 must keep its own real "Sent Nh ago"/"Sent N min ago" caption
        // below, not this one.
        // D14: only a FINISHED split reads "Done". Before D14 there was one synthesized split row
        // and it was always `.sent`, so the unconditional return was correct; now the rows are real
        // (`MigrationDerivations.preparationRows`) and a multi-layer split is genuinely part-way
        // through — an unfinished one must fall through to the ordinary status captions below.
        if row.kind == .splitBalance && row.status == .sent {
            return String(localizable: .migrationStatusDone)
        }
        // The collapsed split keeps the count of what it collapsed: "Ready now · 4 steps", the
        // designed caption (Figma 5207-16322, `migrationPlan.splitBalanceCaption`) that the Confirm
        // Transfer Plan screen has always used via `MigrationTransferPlan.State.splitCaption`.
        //
        // Collapsing four rows into one WITHOUT the count is a straight loss of information: the row
        // stops saying how much work it stands for, and the only remaining hint is a disclosure the
        // user has to open. The count is why the collapse is honest.
        if row.kind == .splitBalance, store.poolFlow.hasSplitDetail {
            return String(
                localizable: .migrationPlanSplitBalanceCaption(
                    unsplitCaption(for: row),
                    store.poolFlow.preparations.count
                )
            )
        }
        return unsplitCaption(for: row)
    }

    /// The row's own status caption, before the split row's step-count suffix is applied.
    private func unsplitCaption(for row: MigrationTransferRow) -> String {
        // ON THE WIRE RIGHT NOW — ahead of every status arm, because a row whose submit call is open
        // is not described by any of them: its durable status is still whatever it was a second ago.
        //
        // `migrationStatus.sendingNow` is designed copy that has been in the catalogue unused, with a
        // note saying it is "the right words for a genuinely in-session submit if a surface ever
        // wants to show one — that window is ~2 s and nothing is watching this list during it."
        // Something is watching now: the user opened the app from a notification precisely to make
        // this happen, and the field window is ~7 s, not 2. This is the moment the string was
        // written for.
        if row.isSubmitting {
            return String(localizable: .migrationStatusSendingNow)
        }
        switch row.status {
        case .sent:
            // Andrea's FIVE-state caption ladder (2026-08-03, confirmed same day R11 landed):
            // Preparing transaction… → Sending now → Sent → Sent → DONE. Green means
            // wallet-confirmed with pool impact now (R11), and its word is "Done" — a state, not
            // an event the user tracks by time. The recency captions ("Sent recently"/"Sent Nh
            // ago") this arm used to render belonged to the pre-R11 world where green meant merely
            // broadcast; they retire from this screen and stay in the catalogue for the plan
            // screens' history rows.
            return String(localizable: .migrationStatusDone)
        case .active where row.isPreparing, .overdue where row.isPreparing:
            // MOB-1466 (smart-banner pass, Figma C5). Below `.sent` — a mined transfer is finished
            // whatever else it says. A transfer whose window is open (or has passed) while its proof
            // is still outstanding would otherwise caption "Ready now" / "Overdue Nh ago", both of
            // which promise a send that cannot happen yet: the engine will refuse it until the proof
            // exists. "Preparing transaction…" is the honest word for that gap.
            //
            // NARROWED 2026-08-02, field-caught from a screenshot. This used to be `case _ where
            // row.isPreparing`, which caught PENDING rows too — and that put two different clocks in
            // one column. `isPreparing` means "the engine can prove this one NOW", and provability
            // is gated on each transfer's own anchor boundary, drawn on a jittered grid. It is
            // therefore NOT in send order. The tester saw:
            //
            //     Transfer 7   ~15 mins
            //     Transfer 8   Preparing transaction… ⟳
            //     Transfer 9   Preparing transaction… ⟳
            //     Transfer 10  ~19 mins
            //
            // and reasonably asked why some rows have a time and some do not. Worse than
            // inconsistent, it implies 8 and 9 have jumped the queue. They have not — their proofs
            // are simply being computed early, which is correct (prove early, send at the window)
            // and completely invisible to when they actually send.
            //
            // A pending row's ETA is true whether or not its proof is being built, so it keeps it.
            // Proving only earns the caption when it is the reason a row cannot do what it claims.
            return String(localizable: .migrationStatusPreparing)
        // MOB-1466: `?? Int.max` — an unknown tip means the window CANNOT be known to have passed,
        // so this arm does not claim it has. The row falls through to the ETA caption, which says
        // "Recomputing ETA…" rather than borrowing this one's "Preparing transaction…".
        case .active where row.isAwaitingRunDependencies && (row.forwardETAMinutes ?? Int.max) <= 0:
            // FIND-1 (2026-08-05, campaign 7): the front-of-queue row, its window passed, but the
            // ENGINE says it is waiting on other transactions of its own run (unmined
            // preparations). The derivation already vetoes the `.overdue` badge for it — see
            // `nonSentRowStatus` — and the default ETA arm below would say "Ready now", a send the
            // engine refuses until the dependencies mine. "Preparing transaction…" is the honest
            // word from Andrea's own ladder: the run IS preparing this transfer's funding. NO
            // spinner — `isInFlight` stays false, nothing runs on this device for it. A row whose
            // window is still ahead keeps its plain ETA (the time is true either way).
            return String(localizable: .migrationStatusPreparing)
        case .overdue:
            // GROUND_RULES D4: real elapsed, from the row (Figma "Overdue · 5h ago"). The 0 placeholder is dead.
            let ago = row.overdueMinutesAgo ?? 0
            return ago >= 60
                ? String(localizable: .migrationStatusOverdueAgo(ago / 60))
                : String(localizable: .migrationStatusOverdueMinutesAgo(max(1, ago)))
        case .confirming:
            // GROUND_RULES R11 + Andrea's ladder: on the chain's side — broadcast, possibly
            // already mined per the engine — but the WALLET's own store has not counted it, so no
            // green and no "Done". Andrea's word for BOTH post-broadcast phases is the same plain
            // "Sent" — the model distinguishes broadcast-unmined from mined-unsynced (the [MIG]
            // trace prints :broadcast vs :confirming), the copy deliberately doesn't. The span is
            // minutes, routinely: the SDK's post-broadcast privacy buffer alone holds sync 180 s
            // testnet / 600 s mainnet. Visually distinct from Done by the NEUTRAL (non-green)
            // check. The old `.active where isBroadcasting` arm this absorbed is gone: every
            // broadcast row is `.confirming` now.
            return String(localizable: .migrationStatusSent)
        // MOB-1466 (Lukas's ruling, 2026-08-08): THE ONE ARRIVED ROW THAT KEEPS "Ready now".
        //
        // Every other row whose window has arrived now says "Recomputing ETA…" via the default arm
        // below, which is true of them: the engine's overdue re-spread raises EVERY pending
        // scheduled height on the next `advance_migration`, so a new time really is coming. It is
        // NOT true here. The re-spread deliberately excludes an anchor-gated transfer —
        // re-spreading on one "would shift the whole plan … every time the gate was waited out,
        // chasing its own tail" (`zcash_pool_migration`, satisfiability.rs) — so this row's height
        // sits in the past until its boundary block settles, and nothing will ever recompute it.
        // Promising a recomputation the engine has decided never to perform is the same class of
        // lie this whole change removes, pointing the other way.
        //
        // Lukas ruled the fallback rather than new copy: "keep it as 'ready now' (= unblocking you
        // with fallback value rather than some new one)". So `migrationPlan.readyNow` survives with
        // exactly ONE caller — this arm — instead of being the default answer for every passed row.
        // What it should ideally say stays open for Andrea: this is a real waiting state that has
        // never had its own frame.
        //
        // LAST before `default` on purpose. Every arm above describes something the row is doing
        // that outranks its clock — submitting, proving, dependency-blocked, broadcast, or wearing
        // the designed "Overdue · Nh ago" badge — and this must not steal any of them. It
        // intercepts only what would otherwise reach the ETA caption.
        case _ where row.isAwaitingAnchorBoundary && (row.forwardETAMinutes ?? Int.max) <= 0:
            return String(localizable: .migrationPlanReadyNow)
        default:
            // Pending/queued-active rows: the shared forward-ETA granularity per the frames
            // (S10-progress Transfer 4 = "~12 hours"). MOB-1513 (B3): a ready-now row now renders
            // "Ready now" (was the "~10 mins" `migrationPlanEtaFirst` fallback), bucketed by the same
            // `MigrationETA` helper every forward surface uses. MOB-1513 (A3): `minutesFromNow` now
            // carries the real, minute-precise ETA (the committed schedule's own per-transfer
            // height against the live tip) for rows backed by a committed schedule, so a sub-hour
            // transfer reads "in ~N mins" here too; it's nil only on the W1 progress-only fallback
            // (no committed schedule yet), where `forwardETAMinutes` falls back to `hoursFromNow`.
            return MigrationETA.caption(minutesFromNow: row.forwardETAMinutes, phrasing: .bare)
        }
    }

    // MARK: - Evaluating note

    /// Handover O2: the data zone's stand-in when the screen was presented before any session
    /// published a snapshot (see `MigrationStatus.State.isEvaluating`). The screen's chrome — back
    /// arrow, title — is real and live above this; only the list is being evaluated, and the
    /// sentence says so. Replaced wholesale by the first snapshot that arrives.
    @ViewBuilder private var evaluatingNote: some View {
        VStack(spacing: 12) {
            ProgressView()

            Text(localizable: .migrationStatusEvaluating)
                .zFont(size: 14, style: Design.Text.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
    }

    // MARK: - Tor-hold note

    /// R7 final review, Important-1 (spec §G): shown when `store.isTorHoldActive` — the info-icon
    /// + tertiary-caption row shape (the retired `footerNote`'s). Flagged for the product/design
    /// pass — no Figma exists for this line (same caveat the `migrationFailure.*` failure-sheet
    /// copy carries).
    @ViewBuilder private var torHoldNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            Text(localizable: .migrationFailureTorHoldStatusNote)
                .zFont(size: 12, style: Design.Text.tertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The `.progress` presentation's info footer — the final frame (Figma 5139-34627) pins one
    /// between the timeline and the "Got it" button. Same row shape as `torHoldNote` above: info
    /// icon + 12pt tertiary caption.
    ///
    /// F6 (Lukas, 2026-08-07) — STATE-DRIVEN, off `poolFlow.banner`, the same
    /// `MigrationBannerVariant` the banner renders from and the same signal the header paragraph
    /// forks on. The rule he set: "the info is tied to what banner says or is doing… the info
    /// should not have independent conditions." Until today this slot rendered ONE borrowed
    /// banner string (`migrationBanner.keepOpenInfo`) for the entire presentation — right in the
    /// two states where the banner also said keep-open, wrong in every other.
    ///
    /// Header and footer are not duplicates: the header states what is happening, the footer what
    /// happens if you leave. The C5 frame draws both.
    ///
    /// `default` is the idle sentence, and that is safe by construction — only four variants reach
    /// `.progress` (see `description`'s own note): `.checkingStatus` no longer opens this screen,
    /// and `hasInvalid` routes to `.recovery` ahead of every state arm.
    @ViewBuilder private var progressFooterNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            Text(footerSentence)
                .zFont(size: 12, style: Design.Text.tertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One sentence per banner state — see `progressFooterNote`. Whole sentences rather than a
    /// shared stem with a swapped verb, for the reason the header's fork records: a verb slotted
    /// into a sentence does not survive a language that reorders clauses.
    private var footerSentence: String {
        switch store.poolFlow.banner {
        case .preparing:
            // Covers the split's PROVE and its BROADCAST alike: a preparation submit deliberately
            // wears the preparing costume (`preparationBroadcastsInFlight`), never "Transfer N is
            // sending", so both halves of the split lane land here. Lukas accepted the imprecision
            // — "it's kinda weird to say prepared while it's sending split.. but it's what it is
            // in Figma" — and the ask itself stays correct either way.
            return String(localizable: .migrationStatusFooterPreparing)
        case .transferSending:
            return String(localizable: .migrationStatusFooterBroadcasting)
        default:
            return String(localizable: .migrationStatusFooterIdle)
        }
    }

    // MARK: - Buttons

    @ViewBuilder private var buttons: some View {
        switch store.presentation {
        case .progress, .rescheduleConfirmed:
            // `.rescheduleConfirmed`'s "Got it" routes through the same exit as `.progress`'s
            // (MOB-1478 W7).
            ZashiButton(String(localizable: .migrationGotIt)) {
                store.send(.gotItTapped)
            }
        case .resume:
            // NO BUTTONS, twice over. The Reschedule CTA is WITHHELD (AUD-2b interim, 2026-08-05,
            // the never-lie ruling — no production reschedule API exists yet; the store's
            // machinery stays for the #2927/#2932 wiring). The Send-now CTA was REMOVED
            // 2026-08-07 with the whole manual-tap send surface (Lukas: "send is driven only by
            // .broadcast(id) next_step"). The presentation is a READOUT: back is the exit; what
            // action (if any) this screen regains is product's (ERROR_HANDLING / B8-fate thread).
            EmptyView()
        }
    }
}

// MARK: - Presentation modifier

private extension View {
    /// `.progress`'s back was already close-like (`zashiBackV2` sending `.gotItTapped`) before
    /// `isFlowRoot` existed — that stands unconditionally. `.resume`'s back is a plain pop unless
    /// this screen is the coordinator's re-entry root, in which case it closes the flow instead
    /// (MOB-1466 back-semantics: "when `isFlowRoot == false`, current behavior stands").
    /// `.rescheduleConfirmed` (MOB-1478 W7) falls through to that same plain-pop-or-close handling —
    /// it never needs `.progress`'s special close-wired arrow.
    @ViewBuilder func applyPresentationModifier(store: StoreOf<MigrationStatus>) -> some View {
        if store.presentation == .progress {
            zashiBackV2 {
                store.send(.gotItTapped)
            }
        } else if store.isFlowRoot {
            zashiBackV2 {
                store.send(.closeTapped)
            }
        } else {
            zashiBack()
        }
    }
}

// MARK: - First-render prewarm

// `UIHostingController`-based prewarm is iOS-only (AppKit's analogous `NSHostingController` would
// need its own off-screen host-window plumbing to match, and this is a micro-optimization, not
// migration logic) — `AppDelegate`, the only caller, is itself `#if os(iOS)`-gated (see
// AppDelegate.swift), so this is already unreachable on macOS; the gate below just lets it compile.
#if os(iOS)
/// MOB-1466 (field, 2026-08-03): the FIRST render of this screen's view tree costs the process a
/// one-time payment — Swift instantiates generic metadata for the whole nested SwiftUI hierarchy
/// (timeline → rows → badges → …), and in unoptimized debug builds that payment is 1–2 s of main
/// thread. It was always there; while hydration was slow it happened after the push animation
/// settled and nobody saw it. Once the DBActor read/write split and the pre-sweep cache warm-up
/// made hydration fast, the payment moved INTO the push animation and froze it mid-slide — first
/// open only, because the runtime caches the metadata for the rest of the process.
///
/// The payment cannot be deleted, so it is moved: `AppDelegate` calls this once, shortly after
/// launch, and an off-screen `UIHostingController` renders the screen's heaviest views with the
/// preview fixtures below. By the time a user can reach the real screen, the metadata is warm and
/// the push animates clean. Release builds pay milliseconds here; debug pays its 1–2 s while the
/// user is still looking at the freshly launched Home screen instead of mid-animation.
enum MigrationStatusPrewarm {
    @MainActor static func run() {
        let content = VStack(alignment: .leading, spacing: 0) {
            // MigrationPoolFlowHeader was prewarmed here until R9 dropped the component entirely
            // (2026-08-03) — the timeline is the screen's remaining heavy view.
            MigrationTransferTimeline(
                rows: IdentifiedArrayOf<MigrationTransferRow>.previewProgressRows,
                caption: { _ in "" }
            )
        }
        let host = UIHostingController(rootView: content)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.layoutIfNeeded()
    }
}
#endif

// MARK: - Mock data

private extension IdentifiedArray where ID == MigrationTransferRow.ID, Element == MigrationTransferRow {
    /// The 6-transfer set from the "Final Designs" canvas (10.00 / 1.00 / 1.00 / 0.2 / 0.2 /
    /// 0.05 ZEC). MOB-1478 W7: Transfer 2 exercises sub-hour `sentMinutesAgo` ("Sent 18 min ago")
    /// and Transfer 3 exercises `isBroadcasting` ("Sending now"), matching the updated S10-progress
    /// frame.
    static var previewProgressRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000_000_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(
                id: "1", index: 1, amount: Zatoshi(100_000_000), status: .sent, hoursFromNow: 0, sentMinutesAgo: 18
            ),
            MigrationTransferRow(
                id: "2", index: 2, amount: Zatoshi(100_000_000), status: .active, hoursFromNow: 0, isBroadcasting: true
            ),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 12),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 18),
            MigrationTransferRow(id: "5", index: 5, amount: Zatoshi(5_000_000), status: .pending, hoursFromNow: 36)
        ]
    }

    /// The resume/re-scheduling frame (Figma B8 · Migration in Progress): two sent, one overdue,
    /// three pending.
    static var previewResumeRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000_000_000), status: .sent, hoursFromNow: 18),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(100_000_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(100_000_000), status: .overdue, hoursFromNow: 5),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 12),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 18),
            MigrationTransferRow(id: "5", index: 5, amount: Zatoshi(5_000_000), status: .pending, hoursFromNow: 36)
        ]
    }

    /// The post-reschedule confirmation frame (MOB-1478 W7): the two already-sent transfers stand,
    /// Transfer 3 (the one that was stalled) is freshly re-windowed to a real ETA rather than
    /// "Sending now" — the reschedule only re-queues it, broadcasting hasn't started yet.
    static var previewRescheduleConfirmedRows: Self {
        [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000_000_000), status: .sent, hoursFromNow: 6),
            MigrationTransferRow(
                id: "1", index: 1, amount: Zatoshi(100_000_000), status: .sent, hoursFromNow: 0, sentMinutesAgo: 18
            ),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(100_000_000), status: .active, hoursFromNow: 6),
            MigrationTransferRow(id: "3", index: 3, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 12),
            MigrationTransferRow(id: "4", index: 4, amount: Zatoshi(20_000_000), status: .pending, hoursFromNow: 18),
            MigrationTransferRow(id: "5", index: 5, amount: Zatoshi(5_000_000), status: .pending, hoursFromNow: 36)
        ]
    }
}

// MARK: - Previews

#Preview("Progress") {
    NavigationView {
        MigrationStatusView(
            store: StoreOf<MigrationStatus>(
                initialState: MigrationStatus.State(
                    presentation: .progress,
                    rows: .previewProgressRows,
                    totalDurationHours: 24
                )
            ) {
                MigrationStatus()
            }
        )
    }
}

#Preview("Resume") {
    NavigationView {
        MigrationStatusView(
            store: StoreOf<MigrationStatus>(
                initialState: MigrationStatus.State(
                    presentation: .resume,
                    rows: .previewResumeRows,
                    totalDurationHours: 24,
                    stalledNumber: 3,
                    stalledHoursAgo: 5
                )
            ) {
                MigrationStatus()
            }
        )
    }
}

#Preview("Re-scheduling") {
    NavigationView {
        MigrationStatusView(
            store: StoreOf<MigrationStatus>(
                initialState: MigrationStatus.State(
                    presentation: .resume,
                    rows: .previewResumeRows,
                    totalDurationHours: 24,
                    stalledNumber: 3,
                    stalledHoursAgo: 5,
                    isRescheduling: true
                )
            ) {
                MigrationStatus()
            }
        )
    }
}

#Preview("Reschedule Confirmed") {
    NavigationView {
        MigrationStatusView(
            store: StoreOf<MigrationStatus>(
                initialState: MigrationStatus.State(
                    presentation: .rescheduleConfirmed(first: 3, last: 6),
                    rows: .previewRescheduleConfirmedRows,
                    totalDurationHours: 24
                )
            ) {
                MigrationStatus()
            }
        )
    }
}
