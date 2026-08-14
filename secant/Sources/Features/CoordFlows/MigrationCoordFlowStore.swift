//
//  MigrationCoordFlowStore.swift
//  Zodl
//
//  Coordinator for the Orchard -> Ironwood migration flow. `MigrationEntry` is the flow's root
//  screen (mirroring `SendCoordFlow`'s `sendFormState`); every other screen lives in `path`.
//
//  PHASE 2 SCOPE (docs/slipstream/migration/REBUILD_PLAN.md). #1930's coordinator is a 2,900-line
//  file covering every phase at once; this is the same skeleton reduced to the two lanes Phase 2
//  ships, with the SAME store shape and case names so later phases re-add their rows rather than
//  reshaping anything:
//
//    Entry --(.immediate)-------> ReviewTransfer --> Sending          (the MANUAL lane, end to end)
//    Entry --(.privateScheduled)-> HowItWorks -----> TransferPlan     (the PRIVACY lane, PREVIEW only)
//
//  Deliberately absent, each landing with the phase that needs it:
//  - the Tor bottom sheet + network snapshot forming (`torSheetState`, `PendingTorDestination`,
//    `formNetworkSnapshot`) — Phase 3, with the N-series network law;
//  - the commit pipeline, Scheduled/Status/Notifications screens and the first-delivery kick —
//    Phase 3/4;
//  - Recovery/Complete and the dust lane — Phases 5/6;
//  - the whole Keystone ceremony (`keystoneSign`/`scan`, `KeystoneSigningContext`,
//    `PendingScheduleStore`, `KeystoneBatchRounds`, the firmware gate) — Phase 7.
//
//  D12 (one fork, one consent): the privacy-vs-manual choice exists ONLY here, at the start.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationCoordFlow {
    /// PHASE 7 (Keystone): which signing source is awaiting/mid QR round-trip, so the scan
    /// completion knows which chain to resume once the applied signatures come back.
    ///
    /// #1930 also carries `.recoveryRefresh(schedule:)` — the expired-transfer recovery's lane. That
    /// screen is Phase 5; adding the case then makes the compiler point at
    /// `resumeCommittedMigrationChain` and `pendingKeystoneSchedule`, which is exactly where its
    /// behaviour differs. The MACHINE below is complete either way — Phase 5 adds a caller, not a
    /// mechanism.
    enum KeystoneSigningContext: Equatable {
        /// The scheduled lane's plan commit (`MigrationTransferPlan`'s `.keystone` confirm intent) —
        /// a BATCH ceremony over the run's preparation + transfer PCZTs.
        case planCommit
        /// The manual lane's immediate sweep (`MigrationReviewTransfer.requestKeystoneSignature`) —
        /// a SINGLE-PCZT ceremony over one ordinary, engine-external `ImmediateMigrationProposal`.
        case immediateReview
    }

    /// PHASE 7: the batch ceremony's multi-round bookkeeping.
    ///
    /// A batch beyond one signing round's action budget signs across several QR round trips:
    /// each round is a full, self-contained ceremony (own request id, own build → scan → decode →
    /// apply), and the rounds' applied signatures accumulate HERE — nothing stores until the last
    /// round lands, preserving the all-or-nothing invariant (an abandon mid-sequence discards
    /// everything, and the engine re-serves the still-unsigned batch on re-entry).
    ///
    /// Set by `beginKeystoneCeremony` for every batch ceremony, single-round included (`roundIndex`
    /// 0 is then also the last round); `nil` for the immediate lane's single-PCZT ceremony, which
    /// never chunks. Cleared at the last round's store handoff and by every ceremony-ending route.
    struct KeystoneBatchRounds: Equatable {
        /// The ceremony's rounds, already packed by ACTION budget by the SDK at propose time
        /// (`MigrationKeystoneBatch.rounds`). Concatenated they are the full ordered batch —
        /// preparation PCZTs first, then the schedule's transfers — the order both the stores and
        /// `preparationCount` depend on.
        var rounds: [[MigrationUnsignedTransferPczt]]
        /// How many leading entries of the concatenated `rounds` are preparation transactions — from
        /// `MigrationKeystoneBatch` so the signed result splits the same way. See
        /// `MigrationCoordFlow.splitKeystoneBatch`.
        var preparationCount: Int
        /// The 0-based round currently showing/being scanned.
        var roundIndex = 0
        /// Applied signatures of the COMPLETED rounds, in original batch order.
        var accumulatedSigned: [MigrationSignedTransferPczt] = []
    }

    /// Which destination the coordinator stashed while the Tor bottom sheet is presented — resumed
    /// once the user confirms ("Got it") or swipes the sheet away (identical outcome, using
    /// whatever toggle state is showing at that moment).
    enum PendingTorDestination: Equatable {
        /// Immediate mode: push Review Transfer directly.
        case reviewTransfer
        /// Scheduled mode (from How This Works): continue to the plan.
        ///
        /// PHASE 3: #1930 names this `.permissionChain` because it runs the notification-permission
        /// chain here. Permissions are Phase 4; the destination itself is the same one either way,
        /// so the case keeps its scheduled-lane MEANING and gains the chain in Phase 4.
        case transferPlan
    }

    @Reducer(state: .equatable)
    enum Path {
        /// PHASE 6: the terminal per-run screen — summary, the residual lock/"Migrate anyway" fork,
        /// and the acknowledgement that lets the next round (or nothing) take over.
        case complete(MigrationComplete)
        case howItWorks(MigrationHowItWorks)
        case keystoneSign(MigrationKeystoneSign)
        case notifications(MigrationNotifications)
        /// PHASE 5: the attention lane — "Transfers No Longer Valid" (a funding note was spent
        /// externally) and "Reschedule Transfers" (a transfer's window elapsed). Calm, actionable,
        /// never an error surface.
        case recovery(MigrationRecovery)
        case reviewTransfer(MigrationReviewTransfer)
        case scan(Scan)
        case scheduled(MigrationScheduled)
        case sending(MigrationSending)
        case status(MigrationStatus)
        case transferPlan(MigrationTransferPlan)
    }

    @ObservableState
    struct State: Equatable {
        var path = StackState<Path.State>()
        var entryState = MigrationEntry.State()
        /// Whether re-entry routing chose the fork itself as the destination — the ONLY condition
        /// under which the flow root reveals.
        ///
        /// Entry is the flow's ROOT screen, so it renders the instant the flow opens, while the real
        /// destination is only APPENDED once `reentryPathState`'s async reads resolve. On a committed
        /// run that means the fork — "migrate privately, or manually?" — flashed up before the status
        /// screen replaced it, which is what a tester saw on 07-31: the fork offers a CHOICE a
        /// committed run has already made, and a fast tap on it starts a second flow over a live one.
        ///
        /// FIELD BUG (2026-08-06): merely holding the root back until "routing has decided" was not
        /// enough — `pushHydratedPathState` used to reveal AND push in the same mutation, so a
        /// resolved PUSH destination still satisfied this flag, and the fork became the push
        /// animation's own visible base layer, staying beneath the destination for the stack's whole
        /// life.
        ///
        /// So: revealed IFF routing chose the fork (`reentryPathState` returning `nil` — the fork IS
        /// the destination). A resolved push destination never sets this — the root stays hidden for
        /// that stack's entire life, and the pushed screen renders over a neutral, permanently-hidden
        /// root instead of a tappable fork.
        var isReentryResolved = false
        /// The lane the user picked at the fork. Held here so a later hop in the same run doesn't
        /// need to re-read it. #1930 also persisted it via `migrationManager.setMigrationMode`;
        /// that persistence matters once a run can be COMMITTED (Phase 3) — Phase 2's manual lane
        /// completes inside a single flow presentation.
        var mode: MigrationMode?
        /// The Tor bottom sheet's own state — always present (not optional), toggled on screen via
        /// `isTorSheetPresented`, mirroring the `ServerSetup`/`serverSetupViewBinding` precedent in
        /// `Root` rather than an `@Presents`/`ifLet` destination (there is exactly one sheet, and
        /// `zashiSheet` only takes a `Binding<Bool>` anyway).
        var torSheetState = MigrationTorSheet.State()
        var isTorSheetPresented = false
        /// Non-nil exactly while `isTorSheetPresented` is true — see `PendingTorDestination`.
        var pendingTorDestination: PendingTorDestination?

        // PHASE 7 — the Keystone ceremony's own state.

        /// Set when a `.keystoneSignRequested` delegate pushes `keystoneSign`; cleared once the QR
        /// round-trip resolves (resumed, rejected, or abandoned). Doubles as the TOMBSTONE every
        /// late completion checks before touching the path — a ceremony torn down mid-flight (the
        /// user swipe-backs off `scan` and taps Reject while proving runs) clears this first.
        var pendingKeystoneSigning: KeystoneSigningContext?
        /// The account that OWNS the pending ceremony — recorded beside `pendingKeystoneSigning` and
        /// cleared with it, so a teardown that runs AFTER an account switch still cancels the
        /// stranded run on the account that built it, not the newly selected one.
        var pendingKeystoneSigningAccountUUID: AccountUUID?
        /// One-shot guard making the BATCH round-trip's completion single-delivery. `ScanUIView`
        /// forwards every camera metadata callback regardless of ceremony state, and `Scan`'s own
        /// intake gate (`isAnythingFound`) only flips once the async apply effect's result lands —
        /// so a late frame in that window can re-decode a single-part response standalone and reach
        /// the coordinator as a SECOND completion with a legitimately-matching request id. Set right
        /// before the apply effect dispatches; a duplicate is DROPPED, never abandoned.
        var keystoneBatchApplyInFlight = false
        /// The SINGLE-PCZT (immediate-lane) ceremony's own one-shot guard — the twin of
        /// `keystoneBatchApplyInFlight` for the production `.scan(.foundPCZT)` round-trip. That
        /// checker decodes SYNCHRONOUSLY inside `Scan`'s reducer, but two camera frames can both
        /// pass `isAnythingFound` before the first `.foundPCZT` is processed. Armed for the WHOLE
        /// post-scan leg (set before the proofs+submit effect dispatches — a duplicate mid-proving
        /// would otherwise DOUBLE-BROADCAST).
        var keystoneImmediateSubmitInFlight = false
        /// The batch ceremony's multi-round bookkeeping — non-`nil` exactly while a batch ceremony
        /// is in flight; `nil` for the immediate lane. See `KeystoneBatchRounds`.
        var keystoneBatchRounds: KeystoneBatchRounds?
        /// The dotted `major.minor.build` firmware version the decode envelope (or PCZT stamp)
        /// reported for a ceremony that failed the minimum-firmware gate; `nil` when none was
        /// reported at all. A formatted `String` deliberately, not a `KeystoneDisplayFirmwareVersion`: the
        /// SDK's `ZcashLightClientKit.KeystoneFirmwareVersion` and this app's own
        /// `Features/SendConfirmation/KeystoneDisplayFirmwareVersion.swift` share a bare name, and
        /// formatting once at detection time keeps this field trivially Equatable/Sendable.
        var detectedKeystoneFirmwareVersion: String?
        var isKeystoneFirmwareGatePresented = false
        /// The dotted minimum-firmware floor the FAILED gate was checked against — the two lanes
        /// gate on DIFFERENT floors (the immediate lane on the PCZT stamp floor, the batch lane on
        /// the batch-protocol floor), and the sheet's copy must echo whichever actually applied.
        var keystoneFirmwareGateMinimumVersion: String?

        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init() { }
    }

    enum Action: BindableAction {
        /// Exists so the two coordinator-owned sheets can be presented with `$store.<flag>` rather
        /// than a hand-rolled `Binding(get:set:)`.
        ///
        /// A hand-rolled binding's `get` closure is invoked by SwiftUI during ITS update cycle —
        /// outside the `WithPerceptionTracking` scope the view body established — so reading store
        /// state in it trips "Perceptible state was accessed but is not being tracked" on every
        /// screen the coordinator hosts, not just the one owning the sheet. `$store.<flag>` reads
        /// through `@Perception.Bindable`, which is tracked. Same shape as
        /// `AddKeystoneHWWalletCoordFlow`.
        ///
        /// The write still runs its side effects: `BindingReducer()` applies the value, then
        /// `coordinatorReduce()` observes `.binding(\.isTorSheetPresented)` /
        /// `.binding(\.isKeystoneFirmwareGatePresented)` and forwards to the existing presentation
        /// actions, which stay in place for their programmatic senders.
        case binding(BindingAction<State>)
        case entry(MigrationEntry.Action)
        /// Terminal: the flow is done (or was backed out of) — `Root` tears it down.
        case flowFinished
        case onAppear
        case path(StackActionOf<Path>)
        /// Pushes a path state that had to be hydrated asynchronously first (the network snapshot
        /// must exist before anything downstream reads it), so the push itself stays synchronous.
        /// Appends without revealing the root — see `State.isReentryResolved`.
        case pushHydratedPathState(Path.State)
        /// Re-entry routing has decided — reveal the flow root. See `State.isReentryResolved`.
        case reentryResolved
        /// PHASE 5: the `.notesSpent` recovery lane — a funding note was spent outside the run, so
        /// the whole step is re-planned from live balances. Also the fallback when an expired
        /// refresh fails.
        case recoveryRestartRequested
        /// PHASE 5: an expired-transfer refresh or a restart failed. Clears the recovery screen's
        /// in-flight flag so its Continue button is usable again — a dead button is the one outcome
        /// this lane must never produce.
        case recoveryFailed
        /// PHASE 6: "Migrate anyway" — the residual has been unlocked and the ordinary immediate
        /// lane takes it from here. Carries no proposal: `MigrationReviewTransfer`'s `.immediate`
        /// mode proposes for itself on appear, exactly as the manual lane's own entry does.
        case migrateAnywayUnlocked
        /// PHASE 6: the unlock or the immediate proposal failed; clears the Complete screen's
        /// single-flight flag so the button comes back.
        case migrateAnywayFailed
        /// Same, for the Status screen — kept separate because re-entry hydrates it from a
        /// different source (rows + summary) than a fresh push.
        case pushHydratedStatus(MigrationStatus.State)
        /// Audit 2026-08-03 (#17): the reschedule effect's landing pad — a COORDINATOR action so
        /// the reducer can check the target element still exists before forwarding (the parent-
        /// level effect survives the element's removal, so a back-tap mid-reschedule used to
        /// deliver into a missing element). Replaces the dead `sendNowCompleted`. (2026-08-07:
        /// the Send-now surface is gone entirely, so this stack action can never gain a send-now
        /// caller; the Sending screen's close ends the whole flow as before.)
        case rescheduleResultReady(id: StackElementID, rows: [MigrationTransferRow], totalDurationHours: Int?)
        /// The Tor sheet's "switch server" escape — `Root` opens Server Setup and tears the flow
        /// down (N6: a manual switch mid-run is a privacy decision, not a silent one).
        case switchServerRequested
        case torSheet(MigrationTorSheet.Action)
        case torSheetPresentationChanged(Bool)
        /// The sheet's state is resolved asynchronously (it needs the run's broadcast endpoint on
        /// the choice surface), so presentation is a two-step: resolve, then present with the
        /// destination to resume once the user confirms.
        case torSheetStateReady(MigrationTorSheet.State, destination: PendingTorDestination)

        // PHASE 7 — the Keystone ceremony.

        /// Internal: the batch ceremony's store step finished — every entry (note-split preps AND
        /// the schedule's own transfers) stored, the committed schedule recorded — pops `scan` +
        /// `keystoneSign` and resumes whichever chain `context` represents.
        case keystoneSigningSubmitted(context: KeystoneSigningContext)
        /// Internal: `applyKeystoneBatchSignatures` returned. `unsignedPczts` is the ORIGINAL array
        /// handed to `buildKeystoneSignBatchQRParts`; `signed` is the returned, positionally-paired
        /// result. Dispatched from a `.run` effect (apply is `async throws`) rather than handled
        /// inline, so the path is still exactly `[..., keystoneSign, scan]` when this lands — the
        /// `depthBelowTop: 2` schedule read depends on that.
        case keystoneBatchSignaturesApplied(
            context: KeystoneSigningContext,
            accountUUID: AccountUUID,
            unsignedPczts: [MigrationUnsignedTransferPczt],
            signed: [MigrationSignedTransferPczt]
        )
        /// Internal: the immediate lane's Keystone post-signing submit succeeded — pops back like a
        /// resume would, then pushes `MigrationSending.State` ALREADY in `.success` with the real
        /// txid (the broadcast happened here, not on that screen's `onAppear`).
        case keystoneImmediateSubmitted(txId: String)
        /// Internal: the immediate lane's post-signing proofs+submit FAILED. Pops exactly like an
        /// abandon, but the failure is VISIBLE and retryable — the retained Review element comes back
        /// with its commit-failure sheet armed. Deliberately skips the abandon's stray-run cancel:
        /// the immediate proposal is engine-external, so no engine run exists to cancel.
        case keystoneImmediateSubmitFailed
        /// Internal: `keystoneSign(.delegate(.rejected))`'s pop, deferred to a follow-up self-action
        /// because popping the element inline would race `.forEach(\.path, action:)`'s delivery of
        /// that same action to the (then-missing) element.
        case keystoneSignRejected
        /// Internal: the shared sink for EVERY terminal failure of the signing session — a build
        /// failure, a decode failure, a firmware-gate rejection, an apply failure, or a store
        /// failure. Pops back to the initiating screen, clears the context, and cancels the stray
        /// engine run the ceremony's own PCZT build created.
        case keystoneScanAbandoned
        /// `zashiSheet`'s `isPresented` binding for the minimum-firmware gate — mirrors
        /// `torSheetPresentationChanged`'s contract. `false` clears the detected/minimum versions.
        case keystoneFirmwareGatePresentationChanged(Bool)
    }

    // PHASE 7: the immediate single-PCZT ceremony resets the shared BC-UR fountain decoder before
    // pushing its scan session (`SendConfirmation.getSignatureTapped` precedent), so a retry
    // ceremony never inherits a previous session's accumulated frames.
    // PHASE 5: the expired-transfer refresh re-signs the rebuilt rows IN PLACE for a software
    // account, so this coordinator now derives a USK of its own (`MigrationSpendingKeyDerivation`)
    // — hence the derivation trio below, mirroring `MigrationTransferPlan`'s own dependency set.
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.keystoneHandler) var keystoneHandler
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }

    var body: some Reducer<State, Action> {
        // FIRST, deliberately: it applies the binding's write, so the side-effect arms in
        // `coordinatorReduce()` observe state that is already up to date.
        BindingReducer()

        coordinatorReduce()

        Scope(state: \.entryState, action: \.entry) {
            MigrationEntry()
        }

        Scope(state: \.torSheetState, action: \.torSheet) {
            MigrationTorSheet()
        }

        Reduce { _, _ in .none }
            .forEach(\.path, action: \.path)
    }
}
