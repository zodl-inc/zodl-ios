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
//  OWN existing Keystone resubmit lane (`.retryTapped` -> `resubmitSignedNoteSplit` ->
//  `submitSignedNoteSplit`), never a new UI. `pendingKeystoneSplitResume` stashes what to resume with
//  once that screen's `.continued` fires — the same post-commit routing `resumeAfterKeystoneSigning`
//  would have reached immediately had no split been needed. `KeystoneSigningContext` gains a `.dust`
//  case: `.complete(.delegate(.migrateAnyway))` now forks on vendor, and a Keystone account proposes
//  + PCZT-signs a batch-of-1 dust transfer through this SAME signing machinery before broadcasting it
//  via the dust Sending lane's existing `executeNextPendingMigrationTransfer` path.
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
        case immediateReview
        /// MOB-1496 (W6 §3): the Keystone "Migrate anyway" dust lane — a batch-of-1, no sentinel
        /// (there is no split in the dust lane). The schedule is proposed directly by the
        /// coordinator (`.keystoneDustPCZTsProposed`), not read off any path element's own state, so
        /// it rides along on the context itself for `pendingKeystoneSchedule` to hand back.
        case dust(MigrationSchedule)
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
        case noteSplit(MigrationNoteSplit)
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
        /// MOB-1478 (W2): the Tor bottom sheet's own state — always present (not optional), toggled
        /// on screen via `isTorSheetPresented`, mirroring the `ServerSetup`/`serverSetupViewBinding`
        /// precedent in `Root` rather than an `@Presents`/`ifLet` destination (there's exactly one
        /// sheet, it never needs independent effect-cancellation-on-dismiss semantics `zashiSheet`
        /// wouldn't already give it, and `zashiSheet` itself only takes a `Binding<Bool>` anyway).
        var torSheetState = MigrationTorSheet.State()
        var isTorSheetPresented = false
        /// Non-nil exactly while `isTorSheetPresented` is true — see `PendingTorDestination`.
        var pendingTorDestination: PendingTorDestination?
        /// MOB-1496 (W6): non-nil while a `.noteSplit` screen pushed by `resumeAfterKeystoneSigning`
        /// (to broadcast a just-stored Keystone split) is showing — carries the SAME context so its
        /// own `.delegate(.continued)` resumes exactly the post-commit chain that would have run
        /// immediately had no split been needed (`resumeCommittedMigrationChain`), instead of
        /// falling into the permission-chain fallback that handler otherwise takes. `nil` for every
        /// other `.noteSplit` occurrence (re-entry root, or the pre-MOB-1478 defensive branch).
        var pendingKeystoneSplitResume: KeystoneSigningContext?
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
        /// Internal: MOB-1468 Keystone `scan(.foundPCZTBatch)` finished storing the signed PCZTs
        /// (`storeSignedMigrationTransactions`, `Void`-returning) — pops `scan`+`keystoneSign` and
        /// resumes the chain `context` represents. MOB-1478 (W4): the stored batch now always
        /// includes the note-split PCZT first when `isNoteSplitNeeded()` — there's no separate
        /// per-source result to carry any more (the old `.noteSplit` context's `TransferResult`/
        /// signed-PCZT payload is gone along with that context). MOB-1496 (W6): `splitPczt` is the
        /// sentinel entry's PCZT bytes, split out of the stored batch (`nil` when the run needed no
        /// split, or when the store itself failed) — non-`nil` routes to the note-split screen
        /// instead of resuming the schedule/review chain immediately (see
        /// `resumeAfterKeystoneSigning`).
        case keystoneSigningSubmitted(context: KeystoneSigningContext, splitPczt: Data?)
        /// Internal: MOB-1496 (W6 §3) — the Keystone dust lane's upfront propose
        /// (`.complete(.delegate(.migrateAnyway))`'s Keystone fork) came back with a non-empty
        /// schedule and its PCZTs — pushes the existing Keystone signing context as a batch-of-1 (no
        /// sentinel; there is no split in the dust lane).
        case keystoneDustPCZTsProposed(schedule: MigrationSchedule, pczts: [MigrationUnsignedTransferPczt])
        /// Internal: MOB-1496 (W6) — the note-split screen's `.delegate(.continued)` landed while
        /// `pendingKeystoneSplitResume` was set (the mid-Keystone-commit split-broadcast case) — its
        /// pop is deferred to this follow-up self-action for the SAME reason `keystoneSignRejected`
        /// defers its own: popping the `noteSplit` element inline in the `.path(.element(...))` case
        /// would race `.forEach(\.path, action:)`'s delivery of that same action to the (then-missing)
        /// element (a TCA "missing element" runtime error, caught by
        /// `noteSplitContinuedAfterKeystoneSplitRoutingResumesToScheduledAndClearsPendingResume`).
        case keystoneSplitResumeContinued
        /// Internal: MOB-1468 `keystoneSign(.delegate(.rejected))`'s pop, deferred to a follow-up
        /// self-action for the same reason `sendNowCompleted` defers its pop — popping the
        /// `keystoneSign` element inline in the `.path(.element(...))` case would race
        /// `.forEach(\.path, action:)`'s delivery of that same action to the (then-missing) element.
        case keystoneSignRejected
        /// Internal: an empty scanned batch abandons the signing session — pops BOTH the `scan`
        /// and `keystoneSign` elements back to the initiating screen (deferred like
        /// `keystoneSignRejected`, since `scan` is the acting element) and clears the context.
        case keystoneScanAbandoned
        /// MOB-1478 (W2): the Tor bottom sheet's own actions (toggle binding + "Got it").
        case torSheet(MigrationTorSheet.Action)
        /// MOB-1478 (W2): `zashiSheet`'s `isPresented` binding changed — `true` when presented (the
        /// coordinator already set this synchronously before returning, so this is mostly a
        /// same-value echo), `false` on dismissal (both an explicit "Got it" — which also flips this
        /// itself — and a swipe-to-dismiss, which the sheet's own gesture drives).
        case torSheetPresentationChanged(Bool)
    }

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
