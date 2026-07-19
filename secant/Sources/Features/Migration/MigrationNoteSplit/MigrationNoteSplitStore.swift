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
//  pushes this screen mid-Keystone-commit to broadcast a just-signed split, dispatching `.retryTapped`
//  itself as the first attempt. MOB-1496 (C-1 fix, final review R6): that push now also sets
//  `splitStored: true` (the coordinator's own store effect already called `storeSignedNoteSplit`
//  before pushing this screen — see that effect's doc for why the store must run there, not here), so
//  `retryTapped`'s Keystone fork only ever (re)broadcasts for this, the only live caller today. The
//  fork's store-then-broadcast fallback (`splitStored == false`) is kept dormant rather than deleted —
//  same reasoning as the failure sheet above — so a future caller that hands over an un-stored PCZT
//  has somewhere to plug in.
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
        /// PCZT. Non-`nil` forks `retryTapped` onto the Keystone lane (`storeSignedNoteSplit`/
        /// `broadcastStoredNoteSplit`) instead of the software `submitNoteSplit` re-preparation.
        /// Cleared once `.splitConfirmed` lands.
        var signedNoteSplitPczt: Data?
        /// MOB-1496 (C-1 fix, final review R6): true once `signedNoteSplitPczt` is durably stored in
        /// the migration engine — `retryTapped`'s Keystone fork then only (re)broadcasts
        /// (`broadcastStoredNoteSplit`), never re-stores. The coordinator's batch-commit push
        /// (the only live caller today) always sets this `true` — its own store effect already
        /// called `storeSignedNoteSplit` before pushing this screen. `false` (the default) makes the
        /// fork self-sufficient for a hypothetical future caller that hands over an un-stored PCZT:
        /// its first `retryTapped` stores once, flips this via `.noteSplitStored`, then broadcasts;
        /// every later retry (after e.g. a broadcast-only failure) skips straight to broadcasting.
        /// Cleared once `.splitConfirmed` lands, alongside `signedNoteSplitPczt`.
        var splitStored = false

        init(
            phase: Phase = .splitting,
            amount: Zatoshi = Zatoshi.zero,
            fee: Zatoshi = Zatoshi.zero,
            txId: String = "",
            isFailurePresented: Bool = false,
            isFlowRoot: Bool = false,
            signedNoteSplitPczt: Data? = nil,
            splitStored: Bool = false
        ) {
            self.phase = phase
            self.amount = amount
            self.fee = fee
            self.txId = txId
            self.isFailurePresented = isFailurePresented
            self.isFlowRoot = isFlowRoot
            self.signedNoteSplitPczt = signedNoteSplitPczt
            self.splitStored = splitStored
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
        /// MOB-1496 (C-1 fix, final review R6): the Keystone fork's `storeSignedNoteSplit` call
        /// succeeded — flips `state.splitStored` so a LATER retry (e.g. after a broadcast-only
        /// failure) skips straight to `broadcastStoredNoteSplit` instead of re-storing.
        case noteSplitStored
        /// `migrationManager.stateEvents()` reported `.readyToPropose` while splitting.
        case splitConfirmed
        case splitResult(MigrationTransferResult)

        enum Delegate: Equatable {
            case continued
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

            case .splitConfirmed:
                state.phase = .confirmed
                state.signedNoteSplitPczt = nil
                state.splitStored = false
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
                let result = try await sdkSynchronizer.submitNoteSplit(account.id, proposal, usk, options)
                await send(.splitResult(result))
                if case MigrationTransferResult.success = result {
                    await migrationManager.reconcile()
                }
            } catch ZcashError.migrationRecordFailedAfterBroadcast(_) {
                // [MOB-1496] The broadcast DID land; only recording failed (the engine self-heals
                // on a later read/attempt) — route to the success-like path rather than implying a
                // failure that didn't happen.
                await send(.splitResult(MigrationTransferResult.success(txId: "")))
                await migrationManager.reconcile()
            } catch {
                await send(.splitResult(MigrationTransferResult.networkError(retryable: true)))
            }
        }
    }

    /// MOB-1468 (Keystone) `retryTapped` fork: re-broadcasts a Keystone-signed split PCZT instead of
    /// re-preparing/resubmitting the software proposal. MOB-1496 (C-1 fix, final review R6):
    /// store-aware — `stored` is `state.splitStored` at the point `retryTapped` fired. The
    /// coordinator's batch-commit push (the only live caller today) always arrives with
    /// `stored == true` (its own store effect already called `storeSignedNoteSplit`, which MUST run
    /// before the schedule store — see that effect's doc for why), so every attempt here is
    /// `broadcastStoredNoteSplit` only, which is idempotent by construction (a retry just re-asks the
    /// engine what's next-due, never re-stores) — unlike the old `submitSignedNoteSplit` composite
    /// this replaces, whose retry re-ran the by-then-already-consumed store and threw forever. Kept
    /// general — store once via `storeSignedNoteSplit` THEN broadcast when `stored` is `false`,
    /// flipping `state.splitStored` via `.noteSplitStored` so a LATER retry (e.g. after a
    /// broadcast-only failure) never re-stores — so this lane is self-sufficient for a hypothetical
    /// future caller that hands over an un-stored PCZT.
    private func resubmitSignedNoteSplit(_ pczt: Data, stored: Bool, account: WalletAccount?) -> Effect<Action> {
        guard let account else {
            return .run { send in await send(.splitResult(MigrationTransferResult.networkError(retryable: true))) }
        }

        return .run { send in
            let options = await migrationManager.migrationNetworkOptions(account.id)
            do {
                if !stored {
                    try await sdkSynchronizer.storeSignedNoteSplit(account.id, pczt)
                    await send(.noteSplitStored)
                }
                await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
                let result = try await sdkSynchronizer.broadcastStoredNoteSplit(account.id, options)
                await send(.splitResult(result))
                if case MigrationTransferResult.success = result {
                    await migrationManager.reconcile()
                }
            } catch ZcashError.migrationRecordFailedAfterBroadcast(_) {
                await send(.splitResult(MigrationTransferResult.success(txId: "")))
                await migrationManager.reconcile()
            } catch {
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
