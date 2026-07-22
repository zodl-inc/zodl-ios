//
//  MigrationCoordFlowStore.swift
//  Zashi
//
//  Coordinator for the Orchard -> Ironwood migration flow (MOB-1466). Chains the visual-only
//  migration screens (MOB-1460...1464) into a live, state-driven flow: re-entry routing, mode/
//  network-privacy persistence, permission-step sequencing, and the scheduled/manual/immediate
//  chaining table. `MigrationEntry` is the flow's root screen (mirroring `SendCoordFlow`'s
//  `sendFormState`); every other screen lives in `path`. Everything here runs against the real
//  SDK-backed migration APIs (MOB-1495 shipped the SDK surface; MOB-1496 wired the app onto it).
//
//  MOB-1468 (Keystone) adds `keystoneSign`/`scan` path elements and `pendingKeystoneSigning`: the
//  two remaining signing sources (TransferPlan/ReviewTransfer) delegate `.keystoneSignRequested`
//  instead of signing locally, the coordinator routes through a QR sign/scan round-trip, then
//  resumes whichever chain the source represents. See `MigrationCoordFlowCoordinator.swift`'s
//  Keystone rows for the routing table.
//
//  MOB-1478 (W2/W3/W4) reshapes the scheduled entry chain and replaces the full-screen Network
//  Privacy step with a coordinator-owned Tor bottom sheet: `torSheetState`/`isTorSheetPresented`/
//  `pendingTorDestination` back a single sheet presented from Entry (immediate) — see
//  `MigrationCoordFlowCoordinator`'s Tor-sheet section. Note splitting also leaves forward routing
//  entirely (silent-after-commit, under the TransferPlan/ReviewTransfer commit CTAs) —
//  `MigrationNoteSplit` is re-entry-only now, so its Keystone signing folds into `TransferPlan`'s
//  batch and `KeystoneSigningContext` no longer has a `.noteSplit` case.
//
//  MOB-1487 (round 3): the scheduled/private path routed ALL migration transactions over Tor
//  unconditionally — How This Works stopped gating on the Tor sheet and `PendingTorDestination`
//  dropped its `.permissionChain` case.
//
//  MOB-1494 (round 4): the revised canvas re-adds the Tor toggle sheet on the scheduled path
//  (decision reversal, Michal 2026-07-18) — How This Works gates on the same
//  `walletStorage.exportTorSetupFlag()` check as Entry (immediate), `PendingTorDestination`
//  regains `.permissionChain`, and the flag-on shortcut keeps MOB-1487's persist-fix (persisted
//  options feed background sends) without the forcing.
//
//  MOB-1496 (W6) fixes a latent real-SDK break in the Keystone batch flow: the note-split PCZT used
//  to ride the WHOLE signed batch into `storeSignedMigrationTransactions` (the schedule-PCZT store —
//  all-or-nothing, keyed by engine-issued ids only), but a `"note-split"` sentinel is not an engine
//  id, so the real engine would reject the whole store. The `.scan(.foundPCZTBatch)`/
//  `.simulateSignature` store step now re-pairs + validates the scanned batch before storing
//  anything (`MigrationCoordFlow.rePairedKeystoneBatch`), splits any sentinel entry out
//  (`MigrationCoordFlow.splitKeystoneBatch`), stores ONLY the schedule's engine-id entries, and — iff
//  a split was present — routes it to a freshly pushed `MigrationNoteSplit` screen via that screen's
//  OWN existing Keystone resubmit lane, never a new UI. `pendingKeystoneSplitResume` stashes what to
//  resume with once that screen's `.continued` fires — the same post-commit routing
//  `resumeAfterKeystoneSigning` would have reached immediately had no split been needed.
//  `KeystoneSigningContext` gains a `.dust` case: `.complete(.delegate(.migrateAnyway))` now forks on
//  vendor, and a Keystone account proposes + PCZT-signs a batch-of-1 dust transfer through this SAME
//  signing machinery before broadcasting it via the dust Sending lane's existing
//  `executeNextPendingMigrationTransfer` path.
//
//  MOB-1496 (final review R6, C-1 fix): W6's store order (schedule, then split) was backwards against
//  the real engine — the split's store unconditionally starts a NEW run, so storing it second created
//  a run that shadowed the just-committed schedule forever. The store step now stores the split FIRST
//  (when present) — the run-creating call the schedule's uses-or-creates store then joins — and
//  abandons if that alone fails (nothing stored, same `keystoneScanAbandoned` semantics as a re-pair
//  failure). The old `submitSignedNoteSplit` composite (store-then-broadcast, no memory of a prior
//  success — so a retry after a successful store re-ran the store and threw) is deleted; the resubmit
//  lane's `.retryTapped` -> `resubmitSignedNoteSplit` now calls `storeSignedNoteSplit`/
//  `broadcastStoredNoteSplit` as two members, tracked via `MigrationNoteSplit.State.splitStored` so a
//  retry only ever re-broadcasts once the store has succeeded.
//
//  MOB-1496 (final review R6, C-1b fix — fix-wave 2): the C-1 fix closed the run-shadowing hazard but
//  traced only the RUN-CREATION half of the engine's phase machine, not the phase machine itself. The
//  engine's `record_transfer_result` prep branch (`context.rs:1299-1303`) UNCONDITIONALLY overwrites
//  the run's phase to `WaitingDenomConfirmations` the instant the split's broadcast is recorded — so
//  storing the schedule (which sets `BroadcastScheduled`) BEFORE that broadcast, as the C-1 fix did,
//  gets silently clobbered the moment the broadcast lands; the run then parks at `.readyToPropose`
//  forever once the split mines (`context.rs:361-378`, unconditional — no pending-rows check), and the
//  committed schedule never executes. Step 0 of the fix-wave-2 report traced the denom-advance guard
//  and found it fires from phase ∈ {`PreparingDenominations`, `WaitingDenomConfirmations`} — NOT
//  `BroadcastScheduled` — so a schedule store performed right after the split's broadcast SUCCEEDS
//  (not waiting for on-chain confirmation) is the earliest point provably safe: mining cannot occur in
//  the synchronous window between "broadcast accepted" and "schedule stored", so the run's phase is
//  already `BroadcastScheduled` by the time any later read could observe the split as mined. The
//  store step now stores ONLY the split up front (`storeSignedNoteSplit`) when one is present, carries
//  the ALREADY-SIGNED schedule entries forward in `pendingKeystoneScheduleStore` instead of storing
//  them immediately, and defers `storeSignedMigrationTransactions` -> `recordCommittedSchedule` ->
//  `reconcile()` to `MigrationCoordFlowCoordinator.storeDeferredKeystoneSchedule`, triggered by the
//  note-split screen's `.delegate(.storeScheduleRequested)` — sent automatically once its Keystone
//  broadcast lands, and again on every subsequent store-retry tap (a store failure never re-signs or
//  re-broadcasts the already-safe split, only the store itself retries). No-split batches (including
//  the Keystone dust lane) are unaffected — the schedule store still runs immediately, as before.
//
//  MOB-1496 (final engine, plural preps): the SDK replaced the singular Keystone note-split pair with
//  a plural one — the final engine builds N preparation transactions, not one split transaction (see
//  `MigrationCoordFlowCoordinator.swift`'s header for the full reshape and the two engine facts behind
//  it). `PendingScheduleStore`/`KeystoneSigningContext` are unaffected — only the prep payload
//  pluralizes: `keystoneSigningSubmitted`'s `splitPczt: Data?` becomes
//  `signedPreps: [MigrationSignedTransferPczt]?`, and `MigrationNoteSplit.State.signedNoteSplitPczt`
//  (referenced by this file's C-1/C-1b notes above as a single `Data`) is the same array type. The
//  C-1/C-1b store-ordering fixes above stay in force verbatim under the final engine — only their
//  claim that the split's OWN store is what creates the engine run no longer holds (the run is
//  created earlier, at PCZT-build time); see `storeKeystoneSignedBatch`'s doc for the corrected
//  account.
//
//  MOB-1497 (T2 of the Tor & broadcast-routing requirements round): forming the run's network
//  snapshot moves from the Tor-choice RESOLUTION points to sheet PRESENTATION (R13 needs the
//  broadcast endpoint to exist ON the choice surface) — `torSheetStateReady` carries the
//  fully-hydrated `MigrationTorSheet.State` (host, identity-custom classification) the new async
//  `torSheetState(usesFullBalanceCopy:accountUUID:)` helper resolves. The sheet's own confirm no
//  longer forms at all (`confirmTorSheet` — the "confirm must not re-roll" rule): it persists the
//  stored choice exactly as before, plus calls the new `migrationManager.confirmProvisionalTorChoice`
//  to flip `useTor` on the ALREADY-formed provisional snapshot without touching its endpoint. See
//  `MigrationCoordFlowCoordinator.swift`'s header doc for the full routing detail.
//
//  MOB-1497 (T4, Q3'26 canvas): the custom-server Tor sheet's "Switch Server" is wired up — a new
//  `switchServerRequested` action (sibling of `flowFinished`) that the coordinator emits after
//  dismissing the sheet, persisting nothing for the abandoned attempt; `Root` tears the flow down
//  exactly as `flowFinished` does and opens Server Setup. The R13 broadcast-server disclosure is
//  also fully retired: the sheet-skipped/confirmed footers on Transfer Plan / Review Transfer and
//  their `broadcastDisclosureHost` state are gone, so the coordinator no longer threads a host or
//  peeks the snapshot for one.
//
//  MOB-1513 (B4 — confirm redesign + "Splitting Funds" removal): the W6/C-1/C-1b mid-Keystone-commit
//  note-split detour narrated above is RETIRED — the ceremony still stores preps first and defers the
//  schedule entries (`PendingScheduleStore`, unchanged shape), but `resumeAfterKeystoneSigning` now
//  resumes STRAIGHT to B9 Migration Scheduled, and the first-prep broadcast + deferred schedule store
//  both live in the coordinator's post-confirm first-delivery kick
//  (`MigrationCoordFlowCoordinator.runFirstDeliveryKick`, completing via the new
//  `deferredKeystoneScheduleStored` action). `pendingKeystoneSplitResume`, the
//  `keystoneSplitResumeContinued` action, the `storeScheduleRequested`/`splitConfirmed` handshake
//  cases, and `storeDeferredKeystoneSchedule` are deleted with the detour.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationCoordFlow {
    /// MOB-1468 (Keystone): which signing source is awaiting/mid QR round-trip, so
    /// `scan(.foundPCZTBatch)` knows which chain to resume once the signed PCZTs come back.
    enum KeystoneSigningContext: Equatable {
        /// Fresh + re-created plans (`requiresSigning == true`) — the rescheduled variant never
        /// re-signs, so it never reaches this context. MOB-1478 (W4): the batch this context signs
        /// now also carries the note-split PCZT first, when `isNoteSplitNeeded()` — the split no
        /// longer has its own signing context (see `MigrationTransferPlanStore`).
        case planCommit
        /// MOB-1513: the entry-screen immediate lane's Keystone PCZT-signing ceremony
        /// (`MigrationReviewTransferStore.requestKeystoneSignature`). MOB-1496 (W-B): the "Migrate
        /// anyway" hop over Migration Complete reuses this SAME context — both are an ordinary
        /// `ImmediateMigrationProposal`'s single PCZT, engine-external, with no schedule for
        /// `pendingKeystoneSchedule` to read back.
        case immediateReview
    }

    /// MOB-1496 (C-1b fix, fix-wave 2): the ALREADY-SIGNED schedule payload a Keystone-with-split
    /// commit must store only after its split's broadcast succeeds (Step 0's engine trace — see the
    /// header comment above). Threaded from the batch-commit store effect, through
    /// `.keystoneSigningSubmitted`, into `State.pendingKeystoneScheduleStore`; consumed (MOB-1513
    /// B4) by `MigrationCoordFlowCoordinator.runFirstDeliveryKick`'s deferred store step.
    struct PendingScheduleStore: Equatable {
        let accountUUID: AccountUUID
        let scheduleEntries: [MigrationSignedTransferPczt]
        let schedule: MigrationSchedule?
    }

    /// MOB-1478 (W2): which destination the coordinator stashed while the Tor bottom sheet is
    /// presented — resumed once the user confirms ("Got it") or swipes the sheet away (identical
    /// outcome, using whatever toggle state is showing at that moment). MOB-1494 (round 4): the
    /// scheduled path hosts the sheet again, so `.permissionChain` is back alongside
    /// `.reviewTransfer`.
    enum PendingTorDestination: Equatable {
        /// Immediate mode: push Review Transfer directly.
        case reviewTransfer
        /// Scheduled mode (from How This Works): run the permission chain
        /// (`nextPermissionStepResult()`).
        case permissionChain
    }

    @Reducer(state: .equatable)
    enum Path {
        case backgroundDelivery(MigrationBackgroundDelivery)
        case complete(MigrationComplete)
        case howItWorks(MigrationHowItWorks)
        case keystoneSign(MigrationKeystoneSign)
        case notifications(MigrationNotifications)
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
        /// Persisted via `manager.setMigrationMode` once chosen; held here too so later hops in
        /// the same run (e.g. immediate's Tor-skip) don't need to re-read the dependency.
        var mode: MigrationMode?
        /// MOB-1468 (Keystone): set when a `.keystoneSignRequested` delegate pushes `keystoneSign`,
        /// cleared once the QR round-trip resolves (either resumed via `foundPCZTBatch` or backed
        /// out via `.rejected`).
        var pendingKeystoneSigning: KeystoneSigningContext?
        /// MOB-1509: the account that OWNS the pending ceremony — recorded beside
        /// `pendingKeystoneSigning` at its three setters and cleared with it, so an external
        /// teardown that runs AFTER an account switch (the cross-account notification tap) still
        /// cancels the stranded run on the account that built it, not the newly selected one.
        var pendingKeystoneSigningAccountUUID: AccountUUID?
        /// MOB-1513 (H3 guard): the account THIS flow instance opened for — recorded synchronously
        /// at `.onAppear`'s genuine-flow-start branch (`state.path.isEmpty`), alongside arming
        /// `migrationManager.setMigrationFlowPresented`. Every close/replace site reads this back
        /// (never re-derives from `selectedWalletAccount`, which can move on mid-flow — the
        /// `.home(.walletAccountTapped)` teardown runs BEFORE the switch, but relying on that
        /// ordering is exactly the fragility this field avoids) to disarm the SAME account's signal
        /// it armed. Identical "record the owner, don't trust the account selected at close time"
        /// precedent as `pendingKeystoneSigningAccountUUID` above.
        var presentedMigrationFlowAccountUUID: AccountUUID?
        /// MOB-1510: firmware version detected on the scanned batch entry that failed the
        /// minimum-firmware gate — `nil` when that entry carried no version stamp at all (firmware
        /// older than the stamping feature). Drives the copy on `KeystoneFirmwareUpdateContent`,
        /// mirrors `torSheetState`/`isTorSheetPresented`'s "coordinator owns its own sheet state"
        /// idiom rather than an `@Presents`/`ifLet` destination.
        var detectedKeystoneFirmware: KeystoneFirmwareVersion?
        var isKeystoneFirmwareUpdatePresented = false
        /// MOB-1478 (W2): the Tor bottom sheet's own state — always present (not optional), toggled
        /// on screen via `isTorSheetPresented`, mirroring the `ServerSetup`/`serverSetupViewBinding`
        /// precedent in `Root` rather than an `@Presents`/`ifLet` destination (there's exactly one
        /// sheet, it never needs independent effect-cancellation-on-dismiss semantics `zashiSheet`
        /// wouldn't already give it, and `zashiSheet` itself only takes a `Binding<Bool>` anyway).
        var torSheetState = MigrationTorSheet.State()
        var isTorSheetPresented = false
        /// Non-nil exactly while `isTorSheetPresented` is true — see `PendingTorDestination`.
        var pendingTorDestination: PendingTorDestination?
        /// MOB-1496 (C-1b fix, fix-wave 2; re-homed by MOB-1513 B4): the Keystone commit's
        /// already-signed schedule entries, held back from `storeSignedMigrationTransactions` until
        /// a preparation broadcast succeeds (see this file's header comment for why storing any
        /// earlier strands the run once the split mines). Consumed by the coordinator's
        /// post-confirm first-delivery kick (`MigrationCoordFlowCoordinator.runFirstDeliveryKick`),
        /// which runs the deferred store once a prep broadcast has landed and clears this via
        /// `.deferredKeystoneScheduleStored`. A kick that exhausts its bounded attempts leaves it
        /// intact AND arms the state-event re-arm (`.firstDeliveryKickFailed`, payload captured in
        /// the effect — this STATE copy resets at flow teardown, the armed effect does not).
        /// In-memory only — see `runFirstDeliveryKick`'s doc for the accepted app-death loss window.
        var pendingKeystoneScheduleStore: PendingScheduleStore?
        /// MOB-1496: the real per-account SDK surface needs a concrete `AccountUUID` for nearly
        /// every migration call the coordinator makes.
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        init() { }
    }

    /// Result of the async permission-step helper (`nextPermissionStepResult()`): the screen to push
    /// (`nil` once every permission step is satisfied and the flow can proceed straight to the plan
    /// screen the caller already knows to push). MOB-1478 (W2): Tor resolution no longer happens
    /// inside this chain — this struct dropped its `forcedUseTor` flag along with the deleted
    /// Network Privacy step. MOB-1487 (round 3): the scheduled lane now force-sets and persists
    /// `useTor` unconditionally immediately before this chain runs, with no sheet and no gate.
    struct PermissionStepResult: Equatable {
        var pathState: Path.State?
    }

    enum Action {
        case entry(MigrationEntry.Action)
        case flowFinished
        /// MOB-1497 (T4): the custom-server Tor sheet's "Switch Server" — a sibling terminal signal
        /// to `flowFinished`, emitted by the coordinator (`.torSheet(.delegate(.switchServer))`)
        /// after it dismisses the sheet and clears `pendingTorDestination`. Persists NOTHING for the
        /// abandoned attempt (the run's snapshot stays provisional); `Root` runs the SAME teardown
        /// as `flowFinished` and then routes to Server Setup instead of closing to Home.
        case switchServerRequested
        case onAppear
        case path(StackActionOf<Path>)
        /// Internal: the async re-entry/permission-step helper resolved the next screen to push
        /// (or `nil` when nothing needs appending — the `.entry` re-entry route).
        case pushNextPermissionStep(PermissionStepResult)
        /// Internal: a fresh `MigrationStatus.State` (already hydrated) to push — used by Sending's
        /// manual-first-transfer close (no `.status` beneath yet). A dedicated case (rather than
        /// reusing `pushHydratedPathState`) so its `isFlowRoot: false` (mid-flow push) stays
        /// visibly distinct in the reducer from the re-entry root's `isFlowRoot: true` status push.
        case pushHydratedStatus(MigrationStatus.State)
        /// Internal: a fresh `Path.State` (already hydrated) to push — used by Status `.sendNow`'s
        /// overdue-batch Sending screen, Status `.reschedule`'s rescheduled plan, and Recovery
        /// `.recreate`'s re-created plan.
        case pushHydratedPathState(Path.State)
        /// Internal: sendNow's Sending screen finished (`.closed`) — refresh the `.status` element
        /// beneath with freshly-read rows and pop back to it.
        case sendNowCompleted(rows: [MigrationTransferRow])
        /// Internal: MOB-1468 Keystone `scan(.foundPCZTBatch)` finished the ceremony's store step —
        /// pops `scan`+`keystoneSign` and resumes the chain `context` represents. The ceremony
        /// stores any sentinel-prefixed preparation entries via `storeSignedNoteSplits` first (C-1
        /// order — see `storeKeystoneSignedBatch`'s doc); a no-prep batch's schedule entries store
        /// immediately too. MOB-1496 (C-1b fix, fix-wave 2; re-homed by MOB-1513 B4):
        /// `pendingScheduleStore` carries the already-signed schedule entries when (and only when)
        /// preps rode the batch — the schedule is not stored inline then; it rides along to be
        /// stored by the post-confirm first-delivery kick once a prep broadcast succeeds (see
        /// `State.pendingKeystoneScheduleStore`). `nil` for a no-prep batch, whose schedule already
        /// stored immediately, unchanged.
        case keystoneSigningSubmitted(
            context: KeystoneSigningContext,
            pendingScheduleStore: PendingScheduleStore?
        )
        /// Internal: MOB-1513 (B4) — the first-delivery kick's deferred Keystone schedule store
        /// succeeded (`storeSignedMigrationTransactions` -> `recordCommittedSchedule` ->
        /// `reconcile`) — releases `pendingKeystoneScheduleStore` and cancels any armed
        /// state-event re-arm. Never sent on a kick failure (broadcast or store), which leaves the
        /// stash intact.
        case deferredKeystoneScheduleStored
        /// Internal: MOB-1513 (B4 fix wave) — the first-delivery kick exhausted its bounded
        /// attempts with a Keystone deferred schedule store still pending. Arms the SILENT
        /// state-event re-arm (`.deferredKeystoneScheduleResolveDue` per
        /// `migrationManager.stateEvents` emission) so the store still happens once a prep
        /// broadcast lands, no matter who lands it (a later BG-window broadcast, or foreground
        /// reconcile observing the mined prep). Carries the payload IN THE ACTION — the flow's
        /// teardown resets coordinator state, but this flow is a permanent `Scope` child of Root
        /// (no dismissal effect-cancellation), so the armed effect and its captured payload outlive
        /// a "Got it" close by design.
        case firstDeliveryKickFailed(pendingScheduleStore: PendingScheduleStore, accountUUID: AccountUUID)
        /// Internal: MOB-1513 (B4 fix wave) — one `stateEvents` emission arrived while the re-arm
        /// above is active: run one silent resolve attempt (probe the next-due lane; a landed or
        /// exhausted (`nil`) outcome runs the deferred store) with the payload the re-arm captured.
        case deferredKeystoneScheduleResolveDue(pendingScheduleStore: PendingScheduleStore, accountUUID: AccountUUID)
        /// MOB-1513: the immediate lane's Keystone post-signing submit
        /// (`MigrationCommitPipeline.commitImmediateKeystone`, dispatched from
        /// `submitImmediateKeystoneTransaction`) succeeded — pops back to the signing source exactly
        /// like `resumeAfterKeystoneSigning`'s no-preps branch, but pushes `MigrationSending.State`
        /// ALREADY in `.success` phase with the real txid (the broadcast already happened here, not
        /// on that screen's `onAppear` — see `submitImmediateKeystoneTransaction`'s doc for why the
        /// Keystone lane can't defer to the Sending screen the way the software lane does).
        case keystoneImmediateSubmitted(txId: String)
        /// Internal: MOB-1496 (W-B) — "Migrate anyway"'s Keystone fork
        /// (`.complete(.delegate(.migrateAnyway))`) unlocked, proposed the immediate migration, and
        /// built its single PCZT via `createPCZTFromProposal` — arms `.immediateReview` (the SAME
        /// context the entry-screen immediate lane's Keystone ceremony uses) and pushes
        /// `keystoneSign`, exactly like `MigrationReviewTransferStore.requestKeystoneSignature`'s
        /// `.keystoneSignRequested` delegate does for that lane.
        case migrateAnywayImmediateKeystonePCZTProposed(pczts: [MigrationUnsignedTransferPczt])
        /// Internal: MOB-1468 `keystoneSign(.delegate(.rejected))`'s pop, deferred to a follow-up
        /// self-action for the same reason `sendNowCompleted` defers its pop — popping the
        /// `keystoneSign` element inline in the `.path(.element(...))` case would race
        /// `.forEach(\.path, action:)`'s delivery of that same action to the (then-missing) element.
        case keystoneSignRejected
        /// Internal: an empty/mismatched scanned batch, OR a split-store failure (MOB-1496 C-1 fix,
        /// final review R6 — nothing was stored, so there is nothing to resume), abandons the signing
        /// session — pops back to the initiating screen (deferred like `keystoneSignRejected`) and
        /// clears the context. Pop count adapts to the caller: 2 (`scan` + `keystoneSign`) for the
        /// real round-trip, where `scan` is always the acting/top element; 1 (`keystoneSign` only) for
        /// the simulator bypass, which never pushes `scan`.
        case keystoneScanAbandoned
        /// MOB-1510: `zashiSheet`'s `isPresented` binding changed for the firmware-update prompt —
        /// mirrors `torSheetPresentationChanged`'s contract. `false` clears `detectedKeystoneFirmware`
        /// (there is only ever a "Close" affordance here, no warn-on-swipe distinction to make).
        case keystoneFirmwareUpdatePresentationChanged(Bool)
        /// MOB-1478 (W2): the Tor bottom sheet's own actions (toggle binding + "Got it").
        case torSheet(MigrationTorSheet.Action)
        /// MOB-1478 (W2): `zashiSheet`'s `isPresented` binding changed — `true` when presented (the
        /// coordinator already set this synchronously before returning, so this is mostly a
        /// same-value echo), `false` on dismissal (both an explicit "Got it" — which also flips this
        /// itself — and a swipe-to-dismiss, which the sheet's own gesture drives).
        case torSheetPresentationChanged(Bool)
        /// MOB-1497 (T2): the async presentation-time helper (`torSheetState(usesFullBalanceCopy:
        /// accountUUID:)`) resolved a fully-hydrated `MigrationTorSheet.State` — forms the run's
        /// snapshot and threads its `broadcastEndpoint.host`/identity-custom classification in
        /// (R13/R2/R12) before the sheet is actually shown. Presenting is deferred to this follow-up
        /// action (rather than done inline at the send site) because forming is async and R13
        /// requires the endpoint to exist ON the choice surface the moment it appears.
        case torSheetStateReady(MigrationTorSheet.State, destination: PendingTorDestination)
    }

    // MOB-1513 (B4 fix wave): paces the first-delivery kick's bounded in-kick broadcast retries.
    @Dependency(\.continuousClock) var clock
    @Dependency(\.migrationBGScheduler) var migrationBGScheduler
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userNotifications) var userNotifications
    @Dependency(\.walletStorage) var walletStorage

    init() { }

    var body: some Reducer<State, Action> {
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
