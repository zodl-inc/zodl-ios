//
//  MigrationReviewTransferStore.swift
//  zodl
//
//  "Review Transfer" screen (MOB-1463, Figma S7 · immediate 2867:5924 / manual "3 of 5" 2729:8544,
//  equivalent to frame 2712:7779 which fails to render via MCP). Final confirmation before a
//  migration transfer is sent — either the single immediate sweep, or one step of a scheduled plan.
//  Manual step has its data injected by the coordinator (no propose) and confirm delegates directly —
//  the transfer was already signed at plan commit. When the manual-step variant is a flow re-entry
//  root (`isFlowRoot`), its back control closes the flow via a `.closed` delegate instead of popping —
//  reusing `.confirmed` for a back-tap would incorrectly signal the transfer was confirmed (MOB-1466).
//  Both delegates are consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1513 (Lane A2 — send-max immediate migration): immediate mode used to propose+display an
//  ENGINE-HELD, single-transfer `MigrationSchedule` (`proposeImmediateMigration() ->
//  MigrationSchedule`), sign+store it HERE via `signAndStoreMigrationSchedule` before delegating, and
//  broadcast it LATER, on the Sending screen, via `executeNextPendingMigrationTransfer` — despite the
//  screen's own historical doc already claiming "single-transfer engine semantics", that schedule was
//  in fact just an engine-internal implementation detail with its own plan-cache/run bookkeeping. That
//  claim is genuinely true now, via the real SDK's send-max surface:
//  `proposeImmediateMigration(accountUUID:)` returns an ORDINARY, engine-external
//  `ImmediateMigrationProposal` — a send-max transaction that, by construction, is always exactly one
//  transaction (`Proposal.transactionCount() == 1`), with no engine plan cache behind it to go stale.
//  `onAppear` proposes it ONCE (cache guard: a re-appearance with an already-populated
//  `immediateProposal` never re-proposes — mirrors `MigrationTransferPlanStore`'s injected-schedule/
//  hydrated-rows guard) and displays its `amount`/`fee` directly (no more hardcoded standard-fee
//  placeholder or `transfers.first?.amount` read — the proposal's own fields are the real, deterministic
//  values). `confirmTapped`'s SOFTWARE branch has no local commit step left at all: there is nothing to
//  sign+store ahead of a broadcast that only ever happens once, when the actual USK-signing submit
//  runs — it just delegates `.confirmed`, and the coordinator threads `immediateProposal` into the
//  pushed `MigrationSending.State`, whose `onAppear` now performs the genuine create+sign+submit for
//  this lane (see that store's doc). An explicit Retry (after a propose failure) may still re-propose;
//  a commit failure's Retry re-attempts with the SAME already-fetched proposal (no re-propose needed —
//  there is no plan-cache staleness to worry about).
//
//  MOB-1468 (Keystone): a Keystone-vendor account in immediate mode forks `confirmTapped` — instead of
//  falling through to the plain `.confirmed` delegate above, it proposes the `ImmediateMigrationProposal`'s
//  single PCZT via `createPCZTFromProposal(accountUUID:proposal:)` (MOB-1513: the SAME ordinary-send
//  PCZT builder used elsewhere, not the engine's schedule-based `proposeMigrationPCZTs` this fork used
//  to call) wrapped as a one-element Keystone signing batch, and delegates
//  `.keystoneSignRequested([pczt])` for the coordinator to route through `MigrationKeystoneSign` +
//  `Scan`. The coordinator's own dedicated post-signing step
//  (`MigrationCoordFlowCoordinator.submitImmediateKeystoneTransaction`) adds proofs and submits once the
//  signature comes back — see that function's doc for why the Keystone lane's actual broadcast can't
//  defer to the Sending screen the way the software lane's does. The manual-step path (transfers
//  already signed at plan commit) is unchanged — no PCZT is ever proposed there.
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

        /// Distinguishes what `isFailurePresented`'s sheet is showing, so `retryTapped` re-attempts
        /// the right thing and the view picks the right copy. `nil` while no failure sheet is
        /// presented.
        enum FailureReason: Equatable {
            /// `onAppear`'s `ImmediateMigrationProposal` propose threw — Retry re-proposes via
            /// `proposeImmediateMigration`.
            case propose
            /// The commit itself failed (software submit, or the Keystone PCZT-proposal fork) —
            /// Retry re-attempts the whole commit.
            case commit
        }

        var mode = Mode.immediate
        var amount = Zatoshi.zero
        var fee = Zatoshi.zero
        /// MOB-1513: immediate mode's send-max proposal, fetched on `onAppear` and displayed as
        /// `amount`/`fee` — the actual create+sign+submit happens later, on the Sending screen
        /// (software) or in the coordinator's post-Keystone-signing step, both of which need this
        /// same proposal threaded through. `nil` in manual-step mode (nothing to propose here), and
        /// in immediate mode until a proposal succeeds — also the `onAppear` cache guard: non-`nil`
        /// means "already proposed, don't propose again."
        var immediateProposal: ImmediateMigrationProposal?
        /// True when the manual-step variant is the coordinator's re-entry root — its back control
        /// then closes the flow instead of popping.
        var isFlowRoot = false
        /// Failure sheet, presented instead of proceeding. Covers a propose failure (immediate mode
        /// only) and a commit failure (software submit, or the Keystone PCZT-proposal fork).
        var isFailurePresented = false
        /// Which kind of failure `isFailurePresented` is showing; see `FailureReason`.
        var failureReason: FailureReason?

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
        /// MOB-1513: immediate mode delegates `.confirmed` directly — the actual create+sign+submit
        /// happens on the Sending screen (software) or was already handled by the coordinator's
        /// post-Keystone-signing step before this action even fires (Keystone). Manual step also
        /// delegates directly (transfer already signed at plan commit).
        case confirmTapped
        case delegate(Delegate)
        /// The commit failed — presents the failure sheet instead of proceeding. Covers any
        /// software commit failure and the Keystone PCZT-proposal fork's failures.
        case noteSplitFailed
        /// Immediate mode only: proposes the send-max proposal for Amount/Fee display.
        case onAppear
        /// Failure sheet: dismiss, then re-attempt the failed step from scratch — the whole commit
        /// sequence when `failureReason == .commit` (or unset), or a fresh proposal when
        /// `failureReason == .propose`.
        case retryTapped
        /// MOB-1513: `proposeImmediateMigration()` threw — presents the failure sheet;
        /// `immediateProposal` is left untouched (never a silent placeholder fallback).
        case transferProposalFailed
        /// MOB-1513: `proposeImmediateMigration()` result (immediate mode only).
        case transferProposed(ImmediateMigrationProposal)

        enum Delegate: Equatable {
            case closed
            case confirmed
            /// MOB-1468 (Keystone): the immediate-mode proposal's PCZT was proposed and needs QR
            /// signing — a single-element array, the shared shape across the Keystone signing
            /// sources so the coordinator can treat them symmetrically.
            case keystoneSignRequested([MigrationUnsignedTransferPczt])
        }
    }

    /// MOB-1513: the sentinel id the immediate lane's single Keystone-signing PCZT rides under — it
    /// carries no engine-issued id (unlike the schedule/prep PCZTs `proposeKeystoneBatch` builds),
    /// since `createPCZTFromProposal` is the ordinary-send PCZT builder, not an engine call. Never
    /// looked up by id anywhere downstream — the coordinator's post-signing step reads the batch's
    /// single entry positionally (`.first`), matching the batch's guaranteed one-element shape.
    static let immediateKeystonePcztId = "immediate"

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
                state.failureReason = nil
                return .none

            case .closeTapped:
                return .send(.delegate(.closed))

            case .confirmTapped, .retryTapped:
                state.isFailurePresented = false

                // MOB-1513: a propose failure's Retry re-proposes instead of re-attempting the
                // commit — checked FIRST, before any of the commit guards below.
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

                // MOB-1513: never delegate for a proposal that doesn't exist yet (propose still in
                // flight, or failed) — deliberately a SEPARATE guard from the mode check above, so a
                // nil proposal in immediate mode returns `.none` (stay put) rather than falling into
                // the manual step's "already signed, just acknowledge" delegate.
                guard let proposal = state.immediateProposal else {
                    return .none
                }
                guard let account = state.selectedWalletAccount else { return .none }

                guard account.vendor != WalletAccount.Vendor.keystone else {
                    return requestKeystoneSignature(for: proposal, account: account)
                }

                // MOB-1513: nothing left to pre-commit locally for the software lane — the actual
                // create+sign+submit happens on the Sending screen, which the coordinator threads
                // `immediateProposal` into.
                return .send(.delegate(.confirmed))

            case .delegate:
                return .none

            case .noteSplitFailed:
                state.isFailurePresented = true
                state.failureReason = State.FailureReason.commit
                return .none

            case .onAppear:
                guard case .immediate = state.mode else { return .none }
                // MOB-1513: cache guard — an already-populated proposal (a re-appearance, e.g. after
                // backgrounding) is never re-proposed. MOB-1513 (E2-FIX): the entry propose is the
                // bounded, quiet retry (`proposeWithRetryEffect`); an explicit Retry stays the
                // single-attempt `proposeEffect`.
                guard state.immediateProposal == nil else { return .none }
                return proposeWithRetryEffect(accountUUID: state.selectedWalletAccount?.id)

            case .transferProposalFailed:
                state.isFailurePresented = true
                state.failureReason = State.FailureReason.propose
                return .none

            case .transferProposed(let proposal):
                state.immediateProposal = proposal
                state.amount = proposal.amount
                state.fee = proposal.fee
                return .none
            }
        }
    }

    /// MOB-1468 (Keystone) `confirmTapped` fork: proposes the immediate proposal's single PCZT via
    /// `createPCZTFromProposal` (MOB-1513: the ordinary-send PCZT builder — the proposal is
    /// engine-external, so there is no schedule for the engine's `proposeMigrationPCZTs`/
    /// `proposeNoteSplitPCZTs` machinery to build a batch from; a send-max sweep also never needs a
    /// note split of its own) and hands the resulting one-element batch to the coordinator for QR
    /// signing.
    private func requestKeystoneSignature(for proposal: ImmediateMigrationProposal, account: WalletAccount) -> Effect<Action> {
        .run { send in
            do {
                let pczt = try await sdkSynchronizer.createPCZTFromProposal(account.id, proposal.proposal)
                await send(.delegate(.keystoneSignRequested([MigrationUnsignedTransferPczt(id: Self.immediateKeystonePcztId, pczt: pczt)])))
            } catch {
                await send(.noteSplitFailed)
            }
        }
    }

    /// MOB-1513: proposes a fresh `ImmediateMigrationProposal` via `proposeImmediateMigration` —
    /// `retryTapped`'s SINGLE-attempt re-proposal after a propose failure (an explicit user tap, not
    /// a flow entry). Throws through to `.transferProposalFailed` instead of silently falling back to
    /// a placeholder proposal. `onAppear`'s entry propose uses `proposeWithRetryEffect` instead.
    private func proposeEffect(accountUUID: AccountUUID?) -> Effect<Action> {
        guard let accountUUID else { return .none }

        return .run { send in
            do {
                let proposal = try await sdkSynchronizer.proposeImmediateMigration(accountUUID)
                await send(.transferProposed(proposal))
            } catch {
                await send(.transferProposalFailed)
            }
        }
    }

    /// MOB-1513 (E2-FIX): the bounded, quiet propose used at FLOW ENTRY (`onAppear`). Right after a
    /// restore there is a short window (~30 s, mostly hidden by the SDK's balance hold) where the
    /// migration banner can appear while the wallet's notes are not yet witnessable — the send-max
    /// builder then finds no spendable Orchard notes and `proposeImmediateMigration` throws
    /// `ZcashError.rustProposeSendMaxTransfer`. On that ONE outcome this keeps the screen in its
    /// existing loading state and re-proposes every `proposeRetryInterval`, for up to
    /// `proposeRetryMaxRetries` re-attempts (~60 s from the first). The first success proceeds
    /// normally (`.transferProposed`); EVERY OTHER error surfaces immediately through the existing
    /// `.transferProposalFailed` path (unchanged), and an exhausted window surfaces that SAME propose-
    /// failure sheet — the retry only DEFERS today's error path, it never replaces or hides it.
    ///
    /// Single-flight + dismiss-cancellable via `CancelID.proposeRetry` (`cancelInFlight` restarts the
    /// window on a re-appearance; TCA cancels the loop when the screen is popped). `try await
    /// clock.sleep` (not `try?`) so a cancellation exits the loop promptly instead of spinning.
    private func proposeWithRetryEffect(accountUUID: AccountUUID?) -> Effect<Action> {
        guard let accountUUID else { return .none }

        return .run { send in
            for retry in 0...Constants.proposeRetryMaxRetries {
                do {
                    let proposal = try await sdkSynchronizer.proposeImmediateMigration(accountUUID)
                    await send(.transferProposed(proposal))
                    return
                } catch {
                    guard Self.isWalletNotReadyYet(error) else {
                        await send(.transferProposalFailed)
                        return
                    }
                }
                guard retry < Constants.proposeRetryMaxRetries else { break }
                try await clock.sleep(for: Constants.proposeRetryInterval)
            }
            await send(.transferProposalFailed)
        }
        .cancellable(id: CancelID.proposeRetry, cancelInFlight: true)
    }

    /// MOB-1513 (E2-FIX): the ONLY propose outcome the bounded entry retry treats as "the wallet's
    /// notes aren't witnessable yet." `proposeImmediateMigration` builds an ordinary send-max, so a
    /// no-spendable-notes result is a `ZcashError.rustProposeSendMaxTransfer` throw (the engine's own
    /// transient "not witnessable yet" state surfaces as this nothing-to-select build failure, NOT as
    /// the hard `migrationProvingUnavailable`, which by SDK contract means proving failed hard).
    /// Deliberately keyed on the typed ZcashError CASE, never a message substring — every other error
    /// (address lookup, proposal decode, ...) is a genuine failure that surfaces immediately.
    static func isWalletNotReadyYet(_ error: Error) -> Bool {
        guard let zcashError = error as? ZcashError else { return false }
        if case .rustProposeSendMaxTransfer = zcashError {
            return true
        }
        return false
    }
}
