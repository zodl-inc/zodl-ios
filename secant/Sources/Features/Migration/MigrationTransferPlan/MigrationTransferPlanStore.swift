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
//  MOB-1478 (W4): note splitting runs silently under this screen's commit, right before signing —
//  `.confirmTapped`/`.retryTapped` share one effect: iff `isNoteSplitNeeded()`, `prepareNoteSplit` +
//  `submitNoteSplit` first (mirrors `MigrationNoteSplitStore`'s old explainer-confirm sequence 1:1);
//  a split failure presents the same Cancel/Retry failure sheet `MigrationNoteSplit` uses (this
//  screen had none before) instead of proceeding to sign+store. The Keystone fork's batch
//  (`requestKeystoneSignature`) now proposes the note-split PCZT first too, when needed, so the WHOLE
//  batch (split + all N transfers) signs in the same QR ceremony — `storeSignedMigrationTransactions`
//  stores the whole `[MigrationSignedTransferPczt]` array atomically, so the no-partial-storage
//  invariant holds unchanged (MOB-1496: see `requestKeystoneSignature`'s doc for the note-split
//  PCZT's sentinel-id wrapping, needed since it's typed differently — raw `Data` — from the
//  schedule's own PCZTs). `MigrationNoteSplit` itself no longer requests Keystone signing
//  (re-entry-only now).
//
//  MOB-1496 (R8-T1 remediation): the software commit sequence and the Keystone PCZT-proposal fork
//  now delegate to the shared `MigrationCommitPipeline` (finding #19 — this store and
//  `MigrationReviewTransferStore` drove byte-identical copies of both before), always in
//  `.scheduled` mode (every `variant` here signs a multi-transfer schedule the same way).
//  `onAppear`'s propose and `confirmTapped`'s commit no longer silently fall back to an empty
//  schedule on failure (finding S3): a propose failure presents the SAME failure sheet with
//  `failureReason == .propose` (Retry re-proposes), and Confirm is guarded against a nil or
//  zero-transfer schedule regardless of why. A landed-but-unrecorded note split
//  (`ZcashError.migrationRecordFailedAfterBroadcast`) is treated as success rather than routed into
//  a Retry that would re-sign a conflicting split (finding #1) — see `MigrationCommitPipeline
//  .commitSoftware`'s doc. The Keystone fork now throws through instead of swallowing errors with
//  `try?`, and an empty PCZT batch is also a failure (finding #4).
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
        /// `totalRounds` additionally needs the SDK estimate (stubbed nil until librustzcash#2714).
        var round: Int?
        var totalRounds: Int?
        @Shared(.inMemory(.exchangeRate)) var currencyConversion: CurrencyConversion?
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
        /// MOB-1478 (W4): failure sheet for the silent note-split step, presented over this screen
        /// instead of proceeding to sign+store — mirrors `MigrationNoteSplit.State.isFailurePresented`.
        /// MOB-1496 (R8-T1, S3): also covers a propose failure now — see `failureReason`.
        var isFailurePresented = false
        /// MOB-1496 (R8-T1, S3): which kind of failure `isFailurePresented` is showing; see
        /// `FailureReason`.
        var failureReason: FailureReason?
        /// R9-T2 (finding 3): the classified/routed variant of a `.commit`-reason failure sheet —
        /// see `MigrationSending.State.failureKind`'s doc for the shared shape. Always `nil` for a
        /// `.propose` failure (never broadcast-related) and for an unclassifiable or Keystone commit
        /// failure (today's generic copy, unchanged).
        var failureKind: MigrationBroadcastFailureRoute?
        @Presents var alert: AlertState<Action>?

        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

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
        case alert(PresentationAction<Action>)
        case binding(BindingAction<State>)
        /// R9-T2 (finding 3, R14/R15/R16): `routeBroadcastFailure`'s resolved route for a classified
        /// scheduled-commit split failure — see `MigrationSending.Action.broadcastFailureRouted`'s
        /// doc for the shared shape. Never sent for an unclassified failure — `failureKind` then
        /// stays `nil`, the existing generic sheet.
        case broadcastFailureRouted(MigrationBroadcastFailureRoute)
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        /// Signs and stores the active schedule (silently splitting first, when needed).
        case confirmTapped
        case delegate(Delegate)
        /// The commit failed — presents the failure sheet instead of proceeding to sign+store.
        /// Covers the silent note-split step (MOB-1478 W4), any other software commit failure, and
        /// (MOB-1496 R8-T1, #4) the Keystone PCZT-proposal fork's failures.
        case noteSplitFailed
        /// R9-T2 (R11, reused from `MigrationTorSheet`'s off-warning): the R14 sheet's "Proceed
        /// without Tor" alert confirms — turns Tor off for the REST of this run then re-attempts the
        /// commit.
        case offWarningProceedTapped
        case onAppear
        /// MOB-1511 (W2): the round context loaded on appearance — see `State.round`'s doc.
        case roundContextLoaded(round: Int, totalRounds: Int?)
        /// R9-T2 (R14): the `.torFirstRunChoice` sheet's "Proceed without Tor" button — presents the
        /// R11 warning alert instead of proceeding directly.
        case proceedWithoutTorTapped
        /// Failure sheet: dismiss, then re-attempt the failed step from scratch — the whole commit
        /// sequence when `failureReason == .commit` (or unset), or (MOB-1496 R8-T1, S3) a fresh
        /// proposal when `failureReason == .propose`.
        case retryTapped
        /// `signAndStoreMigrationSchedule` completed.
        case scheduleSigned
        /// MOB-1496 (R8-T1, S3): `proposeMigrationTransfers()` threw — presents the failure sheet;
        /// `schedule`/`rows` are left untouched (never a silent empty-schedule fallback).
        case transferProposalFailed
        /// `proposeMigrationTransfers()` result — populates rows/duration for a fresh entry.
        case transfersProposed(MigrationSchedule)
        /// R9-T2 (R17): the `.providerExhausted` sheet's "Broadcast via sync server" button.
        case useSyncServerTapped

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
            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                // Mirrors `MigrationSendingStore`'s identical shape — this screen has no toggle
                // analog to restore; "Keep Tor on" simply returns to the R14 sheet unchanged.
                state.alert = nil
                return .none

            case .binding:
                return .none

            case .broadcastFailureRouted(let route):
                state.failureKind = route
                return .none

            case .cancelTapped:
                state.isFailurePresented = false
                state.failureReason = nil
                state.failureKind = nil
                return .none

            case .confirmTapped, .retryTapped:
                state.isFailurePresented = false
                state.failureKind = nil

                // MOB-1496 (R8-T1, S3): a propose failure's Retry re-proposes instead of
                // re-attempting the commit — checked FIRST, before any of the commit guards below.
                if case .retryTapped = action, state.failureReason == State.FailureReason.propose {
                    state.failureReason = nil
                    return proposeEffect(accountUUID: state.selectedWalletAccount?.id)
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
                    return requestKeystoneSignature(for: schedule, account: account)
                }

                guard let zip32AccountIndex = account.zip32AccountIndex else { return .none }

                return commitEffect(schedule: schedule, account: account, zip32AccountIndex: zip32AccountIndex)

            case .delegate:
                return .none

            case .noteSplitFailed:
                state.isFailurePresented = true
                state.failureReason = State.FailureReason.commit
                return .none

            case .offWarningProceedTapped:
                state.alert = nil
                state.isFailurePresented = false
                state.failureKind = nil
                state.failureReason = nil
                let account = state.selectedWalletAccount
                if let account {
                    migrationManager.overrideTorForRun(account.id, false)
                }
                return retryCommitEffect(state)

            case .proceedWithoutTorTapped:
                // Gated to the R14 first-run-choice variant — the alert this presents leads to a
                // clearnet retry (`overrideTorForRun(account, false)`), which R15's mid-run hold must
                // never offer. Mirrors `MigrationSendingStore`'s identical guard.
                guard state.failureKind == MigrationBroadcastFailureRoute.torFirstRunChoice else { return .none }
                // Scheduled commits are never full-balance (only the immediate lane is — this screen
                // is only ever reached for `.privateScheduled` mode), so unlike Sending/NoteSplit this
                // never reads `migrationManager.migrationMode()`.
                state.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: .offWarningProceedTapped)
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

                // `includeResidual: false` by design: the scheduled plan never folds the Orchard
                // remainder into its own run — dust stays on the separate, post-completion
                // "Migrate anyway" lane (`migrateMigrationDust`/the Keystone propose fork in
                // `MigrationCoordFlowCoordinator`, both `includeResidual: true`, MOB-1496 W6). This
                // screen is only ever reached for `.privateScheduled` mode (the coordinator routes
                // `.immediate` through `MigrationReviewTransfer` instead), so
                // `proposeMigrationTransfers` (not `proposeImmediateMigration`) is always correct
                // here.
                // `.concatenate` (not `.merge`): the round load answers instantly today, and a
                // deterministic receive order keeps exhaustive TestStores stable.
                return .concatenate(roundContextEffect, proposeEffect(accountUUID: state.selectedWalletAccount?.id))

            case .roundContextLoaded(let round, let totalRounds):
                // MOB-1511 (W2): shown only for a genuinely multi-round migration — a later round
                // in flight, or a known engine estimate above one.
                state.round = round >= 2 || (totalRounds ?? 1) > 1 ? round : nil
                state.totalRounds = state.round != nil ? totalRounds : nil
                return .none

            case .scheduleSigned:
                return .send(.delegate(.confirmed))

            case .transferProposalFailed:
                state.isFailurePresented = true
                state.failureReason = State.FailureReason.propose
                return .none

            case .transfersProposed(let schedule):
                apply(schedule, to: &state)
                return .none

            case .useSyncServerTapped:
                state.isFailurePresented = false
                state.failureKind = nil
                state.failureReason = nil
                guard let account = state.selectedWalletAccount else { return .none }
                return .concatenate(
                    .run { [migrationManager] _ in await migrationManager.overrideBroadcastEndpointToSyncServer(account.id) },
                    retryCommitEffect(state)
                )
            }
        }
    }

    /// R9-T2 (finding 3): the software commit sequence `.confirmTapped`/`.retryTapped`'s fallthrough,
    /// `.offWarningProceedTapped`, and `.useSyncServerTapped` all funnel into — classifies+routes a
    /// scheduled-commit split failure via `MigrationCommitPipeline`'s typed
    /// `MigrationCommitError.splitFailedRouted` before falling back to the existing generic
    /// `.noteSplitFailed` outcome, mirroring `MigrationSendingStore`/`MigrationNoteSplitStore`'s
    /// "route first, generic outcome second" ordering. A `nil` route (unclassifiable failure) sends
    /// only `.noteSplitFailed` — `state.failureKind` stays `nil`, today's generic sheet.
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
            } catch MigrationCommitError.splitFailedRouted(let route) {
                if let route {
                    await send(.broadcastFailureRouted(route))
                }
                await send(.noteSplitFailed)
            } catch {
                await send(.noteSplitFailed)
            }
        }
    }

    /// R9-T2 (finding 3): the retry dispatch `.offWarningProceedTapped`/`.useSyncServerTapped` share —
    /// a ROUTED failure (`failureKind != nil`) can only ever have come from the software
    /// `commitSoftware` path (Keystone forks BEFORE ever reaching it — see `requestKeystoneSignature`
    /// below), so this skips straight to the software guard chain without re-checking
    /// `requiresSigning`/vendor, unlike `.confirmTapped`/`.retryTapped`'s own fuller chain. Takes a
    /// snapshot of `State` rather than `inout`, mirroring `MigrationNoteSplitStore.retryEffect` — ONE
    /// of the guards below failing (e.g. the account was deselected mid-flow) is a silent no-op,
    /// mirroring `.confirmTapped`/`.retryTapped`'s own identical guards.
    private func retryCommitEffect(_ state: State) -> Effect<Action> {
        guard let schedule = state.schedule, !schedule.transfers.isEmpty else { return .none }
        guard let account = state.selectedWalletAccount else { return .none }
        guard let zip32AccountIndex = account.zip32AccountIndex else { return .none }

        return commitEffect(schedule: schedule, account: account, zip32AccountIndex: zip32AccountIndex)
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
    /// `.scan(.foundPCZTBatch)`/`.simulateSignature` handlers split the prefixed entries back out
    /// (stripping the prefix) before storing — only the schedule's own engine-id-paired entries reach
    /// `storeSignedMigrationTransactions`, and the preps route through the dedicated
    /// `storeSignedNoteSplits`/`broadcastStoredNoteSplit` pair instead (via the existing
    /// `MigrationNoteSplit` resubmit lane) — see that coordinator's doc for the full mechanism,
    /// including why (C-1 fix, final review R6) the preps still store BEFORE the schedule. The
    /// software path above (which routes the split through `submitNoteSplit` directly) is unaffected
    /// either way.
    ///
    /// MOB-1496 (R8-T1, #19/#4; final engine: unconditional fold): now delegates to the shared
    /// `MigrationCommitPipeline.proposeKeystoneBatch(schedule:account:sdkSynchronizer:)` — every
    /// member throws through (no more `try?` swallowing), and an empty resulting batch is ALSO a
    /// failure, so this never delegates a silently empty/partial batch; both route to the SAME
    /// failure sheet the software fork uses, and Retry re-runs this same propose. `mode` is no longer
    /// passed — the shared pipeline folds preps unconditionally now, mode-independent.
    private func requestKeystoneSignature(for schedule: MigrationSchedule, account: WalletAccount) -> Effect<Action> {
        .run { send in
            do {
                let pczts = try await MigrationCommitPipeline.proposeKeystoneBatch(
                    schedule: schedule,
                    account: account,
                    sdkSynchronizer: sdkSynchronizer
                )
                await send(.delegate(.keystoneSignRequested(pczts)))
            } catch {
                await send(.noteSplitFailed)
            }
        }
    }

    /// MOB-1496 (R8-T1, S3): proposes a fresh schedule via `proposeMigrationTransfers` — shared by
    /// `onAppear`'s first-run proposal and `retryTapped`'s re-proposal after a propose failure.
    /// Throws through to `.transferProposalFailed` instead of silently falling back to an empty
    /// schedule.
    private func proposeEffect(accountUUID: AccountUUID?) -> Effect<Action> {
        guard let accountUUID else { return .none }

        return .run { send in
            do {
                let schedule = try await sdkSynchronizer.proposeMigrationTransfers(accountUUID, false)
                await send(.transfersProposed(schedule))
            } catch {
                await send(.transferProposalFailed)
            }
        }
    }

    /// Populates `rows`/`totalDurationHours`/`schedule` from a `MigrationSchedule`, whether it was
    /// freshly proposed or injected by the coordinator. The first transfer is `.active` (ready now);
    /// the rest are `.pending`. `hoursFromNow` comes from `estimateTimestamp` where the SDK can
    /// resolve a height to a timestamp; unresolved heights default to `0`.
    private func apply(_ schedule: MigrationSchedule, to state: inout State) {
        state.rows = IdentifiedArrayOf(
            uniqueElements: schedule.transfers.enumerated().map { index, transfer in
                MigrationTransferRow(
                    id: transfer.id,
                    index: index,
                    amount: transfer.amount,
                    status: index == 0 ? .active : .pending,
                    hoursFromNow: hoursFromNow(forHeightReadyAt: transfer.nextExecutableAfterHeight)
                )
            }
        )
        state.totalDurationHours = schedule.estimatedDurationHours
        state.schedule = schedule
    }

    private func hoursFromNow(forHeightReadyAt height: BlockHeight) -> Int {
        guard let readyTimestamp = sdkSynchronizer.estimateTimestamp(height) else { return 0 }

        let seconds = Date(timeIntervalSince1970: readyTimestamp).timeIntervalSinceNow
        return max(0, Int(seconds / 3_600))
    }
}
