//
//  MigrationStatusStore.swift
//  zodl
//
//  "Migration Progress" / "Resume Migration" / "Re-scheduling…" screen (MOB-1464, Figma S10 ·
//  progress 2709:3350 / resume 2696:7133 / re-scheduling 2840:3656).
//
//  R13 Brick 2: this screen renders THE published snapshot and nothing else. `onAppear` primes
//  synchronously from `currentMigrationSnapshot` (the channel's last value — painting the source,
//  not a cache), kicks one rebuild (`refreshMigrationSnapshot` — R3: every open re-verifies), and
//  subscribes `migrationSnapshotEvents` for live emissions. The private pulls this replaces —
//  `migrationTransfers()`/`migrationSummary()` per `stateEvents` tick, the cached-rows first
//  paint — were the "so behind" class of 2026-08-03: a doorbell with no payload, answered by each
//  surface at its own moment. The 30s pulse survives ONLY as a wall-clock writer (see
//  `.refreshPulse`): it asks the one pipeline to re-derive, never queries on its own.
//  When this screen is a flow re-entry root (`isFlowRoot`), its back control closes the flow
//  (`.done`) instead of popping — every other delegate is consumed by
//  `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1478 (W7): rows can now carry sub-hour sent recency (`sentMinutesAgo`) and a broadcasting
//  flag (`isBroadcasting`) — both just ride along through `statusLoaded`/`migrationStateChanged`
//  unchanged; the View derives their captions. `.rescheduleConfirmed(first:last:)` is a new
//  presentation reached via the public `rescheduleCompleted` action, landing on this same screen
//  instead of flipping `isRescheduling` back to `.resume`. The reschedule effect itself (SDK
//  reschedule + background-window scheduling) still runs in `MigrationCoordFlowCoordinator`, which
//  today pushes a fresh `TransferPlan` screen on completion instead — wiring it to send
//  `rescheduleCompleted` here is a later phase.
//
//  2026-08-07 (Lukas): THE SEND-NOW SURFACE IS GONE — "there is no send now anymore; send is
//  driven only by .broadcast(id) next_step, never waiting on manual tap." The D3 in-place lane
//  (biometrics -> silence window -> manager broadcast session), its `.delegate(.sendNow)` manual
//  push, the `sendGate()` consults, the `migrationSendWaitActive` fence and the windowMissed
//  footer all left with it. Delivery is exclusively the driver's `.broadcast(id)` discharge (open
//  lanes + tick); this screen's `.resume` presentation remains as the overdue re-entry READOUT —
//  timeline + notes, no send affordance. The failed-send retry surface is ERROR_HANDLING's open
//  product thread.
//

import Foundation
@preconcurrency import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationStatus {
    @ObservableState
    struct State: Equatable {
        enum Presentation: Equatable {
            case progress
            case resume
            /// Post-reschedule confirmation (MOB-1478 W7): entered via `rescheduleCompleted` instead
            /// of flipping back to `.resume`. `first`/`last` are the stalled-range transfer numbers
            /// ("Transfers {first}-{last}") captured from `.resume`'s `stalledNumber`/`rows.count` at
            /// the moment of transition.
            case rescheduleConfirmed(first: Int, last: Int)
        }

        /// Goal #6: the ORCHARD -> IRONWOOD header's data, from the SINGLE derivation the timeline
        /// rows also come from — so the header's Ironwood figure and the checkmarks below it cannot
        /// drift. See `MigrationViewSnapshot`.
        var poolFlow = MigrationViewSnapshot.empty
        /// GOAL #4: the split-detail sheet (Figma 5207-16025), opened by the "Show details" button
        /// on the collapsed Split Balance row (5207-16322). Its steps come from `poolFlow`, so the
        /// sheet is the FOURTH observer of one derivation rather than a fourth reader of the engine.
        var isSplitDetailPresented = false
        var presentation = Presentation.progress
        var rows: IdentifiedArrayOf<MigrationTransferRow> = []
        /// The schedule's total remaining-duration estimate. `nil` when not derivable — a W1
        /// fallback re-entry with no persisted schedule yet (MOB-1513) — never a placeholder `0`;
        /// the `.progress` description omits its duration clause when this is `nil` (see
        /// `MigrationStatusView.description`).
        var totalDurationHours: Int?
        /// Resume header: "Transfer {n} of {m} …".
        var stalledNumber = 0
        var stalledHoursAgo = 0
        /// Visual-only: skeleton captions + disabled spinner button on the resume presentation.
        var isRescheduling = false
        /// True when this screen is the coordinator's re-entry root (both presentations) — its back
        /// control then closes the flow instead of popping.
        var isFlowRoot = false
        /// MOB-1497 (R7 final review, Important-1 — spec §G): true iff the selected account's most
        /// recent broadcast failure was a mid-run Tor hold — carries the Tor-specific line on the
        /// `.resume` presentation (see `MigrationStatusView.torHoldNote`). Loaded both via
        /// `.statusLoaded` (live, re-derived on every load/state-change tick) and the coordinator's
        /// re-entry hydration (`MigrationCoordFlowCoordinator.statusResumeState`/
        /// `statusProgressState`) — the one stored per-load flag left here.
        var isTorHoldActive = false
        /// F#9 (MOB-1497 T5 completion): mirrors `snapshot.needsTorFirstRunChoice` — the
        /// headless-routed first-run Tor choice presents HERE, because the scheduled lane never
        /// visits the Sending screen that owns the interactive presentation. Present/dismiss
        /// follows the snapshot, so every surface drops the sheet in the same republish.
        var isTorChoicePresented = false
        /// F#9: the R11 off-warning alert for the Status-presented Tor choice — the same
        /// `AlertState.migrationTorOffWarning` the Sending lane presents (its exact `@Presents`
        /// + scoped-`.alert` shape).
        @Presents var alert: AlertState<Action>?
        /// Handover O2 (the QA force-quit): true when the screen was presented before ANY session
        /// ever published a snapshot — the coordinator's hydration read a `nil` published window
        /// (typically: first open of the process while a prove sweep holds the DB actor). The
        /// screen presents its chrome (back + title) with a centered "Evaluating state…" spinner
        /// in place of the timeline, instead of navigation waiting out the sweep behind a bare
        /// spinner. Cleared by the first value that arrives — the `onAppear` prime or any
        /// `snapshotUpdated` emission — never by a timer: the data's arrival IS the state change.
        var isEvaluating = false
        var cancelStateStreamId = UUID()
        /// MOB-1466: the 30s refresh pulse's cancel id — see `onAppear`'s pulse effect.
        var cancelRefreshPulseId = UUID()
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        var remainingCount: Int {
            rows.filter { $0.status != .sent }.count
        }

        /// MOB-1513 (A2): mirrors `MigrationTransferPlan.State.splitRow` for this post-commit
        /// screen — but COMPLETED (`.sent`) rather than merely ready, since by the time any
        /// Status/Resume/reschedule-confirmed presentation is reachable the note-split has
        /// definitely already broadcast (a precondition of scheduling any transfer at all — see
        /// `MigrationTransferTimeline`'s header doc for the shared-component side of this fix).
        /// `nil` before any rows have loaded. Computed off `rows` (not stored) so it can never
        /// drift from whatever `rows` currently holds — including the coordinator's own re-entry
        /// hydration (`statusResumeState`/`statusProgressState`), which constructs `rows` directly
        /// without going through `.statusLoaded` — and so it doesn't force every
        /// `.statusLoaded`/`.rescheduleCompleted` call site (and every existing exhaustive
        /// `TestStore` assertion) to separately track a parallel stored field.
        /// D14: the run's REAL note-preparation rows — now read from `poolFlow`, NOT from a stored
        /// second copy.
        ///
        /// It WAS a separate stored field, hydrated by its own `migrationPreparationRows` call one
        /// line below the coordinator's snapshot read. Both ultimately call the same manager
        /// function, but at two moments, which is the two-clocks shape this whole pass exists to
        /// remove — and it bit immediately: the collapsed row was built from one copy while the
        /// row's own "· N steps" count and the "Show details" gate read the other. A row that
        /// disagrees with its own step count is worse than either version alone.
        ///
        /// Empty means "no preparation statuses readable", and `splitRows` falls back to the single
        /// synthesized row below — exactly what this screen showed before D14.
        var preparationRows: [MigrationTransferRow] { poolFlow.preparations }

        var splitRows: IdentifiedArrayOf<MigrationTransferRow> {
            // GOAL #4 (field, 2026-08-03): the timeline shows ONE Split Balance row, ALWAYS.
            //
            // It used to return the real per-split rows as soon as the engine had them, so the
            // screen changed shape the moment a migration started: the "Split Balance" summary of
            // Figma 5207-16024 at the start, then abruptly Split 1 / Split 2 / Split 3 as separate
            // timeline entries once splitting began. Lukas's call, and the right one — the split is
            // ONE step in the user's story of the migration, and its parts belong in the sheet, not
            // in the same list as the transfers.
            //
            // The real rows are still the SOURCE: collapsed here so the row's state and ETA stay
            // truthful for a multi-layer split that is genuinely part-way through, rather than
            // falling back to the `.sent` placeholder below (which is only correct when there is no
            // engine data at all).
            if !preparationRows.isEmpty {
                return [
                    Self.collapsedSplitRow(
                        from: preparationRows,
                        transfers: rows,
                        isSubmitting: poolFlow.isSubmitting
                    )
                ]
            }

            guard !rows.isEmpty else { return [] }
            // MOB-1513: `rows` can now be a W1-fallback derivation (no committed schedule — every
            // row's `amount` is `nil` on that path) — the sum stays honest: `nil` (unknown total)
            // if ANY row's amount is, rather than silently treating an unknown row as zero.
            let totalAmount: Zatoshi? = rows.contains { $0.amount == nil }
                ? nil
                : rows.reduce(Zatoshi.zero) { $0 + ($1.amount ?? Zatoshi.zero) }
            return [
                MigrationTransferRow(
                    id: "split-balance",
                    index: 0,
                    amount: totalAmount,
                    status: .sent,
                    hoursFromNow: 0,
                    kind: .splitBalance
                )
            ]
        }

        /// GOAL #4: the per-split engine rows as ONE timeline entry — see `splitRows`.
        ///
        /// AMOUNT is the total being migrated (the transfers' sum), NOT the preparations' sum:
        /// preparations are self-sends that repeatedly re-split the same balance, so adding them
        /// would multiply-count the user's own money. Taken from the transfers keeps the figure
        /// identical before and after splitting starts, which is the point — the number must not
        /// jump when the shape of the list stops changing.
        ///
        /// STATUS is the least-finished part: a split is done only when every part of it is.
        /// ETA is the furthest-out part, for the same reason.
        ///
        /// `isSubmitting` is the collapsed row's THIRD source of truth about itself and deliberately
        /// not derived from `preparations`: no durable row can know a submit call is open — the
        /// engine only writes `.broadcast(txid:)` once it returns. It comes from the snapshot, the
        /// same value the banner's split arm reads, so the row spins for exactly the window the
        /// banner asks the user to stay. See `MigrationTransferRow.isSubmitting`.
        static func collapsedSplitRow(
            from preparations: [MigrationTransferRow],
            transfers: IdentifiedArrayOf<MigrationTransferRow>,
            isSubmitting: Bool
        ) -> MigrationTransferRow {
            let total: Zatoshi? = transfers.isEmpty || transfers.contains { $0.amount == nil }
                ? nil
                : transfers.reduce(Zatoshi.zero) { $0 + ($1.amount ?? Zatoshi.zero) }

            let allSent = preparations.allSatisfy { $0.status == MigrationTransferRow.Status.sent }
            // Field, 2026-08-03 ("took me a while to see why"): the banner said "Keep Zodl open"
            // with a spinner while this collapsed row showed a bare ETA — the PROVING child's
            // in-flight state was dropped by the collapse, so the one row on screen never said
            // why staying mattered, and the user had to open the sheet to find a single quiet
            // "Preparing". The collapse now picks its REPRESENTATIVE child by story priority
            // rather than list order: a child the app is proving RIGHT NOW outranks one merely
            // waiting on the chain (`.confirming`), which outranks one waiting on its schedule —
            // so the collapsed caption and spinner (`isInFlight` = the propagated `isPreparing`)
            // tell the most actionable truth the parts contain, and the banner's keep-open ask
            // has its on-screen counterpart again.
            let proving = preparations.first { $0.isPreparing && $0.status != MigrationTransferRow.Status.sent }
            let confirming = preparations.first { $0.status == MigrationTransferRow.Status.confirming }
            let unfinished = preparations.first { $0.status != MigrationTransferRow.Status.sent }
            let representative = proving ?? confirming ?? unfinished

            return MigrationTransferRow(
                id: "split-balance",
                index: 0,
                amount: total,
                status: allSent ? MigrationTransferRow.Status.sent : (representative?.status ?? MigrationTransferRow.Status.sent),
                hoursFromNow: preparations.map(\.hoursFromNow).max() ?? 0,
                isPreparing: !allSent && proving != nil,
                isSubmitting: isSubmitting,
                kind: MigrationTransferRow.Kind.splitBalance
            )
        }

        init(
            presentation: Presentation = .progress,
            rows: IdentifiedArrayOf<MigrationTransferRow> = [],
            totalDurationHours: Int? = nil,
            stalledNumber: Int = 0,
            stalledHoursAgo: Int = 0,
            isRescheduling: Bool = false,
            isFlowRoot: Bool = false
        ) {
            self.presentation = presentation
            self.rows = rows
            self.totalDurationHours = totalDurationHours
            self.stalledNumber = stalledNumber
            self.stalledHoursAgo = stalledHoursAgo
            self.isRescheduling = isRescheduling
            self.isFlowRoot = isFlowRoot
        }
    }

    enum Action: Equatable {
        /// Flow-root back control: closes the flow instead of popping.
        case closeTapped
        /// Progress CTA and the X close.
        case gotItTapped
        case showSplitDetailTapped
        case splitDetailDismissed
        /// The sheet's presentation BINDING (`$store...sending`) — SwiftUI writes `false` here on
        /// drag-dismiss. Distinct from `splitDetailDismissed` (the sheet's own button) only in who
        /// sends it; both land on the same flag.
        case splitDetailPresentedChanged(Bool)
        case delegate(Delegate)
        case onAppear
        /// The screen left the hierarchy — tears down the two `onAppear` effects (the snapshot
        /// subscription and the wall-clock pulse). The pulse's own comment always said "cancelled
        /// with the screen"; until this action existed, nothing did it, and both effects kept
        /// firing into a path whose element was gone (hundreds of TCA missing-element warnings per
        /// session, field-caught 2026-08-03).
        case onDisappear
        /// R13 Brick 2: the screen's 30s wake-up survives ONLY as a wall-clock WRITER — ETA
        /// captions age with the clock, which no DB write announces, so the screen asks THE
        /// pipeline to re-derive (`refreshMigrationSnapshot`), never queries on its own. The
        /// channel's value-equality dedupe keeps quiet ticks silent. Retires when rows carry
        /// absolute dates the view formats live.
        case refreshPulse
        /// R13 Brick 2: THE screen's one data action — a fresh `MigrationViewSnapshot` published
        /// by the channel (every writer edge republishes; emissions are value-deduplicated).
        /// Replaces `statusLoaded`/`migrationStateChanged`: rows, duration, Tor-hold and the pool
        /// header all land from ONE value, so no two facts on this screen can be from different
        /// moments.
        case snapshotUpdated(MigrationViewSnapshot)
        /// F#9: the R11 off-warning alert's routing — `MigrationSendingStore`'s exact shape.
        case alert(PresentationAction<Action>)
        /// F#9: the sheet's own R11 warning confirmation — proceeds without Tor for this run.
        case torChoiceOffWarningConfirmed
        /// F#9: present/dismiss binding for the first-run Tor sheet; `false` resolves the pending
        /// prompt (keep Tor, wait) — swipe-dismiss and Cancel land here identically.
        case torChoicePresentedChanged(Bool)
        /// F#9: the sheet's "Proceed without Tor" — presents the R11 warning alert first.
        case torChoiceProceedTapped
        /// Public: the coordinator's reschedule effect (SDK reschedule + first-window scheduling)
        /// finished — lands on `.rescheduleConfirmed` with the refreshed rows/duration instead of
        /// flipping `isRescheduling` back to `.resume`. The coordinator doesn't send this yet (it
        /// still pushes a fresh `TransferPlan` screen on completion) — wiring it up is a later phase;
        /// this action is the store-side surface for it (MOB-1478 W7).
        case rescheduleCompleted(rows: [MigrationTransferRow], totalDurationHours: Int?)
        case rescheduleTapped
        // (R13 Brick 2: `statusLoaded` retired — see `snapshotUpdated`. 2026-08-07: the whole
        // sendNow action family — tapped/authenticated/windowCleared/finished — and the
        // `.sendNow` delegate retired with the manual-tap send surface.)
        enum Delegate: Equatable {
            case done
            case reschedule
        }
    }

    /// MOB-1466: the open screen's re-derivation period — see `onAppear`'s refresh-pulse effect.
    /// Deliberately its OWN constant, not `migrationTickInterval`: the tick loop's `.zero` off
    /// switch must not silence this screen (ETA captions age with the wall clock either way) —
    /// pinned by `thePulseStillFiresWithTheTickLoopSwitchedOff`.
    private static let refreshPulseInterval: Swift.Duration = .seconds(30)

    @Dependency(\.continuousClock) var continuousClock
    @Dependency(\.migrationManager) var migrationManager

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .closeTapped:
                return .send(.delegate(.done))

            case .showSplitDetailTapped:
                state.isSplitDetailPresented = true
                return .none

            case .splitDetailPresentedChanged(let presented):
                state.isSplitDetailPresented = presented
                return .none

            case .splitDetailDismissed:
                state.isSplitDetailPresented = false
                return .none

            case .gotItTapped:
                return .send(.delegate(.done))

            case .delegate:
                return .none

            case .onAppear:
                let accountUUID = state.selectedWalletAccount?.id
                // PAINT FIRST, THEN SUBSCRIBE (R13 Brick 2). Field-caught 2026-08-01: tapping the
                // banner gave a blank screen with a spinner for ten seconds and more, because this
                // screen drew nothing until an async read returned — measured at 4.75 s on a quiet
                // open and 18.3 s while the prove sweep held the wallet database. So it paints the
                // channel's LAST PUBLISHED value synchronously, before the first frame — that is
                // painting THE source, not a side cache. (Until 2026-08-07 an `isUpdating` flag
                // also labelled that value as an earlier session's answer, and an `asOfSyncedAt`
                // age line sat beside it. Neither was ever in a design; both are gone. The screen
                // states what IS, and says nothing about the freshness of its own plumbing.)
                //
                // Guarded on `rows.isEmpty` so it never clobbers fresher rows the coordinator's own
                // re-entry hydration already put in state.
                if state.rows.isEmpty, let published = migrationManager.currentMigrationSnapshot(accountUUID) {
                    state.isEvaluating = false
                    state.poolFlow = published
                    state.rows = IdentifiedArrayOf(uniqueElements: published.transfers)
                    state.totalDurationHours = published.summary.estimatedDurationHours
                    state.isTorHoldActive = published.isTorHoldActive
                    // The render half of the pipeline audit: this line's figures must echo the
                    // manager's own "SNAPSHOT: published" line — DB → loader → channel → pixels,
                    // confirmable by grep.
                    MigrationTrace.event(
                        "SNAPSHOT applied @ status (primed)"
                        + " — done \(published.doneTransfers)/\(published.totalTransfers)"
                        + " · rows \(published.transfers.count)"
                        + " · iw \(published.ironwoodHeld.decimalString())"
                    )
                }
                // R3 in channel form: every open re-verifies — one coalesced rebuild lands as the
                // subscription's first live emission and replaces the primed value.
                migrationManager.refreshMigrationSnapshot(accountUUID)
                return .merge(
                    .publisher {
                        // `dropFirst()` skips the subject's replay — the synchronous prime above
                        // already consumed it; every forwarded emission is a genuinely fresh build.
                        migrationManager.migrationSnapshotEvents(accountUUID)
                            .dropFirst()
                            .compactMap { $0 }
                            .map(Action.snapshotUpdated)
                    }
                    .cancellable(id: state.cancelStateStreamId, cancelInFlight: true),
                    // The wall-clock pulse — see `.refreshPulse`. First tick a full 30s in; the
                    // rebuild above just ran.
                    .run { send in
                        for await _ in continuousClock.timer(interval: MigrationStatus.refreshPulseInterval) {
                            await send(.refreshPulse)
                        }
                    }
                    .cancellable(id: state.cancelRefreshPulseId, cancelInFlight: true)
                )

            case .onDisappear:
                return .merge(
                    .cancel(id: state.cancelStateStreamId),
                    .cancel(id: state.cancelRefreshPulseId)
                )

            case .refreshPulse:
                // The wall-clock writer: ask THE pipeline to re-derive (ETA captions age with the
                // clock, which no DB write announces). Never a private query; the channel's
                // value-equality dedupe keeps quiet ticks off the screen.
                migrationManager.refreshMigrationSnapshot(state.selectedWalletAccount?.id)
                return .none

            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .torChoicePresentedChanged(let isPresented):
                state.isTorChoicePresented = isPresented
                guard !isPresented else { return .none }
                // F#9: dismissing IS the "keep Tor, wait" resolution — consuming the latch is
                // idempotent, and it re-arms on the next failed attempt if Tor stays unreachable.
                return .run { [account = state.selectedWalletAccount?.id] _ in
                    await migrationManager.resolveMigrationTorPrompt(account)
                }

            case .torChoiceProceedTapped:
                // R11 parity with the Sending lane: proceeding without Tor is a privacy-reducing
                // choice, so the designed warning alert gates it here exactly as it does there.
                let usesFullBalanceCopy = migrationManager.migrationMode(state.selectedWalletAccount?.id) == MigrationMode.immediate
                state.alert = AlertState.migrationTorOffWarning(
                    usesFullBalanceCopy: usesFullBalanceCopy,
                    proceedAction: .torChoiceOffWarningConfirmed
                )
                return .none

            case .torChoiceOffWarningConfirmed:
                state.isTorChoicePresented = false
                return .run { [account = state.selectedWalletAccount?.id] _ in
                    // The override consumes the pending prompt itself; the explicit resolve after
                    // it republishes so every surface drops the sheet in the same pass.
                    migrationManager.overrideTorForRun(account, false)
                    await migrationManager.resolveMigrationTorPrompt(account)
                }

            case .rescheduleCompleted(let rows, let totalDurationHours):
                // NEVER-LIE BELT (AUD-2b interim, 2026-08-05): land back on `.resume`, NOT on
                // `.rescheduleConfirmed` — no production reschedule API exists yet, so nothing was
                // rescheduled and the confirmation copy ("successfully rescheduled") was false.
                // The CTA that reached this is withheld from the view for the same reason; this
                // arm is the belt for any path that still sends the action. Restore
                // `.rescheduleConfirmed(first: state.stalledNumber, last: state.rows.count)` only
                // when the completion reports a REAL engine re-spread (librustzcash #2927/#2932).
                state.presentation = .resume
                state.rows = IdentifiedArrayOf(uniqueElements: rows)
                state.totalDurationHours = totalDurationHours
                state.isRescheduling = false
                return .none

            case .rescheduleTapped:
                state.isRescheduling = true
                return .send(.delegate(.reschedule))

            case .snapshotUpdated(let snapshot):
                state.isEvaluating = false
                state.poolFlow = snapshot
                state.rows = IdentifiedArrayOf(uniqueElements: snapshot.transfers)
                state.totalDurationHours = snapshot.summary.estimatedDurationHours
                state.isTorHoldActive = snapshot.isTorHoldActive
                // F#9: presentation follows the snapshot — the sheet appears when the headless
                // lane latched the first-run choice and drops when any surface resolved it.
                state.isTorChoicePresented = snapshot.needsTorFirstRunChoice
                // The render half of the pipeline audit — echoes the manager's "SNAPSHOT:
                // published" figures, so "DB holds it, UI renders it" is one grep away.
                MigrationTrace.event(
                    "SNAPSHOT applied @ status — done \(snapshot.doneTransfers)/\(snapshot.totalTransfers)"
                    + " · rows \(snapshot.transfers.count)"
                    + " · iw \(snapshot.ironwoodHeld.decimalString())"
                )
                return .none
            }
        }
    }

    // (D3's in-place Send-now silence window — `sendWindowWaitEffect`, the
    // `migrationSendWaitActive` fence, `setSendWaitActive`, the `sendGate()` consults and the
    // `syncPrivacyBufferMinutes` footer formula — was REMOVED 2026-08-07 with the whole
    // manual-tap send surface.)
}
