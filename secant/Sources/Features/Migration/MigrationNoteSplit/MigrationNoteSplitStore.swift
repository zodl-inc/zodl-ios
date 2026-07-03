//
//  MigrationNoteSplitStore.swift
//  zodl
//
//  "Split Your Wallet Funds" screen (MOB-1461, Figma S2 · 2867:10535 explainer / 2867:10741
//  progress / 2867:10645 success / 2670:15570 failure sheet). One screen, three phases (explainer
//  -> splitting -> confirmed) plus a failure bottom sheet presented over the splitting phase.
//  `onAppear` resumes an already-pending split or prepares a fresh one; `confirmTapped`/`retryTapped`
//  submit it; a `migrationStateStream()` subscription advances `.splitting` -> `.confirmed` once the
//  SDK reports `.readyToPropose`. When the splitting phase is a flow re-entry root (`isFlowRoot`),
//  its back control closes the flow (`closeTapped` -> `.delegate(.continued)`) instead of popping
//  (MOB-1466). The `.continued` delegate is consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1468 (Keystone): a Keystone-vendor account forks `confirmTapped` — instead of submitting a
//  proposal locally, it proposes the note-split PCZT (`proposeNoteSplitPCZT()`) and delegates
//  `.keystoneSignRequested([pczt])` for the coordinator to route through `MigrationKeystoneSign` +
//  `Scan`. The software (`.zcash`) path is unchanged. Once the coordinator completes the QR
//  round-trip it mutates this element in place into `.splitting` phase with `signedNoteSplitPczt`
//  set — `retryTapped` then forks too: a signed PCZT present means re-broadcast the SAME PCZT via
//  `submitSignedNoteSplit` (never a new signing round); `nil` keeps the existing software retry.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationNoteSplit {
    @ObservableState
    struct State: Equatable {
        enum Phase: Equatable {
            case explainer
            case splitting
            case confirmed
        }

        var phase = Phase.explainer
        var amount = Zatoshi.zero
        var fee = Zatoshi.zero
        /// Shown from the splitting phase on.
        var txId = ""
        /// Failure sheet presented over the splitting phase.
        var isFailurePresented = false
        /// The prepared split proposal, held so `retryTapped` can re-submit without re-preparing.
        var proposal: NoteSplitProposal?
        var cancelStateStreamId = UUID()
        /// True when the splitting phase is the coordinator's re-entry root — its back control then
        /// closes the flow instead of popping.
        var isFlowRoot = false
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.toast)) var toast: Toast.Edge? = nil
        /// MOB-1468 (Keystone): set by the coordinator once the QR round-trip signs the note-split
        /// PCZT, alongside mutating `phase` to `.splitting`. Non-`nil` forks `retryTapped` to
        /// re-broadcast this SAME signed PCZT via `submitSignedNoteSplit` instead of re-preparing.
        /// Cleared once `.splitConfirmed` lands.
        var signedNoteSplitPczt: Pczt?

        init(
            phase: Phase = .explainer,
            amount: Zatoshi = Zatoshi.zero,
            fee: Zatoshi = Zatoshi.zero,
            txId: String = "",
            isFailurePresented: Bool = false,
            isFlowRoot: Bool = false,
            signedNoteSplitPczt: Pczt? = nil
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
        /// Explainer CTA — submits the prepared split.
        case confirmTapped
        /// Confirmed CTA.
        case continueTapped
        case copyTxIdTapped
        case delegate(Delegate)
        /// `prepareNoteSplit()` result — populates amount/fee and stores the proposal for submission.
        case noteSplitPrepared(NoteSplitProposal)
        case onAppear
        /// Failure sheet: dismiss, then re-submit the stored proposal.
        case retryTapped
        /// `migrationStateStream()` reported `.readyToPropose` while splitting.
        case splitConfirmed
        case splitResult(TransferResult)

        enum Delegate: Equatable {
            case continued
            /// MOB-1468 (Keystone): the note-split PCZT was proposed and needs QR signing — a
            /// single-element array (batched-session-of-1), the shared shape across all three
            /// Keystone signing sources so the coordinator can treat them symmetrically.
            case keystoneSignRequested([Pczt])
        }
    }

    @Dependency(\.pasteboard) var pasteboard
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

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

            case .confirmTapped:
                guard state.selectedWalletAccount?.vendor == .keystone else {
                    state.phase = .splitting
                    return submitNoteSplit(state.proposal)
                }
                return requestKeystoneNoteSplitSignature()

            case .continueTapped:
                return .send(.delegate(.continued))

            case .copyTxIdTapped:
                pasteboard.setString(state.txId.redacted)
                state.$toast.withLock { $0 = .top(String(localizable: .generalCopiedToTheClipboard)) }
                return .none

            case .delegate:
                return .none

            case .noteSplitPrepared(let proposal):
                state.proposal = proposal
                state.amount = Zatoshi(proposal.outputNotes.reduce(0) { $0 + $1.amount })
                state.fee = proposal.fee
                return .none

            case .onAppear:
                let isPendingConfirmation = sdkSynchronizer.getMigrationState() == .splitPendingConfirmation
                if isPendingConfirmation {
                    state.phase = .splitting
                }

                return .merge(
                    subscribeToMigrationState(cancelId: state.cancelStateStreamId),
                    isPendingConfirmation ? .none : prepareNoteSplit()
                )

            case .retryTapped:
                state.isFailurePresented = false
                if let signedNoteSplitPczt = state.signedNoteSplitPczt {
                    return resubmitSignedNoteSplit(signedNoteSplitPczt)
                }
                return submitNoteSplit(state.proposal)

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

    private func prepareNoteSplit() -> Effect<Action> {
        .run { send in
            let proposal = await sdkSynchronizer.prepareNoteSplit()
            await send(.noteSplitPrepared(proposal))
        }
    }

    private func submitNoteSplit(_ proposal: NoteSplitProposal?) -> Effect<Action> {
        guard let proposal else { return .none }

        return .run { send in
            let result = await sdkSynchronizer.submitNoteSplit(proposal)
            await send(.splitResult(result))
        }
    }

    /// MOB-1468 (Keystone) `confirmTapped` fork: proposes the note-split PCZT and hands it to the
    /// coordinator for QR signing. Does not touch `phase` — the coordinator flips it to `.splitting`
    /// once the signed PCZT comes back from the scan.
    private func requestKeystoneNoteSplitSignature() -> Effect<Action> {
        .run { send in
            let pczt = await sdkSynchronizer.proposeNoteSplitPCZT()
            await send(.delegate(.keystoneSignRequested([pczt])))
        }
    }

    /// MOB-1468 (Keystone) `retryTapped` fork: re-broadcasts the SAME already-signed PCZT — never a
    /// new signing round.
    private func resubmitSignedNoteSplit(_ pczt: Pczt) -> Effect<Action> {
        .run { send in
            let result = await sdkSynchronizer.submitSignedNoteSplit(pczt)
            await send(.splitResult(result))
        }
    }

    private func subscribeToMigrationState(cancelId: UUID) -> Effect<Action> {
        .publisher {
            sdkSynchronizer.migrationStateStream()
                .compactMap { state -> Action? in
                    state == .readyToPropose ? Action.splitConfirmed : nil
                }
        }
        .cancellable(id: cancelId, cancelInFlight: true)
    }
}
