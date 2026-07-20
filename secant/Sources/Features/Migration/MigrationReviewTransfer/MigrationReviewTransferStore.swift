//
//  MigrationReviewTransferStore.swift
//  zodl
//
//  "Review Transfer" screen (MOB-1463, Figma S7 · immediate 2867:5924 / manual "3 of 5" 2729:8544,
//  equivalent to frame 2712:7779 which fails to render via MCP). Final confirmation before a
//  migration transfer is sent — either the single immediate transfer, or one step of a scheduled
//  plan. Immediate mode proposes its own single-transfer schedule on `onAppear` (for Amount/Fee) and
//  signs+stores it on confirm before delegating; manual step has its data injected by the
//  coordinator (no propose) and confirm delegates directly — the transfer was already signed at plan
//  commit. When the manual-step variant is a flow re-entry root (`isFlowRoot`), its back control
//  closes the flow via a new `.closed` delegate instead of popping — reusing `.confirmed` for a
//  back-tap would incorrectly signal the transfer was confirmed (MOB-1466). Both delegates are
//  consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1468 (Keystone): a Keystone-vendor account in immediate mode forks `confirmTapped` — instead
//  of signing+storing `state.schedule` locally (the same schedule `onAppear` proposed via
//  `proposeImmediateMigration()` for Amount/Fee), it proposes that schedule's PCZT
//  (`proposeMigrationPCZTs(schedule)`) and delegates `.keystoneSignRequested(pczts)` for the
//  coordinator to route through `MigrationKeystoneSign` + `Scan`. The manual-step path (transfers
//  already signed at plan commit) is unchanged — `signAndStoreMigrationSchedule` never runs there.
//
//  MOB-1496 (R8-T1 remediation, finding S1): immediate mode's commit is now split-free, matching the
//  engine's own design (`propose_immediate_migration_transfers` sweeps the whole balance in one
//  transaction, "skipping the split entirely"). The MOB-1478 (W4) silent-split step described below
//  is GONE from this screen — consulting `isNoteSplitNeeded()` here and then signing the
//  already-proposed immediate schedule without re-proposing would silently stage a self-conflicting
//  pair (the wallet DB never re-scans the split mid-flow, sync being stopped) that a later broadcast
//  rejects. The software commit and the Keystone PCZT-proposal fork now delegate to the shared
//  `MigrationCommitPipeline` (finding #19 — this store and `MigrationTransferPlanStore` drove
//  byte-identical copies of both before) in `.immediate` mode, which never calls
//  `isNoteSplitNeeded`/`prepareNoteSplit`/`submitNoteSplit`/`stopSyncBeforeMigrationBroadcast` — that
//  stop existed only to guard the split's own broadcast, and nothing in the immediate commit
//  broadcasts anything (`signAndStoreMigrationSchedule` only signs and persists locally). `onAppear`'s
//  propose and `confirmTapped`'s commit no longer silently fall back to an empty schedule on failure
//  (finding S3): a propose failure presents the failure sheet with `failureReason == .propose` (Retry
//  re-proposes), and Confirm is guarded against a nil or zero-transfer schedule regardless of why.
//  The Keystone fork now throws through instead of swallowing errors with `try?`, and an empty PCZT
//  batch is also a failure (finding #4).
//
//  MOB-1496 (final engine, plural preps): the paragraph above's "immediate mode's commit is now
//  split-free" still holds for the SOFTWARE commit (`commitSoftware`'s `.immediate` case) but no
//  longer for the Keystone PCZT-proposal fork (`requestKeystoneSignature` below) — the final engine's
//  immediate flag only rewrites transfer heights, so an immediate-mode Keystone batch CAN carry
//  preparation (note-split) PCZTs now; `MigrationCommitPipeline.proposeKeystoneBatch` folds them in
//  unconditionally, mode-independent (no more `mode` parameter at all). The 4 members named above
//  (`isNoteSplitNeeded`/`prepareNoteSplit`/`submitNoteSplit`/`stopSyncBeforeMigrationBroadcast`) are
//  still never called by the Keystone fork — it calls the new, distinct `proposeNoteSplitPCZTs`
//  instead, whose (possibly empty) prep subset is stored and broadcast entirely differently (see
//  `requestKeystoneSignature`'s own doc, and `MigrationCoordFlowCoordinator`'s Keystone-signing
//  section for the store/broadcast/resume mechanism).
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationReviewTransfer {
    @ObservableState
    struct State: Equatable {
        enum Mode: Equatable {
            case immediate
            case manualStep(number: Int, total: Int)
        }

        /// MOB-1496 (R8-T1, S3): distinguishes what `isFailurePresented`'s sheet is showing, so
        /// `retryTapped` re-attempts the right thing and the view picks the right copy. `nil` while
        /// no failure sheet is presented.
        enum FailureReason: Equatable {
            /// `onAppear`'s single-transfer schedule proposal threw — Retry re-proposes via
            /// `proposeImmediateMigration`.
            case propose
            /// The commit itself failed (software sign+store, or the Keystone PCZT-proposal fork)
            /// — Retry re-attempts the whole commit.
            case commit
        }

        /// Standard ZIP-317 marginal fee shown throughout the app (`Zatoshi(100_000)` precedent —
        /// migration schedules don't carry a fee field of their own).
        fileprivate static let standardFee = Zatoshi(100_000)

        var mode = Mode.immediate
        var amount = Zatoshi.zero
        var fee = Zatoshi.zero
        /// Immediate mode: the single-transfer schedule proposed on `onAppear`, signed+stored on
        /// confirm. `nil` in manual-step mode (nothing to propose or sign here), and (MOB-1496
        /// R8-T1, S3) also `nil` in immediate mode until a proposal succeeds.
        var schedule: MigrationSchedule?
        /// True when the manual-step variant is the coordinator's re-entry root — its back control
        /// then closes the flow instead of popping.
        var isFlowRoot = false
        /// MOB-1478 (W4): failure sheet, presented instead of proceeding to sign+store — mirrors
        /// `MigrationNoteSplit.State.isFailurePresented`. MOB-1496 (R8-T1, S3): also covers a
        /// propose failure now — see `failureReason`.
        var isFailurePresented = false
        /// MOB-1496 (R8-T1, S3): which kind of failure `isFailurePresented` is showing; see
        /// `FailureReason`.
        var failureReason: FailureReason?

        /// MOB-1497 (T2, R13): the formed snapshot's broadcast host — populated for the immediate
        /// mode, whether reached via the sheet-SKIPPED shortcut (whose footer disclosure this IS) or
        /// via the sheet's own confirm (redundant with the sheet's disclosure line the user just saw,
        /// but harmless — same "always hydrate" precedent as `MigrationStatus.State
        /// .syncPrivacyBufferMinutes`). Never populated for the manual-step mode (re-entry only, out
        /// of this task's scope — see the brief's "immediate-path Review Transfer footer" wording).
        /// `nil` hides the footer row: no snapshot yet, or an identity-custom user (R13 doesn't apply
        /// to them — see `MigrationTransferPlan.State.broadcastDisclosureHost`'s twin doc).
        var broadcastDisclosureHost: String?
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init(
            mode: Mode = .immediate,
            amount: Zatoshi = Zatoshi.zero,
            fee: Zatoshi = Zatoshi.zero,
            isFlowRoot: Bool = false
        ) {
            self.mode = mode
            self.amount = amount
            self.fee = fee
            self.isFlowRoot = isFlowRoot
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        /// Flow-root back control (manual step only): closes the flow instead of popping.
        case closeTapped
        /// Immediate mode signs+stores the schedule before delegating (MOB-1496 R8-T1, S1:
        /// split-free — the engine's immediate path never expects a split); manual step delegates
        /// directly.
        case confirmTapped
        case delegate(Delegate)
        /// The commit failed — presents the failure sheet instead of proceeding. Covers any
        /// software commit failure and (MOB-1496 R8-T1, #4) the Keystone PCZT-proposal fork's
        /// failures.
        case noteSplitFailed
        /// Immediate mode only: proposes a single-transfer schedule for Amount/Fee display.
        case onAppear
        /// Failure sheet: dismiss, then re-attempt the failed step from scratch — the whole commit
        /// sequence when `failureReason == .commit` (or unset), or (MOB-1496 R8-T1, S3) a fresh
        /// proposal when `failureReason == .propose`.
        case retryTapped
        /// `signAndStoreMigrationSchedule` completed (immediate mode only).
        case scheduleSigned
        /// MOB-1496 (R8-T1, S3): `proposeImmediateMigration()` threw — presents the failure sheet;
        /// `schedule` is left untouched (never a silent empty-schedule fallback).
        case transferProposalFailed
        /// `proposeImmediateMigration()` result (immediate mode only).
        case transferProposed(MigrationSchedule)

        enum Delegate: Equatable {
            case closed
            case confirmed
            /// MOB-1468 (Keystone): the immediate-mode schedule's PCZT was proposed and needs QR
            /// signing — a single-element array, the shared shape across the Keystone signing
            /// sources so the coordinator can treat them symmetrically. MOB-1496 (R8-T1, S1): never
            /// prefixed with a note-split PCZT — the immediate lane is split-free by engine design.
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
            case .binding:
                return .none

            case .cancelTapped:
                state.isFailurePresented = false
                state.failureReason = nil
                return .none

            case .closeTapped:
                return .send(.delegate(.closed))

            case .confirmTapped, .retryTapped:
                state.isFailurePresented = false

                // MOB-1496 (R8-T1, S3): a propose failure's Retry re-proposes instead of
                // re-attempting the commit — checked FIRST, before any of the commit guards below.
                if case .retryTapped = action, state.failureReason == State.FailureReason.propose {
                    state.failureReason = nil
                    return proposeEffect(accountUUID: state.selectedWalletAccount?.id)
                }
                state.failureReason = nil

                guard case .immediate = state.mode else {
                    // Manual step: the transfer was already signed at plan commit — delegate
                    // directly.
                    return .send(.delegate(.confirmed))
                }

                // MOB-1496 (R8-T1, S3): never sign/delegate for a schedule that doesn't exist yet
                // (propose still in flight, or failed) or that legitimately came back empty —
                // deliberately a SEPARATE guard from the mode check above, so a nil/empty schedule
                // in immediate mode returns `.none` (stay put) rather than falling into the manual
                // step's "already signed, just acknowledge" delegate.
                guard let schedule = state.schedule, !schedule.transfers.isEmpty else {
                    return .none
                }
                guard let account = state.selectedWalletAccount else { return .none }

                guard account.vendor != WalletAccount.Vendor.keystone else {
                    return requestKeystoneSignature(for: schedule, account: account)
                }

                guard let zip32AccountIndex = account.zip32AccountIndex else { return .none }

                return .run { send in
                    do {
                        try await MigrationCommitPipeline.commitSoftware(
                            mode: MigrationCommitMode.immediate,
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
                    } catch {
                        await send(.noteSplitFailed)
                    }
                }

            case .delegate:
                return .none

            case .noteSplitFailed:
                state.isFailurePresented = true
                state.failureReason = State.FailureReason.commit
                return .none

            case .onAppear:
                guard case .immediate = state.mode else { return .none }
                return proposeEffect(accountUUID: state.selectedWalletAccount?.id)

            case .scheduleSigned:
                return .send(.delegate(.confirmed))

            case .transferProposalFailed:
                state.isFailurePresented = true
                state.failureReason = State.FailureReason.propose
                return .none

            case .transferProposed(let schedule):
                state.schedule = schedule
                state.amount = schedule.transfers.first?.amount ?? Zatoshi.zero
                state.fee = State.standardFee
                return .none
            }
        }
    }

    /// MOB-1468 (Keystone) `confirmTapped` fork: proposes the immediate-mode schedule's PCZT and
    /// hands the batch to the coordinator for QR signing.
    ///
    /// MOB-1496 (final engine): UNLIKE the software fork above (`commitSoftware`'s `.immediate` case,
    /// still genuinely split-free — S1 stands for that lane), this Keystone fork's batch CAN now
    /// carry preparation (note-split) PCZTs prefixed ahead of the schedule's own — the R8-T1 (S1) "the
    /// immediate lane is split-free by engine design" premise this comment used to document was
    /// specific to the OLD singular-split API's `isNoteSplitNeeded`/immediate-mode gate, which
    /// `MigrationCommitPipeline.proposeKeystoneBatch` no longer has: the final engine's immediate flag
    /// only rewrites transfer heights, so an immediate-mode PCZT build can legitimately include preps
    /// too, and skipping them here would silently hand the signing device a batch missing
    /// transactions the engine's run already needs signed.
    ///
    /// MOB-1496 (R8-T1, #19/#4; final engine: unconditional fold): delegates to the shared
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

    /// MOB-1496 (R8-T1, S3): proposes a fresh single-transfer schedule via `proposeImmediateMigration`
    /// — shared by `onAppear`'s first-run proposal and `retryTapped`'s re-proposal after a propose
    /// failure. Throws through to `.transferProposalFailed` instead of silently falling back to an
    /// empty schedule.
    private func proposeEffect(accountUUID: AccountUUID?) -> Effect<Action> {
        guard let accountUUID else { return .none }

        return .run { send in
            do {
                let schedule = try await sdkSynchronizer.proposeImmediateMigration(accountUUID)
                await send(.transferProposed(schedule))
            } catch {
                await send(.transferProposalFailed)
            }
        }
    }
}
