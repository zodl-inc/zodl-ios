//
//  MigrationNoteSplitStore.swift
//  zodl
//
//  "Splitting Funds…" / "Split Confirmed!" screen (MOB-1461, Figma S2 · 2867:10741 progress /
//  2867:10645 success / 2670:15570 failure sheet) — MOB-1478 (W4): re-entry-only now. The split
//  itself starts silently under the TransferPlan/ReviewTransfer commit CTAs (`isNoteSplitNeeded()` ->
//  `prepareNoteSplit`/`submitNoteSplit`, or the Keystone batch), so this screen is never pushed by
//  forward routing any more — it only ever appears via `reentryRoute() == .noteSplitProgress` (the
//  home banner's `.splitting` tap), always as the coordinator's flow root. `onAppear` subscribes to
//  `migrationManager.stateEvents(_:)` to advance `.splitting` -> `.confirmed` once the SDK reports
//  `.readyToPropose` (or jumps straight there if that already happened before this screen mounted);
//  `confirmed`'s `continueTapped` closes the flow (the schedule/transfer was already committed before
//  the split even started — the home banner carries the progression from here). `retryTapped`/
//  `splitResult`/the failure sheet are kept for when a split needs re-attempting from this screen,
//  but nothing drives them live today for the SOFTWARE path: that submission (and its own failure
//  handling) happens once, earlier, under the TransferPlan/ReviewTransfer commit CTA — this re-entry
//  screen's `onAppear` only observes `migrationManager.stateEvents(_:)`/does a one-shot state read, so
//  `isFailurePresented` never becomes `true` from a cold mount for that path. Kept ready for a future
//  re-entry-time retry surface.
//
//  MOB-1468 (Keystone): once split signing folded into `MigrationTransferPlan`'s batch (MOB-1478 W4),
//  this screen no longer requests Keystone signing itself. MOB-1496 (W6) reintroduced a coordinator
//  path that DOES set `signedNoteSplitPczt` — `MigrationCoordFlowCoordinator.resumeAfterKeystoneSigning`
//  pushes this screen mid-Keystone-commit to broadcast just-signed preparation (note-split) PCZTs,
//  dispatching `.retryTapped` itself as the first attempt. MOB-1496 (C-1 fix, final review R6): that
//  push now also sets `splitStored: true` (the coordinator's own store effect already called
//  `storeSignedNoteSplits` before pushing this screen — see that effect's doc for why the store must
//  run there, not here), so `retryTapped`'s Keystone fork only ever (re)broadcasts for this, the only
//  live caller today. The fork's store-then-broadcast fallback (`splitStored == false`) is kept
//  dormant rather than deleted — same reasoning as the failure sheet above — so a future caller that
//  hands over an un-stored batch has somewhere to plug in. MOB-1496 (final engine, plural preps):
//  `signedNoteSplitPczt` carries the whole preparation batch now — `[MigrationSignedTransferPczt]`
//  (zero-or-many preps, though this screen is only ever pushed with a non-empty one), not a single
//  `Data` blob — since the final engine builds N preparation transactions, not one split transaction.
//
//  MOB-1496 (C-1b fix, final review R6 fix-wave 2): the coordinator no longer stores this commit's
//  schedule before pushing this screen — Step 0 of the fix-wave-2 report traced the engine's phase
//  machine and found that order lets the split's own broadcast-success record silently strand the
//  schedule once the split mines (see `MigrationCoordFlowCoordinator`'s header comment). The schedule
//  now stores AFTER this screen's Keystone-fork broadcast lands: `resubmitSignedNoteSplit` sends
//  `.splitBroadcastSucceeded` instead of reconciling directly, which sets `awaitingScheduleStore` and
//  asks the coordinator (`.delegate(.storeScheduleRequested)`) to run the deferred store — the
//  coordinator owns it because it alone holds the signed schedule entries. The coordinator reports
//  back via this screen's OWN `.splitConfirmed` (success — same as the legacy re-entry path) or the
//  new `.scheduleStoreFailed` (failure — reuses the EXISTING failure sheet); while
//  `awaitingScheduleStore` is `true`, `retryTapped` re-asks the coordinator instead of re-broadcasting
//  (the split already landed safely) or re-storing (nothing here to store — the coordinator holds it).
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationNoteSplit {
    @ObservableState
    struct State: Equatable {
        enum Phase: Equatable {
            case splitting
            case confirmed
        }

        var phase = Phase.splitting
        var amount = Zatoshi.zero
        var fee = Zatoshi.zero
        /// Shown from the splitting phase on.
        var txId = ""
        /// Failure sheet presented over the splitting phase.
        var isFailurePresented = false
        /// The prepared split proposal, held so `retryTapped` can re-submit without re-preparing.
        var proposal: NoteSplitProposal?
        var cancelStateStreamId = UUID()
        /// True when this screen is the coordinator's re-entry root — always `true` in practice,
        /// since forward routing never pushes `.noteSplit` any more (MOB-1478 W4). Its back control
        /// then closes the flow instead of popping.
        var isFlowRoot = false
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.toast)) var toast: Toast.Edge? = nil
        /// MOB-1468 (Keystone): set by the coordinator once a QR round-trip signs the note-split
        /// preparation PCZT(s). Non-`nil` forks `retryTapped` onto the Keystone lane
        /// (`storeSignedNoteSplits`/`broadcastStoredNoteSplit`) instead of the software
        /// `submitNoteSplit` re-preparation. Cleared once `.splitConfirmed` lands. MOB-1496 (final
        /// engine, plural preps): the whole preparation batch — `[MigrationSignedTransferPczt]`, zero-
        /// or-many, though this screen is only ever pushed with a non-empty one — not a single `Data`
        /// blob.
        var signedNoteSplitPczt: [MigrationSignedTransferPczt]?
        /// MOB-1496 (C-1 fix, final review R6): true once `signedNoteSplitPczt` is durably stored in
        /// the migration engine — `retryTapped`'s Keystone fork then only (re)broadcasts
        /// (`broadcastStoredNoteSplit`), never re-stores. The coordinator's batch-commit push
        /// (the only live caller today) always sets this `true` — its own store effect already
        /// called `storeSignedNoteSplits` before pushing this screen. `false` (the default) makes the
        /// fork self-sufficient for a hypothetical future caller that hands over an un-stored batch:
        /// its first `retryTapped` stores once, flips this via `.noteSplitStored`, then broadcasts;
        /// every later retry (after e.g. a broadcast-only failure) skips straight to broadcasting.
        /// Cleared once `.splitConfirmed` lands, alongside `signedNoteSplitPczt`.
        var splitStored = false
        /// MOB-1496 (C-1b fix, fix-wave 2): true once this screen's Keystone-fork broadcast has
        /// landed and the coordinator's deferred schedule store is in flight (or has failed and is
        /// awaiting a retry) — `retryTapped` then re-asks the coordinator
        /// (`.delegate(.storeScheduleRequested)`) instead of re-broadcasting the already-safe split
        /// or re-submitting the software proposal. Set by `.splitBroadcastSucceeded`; cleared by
        /// `.splitConfirmed` once the coordinator reports the store succeeded.
        var awaitingScheduleStore = false

        init(
            phase: Phase = .splitting,
            amount: Zatoshi = Zatoshi.zero,
            fee: Zatoshi = Zatoshi.zero,
            txId: String = "",
            isFailurePresented: Bool = false,
            isFlowRoot: Bool = false,
            signedNoteSplitPczt: [MigrationSignedTransferPczt]? = nil,
            splitStored: Bool = false,
            awaitingScheduleStore: Bool = false
        ) {
            self.phase = phase
            self.amount = amount
            self.fee = fee
            self.txId = txId
            self.isFailurePresented = isFailurePresented
            self.isFlowRoot = isFlowRoot
            self.signedNoteSplitPczt = signedNoteSplitPczt
            self.splitStored = splitStored
            self.awaitingScheduleStore = awaitingScheduleStore
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        /// Flow-root back control (splitting phase only): closes the flow instead of popping.
        case closeTapped
        /// Confirmed phase CTA: closes the flow (the commit already happened before the split
        /// started — there's nothing left to "continue" into).
        case continueTapped
        case copyTxIdTapped
        case delegate(Delegate)
        case onAppear
        /// Failure sheet: dismiss, then re-submit the stored proposal (or, on the Keystone fork,
        /// (re)store/broadcast the signed PCZT — see `signedNoteSplitPczt`/`splitStored`).
        case retryTapped
        /// MOB-1496 (C-1 fix, final review R6): the Keystone fork's `storeSignedNoteSplits` call
        /// succeeded — flips `state.splitStored` so a LATER retry (e.g. after a broadcast-only
        /// failure) skips straight to `broadcastStoredNoteSplit` instead of re-storing.
        case noteSplitStored
        /// MOB-1496 (C-1b fix, fix-wave 2): the Keystone fork's `broadcastStoredNoteSplit` call
        /// succeeded (including the landed-but-record-failed success-like case) — sets
        /// `state.awaitingScheduleStore` and asks the coordinator to run its deferred schedule store
        /// (`.delegate(.storeScheduleRequested)`); the coordinator alone holds the signed schedule
        /// entries. Never sent by the software fork (`submitNoteSplit`), which has no deferred store.
        case splitBroadcastSucceeded
        /// MOB-1496 (C-1b fix, fix-wave 2): the coordinator's deferred schedule store failed —
        /// re-presents the EXISTING failure sheet; `awaitingScheduleStore` stays `true` so the next
        /// `retryTapped` asks the coordinator again rather than re-broadcasting or re-storing here.
        case scheduleStoreFailed
        /// `migrationManager.stateEvents()` reported `.readyToPropose` while splitting — OR (MOB-1496
        /// C-1b fix, fix-wave 2) the coordinator's deferred schedule store just succeeded. Either way
        /// this is the durable "fully committed" signal: clears `awaitingScheduleStore` alongside the
        /// existing `signedNoteSplitPczt`/`splitStored` clearing.
        case splitConfirmed
        case splitResult(MigrationTransferResult)

        enum Delegate: Equatable {
            case continued
            /// MOB-1496 (C-1b fix, fix-wave 2): ask the coordinator to run its deferred
            /// `storeSignedMigrationTransactions` -> `recordCommittedSchedule` -> `reconcile()`
            /// sequence now — sent automatically once this screen's Keystone-fork broadcast lands
            /// (`.splitBroadcastSucceeded`), and again by `retryTapped` on every subsequent tap while
            /// `awaitingScheduleStore` is `true`.
            case storeScheduleRequested
        }
    }

    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.pasteboard) var pasteboard
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
                return .none

            case .closeTapped:
                return .send(.delegate(.continued))

            case .continueTapped:
                return .send(.delegate(.continued))

            case .copyTxIdTapped:
                pasteboard.setString(state.txId.redacted)
                state.$toast.withLock { $0 = .top(String(localizable: .generalCopiedToTheClipboard)) }
                return .none

            case .delegate:
                return .none

            case .onAppear:
                // MOB-1496 (C-1b fix, fix-wave 2): while `signedNoteSplitPczt` is set, this mount is
                // the Keystone mid-commit push, not a plain re-entry — its confirmation comes
                // EXCLUSIVELY from the coordinator's own deferred-store success signal
                // (`MigrationCoordFlowCoordinator.storeDeferredKeystoneSchedule` dispatching
                // `.splitConfirmed` once `storeSignedMigrationTransactions` actually succeeds), never
                // from this generic engine-state observation. Trusting `.readyToPropose` here too
                // would re-open the exact race Step 0 closed: if a deferred-store attempt fails and
                // the split independently mines before the user retries, the engine legitimately
                // (if unhelpfully) reports `.readyToPropose` via the denom-advance even though the
                // schedule was never stored — jumping to `.confirmed` from THIS read would let
                // Continue resume the chain over a schedule that is still genuinely unstored,
                // exactly the "context dropped while entries are unstored" outcome the retry
                // affordance exists to prevent.
                guard state.signedNoteSplitPczt == nil else {
                    return .none
                }
                let accountUUID = state.selectedWalletAccount?.id
                return .merge(
                    // Defensive: the split may have already reached `.readyToPropose` between the
                    // banner's `reentryRoute()` snapshot and this screen mounting — jump straight
                    // to `.confirmed` via a one-shot read rather than waiting on a stream event
                    // that already fired.
                    .run { send in
                        guard let accountUUID else { return }
                        if (try? await sdkSynchronizer.getMigrationState(accountUUID)) == MigrationState.readyToPropose {
                            await send(.splitConfirmed)
                        }
                    },
                    subscribeToMigrationState(accountUUID: accountUUID, cancelId: state.cancelStateStreamId)
                )

            case .retryTapped:
                state.isFailurePresented = false
                // MOB-1496 (C-1b fix, fix-wave 2): checked FIRST — a broadcast that already landed
                // is safe and must never be re-sent; only the coordinator's deferred schedule store
                // needs retrying (it alone holds the signed entries, so there is nothing to store
                // here).
                if state.awaitingScheduleStore {
                    return .send(.delegate(.storeScheduleRequested))
                }
                if let signedNoteSplitPczt = state.signedNoteSplitPczt {
                    return resubmitSignedNoteSplit(
                        signedNoteSplitPczt,
                        stored: state.splitStored,
                        account: state.selectedWalletAccount
                    )
                }
                return submitNoteSplit(state.proposal, account: state.selectedWalletAccount)

            case .noteSplitStored:
                state.splitStored = true
                return .none

            case .splitBroadcastSucceeded:
                state.awaitingScheduleStore = true
                return .send(.delegate(.storeScheduleRequested))

            case .scheduleStoreFailed:
                state.isFailurePresented = true
                return .none

            case .splitConfirmed:
                state.phase = .confirmed
                state.signedNoteSplitPczt = nil
                state.splitStored = false
                state.awaitingScheduleStore = false
                return .none

            case .splitResult(let result):
                switch result {
                case .success(let txId):
                    state.txId = txId
                    state.isFailurePresented = false
                case .networkError, .invalidNote, .expired:
                    state.isFailurePresented = true
                }
                return .none
            }
        }
    }

    private func submitNoteSplit(_ proposal: NoteSplitProposal?, account: WalletAccount?) -> Effect<Action> {
        guard let proposal else { return .none }

        guard let account, let zip32AccountIndex = account.zip32AccountIndex, account.vendor != WalletAccount.Vendor.keystone else {
            // Keystone accounts never reach here in practice — the coordinator's existing routing
            // keeps them on the PCZT lane (`resubmitSignedNoteSplit`) before this software path
            // would ever run; guarded defensively rather than deriving a USK for an account with
            // no locally-held seed phrase.
            return .run { send in
                await send(.splitResult(MigrationTransferResult.networkError(retryable: true)))
            }
        }

        return .run { send in
            // MOB-1496 (R8-T4, #3): see `MigrationSendingStore.executeNextTransfer`'s twin comment —
            // only a stop that was never followed by a successful broadcast needs the nudge.
            var didStopSyncForBroadcast = false
            do {
                let usk = try MigrationSpendingKeyDerivation.deriveUSK(
                    zip32AccountIndex: zip32AccountIndex,
                    walletStorage: walletStorage,
                    mnemonic: mnemonic,
                    derivationTool: derivationTool,
                    networkType: zcashSDKEnvironment.network().networkType
                )
                let options = await migrationManager.migrationNetworkOptions(account.id)
                await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
                didStopSyncForBroadcast = true
                let result = try await sdkSynchronizer.submitNoteSplit(account.id, proposal, usk, options)
                await send(.splitResult(result))
                if case MigrationTransferResult.success = result {
                    await migrationManager.reconcile()
                } else if didStopSyncForBroadcast {
                    await migrationManager.refreshMigrationSyncGate()
                }
            } catch ZcashError.migrationRecordFailedAfterBroadcast(_) {
                // [MOB-1496] The broadcast DID land; only recording failed (the engine self-heals
                // on a later read/attempt) — route to the success-like path rather than implying a
                // failure that didn't happen.
                await send(.splitResult(MigrationTransferResult.success(txId: "")))
                await migrationManager.reconcile()
            } catch {
                if didStopSyncForBroadcast {
                    await migrationManager.refreshMigrationSyncGate()
                }
                await send(.splitResult(MigrationTransferResult.networkError(retryable: true)))
            }
        }
    }

    /// MOB-1468 (Keystone) `retryTapped` fork: re-broadcasts Keystone-signed preparation (note-split)
    /// PCZTs instead of re-preparing/resubmitting the software proposal. MOB-1496 (C-1 fix, final
    /// review R6): store-aware — `stored` is `state.splitStored` at the point `retryTapped` fired.
    /// The coordinator's batch-commit push (the only live caller today) always arrives with
    /// `stored == true` (its own store effect already called `storeSignedNoteSplits`, which runs
    /// before the schedule store — see that effect's doc for why), so every attempt here is
    /// `broadcastStoredNoteSplit` only, which is idempotent by construction (a retry just re-asks the
    /// engine what's next-due, never re-stores) — unlike the old `submitSignedNoteSplit` composite
    /// this replaces, whose retry re-ran the by-then-already-consumed store and threw forever. Kept
    /// general — store once via `storeSignedNoteSplits` THEN broadcast when `stored` is `false`,
    /// flipping `state.splitStored` via `.noteSplitStored` so a LATER retry (e.g. after a
    /// broadcast-only failure) never re-stores — so this lane is self-sufficient for a hypothetical
    /// future caller that hands over an un-stored batch. MOB-1496 (final engine, plural preps):
    /// `signed` is the whole preparation batch now — `[MigrationSignedTransferPczt]` — not a single
    /// `Data` blob, since the final engine builds N preparation transactions.
    ///
    /// MOB-1496 (C-1b fix, fix-wave 2): a successful broadcast (including the landed-but-
    /// record-failed success-like case) sends `.splitBroadcastSucceeded` instead of reconciling
    /// directly — the coordinator owns the schedule store this commit deferred (it alone holds the
    /// signed entries) and runs its OWN `reconcile()` once that store settles; reconciling here too
    /// would be premature (the run's phase hasn't reached `BroadcastScheduled` yet at this point) and
    /// is no longer this lane's responsibility.
    private func resubmitSignedNoteSplit(_ signed: [MigrationSignedTransferPczt], stored: Bool, account: WalletAccount?) -> Effect<Action> {
        guard let account else {
            return .run { send in await send(.splitResult(MigrationTransferResult.networkError(retryable: true))) }
        }

        return .run { send in
            let options = await migrationManager.migrationNetworkOptions(account.id)
            // MOB-1496 (R8-T4, #3): see `MigrationSendingStore.executeNextTransfer`'s twin comment —
            // only a stop that was never followed by a successful broadcast needs the nudge.
            var didStopSyncForBroadcast = false
            do {
                if !stored {
                    try await sdkSynchronizer.storeSignedNoteSplits(account.id, signed)
                    await send(.noteSplitStored)
                }
                await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
                didStopSyncForBroadcast = true
                let result = try await sdkSynchronizer.broadcastStoredNoteSplit(account.id, options)
                await send(.splitResult(result))
                if case MigrationTransferResult.success = result {
                    await send(.splitBroadcastSucceeded)
                } else if didStopSyncForBroadcast {
                    await migrationManager.refreshMigrationSyncGate()
                }
            } catch ZcashError.migrationRecordFailedAfterBroadcast(_) {
                await send(.splitResult(MigrationTransferResult.success(txId: "")))
                await send(.splitBroadcastSucceeded)
            } catch {
                if didStopSyncForBroadcast {
                    await migrationManager.refreshMigrationSyncGate()
                }
                await send(.splitResult(MigrationTransferResult.networkError(retryable: true)))
            }
        }
    }

    private func subscribeToMigrationState(accountUUID: AccountUUID?, cancelId: UUID) -> Effect<Action> {
        .publisher {
            migrationManager.stateEvents(accountUUID)
                .compactMap { state -> Action? in
                    state == MigrationState.readyToPropose ? Action.splitConfirmed : nil
                }
        }
        .cancellable(id: cancelId, cancelInFlight: true)
    }
}
