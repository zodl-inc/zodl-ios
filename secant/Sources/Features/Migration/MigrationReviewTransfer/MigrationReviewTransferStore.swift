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
//  broadcast it LATER, on the Sending screen, via `performMigrationBroadcast` — despite the
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
//  to call), redacts it for the signer, and delegates `.keystoneImmediateSignRequested(unsigned:redacted:)`
//  for the coordinator to route through the PRODUCTION single-PCZT ceremony (`MigrationKeystoneSign`
//  in single-PCZT mode + `Scan` with the production checker) — MOB-1513 (R8): NOT the migration
//  batch bridge this fork briefly rode, which is scheduled-lane machinery (its apply FFI
//  numeric-parses engine ids this engine-external PCZT doesn't have; Android's immediate lane is
//  single-PCZT for the same reason). The coordinator's own dedicated post-signing step
//  (`MigrationCoordFlowCoordinator.submitImmediateKeystoneTransaction`) adds proofs and submits once the
//  signature comes back — see that function's doc for why the Keystone lane's actual broadcast can't
//  defer to the Sending screen the way the software lane's does. The manual-step path (transfers
//  already signed at plan commit) is unchanged — no PCZT is ever proposed there.
//
//  MOB-1458: `confirmTapped`/`retryTapped`'s entire commit body — the manual-step delegate, the
//  immediate software delegate, and the immediate Keystone PCZT propose+redact — now runs only
//  after a device-authentication (Face ID / Touch ID / passcode) prompt succeeds
//  (`localAuthentication.authenticate()`, via the shared `LocalAuthenticationClient.gated` helper).
//  `isConfirming` flips `true` BEFORE the prompt runs (not after), so the existing Confirm-button
//  spinner covers the authentication sheet too, and a double-tap while it's up hits the
//  single-flight guard instead of opening a second prompt; a refused/cancelled prompt
//  (`.authenticationCancelled`) clears the flag again and — F5 — re-presents the failure sheet if
//  one was showing before the tap, since nothing was signed or broadcast and the sheet is the only
//  surface for a commit failure's message. The propose-failure Retry short-circuit is the one
//  exception — it never authenticates, since re-fetching a proposal for display neither signs nor
//  broadcasts anything.
//
//  MOB-1458 (round 2 — regression fix): what a tap commits to (`State.ConfirmIntent`) is decided
//  SYNCHRONOUSLY in `confirmTapped`/`retryTapped`, BEFORE the authentication prompt opens, and
//  carried as the `confirmAuthenticated` action's payload from there on — `.confirmAuthenticated`
//  switches on the intent it was handed and never re-reads `immediateProposal`/
//  `selectedWalletAccount` from state. A first version of this gate decided what to commit AFTER
//  the prompt returned, re-reading those two fields from state inside `.confirmAuthenticated` — the
//  SAME guards this file always had, just moved to the far side of an `await`. That looks
//  equivalent and is not: `onAppear`'s bounded propose-retry loop (~60 s, covering the post-restore
//  not-yet-witnessable window) keeps running underneath an open authentication prompt — nothing
//  cancels it on `confirmTapped` — so a proposal can land WHILE THE PROMPT IS UP. A tap that opened
//  on an empty, `Zatoshi.zero` screen (propose still in flight) would then authenticate against a
//  proposal the user never saw and never reviewed; worse, a proposal that lands mid-prompt and
//  changes what's on screen would get silently swapped into the commit once the guards re-ran —
//  the exact shape of a spend the user didn't approve. Deciding the intent before the prompt opens,
//  and refusing to open the prompt at all when there's nothing to commit
//  (`State.confirmIntent == nil`), removes that window entirely: what gets confirmed is always
//  exactly what was on screen at the moment of the tap, never whatever arrived after it.
//
//  MOB-1458 (code review): two more early exits dismissed the failure sheet and never restored
//  it — both missed by the round-2 fix above, which only closed the authentication-cancel/success
//  gap. The nil-`ConfirmIntent` no-op (`confirmTapped`/`retryTapped`'s
//  `guard let intent = state.confirmIntent else { ... }`) cleared `isFailurePresented` at the top
//  of the case and never set it back — reachable whenever `confirmIntent` goes nil AFTER a commit
//  failure already put the sheet up (in practice, the shared `selectedWalletAccount` clearing
//  under an open flow). Fixed to mirror `.authenticationCancelled`: restore `isFailurePresented`
//  from `failureReason != nil`. The propose-failure Retry short-circuit had the same shape one
//  guard earlier — it cleared `failureReason` (and with it, the sheet's only way back) BEFORE
//  checking whether `selectedWalletAccount` even resolves to an account to re-propose with. Fixed
//  by running the account guard first, so a nil account restores `isFailurePresented = true`
//  (unconditionally — this branch only runs when `failureReason == .propose`, already known
//  non-nil) instead of clearing state ahead of a re-propose that never launches.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationReviewTransfer {
    @ObservableState
    struct State: Equatable {
        enum Mode: Equatable {
            case immediate
            // (`.manualStep(number:total:)` — the manual-delivery per-transfer review — was
            // REMOVED 2026-08-07 with the whole manual-tap send surface.)
        }

        /// MOB-1458 (round 2): what a Confirm/Retry tap will actually commit to — decided
        /// SYNCHRONOUSLY at tap time by the `confirmIntent` computed property (below) and carried
        /// as the `confirmAuthenticated` action's payload from there on. This is the fix for a
        /// regression: an earlier version of the authentication gate re-derived this same decision
        /// from `immediateProposal`/`selectedWalletAccount` INSIDE `confirmAuthenticated`, i.e.
        /// after the authentication `await` returned. See the file header's MOB-1458 paragraph for
        /// why that reordering is a real bug and not a harmless refactor.
        enum ConfirmIntent: Equatable {
            /// Immediate mode, non-Keystone account: nothing left to commit locally — the
            /// coordinator threads `immediateProposal` into the pushed Sending screen.
            case immediateSoftware
            /// Immediate mode, Keystone account: propose+redact the proposal's PCZT and hand it to
            /// the coordinator's signing ceremony. Carries the exact proposal/account pair
            /// `confirmIntent` read at tap time — NOT whatever `immediateProposal`/
            /// `selectedWalletAccount` hold once the authentication prompt returns.
            case immediateKeystone(proposal: ImmediateMigrationProposal, account: WalletAccount)
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
        /// MOB-1513 (B4) / MOB-1458: true while an async confirm leg is in flight — the
        /// device-authentication prompt itself, the Keystone PCZT build that can follow it, or a
        /// propose-failure Retry's re-propose. Drives the Confirm button's disabled+spinner state
        /// AND the `.confirmTapped`/`.retryTapped` single-flight guard (same treatment as
        /// `MigrationTransferPlan.State.isConfirming` — see its doc). Set by `.confirmTapped`/
        /// `.retryTapped` BEFORE the authentication prompt runs (MOB-1458), so it covers that
        /// window too — a double-tap while Face ID / Touch ID / passcode is up hits the
        /// single-flight guard instead of opening a second prompt. Cleared unconditionally at the
        /// top of `.confirmAuthenticated` — the one shared clear point for every `ConfirmIntent`,
        /// replacing four scattered per-branch clears a code review flagged as error-prone — and by
        /// `.authenticationCancelled` on a refusal. The propose-failure Retry short-circuit clears
        /// it itself, via `.transferProposed`/`.transferProposalFailed` (unchanged), since that path
        /// never authenticates and so never reaches `.confirmAuthenticated` at all. Set `true`
        /// again, briefly, inside `.confirmAuthenticated`'s Keystone branch while
        /// `requestKeystoneSignature` is in flight.
        var isConfirming = false
        /// True when the manual-step variant is the coordinator's re-entry root — its back control
        /// then closes the flow instead of popping.
        var isFlowRoot = false
        /// Failure sheet, presented instead of proceeding. Covers a propose failure (immediate mode
        /// only) and a commit failure (software submit, or the Keystone PCZT-proposal fork).
        var isFailurePresented = false
        /// Which kind of failure `isFailurePresented` is showing; see `FailureReason`.
        var failureReason: FailureReason?

        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        /// MOB-1458 (round 2): what a Confirm/Retry tap commits to, read ONCE at tap time by
        /// `confirmTapped`/`retryTapped` and carried in the `confirmAuthenticated` action from
        /// there on — never re-read after the authentication prompt returns (see `ConfirmIntent`'s
        /// doc for why that distinction matters). `nil` means the tap is a genuine no-op: immediate
        /// mode with no proposal yet (propose still in flight, or failed) or no selected account —
        /// either way, the tap must not open the authentication prompt at all.
        var confirmIntent: ConfirmIntent? {
            guard let immediateProposal, let selectedWalletAccount else { return nil }
            return selectedWalletAccount.vendor == WalletAccount.Vendor.keystone
                ? ConfirmIntent.immediateKeystone(proposal: immediateProposal, account: selectedWalletAccount)
                : ConfirmIntent.immediateSoftware
        }

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
        /// MOB-1458: the device-authentication (Face ID / Touch ID / passcode) prompt that
        /// `confirmTapped`/`retryTapped` launched failed or was cancelled — undoes the
        /// `isConfirming = true` those actions set before the prompt ran, so Confirm is tappable
        /// again, and (F5) re-presents the failure sheet if one was showing before the tap, since
        /// declining must not erase the only surface for a commit failure's message. Nothing was
        /// signed or broadcast, so there is nothing else to unwind.
        case authenticationCancelled
        case binding(BindingAction<State>)
        /// Failure sheet: dismiss (stay on screen).
        case cancelTapped
        /// Flow-root back control (manual step only): closes the flow instead of popping.
        case closeTapped
        /// MOB-1458: the device-authentication prompt succeeded — runs the commit `confirmTapped`/
        /// `retryTapped` decided on BEFORE the prompt ever opened: the manual-step direct delegate,
        /// the immediate-mode software delegate, or the immediate-mode Keystone PCZT
        /// propose+redact. MOB-1458 (round 2): which of those three, and with what data, is fixed
        /// by the `State.ConfirmIntent` payload — this handler switches on it and deliberately never
        /// re-reads `immediateProposal`/`selectedWalletAccount` from state, since either could have
        /// changed while the prompt was up (see `State.ConfirmIntent`'s doc). Never sent directly by
        /// the view.
        case confirmAuthenticated(State.ConfirmIntent)
        /// MOB-1513: immediate mode delegates `.confirmed` directly — the actual create+sign+submit
        /// happens on the Sending screen (software) or was already handled by the coordinator's
        /// post-Keystone-signing step before this action even fires (Keystone). Manual step also
        /// delegates directly (transfer already signed at plan commit). MOB-1458: all of that now
        /// runs only once a device-authentication (Face ID / Touch ID / passcode) prompt succeeds —
        /// see `confirmAuthenticated`/`authenticationCancelled` for the two outcomes. MOB-1458
        /// (round 2): WHICH of those it'll be, and with what data, is decided synchronously right
        /// here, before the prompt opens (`State.confirmIntent`) — a tap with nothing to commit
        /// never opens the prompt at all.
        case confirmTapped
        case delegate(Delegate)
        /// The commit failed — presents the failure sheet instead of proceeding. Covers any
        /// software commit failure and the Keystone PCZT-proposal fork's failures.
        case noteSplitFailed
        /// Immediate mode only: proposes the send-max proposal for Amount/Fee display.
        case onAppear
        /// Failure sheet: dismiss, then re-attempt the failed step from scratch — the whole commit
        /// sequence (MOB-1458: behind a fresh device-authentication prompt, same as
        /// `confirmTapped`) when `failureReason == .commit` (or unset), or a fresh proposal — NOT
        /// re-authenticated, since nothing is signed or broadcast yet — when
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
            /// MOB-1468/MOB-1513 (R8): the immediate-mode proposal's single ordinary-send PCZT was
            /// proposed AND redacted for the signer — the coordinator routes it through the
            /// PRODUCTION single-PCZT Keystone ceremony (`urEncoderForPCZT` QR over `redacted`,
            /// `keystonePCZTScanChecker` scan, the device echoes the full signed PCZT), never the
            /// migration batch bridge. `unsigned` is the unredacted original the post-scan
            /// proofs+combine step needs (`MigrationCommitPipeline.commitImmediateKeystone`); the
            /// redaction is wire-only. R8's root cause for abandoning the batch bridge here: the
            /// batch apply FFI (`decode_signed_pairs`) numeric-parses every PCZT id, and this lane's
            /// engine-external PCZT has none — see `MigrationCoordFlowCoordinator`'s Keystone rows.
            case keystoneImmediateSignRequested(unsigned: Data, redacted: Data)
        }
    }

    /// PHASE 7: the placeholder id the immediate lane's single Keystone-signing PCZT rides under in
    /// `MigrationKeystoneSign.State.pczts`. It carries no engine-issued id — `createPCZTFromProposal`
    /// is the ordinary-send PCZT builder, not an engine call — and it is STATE-ONLY: this lane runs
    /// the production single-PCZT ceremony (`urEncoderForPCZT` QR, `keystonePCZTScanChecker` scan),
    /// never the batch bridge, so the id never reaches the SDK and the coordinator's post-signing
    /// step reads the entry positionally (`.first`).
    ///
    /// `0` rather than #1930's `"immediate"` string: `MigrationUnsignedTransferPczt.id` is a `UInt32`
    /// engine id in this SDK. The value is arbitrary precisely because nothing ever reads it.
    static let immediateKeystonePcztId: UInt32 = 0

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
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .authenticationCancelled:
                // MOB-1458: the prompt failed or was cancelled — undo the `isConfirming = true`
                // set before it launched so Confirm is tappable again. Nothing was signed or
                // broadcast, so there is nothing else to unwind — except (F5) the failure sheet:
                // `failureReason` is cleared only on a successful commit (in `.confirmAuthenticated`
                // now, not here), so re-derive `isFailurePresented` from it rather than leaving a
                // commit-failure screen looking like a fresh, never-attempted review.
                state.isConfirming = false
                state.isFailurePresented = state.failureReason != nil
                return .none

            case .binding:
                return .none

            case .cancelTapped:
                state.isFailurePresented = false
                state.failureReason = nil
                return .none

            case .closeTapped:
                return .send(.delegate(.closed))

            case .confirmAuthenticated(let intent):
                // MOB-1458: authentication already succeeded and `isConfirming` is already `true`
                // (set below, by `confirmTapped`/`retryTapped`, before the prompt ran) — no
                // single-flight re-check here, since re-running `guard !state.isConfirming` would
                // always fail. MOB-1458 (round 2): this one clear replaces four scattered
                // `isConfirming = false` sites a code review flagged as error-prone (one per exit
                // branch of the old post-await guards) — `intent` already encodes which branch we're
                // in, decided BEFORE the prompt opened, so there is exactly one place left to clear
                // the flag. F5: `failureReason` clears here too, and ONLY here — on a successful
                // commit — never on a decline or a dismissal, so a refused prompt leaves a commit
                // failure's message intact for `.authenticationCancelled` to restore.
                state.isConfirming = false
                state.failureReason = nil

                switch intent {
                case .immediateSoftware:
                    // Nothing left to commit locally — the actual create+sign+submit happens on
                    // the Sending screen, which the coordinator threads `immediateProposal` into.
                    return .send(.delegate(.confirmed))

                case .immediateKeystone(let proposal, let account):
                    // Flips back to `true` — the PCZT propose+redact below is itself async, so
                    // Confirm stays in its loading state until `requestKeystoneSignature` resolves.
                    state.isConfirming = true
                    return requestKeystoneSignature(for: proposal, account: account)
                }

            case .confirmTapped, .retryTapped:
                // MOB-1513 (B4): single-flight — a second tap while an async confirm leg is in
                // flight must be a complete no-op (same guard as `MigrationTransferPlan`'s confirm).
                guard !state.isConfirming else { return .none }
                state.isFailurePresented = false

                // MOB-1513: a propose failure's Retry re-proposes instead of re-attempting the
                // commit — checked FIRST, before any of the commit guards below. MOB-1458:
                // deliberately NOT gated behind authentication — it only re-fetches a proposal for
                // display, nothing is signed or broadcast.
                if case .retryTapped = action, state.failureReason == State.FailureReason.propose {
                    // MOB-1458 (code review): the account guard now runs BEFORE `failureReason`
                    // clears — clearing it unconditionally first (the old order) meant a nil
                    // account dismissed the "couldn't load your plan" sheet, wiped its reason, and
                    // launched nothing, leaving the user on a screen with no surface for the
                    // error. Same principle as the nil-`confirmIntent` no-op below: clear state
                    // only once the thing that follows actually proceeds.
                    guard let accountUUID = state.selectedWalletAccount?.id else {
                        // Restored unconditionally `true` here, NOT the `failureReason != nil`
                        // form used at the other restore sites — this branch only runs when
                        // `failureReason == State.FailureReason.propose`, already known non-nil,
                        // so there is no `nil` case to guard against. Don't "fix" this to match
                        // the other sites.
                        state.isFailurePresented = true
                        return .none
                    }
                    state.failureReason = nil
                    // Set only when a real re-propose launches (a nil account is a no-op inside
                    // `proposeEffect`, which must not strand the flag).
                    state.isConfirming = true
                    return proposeEffect(accountUUID: accountUUID)
                }
                // MOB-1458 (round 2 / F5): `failureReason` is deliberately NOT cleared here any
                // more — only `.confirmAuthenticated` clears it, and only on success, so a declined
                // prompt (`.authenticationCancelled`) still has the message to restore.

                // MOB-1458 (round 2 / F1): what this tap commits to is decided HERE, SYNCHRONOUSLY,
                // before the authentication prompt ever opens — never re-read from state once the
                // prompt returns. Re-reading it there is exactly the regression this ordering fixes:
                // `onAppear`'s retry loop can land a proposal WHILE THE PROMPT IS UP, and a post-await
                // guard would silently swap it into the commit. `nil` means there is nothing to
                // commit — the tap is a complete no-op. MOB-1458 (code review): a no-op must restore
                // the failure sheet dismissed at the top of this case, exactly like
                // `.authenticationCancelled` does — nothing ran here either, so there is nothing new
                // to show in its place, and silently dropping the sheet would strand `failureReason`
                // set with no surface rendering it. No prompt opens either way.
                guard let intent = state.confirmIntent else {
                    state.isFailurePresented = state.failureReason != nil
                    return .none
                }

                // MOB-1458: everything past this point signs or broadcasts something, so it's
                // gated behind device authentication (Face ID / Touch ID / passcode).
                // `isConfirming` flips `true` HERE, before the prompt runs, so the existing
                // Confirm-button spinner covers the authentication sheet too, and a double-tap
                // while it's up hits the single-flight guard above instead of opening a second
                // prompt.
                state.isConfirming = true
                return localAuthentication.gated(success: .confirmAuthenticated(intent), cancelled: .authenticationCancelled)

            case .delegate(.keystoneImmediateSignRequested):
                // MOB-1513 (B4): the PCZT is handed to the coordinator (which pushes the QR
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
                guard case .immediate = state.mode else { return .none }
                // MOB-1513: cache guard — an already-populated proposal (a re-appearance, e.g. after
                // backgrounding) is never re-proposed. MOB-1513 (E2-FIX): the entry propose is the
                // bounded, quiet retry (`proposeWithRetryEffect`); an explicit Retry stays the
                // single-attempt `proposeEffect`.
                guard state.immediateProposal == nil else { return .none }
                return proposeWithRetryEffect(accountUUID: state.selectedWalletAccount?.id)

            case .transferProposalFailed:
                state.isConfirming = false
                state.isFailurePresented = true
                state.failureReason = State.FailureReason.propose
                return .none

            case .transferProposed(let proposal):
                state.isConfirming = false
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
    /// note split of its own), redacts it for the signer (MOB-1513 R8 — the production
    /// `SignWithKeystone` wire copy: witnesses/proprietary cleared, FVK and any pre-existing
    /// dummy-spend sigs KEPT, exactly what the device's single-PCZT `zcash-pczt` protocol expects),
    /// and hands both to the coordinator for the production QR ceremony. Either throw surfaces as
    /// the same commit failure (`.noteSplitFailed` -> failure sheet + Retry), never swallowed.
    private func requestKeystoneSignature(for proposal: ImmediateMigrationProposal, account: WalletAccount) -> Effect<Action> {
        .run { send in
            do {
                let pczt = try await sdkSynchronizer.createPCZTFromProposal(account.id, proposal.proposal)
                let redacted = try await sdkSynchronizer.redactPCZTForSigner(Pczt(pczt))
                await send(.delegate(.keystoneImmediateSignRequested(unsigned: pczt, redacted: redacted)))
            } catch {
                LoggerProxy.error("[MOB-1513] immediate Keystone PCZT build/redact failed: \(error)")
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
    ///
    /// Known over-match: the FFI throws this same case for EVERY null send-max return, including a
    /// genuine balance-below-fee wallet (the rust side collapses causes into one error string). Such
    /// a wallet retries for the full window before showing the same failure sheet it gets today —
    /// a bounded latency trade accepted in review; the ordinary send-max exposes no finer-grained
    /// case to key on without message matching.
    static func isWalletNotReadyYet(_ error: Error) -> Bool {
        guard let zcashError = error as? ZcashError else { return false }
        if case .rustProposeSendMaxTransfer = zcashError {
            return true
        }
        return false
    }
}
