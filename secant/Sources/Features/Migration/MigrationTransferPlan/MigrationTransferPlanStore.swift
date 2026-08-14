//
//  MigrationTransferPlanStore.swift
//  zodl
//
//  "Transfer Plan" screen (MOB-1463, Figma S6 · scheduled 2867:10211 / manual 2867:2198 /
//  re-created 2709:3519). One-time review of the migration schedule before signing: a timeline of
//  transfer rows, each showing its amount, status, and ETA. A fresh entry proposes its own schedule
//  on `onAppear`; a recovery/reschedule variant instead has its schedule injected by the coordinator
//  (`injectedSchedule`) and must not re-propose. `confirmTapped` signs and stores whichever schedule
//  is active, unless `requiresSigning == false` (the rescheduled variant, whose transfers are
//  already signed), in which case it's a plain acknowledgment (MOB-1466). Chaining the
//  `confirmTapped` delegate into the rest of the flow is `MigrationCoordFlow`'s job.
//
//  MOB-1468 (Keystone): a Keystone-vendor account with `requiresSigning == true` (fresh + re-created
//  plans) forks `confirmTapped` — instead of signing+storing locally, it proposes the schedule's
//  PCZTs (`proposeMigrationPCZTs(schedule)`) and delegates `.keystoneSignRequested(pczts)` for the
//  coordinator to route through `MigrationKeystoneSign` + `Scan` in ONE batched session. The software
//  path and the rescheduled `requiresSigning == false` variant (never re-signs) are unchanged.
//
//  MOB-1496 (R8-T1 remediation): the software commit sequence and the Keystone PCZT-proposal fork
//  delegate to the shared `MigrationCommitPipeline` (finding #19 — this store and
//  `MigrationReviewTransferStore` drove byte-identical copies of both before).
//  `onAppear`'s propose and `confirmTapped`'s commit never silently fall back to an empty
//  schedule on failure (finding S3): a propose failure presents the SAME failure sheet with
//  `failureReason == .propose` (Retry re-proposes), and Confirm is guarded against a nil or
//  zero-transfer schedule regardless of why. The Keystone fork throws through instead of swallowing
//  errors with `try?`, and an empty PCZT batch is also a failure (finding #4).
//
//  MOB-1513 (B4 — confirm redesign): the commit chain is SIGN-ONLY, plus (Field 2026-08-06) an
//  AWAITED first drive under the same Confirm loader. The MOB-1478 (W4) silent note-split
//  broadcast that used to run under this screen's Confirm (`submitNoteSplit`: proving + inline
//  Tor + broadcast — the multi-second confirm freeze QA hit) left the chain entirely, along with
//  its whole R14-R17 broadcast-failure surface (`failureKind`, `broadcastFailureRouted`, the Tor
//  off-warning alert, and the sync-server fallback actions this store carried in R9-T2) — a
//  commit failure is a plain thrown error now, presented on the existing generic Cancel/Retry
//  sheet. `commitSoftware` returning is no longer the end of the chain: `.scheduleCommitted`
//  keeps the loader up through `migrationManager.advance(.afterSync)` (at tip; skipped mid-sync,
//  deferring to the coming edge) before `.scheduleSigned` navigates — so the run's first
//  preparation is prepared, presigned, and its split broadcast BEFORE this screen ever leaves,
//  not only after, via `MigrationCoordFlowCoordinator`'s post-confirm first-delivery kick. That
//  drive is the DRIVER's own lane (`MigrationManagerClient.advance`, the same call Root's G1 case
//  makes) — NEVER reintroduce an inline SDK broadcast call here (no `submitNoteSplit`/
//  `prepareNoteSplit`); broadcast failures still surface (and retry) through the migration
//  progress machinery, never on this screen. Confirm shows a loader (`isConfirming`) and is
//  single-flight. The Keystone fork's batch (`requestKeystoneSignature`) still proposes any
//  preparation PCZTs first, so the whole batch (preps + all N transfers) signs in the same QR
//  ceremony.
//
//  MOB-1458 (Task 3): both pre-commit consent-echo calls — `commitSoftware`'s
//  `signAndStoreMigrationSchedule` and `requestKeystoneSignature`'s `proposeKeystoneBatch`
//  (`proposeMigrationPCZTs`) — echo-validate the schedule they're handed against the engine's
//  one-slot plan cache and throw `ZcashError.migrationPlanStale` when it no longer matches (a
//  process restart between propose and confirm, a balance change underneath the preview, or a
//  concurrent propose overwriting the cache). That case is now caught SPECIFICALLY on both paths
//  (`refreshAfterPlanStale`) instead of falling into the generic futile-retry failure sheet: a
//  fresh `proposeMigrationTransfers` re-propose (the same call `proposeEffect`'s Retry makes)
//  replaces the stale schedule, `.planStaleRefreshed` re-displays it exactly like a normal
//  propose, and a toast tells the user to review it before re-confirming. Nothing is signed or
//  stored on this path — a thrown commit persists nothing (see `commitSoftware`'s own doc), and
//  the re-propose never blindly re-signs the stale copy (ZIP 318 draws fresh schedule randomness
//  on every proposal, so the SDK never silently signs a plan the user was not shown). Any OTHER
//  thrown error on either path keeps the existing `.noteSplitFailed` handling unchanged.
//
//  MOB-1458: `confirmTapped`/`retryTapped` gate behind device authentication (Face ID / Touch ID /
//  passcode, via `LocalAuthenticationClient`) before running the real confirm body —
//  `State.confirmRequiresAuthentication` decides whether the prompt is needed (F2: reduced to
//  plain `requiresSigning` now — see its own doc for where the expired-recovery review's gate
//  moved). `state.isConfirming` is set `true` BEFORE the gate's effect launches, not after, so the
//  Confirm button's existing spinner covers the authentication sheet too and a double-tap hits the
//  single-flight guard at the top of this case instead of opening a second prompt. A pass sends
//  `.confirmAuthenticated`, carrying a `ConfirmIntent` (F1, see `State.confirmIntent`) — the whole
//  body this case used to run directly, plus WHAT to run it on, both decided synchronously at tap
//  time. A refusal sends `.authenticationCancelled`, clearing `isConfirming` and going no further
//  — nothing is signed, proposed, or delegated. The propose-failure Retry short-circuit above
//  stays UNauthenticated, since it only re-proposes for display; nothing is signed or broadcast
//  either way.
//
//  MOB-1458 (regression fix, F1): before this fix, the guard against a nil/empty schedule lived
//  on the far side of the authentication `await`, re-reading `state.schedule` fresh inside
//  `.confirmAuthenticated` — while `onAppear`'s bounded entry retry (`proposeWithRetryEffect`, up
//  to ~60 s of quiet re-proposing) kept running uncancelled underneath a still-blank timeline. A
//  schedule that arrived DURING the prompt satisfied that guard by construction once
//  authentication passed, so a plan the user was never shown could be signed, persisted, and
//  started — directly against this file's own MOB-1458 (Task 3) invariant that the SDK never
//  signs a plan the user was not shown. `ConfirmIntent` closes this: `State.confirmIntent` decides
//  synchronously at tap time, before the prompt opens, and that CAPTURED decision — not a fresh
//  read of `state` — is what `.confirmAuthenticated` acts on. A schedule landing mid-prompt can no
//  longer retroactively make an already-decided tap valid.
//
//  MOB-1458 (code review): two more early exits dismissed the failure sheet and never restored
//  it — both missed by the F1 fix above, which only closed the authentication-cancel/success gap.
//  The nil-`ConfirmIntent` no-op (`confirmTapped`/`retryTapped`'s
//  `guard let intent = state.confirmIntent else { ... }`) cleared `isFailurePresented` at the top
//  of the case and never set it back — reachable whenever `confirmIntent` goes nil AFTER a commit
//  failure already put the sheet up (in practice, the shared `selectedWalletAccount` clearing
//  under an open flow). Fixed to mirror `.authenticationCancelled`: restore `isFailurePresented`
//  from `failureReason != nil` — the exact promise this guard's own comment already made ("must be
//  able to come back unchanged if what follows is refused, or turns out to be this no-op") but
//  never actually implemented for the no-op half. The propose-failure Retry short-circuit had the
//  same shape one guard earlier — it cleared `failureReason` (and with it, the sheet's only way
//  back) BEFORE checking whether `selectedWalletAccount` even resolves to an account to re-propose
//  with. Fixed by running the account guard first, so a nil account restores
//  `isFailurePresented = true` (unconditionally — this branch only runs when
//  `failureReason == .propose`, already known non-nil) instead of clearing state ahead of a
//  re-propose that never launches.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationTransferPlan {
    @ObservableState
    struct State: Equatable {
        enum Variant: Equatable {
            case scheduled
            // (`.manual` — the manual-delivery plan variant — was REMOVED 2026-08-07 with the
            // whole manual-tap send surface. Its only constructor was a #Preview.)
            case recreated
        }

        /// MOB-1496 (R8-T1, S3): distinguishes what `isFailurePresented`'s sheet is showing, so
        /// `retryTapped` re-attempts the right thing and the view picks the right copy. `nil` while
        /// no failure sheet is presented.
        enum FailureReason: Equatable {
            /// `onAppear`'s schedule proposal threw (including when the coordinator's own upstream
            /// recovery restart threw and left `injectedSchedule` nil) — Retry re-proposes via
            /// `proposeMigrationTransfers`.
            case propose
            /// The commit itself failed (software sign+store, or the Keystone PCZT-proposal fork)
            /// — Retry re-attempts the whole commit.
            case commit
        }

        /// MOB-1458 (regression fix, F1): what a Confirm tap will actually do, decided
        /// SYNCHRONOUSLY at tap time (`State.confirmIntent` below) and carried end-to-end in
        /// `.confirmAuthenticated` — nothing about WHAT to sign/propose is re-read from state after
        /// the authentication `await`. See this file's header for the bug this closes: re-reading
        /// `state.schedule` on the far side of the prompt let a schedule that arrived DURING the
        /// prompt (never shown on the still-blank timeline) satisfy the emptiness guard by
        /// construction.
        enum ConfirmIntent: Equatable {
            /// `requiresSigning == false` — a plain "got it": nothing left to sign or propose.
            case acknowledge
            /// The software lane: sign + store `schedule` with a USK derived for `account` at
            /// `zip32AccountIndex`.
            case software(schedule: MigrationSchedule, account: WalletAccount, zip32AccountIndex: Zip32AccountIndex)
            /// The Keystone lane: propose `schedule`'s PCZTs (plus any preparation PCZTs) for a
            /// batched QR-signing session against `account`.
            case keystone(schedule: MigrationSchedule, account: WalletAccount)
        }

        var variant = Variant.scheduled
        var rows: IdentifiedArrayOf<MigrationTransferRow> = []
        var totalDurationHours = 0
        /// MOB-1511 (W2): the multi-round label — non-nil only when the display rule says the
        /// label belongs on screen (a later round in flight, or a known engine total above one);
        /// `totalRounds` additionally carries the SDK's real run-count estimate — `nil` when the
        /// estimate is unavailable.
        var round: Int?
        var totalRounds: Int?
        /// Coordinator-injected schedule for recovery/reschedule variants — when set, `onAppear`
        /// populates rows from it directly instead of calling `proposeMigrationTransfers()`. `nil`
        /// for a fresh entry, and also (MOB-1496 R8-T1, S3) when the coordinator's own upstream
        /// propose (a recovery restart) failed — either way `onAppear` falls through to its own
        /// fresh proposal, surfacing its own failure sheet if that fails too.
        var injectedSchedule: MigrationSchedule?
        /// The schedule currently backing `rows` (either `injectedSchedule` or a freshly proposed
        /// one) — what `confirmTapped` signs and stores. `nil` until a proposal succeeds.
        var schedule: MigrationSchedule?
        /// P3: the chain-time frame every row's ETA is measured in — the SDK's estimated tip and
        /// MEASURED block rate (see `MigrationChainClock`). Hydrated by `.onAppear`; until it
        /// arrives, rows are laid out against the target-spacing default, then re-applied.
        var chainClock = MigrationChainClock.unknown
        /// A14: the run's REAL per-step preparation ladder, when the engine has statuses to give.
        /// `nil` before the read lands (and for a plan not yet committed, which has no per-step
        /// state to report) — `preparationSteps` then falls back to the shaped placeholder.
        var loadedPrepareBalanceRows: [MigrationPrepareBalanceRow]?
        /// `false` for the rescheduled variant only (MOB-1466): its transfers are already signed at
        /// the original plan commit, so `confirmTapped` is a plain acknowledgment — `false` skips
        /// `signAndStoreMigrationSchedule` and delegates `.confirmed` directly. The re-created
        /// (recovery) variant signs a fresh schedule, so it keeps the default `true`.
        var requiresSigning = true
        // (Audit 2026-08-03, C10: the MOB-1513 C7 `isExpiredRecoveryReview` flag and
        // `pendingKeystoneRecoveryBatch` carrier that lived here were DELETED — nothing ever set
        // or read either, and the coordinator functions their docs named
        // (`recreatedPlanState`/`expiredRecoveryReviewConfirmed`) do not exist: the
        // expired-recovery lane commits one screen earlier and every `requiresSigning == false`
        // confirm routes to `.flowFinished`.)
        /// MOB-1513 (B4): true while an async confirm leg is in flight — the device-authentication
        /// prompt itself (MOB-1458), the software commit (through its `.scheduleCommitted` latch
        /// and the awaited first-drive wait that follows — Field 2026-08-06), the Keystone
        /// PCZT-batch propose, or a propose-failure Retry's re-propose. Drives the Confirm button's
        /// disabled+spinner state AND the `.confirmTapped`/`.retryTapped` single-flight guard: a
        /// second tap while set is a complete no-op, so concurrent commits (the plan-cache-overwrite
        /// race behind QA's `MIGRATION_PLAN_STALE` error sheet) can't happen — and, MOB-1458, a
        /// second tap can't open a second authentication prompt either, since this is set true
        /// BEFORE that prompt's effect launches, not after.
        ///
        /// MOB-1458: cleared unconditionally at the top of `.confirmAuthenticated` — every intent
        /// branch that goes on to launch a further async leg (`.software`, `.keystone`) re-sets it
        /// `true` immediately after, so this is a real transition only for `.acknowledge`, which
        /// delegates `.confirmed` straight away — and by `.authenticationCancelled`. Also cleared
        /// on every terminal outcome of those further legs: `.scheduleSigned` (Field 2026-08-06:
        /// `.scheduleCommitted` deliberately does NOT clear it — the loader must stay up through
        /// the first-drive wait in between), `.noteSplitFailed`, `.delegate(.keystoneSignRequested)`
        /// (so a pop-back after a rejected QR ceremony re-enables Confirm), `.transfersProposed`,
        /// and `.transferProposalFailed`.
        var isConfirming = false
        /// MOB-1466 (field finding O5): true once Confirm has genuinely done its job THIS visit —
        /// the software lane's sign+store, latched at `.scheduleCommitted` (Field 2026-08-06:
        /// moved earlier, from `.scheduleSigned` — so a back-out during the first-drive wait that
        /// follows passes the leave guard honestly, since the plan IS committed by then;
        /// `.scheduleSigned` re-sets it to the same `true` as a belt once the drive also lands) —
        /// or the acknowledge-only lane's no-op "got it" (`.confirmAuthenticated`'s `.acknowledge`
        /// branch). Deliberately NOT set by the Keystone lane's `.delegate(.keystoneSignRequested)`:
        /// that only PROPOSES the batch (the engine persists a run, but nothing is signed yet), and
        /// if the QR ceremony is later rejected/abandoned the coordinator explicitly cancels that run
        /// (`restartCurrentMigrationStep`) — so a user who pops back down to this screen after an
        /// abandoned ceremony genuinely has nothing committed, and `.backTapped`'s guard should
        /// still apply. Read by `.backTapped` — see its doc for the full pass-through rule.
        var hasConfirmed = false
        /// MOB-1478 (W4): failure sheet for the silent note-split step, presented over this screen
        /// instead of proceeding to sign+store — mirrors `MigrationNoteSplit.State.isFailurePresented`.
        /// MOB-1496 (R8-T1, S3): also covers a propose failure now — see `failureReason`.
        var isFailurePresented = false
        /// MOB-1496 (R8-T1, S3): which kind of failure `isFailurePresented` is showing; see
        /// `FailureReason`.
        var failureReason: FailureReason?
        /// The "Prepare Your Balance" sheet behind the collapsed split row's "Show details"
        /// disclosure (Figma 5207:16024). Independent of `isFailurePresented` — the disclosure is
        /// only offered on a healthy plan, and the two are never up at once.
        var isPrepareBalancePresented = false
        /// MOB-1466 (field finding O5): the back-out guard sheet — presented by `.backTapped`
        /// instead of leaving, whenever the plan is not yet confirmed. Independent of the other two
        /// sheet flags above; never up alongside them (the guard only ever presents from the
        /// toolbar back button, which the failure/disclosure sheets don't intercept).
        var isLeaveGuardPresented = false

        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        /// MOB-1458 (Task 3): the app-wide toast idiom — `.planStaleRefreshed` uses it to tell the
        /// user their displayed schedule was silently replaced with a fresh one and needs a look
        /// before they re-confirm. Rendered globally by `RootView`'s `.toast()`, so this screen
        /// needs no view-level wiring of its own.
        @Shared(.inMemory(.toast)) var toast: Toast.Edge? = nil

        /// MOB-1513 (A2): the synthesized "Split Balance" row, computed from `rows` rather than
        /// stored — the note-split is a real, separate broadcast (immediate at commit) that is
        /// never itself an element of `schedule.transfers`, so it's no longer conflated with
        /// `rows`' own index 0 (see `MigrationTransferTimeline`'s header doc for the shared-
        /// component side of this fix). `nil` before any rows have loaded (nothing to summarize
        /// yet). Pre-commit the split hasn't broadcast — `.active`, paired with
        /// `MigrationTransferTimeline`'s check-style badge for it — and `minutesFromNow: 0` so the
        /// caption renders "Ready now" through the very same `MigrationETA.caption` path every
        /// other forward caption uses (see `MigrationTransferPlanView.caption(for:)`), never a
        /// hardcoded string. Amount is the SUM of every listed transfer (Android parity: the split
        /// row shows the total). Computed (not stored) so it can never drift from `rows` and so
        /// `apply`/every existing exhaustive `TestStore` assertion needs no parallel bookkeeping —
        /// `.scheduled`, `.manual`, and `.recreated` all populate `rows` through the same `apply`,
        /// so all three get the same treatment with no variant branch here.
        /// D14: how many note-preparation transactions the engine estimates this run takes — the
        /// number of "Split Balance" rows below. Hydrated by the coordinator from
        /// `MigrationManagerClient.migrationPreparationCount`; `1` until then and whenever the
        /// estimate is unavailable, which is exactly the single row every plan showed before D14.
        var preparationCount = 1

        var splitRows: IdentifiedArrayOf<MigrationTransferRow> {
            guard !rows.isEmpty else { return [] }
            // MOB-1513: this screen's `rows` are always freshly proposed/injected schedule rows
            // (`apply(_:to:)` below), so every row's `amount` is genuinely known in practice — but
            // the sum is honest either way: `nil` (unknown total) if ANY row's amount isn't, rather
            // than silently treating an unknown row as contributing zero to the total shown.
            let totalAmount: Zatoshi? = rows.contains { $0.amount == nil }
                ? nil
                : rows.reduce(Zatoshi.zero) { $0 + ($1.amount ?? Zatoshi.zero) }
            // Figma 5207:16024: ONE collapsed row, whatever the split's transaction count. D14
            // rendered one timeline row per preparation, which put N rows of a mechanism the user
            // did not ask about ahead of the transfers they did — and, having no honest per-step
            // amount to show (`MigrationTransactionStatus` carries none), left every one of those
            // rows amount-less. Collapsed, the row carries the split's real TOTAL again, and the
            // per-step detail moves behind "Show details" into `MigrationPrepareBalanceSheet`.
            return [
                MigrationTransferRow(
                    id: "split-balance",
                    index: 0,
                    amount: totalAmount,
                    status: .active,
                    hoursFromNow: 0,
                    minutesFromNow: 0,
                    kind: .splitBalance
                )
            ]
        }

        /// Whether the split takes more than one transaction — the only case that earns the
        /// "Show details" disclosure and its sheet. A single-transaction split (the overwhelmingly
        /// common case) has nothing to expand: the collapsed row already says all of it.
        var hasMultiStepSplit: Bool {
            preparationCount > 1
        }

        /// The rows the "Prepare Your Balance" sheet renders.
        ///
        /// A14: the engine's REAL per-step states and dependencies once a run is committed and
        /// reporting statuses. The interim ladder survives as the fallback for a plan that has not
        /// been committed yet — there is no per-step state to report before the split exists, and a
        /// shaped placeholder is a better answer there than an empty card.
        var preparationSteps: [MigrationPrepareBalanceRow] {
            loadedPrepareBalanceRows ?? MigrationPrepareBalanceRow.interimLadder(count: preparationCount)
        }

        /// The split row's caption: the shared ETA phrasing on its own for a single-transaction
        /// split, suffixed with the step count when there are several ("Starts right away ·
        /// 4 steps").
        ///
        /// MOB-1466 (field finding O5): `.plan`, not the old `variant == .scheduled ? .inPrefixed :
        /// .bare` split — this state is ALWAYS the pre-commit Transfer Plan screen regardless of
        /// `variant`, and the split row is the single most prominent "Ready now" on it (always the
        /// first row shown), so it takes the same committal phrasing every other caption on this
        /// screen does now. See `MigrationETA.Phrasing.plan`'s doc.
        var splitCaption: String {
            let eta = MigrationETA.caption(minutesFromNow: 0, phrasing: .plan)
            guard hasMultiStepSplit else { return eta }
            return String(localizable: .migrationPlanSplitBalanceCaption(eta, preparationCount))
        }

        /// MOB-1458 (regression fix, F1): what `.confirmTapped`/`.retryTapped` will actually do,
        /// computed fresh from CURRENT state at the call site — `nil` means there is nothing to
        /// confirm and the tap is a no-op. This is the SAME decision the old inline body used to
        /// make on the far side of the authentication prompt (by re-reading state from
        /// `.confirmAuthenticated`); only WHEN it runs moves earlier, to before the prompt opens —
        /// see the file header for the regression that closes. Guard order reproduces the
        /// original exactly and is significant: the `requiresSigning == false` short-circuit must
        /// win first (a rescheduled acknowledgment has neither a schedule nor necessarily a
        /// selected account by the time it reaches this screen), and the Keystone-vendor check
        /// must win before the software-only `zip32AccountIndex` guard (a Keystone account never
        /// has one).
        var confirmIntent: ConfirmIntent? {
            guard requiresSigning else { return .acknowledge }
            // MOB-1496 (R8-T1, S3): an absent or legitimately-empty schedule has nothing to sign —
            // the engine's `sign_and_store_migration_schedule` deterministically refuses an empty
            // one either way.
            guard let schedule, !schedule.transfers.isEmpty else { return nil }
            guard let account = selectedWalletAccount else { return nil }
            guard account.vendor != WalletAccount.Vendor.keystone else {
                return .keystone(schedule: schedule, account: account)
            }
            guard let zip32AccountIndex = account.zip32AccountIndex else { return nil }
            return .software(schedule: schedule, account: account, zip32AccountIndex: zip32AccountIndex)
        }

        /// MOB-1458: whether `confirmTapped`/`retryTapped` must pass the device-authentication
        /// gate (Face ID / Touch ID / passcode) before running its real body.
        ///
        /// MOB-1458 (F2): reduced to plain `requiresSigning` — `isExpiredRecoveryReview` is
        /// deliberately NOT part of this any more, even though that review also puts funds in
        /// motion despite `requiresSigning == false`. On the SOFTWARE lane the expired-recovery
        /// re-signing already happens, ungated, one screen earlier: `.recovery(.delegate(.recreate))`
        /// in the coordinator derives the real spending key, calls `refreshStaleMigrationTransfers`
        /// (which re-signs every rebuilt transfer in-process), then `recordCommittedSchedule` +
        /// `reconcile` — by the time THIS review screen appears the run is already fully committed,
        /// and its Confirm is pure navigation. (Audit 2026-08-03, C10 — truth over intention: no
        /// authentication gate exists on `.recovery(.delegate(.recreate))` either; the recreate
        /// leg runs UNGATED today. If a per-recovery prompt is wanted, it must still be built.) Kept as its own named computed property (rather than
        /// inlined to `requiresSigning` at call sites) since it remains the documented seam a
        /// future `requiresSigning == false` variant author will look at first, and its
        /// truth-table tests (`confirmRequiresAuthenticationIsTrueWheneverRequiresSigningIsTrue` /
        /// `confirmRequiresAuthenticationIsFalseWheneverRequiresSigningIsFalse`) already exist.
        var confirmRequiresAuthentication: Bool {
            requiresSigning
        }

        init(
            variant: Variant = .scheduled,
            rows: IdentifiedArrayOf<MigrationTransferRow> = [],
            totalDurationHours: Int = 0,
            requiresSigning: Bool = true
        ) {
            self.variant = variant
            self.rows = rows
            self.totalDurationHours = totalDurationHours
            self.requiresSigning = requiresSigning
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        /// MOB-1466 (field finding O5): the toolbar back button, intercepted via `.zashiBack
        /// (customDismiss:)`. Presents the leave-guard sheet unless the plan is either already
        /// confirmed this visit (`State.hasConfirmed`) or genuinely has nothing to commit
        /// (`!State.requiresSigning` — the acknowledge-only rescheduled/expired-recovery review
        /// variants, whose Confirm is pure navigation over an already-committed schedule; see
        /// `State.confirmIntent`'s `.acknowledge` doc) — either carve-out passes straight through,
        /// via the SAME `.delegate(.leftWithoutConfirming)` an explicit "Leave anyway" sends.
        /// Deliberately fires even while `isConfirming` is true — a commit in flight is not yet a
        /// SUCCESSFUL one, so the guard still applies (TCA's automatic `StackState` teardown cancels
        /// the in-flight commit effect when the coordinator pops this element in response).
        ///
        /// KNOWN LIMITATION: this only intercepts the toolbar back button. `zashiBack`'s
        /// `customDismiss` has no hook for an interactive edge-swipe gesture, so a swipe-back still
        /// leaves silently, unguarded — the exact gap this task set out to close stays open for
        /// that one gesture. Flagged for a follow-up, not fixed here.
        case backTapped
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        /// Signs and stores the active schedule — sign-only (MOB-1513 B4), then (Field 2026-08-06)
        /// `.scheduleCommitted` keeps this same loader up while it awaits the run's first drive
        /// (prove + first broadcast, `advance(.afterSync)` at tip) before navigating — see its doc.
        case confirmTapped
        /// MOB-1458: `confirmTapped`/`retryTapped`'s device-authentication gate
        /// (`State.confirmRequiresAuthentication`) refused — authentication failed, or the user
        /// cancelled the Face ID / Touch ID / passcode prompt. Clears `isConfirming`; nothing was
        /// signed, proposed, or delegated. MOB-1458 (F5): re-presents the failure sheet if one was
        /// already showing before this tap (a declined Retry must not erase the error the user was
        /// looking at) — see `State.failureReason`'s lifecycle note at `.confirmAuthenticated`.
        case authenticationCancelled
        /// MOB-1458: the device-authentication gate passed (or `confirmRequiresAuthentication`
        /// was `false`, skipping it entirely) — runs the confirm body that used to live directly
        /// under `.confirmTapped`/`.retryTapped`, unchanged. MOB-1458 (regression fix, F1): now
        /// carries the `ConfirmIntent` that `.confirmTapped`/`.retryTapped` decided BEFORE the
        /// prompt opened (`State.confirmIntent`) — this handler acts on that captured decision
        /// instead of re-reading `state`, which is the fix for the regression this task closes
        /// (see the file header).
        case confirmAuthenticated(State.ConfirmIntent)
        case delegate(Delegate)
        /// The commit failed — presents the failure sheet instead of proceeding. Covers any
        /// software commit failure and (MOB-1496 R8-T1, #4) the Keystone PCZT-proposal fork's
        /// failures. (The name predates MOB-1513 B4, when a silent note-split broadcast was part of
        /// the commit — kept for continuity with `MigrationReviewTransfer`'s identical action.)
        case noteSplitFailed
        case onAppear
        /// The collapsed split row's "Show details" disclosure — opens the "Prepare Your Balance"
        /// sheet. Offered only when the split takes more than one transaction
        /// (`State.hasMultiStepSplit`).
        case splitDetailsTapped
        /// "Got it" on the "Prepare Your Balance" sheet, or a swipe-dismiss. Read-only sheet, so
        /// this only closes it.
        case prepareBalanceDismissed
        /// MOB-1466: "Keep reviewing" on the leave-guard sheet, or a swipe-dismiss. Closes the sheet
        /// only — the user stays exactly where they were, nothing is sent anywhere.
        case leaveGuardStayTapped
        /// MOB-1466: "Leave anyway" on the leave-guard sheet — closes it and delegates the actual
        /// pop to the coordinator.
        case leaveGuardLeaveTapped
        /// MOB-1511 (W2): the round context loaded on appearance — see `State.round`'s doc.
        case roundContextLoaded(round: Int, totalRounds: Int?)
        /// D14: the engine's preparation-transaction estimate for this run — how many
        /// "Split Balance" rows the plan shows. Loaded alongside the round context.
        case chainClockLoaded(MigrationChainClock)
        case prepareBalanceRowsLoaded([MigrationPrepareBalanceRow]?)
        case preparationCountLoaded(Int)
        /// Failure sheet: dismiss, then re-attempt the failed step from scratch — the whole commit
        /// sequence when `failureReason == .commit` (or unset), or (MOB-1496 R8-T1, S3) a fresh
        /// proposal when `failureReason == .propose`.
        case retryTapped
        /// Field 2026-08-06: `MigrationCommitPipeline.commitSoftware` returned — the run is
        /// committed (signed + stored + recorded + reconciled). Latches `hasConfirmed`
        /// IMMEDIATELY (before the first drive below), so a re-tap during the drive wait is dead
        /// and a back-out passes the leave guard honestly, then keeps `isConfirming` up while the
        /// newborn run's first drive (prove + first broadcast) runs — see the handler's own doc
        /// for why the drive lives here and not only in Root's G1 case.
        case scheduleCommitted
        /// The whole confirm chain's terminal now: `signAndStoreMigrationSchedule` completed AND
        /// the first drive `.scheduleCommitted`'s handler awaits has either run to completion (at
        /// tip) or was skipped (mid-sync, deferring to the coming edge).
        case scheduleSigned
        /// MOB-1458 (Task 3): the software commit's or the Keystone propose's consent echo found
        /// the displayed schedule stale (`ZcashError.migrationPlanStale`) — `refreshAfterPlanStale`
        /// already re-proposed a fresh one; populates rows/duration from it (like
        /// `transfersProposed`) and shows a toast telling the user to review it before
        /// re-confirming. Nothing was signed or stored.
        case planStaleRefreshed(MigrationSchedule)
        /// MOB-1496 (R8-T1, S3): `proposeMigrationTransfers()` threw — presents the failure sheet;
        /// `schedule`/`rows` are left untouched (never a silent empty-schedule fallback).
        case transferProposalFailed
        /// `proposeMigrationTransfers()` result — populates rows/duration for a fresh entry.
        case transfersProposed(MigrationSchedule)

        enum Delegate: Equatable {
            case confirmed
            /// MOB-1466 (Lukas, 2026-08-07): THE COMMIT LANDED, the first drive has not. Emitted at
            /// `.scheduleCommitted` so the coordinator can put the Scheduling screen up for the
            /// ~30 s the drive takes, instead of leaving the user on this screen under a button
            /// spinner ("I tap start migration and there is a spinner… I'm locked on left screen
            /// and after 30s land to the right one").
            ///
            /// THIS boundary, not `.confirmTapped`: everything that can still fail into THIS
            /// screen's failure sheet — a nil intent, a refused Face ID, a stale plan, a thrown
            /// commit — has already happened by the time this fires. `hasConfirmed` is true, the
            /// plan IS committed, and nothing downstream can send the user back here. Pushing any
            /// earlier would mean popping the Scheduling screen back off on failure, and a
            /// half-second flash of a screen that says "Scheduling…" before an error sheet is worse
            /// than the spinner it replaces.
            case scheduling
            /// PHASE 7 (Keystone): the run's PCZTs — any preparation transactions first, then all N
            /// of the schedule's transfers — were proposed and need QR signing in ONE batched
            /// session. The `MigrationKeystoneBatch` wrapper carries the preparation count, which is
            /// what tells the two halves apart on the way back (see its doc).
            case keystoneSignRequested(MigrationKeystoneBatch)
            /// MOB-1466: "Leave anyway" on the back-out guard sheet, or a silent pass-through when
            /// nothing was at stake (`State.hasConfirmed`/`requiresSigning` — see `.backTapped`'s
            /// doc) — either way the coordinator just pops this screen, exactly like an ordinary
            /// back would have, had the guard not intercepted it.
            case leftWithoutConfirming
        }
    }

    /// MOB-1513 (E2-FIX): single-flight + dismiss-cancellation id for the bounded entry-retry loop
    /// (`proposeWithRetryEffect`). `cancelInFlight` restarts the window on a re-appearance; TCA's
    /// automatic teardown cancels it when the screen is popped.
    private enum CancelID: Hashable {
        case proposeRetry
    }

    /// MOB-1513 (E2-FIX): the bounded entry-retry cadence — see `proposeWithRetryEffect`.
    private enum Constants {
        /// Re-propose at this cadence while the wallet isn't ready yet.
        static let proposeRetryInterval: Duration = .seconds(3)
        /// At most this many re-attempts after the first — `proposeRetryMaxRetries` ×
        /// `proposeRetryInterval` ≈ a 60 s window from the first attempt (the post-restore
        /// not-yet-witnessable window is ~30 s; 60 s is a 2× safety margin).
        static let proposeRetryMaxRetries = 20
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .backTapped:
                // MOB-1466 (field finding O5): see this case's doc on `Action` for the full rule.
                // Both carve-outs leave via the identical delegate an explicit "Leave anyway" sends
                // — the coordinator doesn't need to know which of the three reasons applied.
                guard state.requiresSigning, !state.hasConfirmed else {
                    return .send(.delegate(.leftWithoutConfirming))
                }
                state.isLeaveGuardPresented = true
                return .none

            case .leaveGuardStayTapped:
                state.isLeaveGuardPresented = false
                return .none

            case .leaveGuardLeaveTapped:
                state.isLeaveGuardPresented = false
                return .send(.delegate(.leftWithoutConfirming))

            case .cancelTapped:
                state.isFailurePresented = false
                state.failureReason = nil
                return .none

            case .confirmTapped, .retryTapped:
                // MOB-1513 (B4): single-flight — a second tap while a confirm leg is already in
                // flight must not spawn a concurrent commit (every propose/prepare overwrites the
                // SDK's one-slot plan cache, so a concurrent commit surfaces as the
                // `MIGRATION_PLAN_STALE` error sheet QA hit).
                // E2E harness F#3b (2026-08-04): every refusal on this money path traces — a
                // Confirm tap that produces no [MIG] line means the tap never reached this reducer
                // (disabled button, missed hit target), which is itself the diagnosis.
                guard !state.isConfirming else {
                    MigrationTrace.event("CONFIRM tap ignored — a confirm leg is already in flight")
                    return .none
                }
                guard !state.hasConfirmed else {
                    MigrationTrace.event("CONFIRM tap ignored — this plan is already committed")
                    return .none
                }
                state.isFailurePresented = false

                // MOB-1496 (R8-T1, S3): a propose failure's Retry re-proposes instead of
                // re-attempting the commit — checked FIRST, before any of the commit guards below.
                // MOB-1458: deliberately NOT behind the authentication gate below — it only
                // re-proposes for display, so nothing is signed or broadcast on this leg.
                if case .retryTapped = action, state.failureReason == State.FailureReason.propose {
                    // MOB-1458 (code review): the account guard now runs BEFORE `failureReason`
                    // clears — clearing it unconditionally first (the old order) meant a nil
                    // account dismissed the "couldn't load your plan" sheet, wiped its reason, and
                    // launched nothing, leaving the user on a screen with no surface for the
                    // error. Same principle as the nil-`confirmIntent` no-op below (F1): clear
                    // state only once the thing that follows actually proceeds.
                    guard let accountUUID = state.selectedWalletAccount?.id else {
                        // Restored unconditionally `true` here, NOT the `failureReason != nil`
                        // form used at the other restore sites — this branch only runs when
                        // `failureReason == State.FailureReason.propose`, already known non-nil,
                        // so there is no `nil` case to guard against. Don't "fix" this to match
                        // the other sites.
                        MigrationTrace.event("CONFIRM retry BLOCKED — no selected account; propose-failure sheet restored")
                        state.isFailurePresented = true
                        return .none
                    }
                    state.failureReason = nil
                    // Set only when a real re-propose launches (a nil account is a no-op inside
                    // `proposeEffect`, which must not strand the flag).
                    state.isConfirming = true
                    MigrationTrace.event("CONFIRM retry → fresh propose (recovering from a propose failure)")
                    return proposeEffect(accountUUID: accountUUID)
                }

                // MOB-1458 (regression fix, F1): decided synchronously, from CURRENT state, before
                // anything below ever awaits — see `State.confirmIntent`'s doc. `nil` means there
                // is nothing to confirm, so this tap is a no-op. Deliberately does NOT clear
                // `failureReason` (F5, below): a failure sheet dismissed by this tap must be able
                // to come back unchanged if what follows is refused, or turns out to be this
                // no-op — MOB-1458 (code review): the no-op half of that promise was never actually
                // implemented until now. Restored exactly like `.authenticationCancelled` restores
                // the refused half: nothing ran here either, so dropping the sheet would strand
                // `failureReason` set with no surface left to render it.
                guard let intent = state.confirmIntent else {
                    MigrationTrace.event(
                        "CONFIRM tap NO-OP — nothing to confirm: requiresSigning \(state.requiresSigning)"
                        + ", schedule \(state.schedule.map { "\($0.transfers.count) transfers" } ?? "nil")"
                        + ", account \(state.selectedWalletAccount == nil ? "nil" : "set")"
                        + ", zip32 \(state.selectedWalletAccount?.zip32AccountIndex == nil ? "nil" : "set")"
                    )
                    state.isFailurePresented = state.failureReason != nil
                    return .none
                }

                // MOB-1458: the device-authentication gate — see `State.confirmRequiresAuthentication`'s
                // doc for which of this screen's states need it. The rescheduled acknowledgment
                // (`false`) skips straight through with no prompt.
                guard state.confirmRequiresAuthentication else {
                    MigrationTrace.event("CONFIRM — no auth required (\(Self.describe(intent))), proceeding")
                    return .send(.confirmAuthenticated(intent))
                }

                // Set BEFORE authentication so the Confirm button's existing spinner covers the
                // Face ID/Touch ID sheet too — a double-tap while the prompt is up hits the
                // single-flight guard above instead of opening a second prompt.
                state.isConfirming = true
                MigrationTrace.event("CONFIRM → device auth prompt (\(Self.describe(intent)))")
                return localAuthentication.gated(success: .confirmAuthenticated(intent), cancelled: .authenticationCancelled)

            case .authenticationCancelled:
                MigrationTrace.event("CONFIRM auth refused — nothing signed, Confirm re-enabled")
                // MOB-1458: refused — nothing was signed, proposed, or delegated. Re-enables
                // Confirm. MOB-1458 (F5): `failureReason` is never cleared by the tap that led
                // here (only by a subsequent `.confirmAuthenticated` success, below) — so if a
                // failure sheet was showing before this tap, bring it back rather than leaving a
                // screen that reads as a fresh, never-attempted review with no way back to the
                // error it was showing.
                state.isConfirming = false
                state.isFailurePresented = state.failureReason != nil
                return .none

            case .confirmAuthenticated(let intent):
                // MOB-1458: the gate passed (or didn't apply) — the confirm body that used to run
                // directly under `.confirmTapped`/`.retryTapped`. `isConfirming` is already `true`
                // here for every path that goes on to launch an async leg below (set by the gate
                // above), so this never re-checks the single-flight guard the way that case does.
                // MOB-1458 (regression fix, F1): acts ONLY on `intent`, captured synchronously by
                // `State.confirmIntent` at tap time — never re-reads `state.schedule` or
                // `state.selectedWalletAccount` here, which is exactly the fix (see the file
                // header for the regression this closes).
                //
                // MOB-1458 (F5): `failureReason` clears here — the one place left that clears it
                // outside of a specific success action — since reaching this point means the tap
                // that dismissed the sheet is actually going somewhere, not bouncing off a no-op
                // (a nil `confirmIntent` returns before ever sending this action) or getting
                // refused (`.authenticationCancelled` restores the sheet instead of clearing it).
                state.isConfirming = false
                state.failureReason = nil
                MigrationTrace.event("CONFIRM proceeding — \(Self.describe(intent))")
                switch intent {
                case .acknowledge:
                    // The rescheduled variant, or the expired-recovery review
                    // (`isExpiredRecoveryReview`) — both `requiresSigning == false`: transfers are
                    // already signed, so this is a plain acknowledgment either way. The coordinator
                    // (reading `state.path.last`'s `isExpiredRecoveryReview`) decides any further
                    // routing once `.delegate(.confirmed)` lands; this reducer needs no awareness
                    // of it (see `State.isExpiredRecoveryReview`'s own doc).
                    //
                    // MOB-1466: `hasConfirmed` set for consistency, though `.backTapped`'s own
                    // `!requiresSigning` carve-out already passes this variant through unconditionally.
                    state.hasConfirmed = true
                    return .send(.delegate(.confirmed))

                case .keystone(let schedule, let account):
                    state.isConfirming = true
                    return requestKeystoneSignature(for: schedule, account: account)

                case .software(let schedule, let account, let zip32AccountIndex):
                    state.isConfirming = true
                    return commitEffect(schedule: schedule, account: account, zip32AccountIndex: zip32AccountIndex)
                }

            case .delegate(.keystoneSignRequested):
                // MOB-1513 (B4): the batch is handed to the coordinator (which pushes the QR
                // ceremony on top) — re-enable Confirm so a pop-back after a rejected signature
                // lands on a tappable button again.
                state.isConfirming = false
                return .none

            case .delegate:
                return .none

            case .noteSplitFailed:
                MigrationTrace.event("CONFIRM commit FAILED → failure sheet (reason: commit)")
                state.isConfirming = false
                state.isFailurePresented = true
                state.failureReason = State.FailureReason.commit
                return .none

            case .onAppear:
                // E2E harness F#3b (2026-08-04): which of the three entry modes this appearance
                // takes — the first fact needed to interpret every CONFIRM line that follows.
                let entryMode: String
                if state.injectedSchedule != nil {
                    entryMode = "injected schedule"
                } else if state.rows.isEmpty {
                    entryMode = "fresh propose"
                } else {
                    entryMode = "hydrated rows"
                }
                MigrationTrace.event("PLAN screen open — variant \(state.variant), \(entryMode)")
                // MOB-1511 (W2): the multi-round label loads on EVERY appearance path (fresh
                // proposal, injected schedule, hydrated rows alike) — it derives from persisted
                // app state + the stub estimate, independent of where the rows came from.
                let roundContextEffect = Effect<MigrationTransferPlan.Action>.run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] send in
                    let context = await migrationManager.migrationRoundContext(accountUUID)
                    await send(.roundContextLoaded(round: context.round, totalRounds: context.totalRounds))
                    // D14: same appearance path, same reasoning — derived from live engine state,
                    // independent of where the rows came from.
                    await send(.preparationCountLoaded(await migrationManager.migrationPreparationCount(accountUUID)))
                    // P3: the ETA frame. Loaded on the same appearance path for the same reason —
                    // it depends on live wallet state, not on where the rows came from.
                    await send(.chainClockLoaded(await migrationManager.migrationChainClock(accountUUID)))
                    // A14: the sheet's real per-step ladder. Same appearance path, same reasoning —
                    // and `nil` here simply leaves the placeholder in place.
                    await send(.prepareBalanceRowsLoaded(await migrationManager.migrationPrepareBalanceRows(accountUUID)))
                }
                if let injectedSchedule = state.injectedSchedule {
                    apply(injectedSchedule, to: &state)
                    return roundContextEffect
                }

                // Coordinator-hydrated rows (the rescheduled variant — no schedule object exists
                // for it) must not be overwritten by a fresh proposal.
                if !state.rows.isEmpty {
                    return roundContextEffect
                }

                // By design, the scheduled plan never folds the Orchard
                // remainder into its own run — dust stays on the separate, post-completion
                // "Migrate anyway" lane (MOB-1496 W-B: unlock + `proposeImmediateMigration`, in
                // `MigrationCoordFlowCoordinator`, for both vendors). This screen is only ever
                // reached for `.privateScheduled` mode (the coordinator routes `.immediate` through
                // `MigrationReviewTransfer` instead), so `proposeMigrationTransfers` (not
                // `proposeImmediateMigration`) is always correct here.
                // `.concatenate` (not `.merge`): the round load answers instantly today, and a
                // deterministic receive order keeps exhaustive TestStores stable. MOB-1513 (E2-FIX):
                // the entry propose is the bounded, quiet retry (`proposeWithRetryEffect`); an
                // explicit Retry stays the single-attempt `proposeEffect`.
                return .concatenate(roundContextEffect, proposeWithRetryEffect(accountUUID: state.selectedWalletAccount?.id))

            case .chainClockLoaded(let clock):
                // Re-apply: `apply` runs synchronously on the injected-schedule path before this
                // read can return, so the first layout used the default frame. Without the
                // re-apply those rows would keep target-spacing ETAs for the life of the screen.
                state.chainClock = clock
                if let schedule = state.schedule {
                    apply(schedule, to: &state)
                }
                return .none

            case .prepareBalanceRowsLoaded(let rows):
                // An empty array is not "no steps" — it is a read that found nothing to say, and it
                // must not blank a sheet the placeholder was correctly filling.
                state.loadedPrepareBalanceRows = (rows?.isEmpty ?? true) ? nil : rows
                return .none

            case .preparationCountLoaded(let count):
                state.preparationCount = max(1, count)
                return .none

            case .splitDetailsTapped:
                state.isPrepareBalancePresented = true
                return .none

            case .prepareBalanceDismissed:
                state.isPrepareBalancePresented = false
                return .none

            case .roundContextLoaded(let round, let totalRounds):
                // MOB-1511 (W2): shown only for a genuinely multi-round migration — a later round
                // in flight, or a known engine estimate above one.
                state.round = round >= 2 || (totalRounds ?? 1) > 1 ? round : nil
                state.totalRounds = state.round != nil ? totalRounds : nil
                return .none

            case .scheduleCommitted:
                MigrationTrace.event("CONFIRM commit COMPLETE — signed + stored; driving the first step under the loader")
                // The latch flips HERE — at commit success, BEFORE the drive — not for re-tap
                // safety (`.confirmTapped`/`.retryTapped`'s `isConfirming` guard already fires
                // FIRST in that chain and alone kills a re-tap for this whole window, latch or no
                // latch) but for `.backTapped`'s own guard: without moving it earlier, a back-tap
                // during the drive wait would still read `hasConfirmed == false` and present the
                // leave-guard sheet as though nothing were committed yet, when the plan already
                // IS — flipping the latch here instead lets that back-out pass straight through
                // honestly, exactly like `.backTapped`'s carve-out promises (leaving forfeits
                // nothing).
                state.hasConfirmed = true
                return .merge(
                    // MOB-1466: hand the wait a screen. See `.delegate(.scheduling)`'s doc for why
                    // this boundary and not the tap. Merged rather than concatenated so the drive
                    // below starts immediately — the push is not on its critical path.
                    .send(.delegate(.scheduling)),
                    .run { send in
                    // Field 2026-08-06 (the "instant dismiss" regression): with the push synchronous,
                    // the loader dropped the moment the sign-only commit landed — and the homepage
                    // then rendered the PRE-commit snapshot for the whole prove+broadcast window,
                    // because the post-commit republish queues behind the G1 prove sweep (its summary
                    // join crosses the DB write actor twice: `migrationState`'s advance-step read and
                    // `residualAfterMigration`). The field contract: ONE tap, loader up while the
                    // run's first step is prepared, presigned and its split broadcast, THEN navigate
                    // — by which time the write actor is free, the republish lands, and the homepage
                    // tells the truth. Same phase token and same at-tip guard as Root's G1 drive,
                    // which still fires on `.confirmed` after this (idempotent backstop; the
                    // tick-loop spawn lives there). Mid-sync the drive is skipped exactly like
                    // Root's guard skips: the coming edge owns it, and the loader covers just the
                    // commit.
                    if case .upToDate = sdkSynchronizer.latestState().syncStatus {
                        // Unstructured on purpose: a back-out mid-wait pops this element and TCA
                        // cancels this effect — the drive must survive that cancellation or the
                        // newborn run sits undriven until the next edge/app-open (the exact wedge
                        // G1 closed). `.value` on a non-throwing Task does not return early on
                        // cancellation, and a cancelled effect's trailing send is a no-op — which
                        // is exactly right, the screen is gone.
                        let drive = Task { [migrationManager] in
                            await migrationManager.advance(.afterSync)
                        }
                        _ = await drive.value
                    }
                    await send(.scheduleSigned)
                    }
                )

            case .scheduleSigned:
                MigrationTrace.event("CONFIRM chain COMPLETE — first drive done, delegating .confirmed")
                state.isConfirming = false
                // MOB-1466: the software lane's genuine "Confirm has done its job" moment — signed
                // AND stored. See `State.hasConfirmed`'s doc.
                state.hasConfirmed = true
                return .send(.delegate(.confirmed))

            case .planStaleRefreshed(let schedule):
                MigrationTrace.event("CONFIRM plan STALE — engine refused the commit; fresh plan displayed (\(schedule.transfers.count) transfers)")
                // MOB-1458 (Task 3): mirrors `.transfersProposed` — the fresh schedule replaces
                // the stale one on screen — plus the toast telling the user to review it before
                // tapping Confirm again.
                state.isConfirming = false
                apply(schedule, to: &state)
                state.$toast.withLock { $0 = .topDelayed(String(localizable: .migrationPlanStaleRefreshed)) }
                return .none

            case .transferProposalFailed:
                MigrationTrace.event("PLAN propose FAILED → failure sheet (reason: propose)")
                state.isConfirming = false
                state.isFailurePresented = true
                state.failureReason = State.FailureReason.propose
                return .none

            case .transfersProposed(let schedule):
                MigrationTrace.event("PLAN proposed — \(schedule.transfers.count) transfers, ~\(schedule.estimatedDurationHours)h")
                state.isConfirming = false
                apply(schedule, to: &state)
                return .none
            }
        }
    }

    /// E2E harness F#3b (2026-08-04): one-line render of a `ConfirmIntent` for the [MIG] confirm
    /// trace — the lane and its size only, never key material or addresses.
    static func describe(_ intent: State.ConfirmIntent) -> String {
        switch intent {
        case .acknowledge:
            return "acknowledge"
        case .software(let schedule, _, _):
            return "software commit, \(schedule.transfers.count) transfers"
        case .keystone(let schedule, _):
            return "keystone batch, \(schedule.transfers.count) transfers"
        }
    }

    /// The software commit — sign-only since MOB-1513 (B4): a success sends `.scheduleCommitted`,
    /// which latches `hasConfirmed` and drives the newborn run's first step under the loader, then
    /// itself sends `.scheduleSigned` once that settles. Any thrown error is the plain generic
    /// `.noteSplitFailed` (nothing was persisted — see `MigrationCommitPipeline.commitSoftware`'s
    /// doc). No broadcast happens here any more, so there is no failure to classify/route either.
    /// MOB-1458 (Task 3): `ZcashError.migrationPlanStale` is caught SPECIFICALLY ahead of that
    /// generic catch — see `refreshAfterPlanStale`'s doc.
    private func commitEffect(schedule: MigrationSchedule, account: WalletAccount, zip32AccountIndex: Zip32AccountIndex) -> Effect<Action> {
        .run { send in
            do {
                try await MigrationCommitPipeline.commitSoftware(
                    schedule: schedule,
                    account: account,
                    zip32AccountIndex: zip32AccountIndex,
                    sdkSynchronizer: sdkSynchronizer,
                    migrationManager: migrationManager,
                    walletStorage: walletStorage,
                    mnemonic: mnemonic,
                    derivationTool: derivationTool,
                    networkType: zcashSDKEnvironment.network().networkType
                )
                await send(.scheduleCommitted)
            } catch ZcashError.migrationPlanStale {
                await refreshAfterPlanStale(accountUUID: account.id, send: send)
            } catch {
                await send(.noteSplitFailed)
            }
        }
    }

    /// MOB-1458 (Task 3): the SOFTWARE leg's plan-stale recovery (`commitEffect`'s
    /// `signAndStoreMigrationSchedule` echo). MOB-1458 (final review I1): the Keystone leg no longer
    /// shares this — it uses `restartAfterPlanStale` instead, because its `proposeKeystoneBatch`
    /// run-creates before the echo and so cannot converge on a re-propose. `ZcashError
    /// .migrationPlanStale` means the schedule the user was shown no longer matches the engine's
    /// one-slot plan cache — the process restarted between propose and confirm, the wallet's balance
    /// changed underneath the preview, or a concurrent propose overwrote the cache. ZIP 318 draws
    /// fresh schedule randomness on every proposal, so the SDK deliberately never signs a plan the
    /// user was not shown — the honest software-leg recovery is a fresh `proposeMigrationTransfers`
    /// re-propose (the SAME call `proposeEffect`'s explicit Retry makes; the software commit did NOT
    /// run-create anything, so a re-propose converges), re-displayed via `.planStaleRefreshed`, never
    /// a blind re-sign/re-propose-and-immediately-recommit of the stale copy. The re-propose's OWN
    /// failure (a throw; an empty schedule is deliberately unfiltered here too — exactly like
    /// `proposeEffect`, since `confirmTapped`'s own zero-transfer guard is the single source of
    /// truth for "nothing to sign") falls through to the EXISTING propose-failure sheet
    /// (`.transferProposalFailed`) rather than inventing a second failure surface.
    private func refreshAfterPlanStale(accountUUID: AccountUUID, send: Send<Action>) async {
        do {
            let schedule = try await sdkSynchronizer.proposeMigrationTransfers(accountUUID)
            await send(.planStaleRefreshed(schedule))
        } catch {
            await send(.transferProposalFailed)
        }
    }

    /// MOB-1458 (final review I1): the KEYSTONE leg's plan-stale recovery — `restartCurrentMigrationStep`,
    /// not the software leg's `proposeMigrationTransfers` re-propose. `requestKeystoneSignature`'s
    /// `proposeKeystoneBatch` calls `proposeNoteSplitPCZTs` (run-CREATING, persists an unsigned run)
    /// BEFORE the echo-verified `proposeMigrationPCZTs`, whose echo checks against the STORED committed
    /// run — and the SDK's contract (`ZcashRustBackendWelding`/`MIGRATING.md`) is that re-proposing
    /// cannot converge on an already-committed run: a plain re-propose here would strand the run and
    /// loop the plan-stale toast forever (each round draws fresh randomness that still mismatches the
    /// committed cache). `restartCurrentMigrationStep` is the one call that BOTH cancels any stranded
    /// run AND returns a fresh, committable preview — so it converges in a single round. Its returned
    /// schedule feeds the SAME `.planStaleRefreshed` action (apply + toast) the software leg uses; its
    /// own throw falls through to the existing `.transferProposalFailed` sheet, exactly like
    /// `refreshAfterPlanStale`.
    private func restartAfterPlanStale(accountUUID: AccountUUID, send: Send<Action>) async {
        do {
            let schedule = try await sdkSynchronizer.restartCurrentMigrationStep(accountUUID)
            await send(.planStaleRefreshed(schedule))
        } catch {
            await send(.transferProposalFailed)
        }
    }

    /// The Keystone `confirmTapped` fork: proposes ALL of the schedule's PCZTs — led by any
    /// preparation (note-split) PCZTs the engine still needs — and hands the whole batch to the
    /// coordinator for ONE batched QR-signing session (rounds are the coordinator's business; see
    /// the SDK's action-budget packer).
    ///
    /// Delegates a `MigrationKeystoneBatch`, not a bare array: the prep/transfer boundary is
    /// positional in this SDK and the count has to survive the round trip so the two store calls can
    /// be told apart afterwards — see `MigrationCommitPipeline.proposeKeystoneBatch`'s doc for why
    /// that replaces #1930's id-sentinel entirely.
    ///
    /// Every SDK member throws through, and an empty batch is also a failure, so this never delegates
    /// a silently empty or partial batch. Failures route to the SAME sheet the software fork uses,
    /// and Retry re-runs this same propose.
    ///
    /// `ZcashError.migrationPlanStale` is caught SPECIFICALLY ahead of the generic catch, and — unlike
    /// the software lane — recovers via RESTART, not re-propose: `proposeKeystoneBatch`'s
    /// `proposeNoteSplitPCZTs` is the run-creating call, so a re-propose can never converge on the
    /// already-committed run (it would toast-loop forever). See `restartAfterPlanStale`.
    private func requestKeystoneSignature(for schedule: MigrationSchedule, account: WalletAccount) -> Effect<Action> {
        .run { send in
            do {
                let batch = try await MigrationCommitPipeline.proposeKeystoneBatch(
                    schedule: schedule,
                    account: account,
                    sdkSynchronizer: sdkSynchronizer
                )
                await send(.delegate(.keystoneSignRequested(batch)))
            } catch ZcashError.migrationPlanStale {
                await restartAfterPlanStale(accountUUID: account.id, send: send)
            } catch {
                await send(.noteSplitFailed)
            }
        }
    }

    /// MOB-1496 (R8-T1, S3): proposes a fresh schedule via `proposeMigrationTransfers` —
    /// `retryTapped`'s SINGLE-attempt re-proposal after a propose failure (an explicit user tap, not
    /// a flow entry). Throws through to `.transferProposalFailed` instead of silently falling back to
    /// an empty schedule. `onAppear`'s entry propose uses `proposeWithRetryEffect` instead.
    private func proposeEffect(accountUUID: AccountUUID?) -> Effect<Action> {
        guard let accountUUID else { return .none }

        return .run { send in
            do {
                let schedule = try await sdkSynchronizer.proposeMigrationTransfers(accountUUID)
                await send(.transfersProposed(schedule))
            } catch {
                await send(.transferProposalFailed)
            }
        }
    }

    /// MOB-1513 (E2-FIX): the bounded, quiet propose used at FLOW ENTRY (`onAppear`). Right after a
    /// restore there is a short window (~30 s, mostly hidden by the SDK's balance hold) where the
    /// migration banner can appear while the wallet's notes are not yet witnessable — the engine then
    /// has nothing to schedule and `proposeMigrationTransfers` returns a NON-throwing EMPTY schedule
    /// (its "nothing to migrate yet / nothing due" answer, the same surface the SDK maps the transient
    /// "not witnessable yet" state to). On that ONE outcome this keeps the screen in its existing
    /// loading state and re-proposes every `proposeRetryInterval`, for up to `proposeRetryMaxRetries`
    /// re-attempts (~60 s from the first). The first non-empty schedule proceeds normally
    /// (`.transfersProposed`); a propose THROW is a genuine failure that surfaces immediately through
    /// the existing `.transferProposalFailed` path (unchanged), and an exhausted window surfaces that
    /// SAME propose-failure sheet rather than silently populating an empty plan — the retry only
    /// DEFERS to today's error path, it never hides a real problem.
    ///
    /// Single-flight + dismiss-cancellable via `CancelID.proposeRetry` (`cancelInFlight` restarts the
    /// window on a re-appearance; TCA cancels the loop when the screen is popped). `try await
    /// clock.sleep` (not `try?`) so a cancellation exits the loop promptly instead of spinning.
    private func proposeWithRetryEffect(accountUUID: AccountUUID?) -> Effect<Action> {
        guard let accountUUID else { return .none }

        return .run { send in
            for retry in 0...Constants.proposeRetryMaxRetries {
                do {
                    let schedule = try await sdkSynchronizer.proposeMigrationTransfers(accountUUID)
                    if !schedule.transfers.isEmpty {
                        await send(.transfersProposed(schedule))
                        return
                    }
                    // Empty schedule: the wallet isn't ready yet — stay quiet and retry below.
                } catch {
                    // A THROW is a genuine failure, not the transient empty "nothing due" — surface
                    // it immediately through the existing propose-failure path.
                    await send(.transferProposalFailed)
                    return
                }
                guard retry < Constants.proposeRetryMaxRetries else { break }
                try await clock.sleep(for: Constants.proposeRetryInterval)
            }
            await send(.transferProposalFailed)
        }
        .cancellable(id: CancelID.proposeRetry, cancelInFlight: true)
    }

    /// Populates `rows`/`totalDurationHours`/`schedule` from a `MigrationSchedule`, whether it was
    /// freshly proposed or injected by the coordinator. MOB-1513 (C2, Figma 4207:7394 + 4198:14325):
    /// every transfer row's status is decided by `transferRowStatus` now — see its doc for the rule.
    ///
    /// MOB-1513 (B3): each row's forward ETA is a block delta against the live chain tip —
    /// `MigrationETA.minutesFromNow`. This replaces `estimateTimestamp`, which returns nil for every
    /// FUTURE migration height (beyond the newest bundled checkpoint), flooring every row to 0 and
    /// rendering the "~10 mins" fallback. `minutesFromNow` carries the minute-precise value (so a
    /// sub-hour transfer reads "in ~N mins"); `hoursFromNow` keeps the coarse whole-hour copy.
    ///
    /// P3: measured in `state.chainClock`'s frame — the SDK's estimated tip and MEASURED block rate
    /// — so this screen's "in ~6 hours" and the Status screen's agree about the same transfer.
    private func apply(_ schedule: MigrationSchedule, to state: inout State) {
        let clock = state.chainClock
        // MOB-1513 (C2): mirrors `State.splitRow`'s own gate (shown whenever `rows` is non-empty —
        // see its doc) rather than re-deriving a second "is there a split" notion that could drift
        // from what the view actually renders alongside these rows.
        let hasSplitRow = !schedule.transfers.isEmpty
        state.rows = IdentifiedArrayOf(
            uniqueElements: schedule.transfers.enumerated().map { index, transfer in
                let minutes = MigrationETA.minutesFromNow(scheduledHeight: transfer.nextExecutableAfterHeight, clock: clock)
                return MigrationTransferRow(
                    // OLD -> NEW SDK: `MigrationTransferProposal.id` is `UInt32` now while the row
                    // id is a `String`. `transferKey` is the ONE conversion point (see its doc in
                    // `MigrationManagerLiveKey`) and is the same key the manager's own row join
                    // uses — so a row built here and a row built there are the same row, which is
                    // what lets the live per-transaction statuses join onto these.
                    id: transfer.transferKey,
                    index: index,
                    amount: transfer.amount,
                    status: Self.transferRowStatus(index: index, hasSplitRow: hasSplitRow),
                    // MOB-1466: `nil` = the tip was unknown when this plan row was built, so it
                    // carries no ETA and renders "Recomputing ETA…" rather than the "Starts right
                    // away" a fabricated zero used to produce on every row at once.
                    hoursFromNow: (minutes ?? 0) / 60,
                    minutesFromNow: minutes,
                    isETAKnown: minutes != nil
                )
            }
        )
        state.totalDurationHours = schedule.estimatedDurationHours
        state.schedule = schedule
    }

    /// MOB-1513 (C2, Figma 4207:7394 + 4198:14325): a transfer row's `.active`/`.pending` status.
    /// The synthesized split row (`State.splitRow`) alone carries the current-step styling once
    /// it's shown, so a transfer row is `.active` only in the split row's ABSENCE — `apply`'s
    /// original rule (Figma 3508:11442). Before this fix, both rendered `.active` simultaneously
    /// for any non-empty schedule, since `State.splitRow` shows unconditionally once `rows` is
    /// non-empty — the exact condition `hasSplitRow` mirrors here, so `apply` can in practice only
    /// ever reach the `true` branch for a genuine schedule. Extracted as its own internal,
    /// directly-tested rule (the established pattern for pure per-row logic in this feature — see
    /// `MigrationETA`) rather than inlined, so both branches of the rule stay pinned by a test even
    /// though only one is reachable through `apply` today.
    static func transferRowStatus(index: Int, hasSplitRow: Bool) -> MigrationTransferRow.Status {
        guard !hasSplitRow else { return .pending }
        return index == 0 ? .active : .pending
    }
}
