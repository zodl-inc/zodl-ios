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
//  MOB-1513 (B4 — confirm redesign): the commit chain is SIGN-ONLY now. The MOB-1478 (W4) silent
//  note-split broadcast that used to run under this screen's Confirm (`submitNoteSplit`: proving +
//  inline Tor + broadcast — the multi-second confirm freeze QA hit) left the chain entirely, along
//  with its whole R14-R17 broadcast-failure surface (`failureKind`, `broadcastFailureRouted`, the
//  Tor off-warning alert, and the sync-server fallback actions this store carried in R9-T2) — a
//  commit failure is a plain thrown error now, presented on the existing generic Cancel/Retry
//  sheet. The first prep broadcasts AFTER navigation, via `MigrationCoordFlowCoordinator`'s
//  post-confirm first-delivery kick; broadcast failures surface (and retry) through the migration
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

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationTransferPlan {
    @ObservableState
    struct State: Equatable {
        enum Variant: Equatable {
            case scheduled
            case manual
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
        /// `false` for the rescheduled variant only (MOB-1466): its transfers are already signed at
        /// the original plan commit, so `confirmTapped` is a plain acknowledgment — `false` skips
        /// `signAndStoreMigrationSchedule` and delegates `.confirmed` directly. The re-created
        /// (recovery) variant signs a fresh schedule, so it keeps the default `true`.
        var requiresSigning = true
        /// MOB-1513 (B4): true while an async confirm leg is in flight — the software commit, the
        /// Keystone PCZT-batch propose, or a propose-failure Retry's re-propose. Drives the Confirm
        /// button's disabled+spinner state AND the `.confirmTapped`/`.retryTapped` single-flight
        /// guard: a second tap while set is a complete no-op, so concurrent commits (the
        /// plan-cache-overwrite race behind QA's `MIGRATION_PLAN_STALE` error sheet) can't happen.
        /// Cleared on every outcome: `.scheduleSigned`, `.noteSplitFailed`,
        /// `.delegate(.keystoneSignRequested)` (so a pop-back after a rejected QR ceremony
        /// re-enables Confirm), `.transfersProposed`, and `.transferProposalFailed`.
        var isConfirming = false
        /// MOB-1478 (W4): failure sheet for the silent note-split step, presented over this screen
        /// instead of proceeding to sign+store — mirrors `MigrationNoteSplit.State.isFailurePresented`.
        /// MOB-1496 (R8-T1, S3): also covers a propose failure now — see `failureReason`.
        var isFailurePresented = false
        /// MOB-1496 (R8-T1, S3): which kind of failure `isFailurePresented` is showing; see
        /// `FailureReason`.
        var failureReason: FailureReason?

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
        var splitRow: MigrationTransferRow? {
            guard !rows.isEmpty else { return nil }
            // MOB-1513: this screen's `rows` are always freshly proposed/injected schedule rows
            // (`apply(_:to:)` below), so every row's `amount` is genuinely known in practice — but
            // the sum is honest either way: `nil` (unknown total) if ANY row's amount isn't, rather
            // than silently treating an unknown row as contributing zero to the total shown.
            let totalAmount: Zatoshi? = rows.contains { $0.amount == nil }
                ? nil
                : rows.reduce(Zatoshi.zero) { $0 + ($1.amount ?? Zatoshi.zero) }
            return MigrationTransferRow(
                id: "split-balance",
                index: -1,
                amount: totalAmount,
                status: .active,
                hoursFromNow: 0,
                minutesFromNow: 0,
                kind: .splitBalance
            )
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
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        /// Signs and stores the active schedule (sign-only — the first prep broadcasts later, via
        /// the coordinator's post-confirm kick; MOB-1513 B4).
        case confirmTapped
        case delegate(Delegate)
        /// The commit failed — presents the failure sheet instead of proceeding. Covers any
        /// software commit failure and (MOB-1496 R8-T1, #4) the Keystone PCZT-proposal fork's
        /// failures. (The name predates MOB-1513 B4, when a silent note-split broadcast was part of
        /// the commit — kept for continuity with `MigrationReviewTransfer`'s identical action.)
        case noteSplitFailed
        case onAppear
        /// MOB-1511 (W2): the round context loaded on appearance — see `State.round`'s doc.
        case roundContextLoaded(round: Int, totalRounds: Int?)
        /// Failure sheet: dismiss, then re-attempt the failed step from scratch — the whole commit
        /// sequence when `failureReason == .commit` (or unset), or (MOB-1496 R8-T1, S3) a fresh
        /// proposal when `failureReason == .propose`.
        case retryTapped
        /// `signAndStoreMigrationSchedule` completed.
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
            /// MOB-1468 (Keystone): the schedule's PCZTs (ALL N transfers, plus the note-split PCZT
            /// first when needed — MOB-1478 W4) were proposed and need QR signing in ONE batched
            /// session — the shared shape across the Keystone signing sources so the coordinator can
            /// treat them symmetrically. MOB-1496: the note-split PCZT (raw `Data`) rides along
            /// wrapped under a `"note-split"` sentinel id — see `requestKeystoneSignature`'s doc.
            case keystoneSignRequested([MigrationUnsignedTransferPczt])
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

            case .cancelTapped:
                state.isFailurePresented = false
                state.failureReason = nil
                return .none

            case .confirmTapped, .retryTapped:
                // MOB-1513 (B4): single-flight — a second tap while a confirm leg is already in
                // flight must not spawn a concurrent commit (every propose/prepare overwrites the
                // SDK's one-slot plan cache, so a concurrent commit surfaces as the
                // `MIGRATION_PLAN_STALE` error sheet QA hit).
                guard !state.isConfirming else { return .none }
                state.isFailurePresented = false

                // MOB-1496 (R8-T1, S3): a propose failure's Retry re-proposes instead of
                // re-attempting the commit — checked FIRST, before any of the commit guards below.
                if case .retryTapped = action, state.failureReason == State.FailureReason.propose {
                    state.failureReason = nil
                    // Set only when a real re-propose launches (a nil account is a no-op inside
                    // `proposeEffect`, which must not strand the flag).
                    guard let accountUUID = state.selectedWalletAccount?.id else { return .none }
                    state.isConfirming = true
                    return proposeEffect(accountUUID: accountUUID)
                }
                state.failureReason = nil

                guard state.requiresSigning else {
                    // Rescheduled variant: transfers are already signed — this is acknowledgment.
                    return .send(.delegate(.confirmed))
                }

                // MOB-1496 (R8-T1, S3): never sign/delegate for a schedule that doesn't exist yet
                // (propose still in flight, or failed) or that legitimately came back empty — the
                // engine's `sign_and_store_migration_schedule` deterministically refuses an empty
                // schedule, and an absent one has nothing to sign.
                guard let schedule = state.schedule, !schedule.transfers.isEmpty else {
                    return .none
                }
                guard let account = state.selectedWalletAccount else { return .none }

                guard account.vendor != WalletAccount.Vendor.keystone else {
                    state.isConfirming = true
                    return requestKeystoneSignature(for: schedule, account: account)
                }

                guard let zip32AccountIndex = account.zip32AccountIndex else { return .none }

                state.isConfirming = true
                return commitEffect(schedule: schedule, account: account, zip32AccountIndex: zip32AccountIndex)

            case .delegate(.keystoneSignRequested):
                // MOB-1513 (B4): the batch is handed to the coordinator (which pushes the QR
                // ceremony on top) — re-enable Confirm so a pop-back after a rejected signature
                // lands on a tappable button again.
                state.isConfirming = false
                return .none

            case .delegate:
                return .none

            case .noteSplitFailed:
                state.isConfirming = false
                state.isFailurePresented = true
                state.failureReason = State.FailureReason.commit
                return .none

            case .onAppear:
                // MOB-1511 (W2): the multi-round label loads on EVERY appearance path (fresh
                // proposal, injected schedule, hydrated rows alike) — it derives from persisted
                // app state + the stub estimate, independent of where the rows came from.
                let roundContextEffect = Effect<MigrationTransferPlan.Action>.run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] send in
                    let context = await migrationManager.migrationRoundContext(accountUUID)
                    await send(.roundContextLoaded(round: context.round, totalRounds: context.totalRounds))
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

            case .roundContextLoaded(let round, let totalRounds):
                // MOB-1511 (W2): shown only for a genuinely multi-round migration — a later round
                // in flight, or a known engine estimate above one.
                state.round = round >= 2 || (totalRounds ?? 1) > 1 ? round : nil
                state.totalRounds = state.round != nil ? totalRounds : nil
                return .none

            case .scheduleSigned:
                state.isConfirming = false
                return .send(.delegate(.confirmed))

            case .planStaleRefreshed(let schedule):
                // MOB-1458 (Task 3): mirrors `.transfersProposed` — the fresh schedule replaces
                // the stale one on screen — plus the toast telling the user to review it before
                // tapping Confirm again.
                state.isConfirming = false
                apply(schedule, to: &state)
                state.$toast.withLock { $0 = .topDelayed(String(localizable: .migrationPlanStaleRefreshed)) }
                return .none

            case .transferProposalFailed:
                state.isConfirming = false
                state.isFailurePresented = true
                state.failureReason = State.FailureReason.propose
                return .none

            case .transfersProposed(let schedule):
                state.isConfirming = false
                apply(schedule, to: &state)
                return .none
            }
        }
    }

    /// The software commit — sign-only since MOB-1513 (B4): a success is `.scheduleSigned`, any
    /// thrown error is the plain generic `.noteSplitFailed` (nothing was persisted — see
    /// `MigrationCommitPipeline.commitSoftware`'s doc). No broadcast happens here any more, so
    /// there is no failure to classify/route either. MOB-1458 (Task 3): `ZcashError
    /// .migrationPlanStale` is caught SPECIFICALLY ahead of that generic catch — see
    /// `refreshAfterPlanStale`'s doc.
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
                await send(.scheduleSigned)
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

    /// MOB-1468 (Keystone) `confirmTapped` fork: proposes ALL of the schedule's PCZTs — prefixed with
    /// any preparation (note-split) PCZTs the engine still needs (MOB-1478 W4; MOB-1496: zero, one,
    /// or many, not just one), so the whole batch signs in one QR ceremony — and hands them to the
    /// coordinator for that ONE batched QR-signing session.
    ///
    /// MOB-1496: the real SDK types preparation PCZTs (`proposeNoteSplitPCZTs ->
    /// [MigrationUnsignedTransferPczt]`) and the schedule's transfer PCZTs (`proposeMigrationPCZTs ->
    /// [MigrationUnsignedTransferPczt]`) the same way now, but a prep entry's engine id and a
    /// schedule entry's engine id share the same id-space, so each prep entry is wrapped under a
    /// `keystoneNoteSplitSentinelPrefix` + its own engine id so it can still be told apart in the same
    /// typed batch/QR ceremony. MOB-1496 (W6): on the signed side, `MigrationCoordFlowCoordinator`'s
    /// `.scan(.foundKeystoneBatchSignatures)` handler splits the prefixed entries back out
    /// (stripping the prefix) before storing — only the schedule's own engine-id-paired entries reach
    /// `storeSignedMigrationTransactions`, and the preps route through the dedicated
    /// dedicated `storeSignedNoteSplits` store — see that coordinator's doc for the full mechanism,
    /// including why (C-1 fix, final review R6) the preps still store BEFORE the schedule. The
    /// software path above (sign-only since MOB-1513 B4) is unaffected either way.
    ///
    /// MOB-1496 (R8-T1, #19/#4; final engine: unconditional fold): now delegates to the shared
    /// `MigrationCommitPipeline.proposeKeystoneBatch(schedule:account:sdkSynchronizer:)` — every
    /// member throws through (no more `try?` swallowing), and an empty resulting batch is ALSO a
    /// failure, so this never delegates a silently empty/partial batch; both route to the SAME
    /// failure sheet the software fork uses, and Retry re-runs this same propose. `mode` is no longer
    /// passed — the shared pipeline folds preps unconditionally now, mode-independent.
    /// MOB-1458 (Task 3): `ZcashError.migrationPlanStale` is caught SPECIFICALLY ahead of the
    /// generic catch, exactly like `commitEffect` — see `refreshAfterPlanStale`'s doc.
    private func requestKeystoneSignature(for schedule: MigrationSchedule, account: WalletAccount) -> Effect<Action> {
        .run { send in
            do {
                let pczts = try await MigrationCommitPipeline.proposeKeystoneBatch(
                    schedule: schedule,
                    account: account,
                    sdkSynchronizer: sdkSynchronizer
                )
                await send(.delegate(.keystoneSignRequested(pczts)))
            } catch ZcashError.migrationPlanStale {
                // MOB-1458 (final review I1): the KEYSTONE leg recovers via restart, NOT re-propose —
                // `proposeKeystoneBatch`'s run-creating `proposeNoteSplitPCZTs` means a re-propose can
                // never converge on the committed run (infinite toast loop). See `restartAfterPlanStale`.
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
    /// freshly proposed or injected by the coordinator. The first transfer is `.active` (ready now);
    /// the rest are `.pending`.
    ///
    /// MOB-1513 (B3): each row's forward ETA is a block delta against the LIVE chain tip
    /// (`latestState().latestBlockHeight`, the established synchronous tip accessor) at 75 s/block —
    /// `MigrationETA.minutesFromNow`. This replaces `estimateTimestamp`, which returns nil for every
    /// FUTURE migration height (beyond the newest bundled checkpoint), flooring every row to 0 and
    /// rendering the "~10 mins" fallback. `minutesFromNow` carries the minute-precise value (so a
    /// sub-hour transfer reads "in ~N mins"); `hoursFromNow` keeps the coarse whole-hour copy.
    private func apply(_ schedule: MigrationSchedule, to state: inout State) {
        let tip = sdkSynchronizer.latestState().latestBlockHeight
        state.rows = IdentifiedArrayOf(
            uniqueElements: schedule.transfers.enumerated().map { index, transfer in
                let minutes = MigrationETA.minutesFromNow(scheduledHeight: transfer.nextExecutableAfterHeight, currentTip: tip)
                return MigrationTransferRow(
                    id: transfer.id,
                    index: index,
                    amount: transfer.amount,
                    status: index == 0 ? .active : .pending,
                    hoursFromNow: minutes / 60,
                    minutesFromNow: minutes
                )
            }
        )
        state.totalDurationHours = schedule.estimatedDurationHours
        state.schedule = schedule
    }
}
