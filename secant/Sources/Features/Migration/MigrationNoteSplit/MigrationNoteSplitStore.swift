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
//  `migrationStateStream()` to advance `.splitting` -> `.confirmed` once the SDK reports
//  `.readyToPropose` (or jumps straight there if that already happened before this screen mounted);
//  `confirmed`'s `continueTapped` closes the flow (the schedule/transfer was already committed before
//  the split even started — the home banner carries the progression from here). `retryTapped`/
//  `splitResult`/the failure sheet are kept for when a split needs re-attempting from this screen,
//  though with today's synchronous stubs nothing drives them live yet (real-SDK latency is out of
//  scope for MOB-1478, tracked for the #2572 integration).
//
//  MOB-1468 (Keystone): once split signing folded into `MigrationTransferPlan`'s batch (MOB-1478 W4),
//  this screen no longer requests Keystone signing itself, and no coordinator path sets
//  `signedNoteSplitPczt` any more either (that lived solely in the now-deleted `.noteSplit` Keystone
//  signing context). `retryTapped`'s fork on it is kept dormant rather than deleted — same reasoning
//  as the failure sheet above — so a future re-entry-time Keystone resume has somewhere to plug in;
//  `nil` (the only value reachable today) keeps the existing software retry.
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
        /// PCZT. Non-`nil` forks `retryTapped` to re-broadcast this SAME signed PCZT via
        /// `submitSignedNoteSplit` instead of re-preparing. Cleared once `.splitConfirmed` lands.
        var signedNoteSplitPczt: Data?

        init(
            phase: Phase = .splitting,
            amount: Zatoshi = Zatoshi.zero,
            fee: Zatoshi = Zatoshi.zero,
            txId: String = "",
            isFailurePresented: Bool = false,
            isFlowRoot: Bool = false,
            signedNoteSplitPczt: Data? = nil
        ) {
            self.phase = phase
            self.amount = amount
            self.fee = fee
            self.txId = txId
            self.isFailurePresented = isFailurePresented
            self.isFlowRoot = isFlowRoot
            self.signedNoteSplitPczt = signedNoteSplitPczt
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
        /// Failure sheet: dismiss, then re-submit the stored proposal.
        case retryTapped
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
                    return resubmitSignedNoteSplit(signedNoteSplitPczt, account: state.selectedWalletAccount)
                }
                return submitNoteSplit(state.proposal, account: state.selectedWalletAccount)

            case .splitConfirmed:
                state.phase = .confirmed
                state.signedNoteSplitPczt = nil
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

    /// MOB-1468 (Keystone) `retryTapped` fork: re-broadcasts the SAME already-signed PCZT — never a
    /// new signing round.
    private func resubmitSignedNoteSplit(_ pczt: Data, account: WalletAccount?) -> Effect<Action> {
        guard let account else {
            return .run { send in await send(.splitResult(MigrationTransferResult.networkError(retryable: true))) }
        }

        return .run { send in
            let options = await migrationManager.migrationNetworkOptions(account.id)
            do {
                await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
                let result = try await sdkSynchronizer.submitSignedNoteSplit(account.id, pczt, options)
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
