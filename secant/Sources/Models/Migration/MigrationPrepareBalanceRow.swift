//
//  MigrationPrepareBalanceRow.swift
//  zodl
//
//  One preparation ("split") transaction, as the "Prepare Your Balance" sheet renders it
//  (Figma 5207:16024).
//
//  A run's note-split is not necessarily ONE transaction: the engine reports several across
//  `preparationLayers`, and a later layer can only be built once an earlier one has mined (its
//  inputs are the notes that layer mints). The Transfer Plan timeline therefore shows a single
//  collapsed "Split Balance" row carrying the whole split's amount, and this model backs the sheet
//  behind its "Show details" disclosure, where each step reports what it is waiting on.
//
//  Steps carry no amount by design — `MigrationTransactionStatus` has none to give, and dividing
//  the total N ways would be invented. The sheet shows one honest "Amount Being Split" total in its
//  footer instead.
//
//  The `State` cases map 1:1 onto the engine's per-transaction view once the FFI for
//  `MigrationState::transaction_statuses` lands (zcash/librustzcash#2867 and the `state` module):
//
//  | engine                                        | here            |
//  |-----------------------------------------------|-----------------|
//  | `MigrationTxState::Mined`                     | `.done`         |
//  | `ready` + `NextAction::Prove` / `.Broadcast`   | `.readyToSend`  |
//  | `MigrationTxState::Broadcast`                 | `.sent`         |
//  | `Blocker::Dependencies` (+ `depends_on`)      | `.waitsOn([…])` |
//
//  Until that exists, `interimLadder(count:)` supplies a shaped placeholder so the sheet, its copy
//  and its layout can be built and reviewed ahead of the engine work. Only that one function is
//  provisional — the model and the sheet are not.
//

import Foundation

struct MigrationPrepareBalanceRow: Equatable, Identifiable, Sendable {
    /// What this step is doing. Ordered as the sheet reads top to bottom.
    enum State: Equatable, Sendable {
        /// Mined AND counted by the wallet's own store: this step is behind us (GROUND_RULES
        /// R11 — same standard as every green in the app).
        case done
        /// On the chain's side — broadcast, possibly engine-mined — but the wallet has not counted
        /// it yet. Andrea's five-state ladder (2026-08-03): the word is "Sent", the check is the
        /// neutral one, and there is NO spinner — the chain is working, not the app.
        case sent
        /// Built and due — the wallet can act on it now. Emitted only by the pre-commit
        /// `interimLadder` today: on a REAL run there is no user send action for a preparation
        /// (the app proves and delivers it — D2), so live rows read `.scheduled` or `.preparing`
        /// instead (field 2026-08-05 — this state used to be stamped on every pending step,
        /// schedule-blind).
        case readyToSend
        /// Its scheduled turn is still ahead — the time line under the title says when. Distinct
        /// from `.preparing` because Andrea's ladder reserves that word for work the app is doing
        /// NOW, and from `.readyToSend` because a future turn promises no action to anyone.
        case scheduled
        /// The app's OWN work is on this step right now — its turn has arrived and proving (or
        /// the submit) is running or seconds away. The live-spinner state, and the only one:
        /// Andrea's ladder reserves "Preparing" for app work, so a broadcast step reads `.sent`
        /// (the chain's side), never this. THE SPINNER INVARIANT (Lukas, 2026-08-06): a stalled
        /// sweep remaps due steps to `.scheduled` — the derivation never claims this state while
        /// the banner is quiet.
        case preparing
        /// Blocked until the listed steps have mined. Values are the step numbers AS DISPLAYED
        /// (1-based), so the view never re-derives them; empty is treated as `.preparing` by the
        /// caption, since "waits on nothing" is not a state a user can act on.
        case waitsOn([Int])
        /// SDK addendum §3: dead by an observed event — the engine marked this step
        /// `MigrationTransactionStatus.State.invalid`. No chain condition makes it actionable
        /// again; the run needs the attention flow. Distinct from every state above because it is
        /// the only one the user must DO something about, and rendering it as "Preparing" (which is
        /// where it landed before the state existed) would say the opposite.
        case invalid
    }

    var id: String
    /// 0-based position in the run. The sheet displays `index + 1`.
    var index: Int
    var state: State
    /// Minutes from now until this step is expected to become actionable. `0` reads "Starts right
    /// away" — the design's own first row (5207-16025 draws "in ~0 hours" there).
    ///
    /// NIL FOR A STEP THAT HAS ALREADY HAPPENED, which is why this became optional (field,
    /// 2026-08-03). A `.done` step has no future to state, but a plain `Int` forced it to supply
    /// one, and the only available number was 0 — which the sheet rendered as "Starts right away"
    /// UNDER A GREEN CHECKMARK, beside the word "Done".
    ///
    /// The design never draws a done step: 5207-16025 is the pre-commit ladder, every row still
    /// ahead (in ~0 / ~1 / ~2 / ~3 hours). So nothing specified what a finished row should read, and
    /// the type answered "right away" on the design's behalf. `nil` says "no forward time", and the
    /// sheet omits the line. Absence renders; a wrong number does not.
    /// Whether this step has ANY forward statement to make. `false` for a step that is finished,
    /// on the chain's side, or needing the user — those render their badge and trailing word with no
    /// time line at all (Lukas, 2026-08-07: "finished rows are silent, they have green checkmark and
    /// DONE label").
    ///
    /// Separate from `minutesFromNow` because the two answer different questions and a single
    /// optional could not carry both once "the tip is unknown" existed as a third state.
    var hasForwardTime = true
    /// How long until this step's turn, when there is one. `nil` while `hasForwardTime` means the
    /// chain tip was unknown — no ETA to state, so the sheet says "Recomputing ETA…" rather than
    /// the "Starts right away" a fabricated zero produced on every row at once.
    var minutesFromNow: Int?

    /// A shaped placeholder ladder for `count` steps, pending the real per-transaction statuses:
    /// the first step ready, the second in flight, and each later one waiting on its predecessor —
    /// the shape of a multi-layer split, with none of its real timing.
    ///
    /// The renderer is NOT provisional: `.waitsOn` already takes a set, so a real dependency naming
    /// several predecessors ("Waits on steps 1 & 2", as the design draws step 3) renders correctly
    /// the moment `depends_on` is wired, with no change to the sheet.
    /// The sheet's steps from the ENGINE's own preparation rows — the real thing
    /// `interimLadder` stood in for.
    ///
    /// Reads the rows carried on `MigrationViewSnapshot`, so the sheet renders the same split the
    /// timeline row collapses and the pool header counts. Four observers, one derivation.
    ///
    /// `.expired` maps to `.invalid`: both mean this step needs the user, and the sheet has one
    /// state for that. `.pending` maps to `.waitsOn` its predecessors — the honest reading of a
    /// step the engine has not released yet.
    static func from(preparations: [MigrationTransferRow]) -> [MigrationPrepareBalanceRow] {
        preparations.enumerated().map { position, row in
            let state: State
            switch row.status {
            case .sent:
                state = .done
            case .confirming:
                // GROUND_RULES R11 + Andrea's ladder: on the chain's side, wallet not yet counted
                // it — "Sent", NOT `.done` (the sheet's green must flip in the same sync write as
                // the timeline's, or the two surfaces contradict through one disclosure tap) and
                // NOT `.preparing` (that word claims the APP is working; here the chain is).
                state = .sent
            case .invalid, .expired:
                state = .invalid
            case .active, .overdue:
                // Schedule-aware (field 2026-08-05): a row whose turn is still minutes-to-hours
                // ahead is SCHEDULED — the old mapping stamped every pending step "Ready to send",
                // and once rows drifted overdue under the G1 tick gap their 0-clamped ETAs read
                // "Starts right away" beside it: a sheet full of ready-to-send steps with no time
                // anywhere. A due step is `.preparing` whether or not the sweep has picked it up
                // yet — the app's work is seconds away (the tick loop), and no user action exists
                // for a preparation either way.
                state = !row.isPreparing && (row.forwardETAMinutes ?? Int.max) > 0 ? .scheduled : .preparing
            case .pending:
                // Displayed step numbers are 1-based, and a first step that is somehow pending
                // waits on nothing the user can see — the caption treats an empty list as
                // `.preparing`, which is the truthful fallback.
                state = .waitsOn(Array(1...max(1, position)).filter { _ in position > 0 })
            }
            return MigrationPrepareBalanceRow(
                id: row.id,
                index: position,
                state: state,
                // `forwardETAMinutes`, NOT `hoursFromNow * 60` — the row's own helper, which prefers
                // the minute-precise value and falls back to hours only where no better one exists.
                // Multiplying the coarse field discarded precision the engine had already computed:
                // every step under an hour collapsed to 0 and read "Starts right away", so a real
                // ladder (the design draws ~0 / ~1 / ~2 / ~3 hours) flattened into four identical
                // lines. No forward time for a step with no future to state: finished (`.sent`),
                // on the chain's side (`.confirming` — the chain is working, not a schedule), or
                // needing the user (`.invalid`/`.expired`). A plain 0 on those rendered "Starts
                // right away" under "Sent" — the same lie the done-row fix already removed.
                // MOB-1466: `hasForwardTime` is the finished/unfinished question and
                // `minutesFromNow` is the how-long one. They used to share a single `nil`, which
                // stopped working the moment "the tip is unknown" became a third answer — a
                // completed step and an undateable one are both wordless, but only one of them
                // should say "Recomputing ETA…".
                hasForwardTime: {
                    switch row.status {
                    case .sent, .confirming, .invalid, .expired:
                        return false
                    default:
                        return true
                    }
                }(),
                minutesFromNow: {
                    switch row.status {
                    case .sent, .confirming, .invalid, .expired:
                        return nil
                    default:
                        return row.forwardETAMinutes.map { max(0, $0) }
                    }
                }()
            )
        }
    }

    static func interimLadder(count: Int) -> [MigrationPrepareBalanceRow] {
        let total = max(1, count)
        return (0..<total).map { index in
            let state: State
            switch index {
            case 0: state = .readyToSend
            case 1: state = .preparing
            default: state = .waitsOn([index])
            }
            return MigrationPrepareBalanceRow(
                id: "preparation-\(index)",
                index: index,
                state: state,
                minutesFromNow: index * 60
            )
        }
    }
}
