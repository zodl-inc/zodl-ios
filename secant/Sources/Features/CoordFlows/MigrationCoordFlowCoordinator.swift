//
//  MigrationCoordFlowCoordinator.swift
//  Zashi
//
//  Routing brain for `MigrationCoordFlow` (MOB-1466): re-entry (`.onAppear`), the chaining table
//  from Entry through Complete, and the shared permission-step helper (BackgroundDelivery ->
//  Notifications -> TransferPlan). See the MOB-1466 implementation spec's `MigrationCoordFlow`
//  section for the full chaining table this mirrors row by row.
//
//  MOB-1468 (Keystone) adds a QR sign/scan round-trip ahead of the two signing sources
//  (TransferPlan/ReviewTransfer): each delegates `.keystoneSignRequested(pczts)` instead of signing
//  locally, which sets `pendingKeystoneSigning` and pushes `keystoneSign`; `keystoneSign(.delegate
//  (.getSignature))` pushes `scan` configured with the migration batch checker; `scan(.foundPCZTBatch
//  (signed))` stores the signed PCZTs and resumes whichever chain the source represents, popping both
//  pushed elements and clearing the context. `keystoneSign(.delegate(.rejected))` pops back to the
//  signing source with its state untouched (no partial storage ever happens on that path). See the
//  "Keystone signing" section below.
//
//  MOB-1478 reshapes the scheduled entry chain and the note-split lifecycle:
//  - W2: the full-screen Network Privacy step is replaced by a coordinator-owned Tor bottom sheet.
//    `presentTorSheet`/`confirmTorSheet` originally gated both points that used to push Network
//    Privacy — Entry (immediate mode) and How This Works (scheduled mode) — behind the same
//    `walletStorage.exportTorSetupFlag()` check. MOB-1487 (round 3, below) removed the How This
//    Works gate entirely, so the sheet is Entry (immediate)-only now.
//  - W3: Entry's scheduled/private path now always pushes the new `howItWorks` screen (no more
//    `isNoteSplitNeeded()` branch at Entry).
//  - W4: note splitting leaves forward routing entirely — `MigrationNoteSplit` is reached only via
//    re-entry (`reentryRoute() == .noteSplitProgress`), so it no longer requests Keystone signing;
//    `KeystoneSigningContext` lost its `.noteSplit` case, and `MigrationTransferPlan`'s Keystone batch
//    now carries the split PCZT itself, when needed.
//  - W7: `Status`'s reschedule lands `.rescheduleCompleted` on the SAME status element instead of
//    pushing a new `TransferPlan`.
//  - W8: `nextPermissionStepResult()` picks the Notifications variant off `isManualDelivery()`.
//  - W10: the Keystone scan push sets `instructions`/`forceLibraryToHide`.
//
//  MOB-1480 adds a simulator-only Keystone bypass (no physical device required): `MigrationKeystoneSign
//  Store`'s "Simulate signed result" button delegates `.simulateSignature`, handled here by reading
//  the batch straight off the already-pushed `keystoneSign` element (the bypass never pushes `scan`,
//  so there is no scanned result to read instead) and running the identical store/resume chain the
//  real round-trip uses. `resumeAfterKeystoneSigning` pops 1 or 2 path elements depending on whether
//  `scan` is actually on top, so that one shared resume path stays correct for both callers.
//
//  MOB-1487 (round 3): the scheduled/private path routed ALL migration transactions over Tor
//  unconditionally, per the Core/Wallet decision (2026-07-16) — no sheet, no opt-out on that path.
//  Its lasting piece is the persist-fix: every lane persists `useTor` via
//  `migrationManager.setNetworkPrivacyOptions` (background sends read the persisted copy, not the
//  in-memory `state`).
//
//  MOB-1494 (round 4): the revised canvas re-adds the Tor toggle sheet on the scheduled path
//  (decision reversal, Michal 2026-07-18) — How This Works gates on the same
//  `walletStorage.exportTorSetupFlag()` check as Entry (immediate) and stashes
//  `.permissionChain`; the flag-on shortcut persists `useTor = true` exactly like the immediate
//  lane's. The sheet's toggle defaults ON and its body copy splits by path ("your full balance"
//  on immediate, "your balance" on scheduled). At real-SDK time, Tor-unavailable remains a fail +
//  retry — no direct-connection fallback.
//
//  MOB-1496 (W6): the Keystone `.scan(.foundPCZTBatch)`/`.simulateSignature` store step re-pairs +
//  validates the scanned batch (`MigrationCoordFlow.rePairedKeystoneBatch`) before storing anything —
//  any mismatch (short/long/empty) abandons the session exactly like `keystoneScanAbandoned` already
//  did for an empty batch. It then splits any note-split sentinel entry out of the re-paired batch
//  (`MigrationCoordFlow.splitKeystoneBatch`) so `storeSignedMigrationTransactions` only ever receives
//  engine-id entries; when a split WAS present, `resumeAfterKeystoneSigning` routes it to a freshly
//  pushed `MigrationNoteSplit` screen by dispatching that screen's OWN `.retryTapped` (its existing
//  `resubmitSignedNoteSplit` lane) instead of resuming the schedule/review chain immediately —
//  `pendingKeystoneSplitResume` stashes what to resume with once that screen's `.continued` fires,
//  landing on the SAME `resumeCommittedMigrationChain` helper `resumeAfterKeystoneSigning` uses
//  directly for a no-split batch. `.complete(.delegate(.migrateAnyway))` now forks on vendor:
//  software is unchanged, and Keystone proposes + PCZT-signs a batch-of-1 dust transfer through this
//  same signing machinery (`KeystoneSigningContext.dust`) before broadcasting it via the dust Sending
//  lane's existing `executeNextPendingMigrationTransfer` path (never `migrateMigrationDust`, a USK
//  composite that would re-propose from scratch).
//
//  MOB-1496 (final review R6, C-1 fix): W6's store order was backwards against the real engine —
//  `storeSignedNoteSplitPCZT` unconditionally starts a NEW run, while `storeSignedMigrationTransactions`
//  uses-or-creates the active (newest non-terminal) run; storing the schedule first let the split's
//  later store create a second run that shadowed the schedule's forever. The `.scan(.foundPCZTBatch)`/
//  `.simulateSignature` store step now stores the split FIRST (when present) — creating the run the
//  schedule store then joins — and abandons (same `keystoneScanAbandoned` semantics the re-pair-failure
//  guard already used, generalized to pop the right number of elements for either caller) if that
//  store itself fails, since nothing was persisted yet. The old `submitSignedNoteSplit` composite
//  (store-then-broadcast in one call, with no memory of a prior success) is deleted in favor of
//  `storeSignedNoteSplit`/`broadcastStoredNoteSplit`: the coordinator only ever calls the former, and
//  `resumeAfterKeystoneSigning` pushes `MigrationNoteSplit` with `splitStored: true` so its retry lane
//  only ever (re)broadcasts — idempotent by construction, unlike the old composite's retry, which
//  re-ran the by-then-already-consumed store and threw forever.
//
//  MOB-1496 (final review R6, C-1b fix — fix-wave 2): the C-1 fix closed the run-shadowing hazard but
//  left a deeper one — the engine's `record_transfer_result` prep branch (`context.rs:1299-1303`)
//  UNCONDITIONALLY overwrites the run's phase to `WaitingDenomConfirmations` once the split's
//  broadcast is recorded, clobbering the `BroadcastScheduled` phase C-1's early schedule store had
//  just set; the run then parks at `.readyToPropose` forever once the split mines
//  (`context.rs:361-378`), stranding the committed schedule. Step 0 of the fix-wave-2 report traced
//  the denom-advance guard (fires from `PreparingDenominations`/`WaitingDenomConfirmations`, never
//  `BroadcastScheduled`) and found storing the schedule right after the split's broadcast SUCCEEDS —
//  not waiting for on-chain confirmation — is the earliest point provably safe (mining cannot occur in
//  that synchronous window). The `.scan(.foundPCZTBatch)`/`.simulateSignature` store step now stores
//  ONLY the split up front when one is present, stashing the already-signed schedule entries in
//  `pendingKeystoneScheduleStore` instead of storing them immediately; `storeDeferredKeystoneSchedule`
//  runs the deferred `storeSignedMigrationTransactions` -> `recordCommittedSchedule` -> `reconcile()`
//  once `MigrationNoteSplit` reports `.delegate(.storeScheduleRequested)` — sent automatically the
//  moment its Keystone-fork broadcast (`resubmitSignedNoteSplit`) lands, and again on every subsequent
//  store-retry tap (`awaitingScheduleStore`) — succeeding flips that screen to `.confirmed` via its own
//  `.splitConfirmed` (which also clears `pendingKeystoneScheduleStore`); failing re-presents its
//  EXISTING failure sheet with the entries still stashed. No-split batches (including the Keystone
//  dust lane) are unaffected — see `PendingScheduleStore`'s doc in `MigrationCoordFlowStore.swift`.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension MigrationCoordFlow {
    func coordinatorReduce() -> Reduce<MigrationCoordFlow.State, MigrationCoordFlow.Action> {
        Reduce { state, action in
            switch action {
                // MARK: - Self: onAppear (re-entry)

            case .onAppear:
                guard state.path.isEmpty else { return .none }
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    let pathState = await reentryPathState(accountUUID: accountUUID)
                    await send(.pushNextPermissionStep(PermissionStepResult(pathState: pathState)))
                }

            case .pushNextPermissionStep(let result):
                if let pathState = result.pathState {
                    state.path.append(pathState)
                }
                return .none

                // MARK: - Entry

            case .entry(.dismissRequired):
                // Entry is the flow root: its back button has nothing to pop, it exits the flow.
                return .send(.flowFinished)

            case .entry(.delegate(.chose(let mode))):
                state.mode = mode
                migrationManager.setMigrationMode(mode)

                switch mode {
                case .immediate:
                    // Skip the Tor sheet iff the app-wide Tor setup flag is on — in that case
                    // `useTor` is implicitly `true`, persisted the same way the sheet's own confirm
                    // does (so a background send effect reads the same persisted value), and Review
                    // is pushed directly; otherwise the sheet is shown so the user can opt in
                    // explicitly. Both checks here are synchronous SDK/dependency reads, so no
                    // effect is needed.
                    if walletStorage.exportTorSetupFlag() == true {
                        migrationManager.setNetworkPrivacyOptions(true)
                        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
                    } else {
                        presentTorSheet(destination: .reviewTransfer, state: &state)
                    }
                    return .none

                case .privateScheduled:
                    state.path.append(.howItWorks(MigrationHowItWorks.State()))
                    return .none
                }

                // MARK: - HowItWorks (MOB-1478 W3, MOB-1487 round 3)

            case .path(.element(id: _, action: .howItWorks(.delegate(.continueTapped)))):
                // MOB-1494 (round 4): same Tor gate as the immediate lane — the app-wide Tor setup
                // flag skips the sheet with `useTor` implicitly on (persisted, so background sends
                // read the same value — MOB-1487's persist-fix); otherwise the toggle sheet is
                // shown and the permission chain resumes from its confirm/dismiss.
                if walletStorage.exportTorSetupFlag() == true {
                    migrationManager.setNetworkPrivacyOptions(true)
                    return .run { send in
                        await send(.pushNextPermissionStep(await nextPermissionStepResult()))
                    }
                }
                presentTorSheet(destination: .permissionChain, state: &state)
                return .none

                // MARK: - Tor bottom sheet (MOB-1478 W2)

            case .torSheet(.delegate(.gotIt)):
                return confirmTorSheet(state: &state)

            case .torSheetPresentationChanged(let isPresented):
                state.isTorSheetPresented = isPresented
                // `false` covers both an explicit "Got it" (which already ran `confirmTorSheet`
                // itself, so `pendingTorDestination` is already `nil` and this is a harmless no-op)
                // and a swipe-to-dismiss, which never routed through `.delegate(.gotIt)` at all —
                // the spec treats both identically, so this is the swipe path's own trigger.
                guard !isPresented else { return .none }
                return confirmTorSheet(state: &state)

                // MARK: - NoteSplit (re-entry root, MOB-1478 W4 — OR a MOB-1496 W6 mid-Keystone-commit push)

            case .path(.element(id: let id, action: .noteSplit(.delegate(.continued)))):
                // Forward routing never pushes `.noteSplit` for a FRESH silent split any more (that
                // runs under the TransferPlan/ReviewTransfer commit CTAs), so a flow-root `.noteSplit`
                // is always a re-entry.
                if case .noteSplit(let noteSplitState) = state.path[id: id], noteSplitState.isFlowRoot {
                    return .send(.flowFinished)
                }
                // MOB-1496 (W6): this note-split screen was instead pushed mid-Keystone-commit to
                // broadcast a signed split PCZT (`resumeAfterKeystoneSigning`) — its "Continue"
                // (reached once the broadcast lands and the SDK reports `.readyToPropose`) resumes
                // exactly the chain that would have run immediately had no split been needed, never
                // the permission-chain fallback below. The actual pop+resume is deferred to
                // `keystoneSplitResumeContinued` (see that action's doc) rather than done inline here.
                if state.pendingKeystoneSplitResume != nil {
                    return .send(.keystoneSplitResumeContinued)
                }
                // Kept defensively (the exhaustive shape this reducer already had) for any other
                // non-root, non-Keystone-split `.noteSplit` occurrence rather than deleted.
                return .run { send in
                    await send(.pushNextPermissionStep(await nextPermissionStepResult()))
                }

            case .keystoneSplitResumeContinued:
                guard let resumeContext = state.pendingKeystoneSplitResume else { return .none }
                state.pendingKeystoneSplitResume = nil
                let _ = state.path.popLast()
                return resumeCommittedMigrationChain(context: resumeContext, state: &state)

                // MOB-1496 (C-1b fix, fix-wave 2): the note-split screen's Keystone-fork broadcast
                // landed (or a previous deferred-store attempt failed and the user retried) — see
                // `storeDeferredKeystoneSchedule`'s doc for the full sequence and Step 0's citations.
            case .path(.element(id: let id, action: .noteSplit(.delegate(.storeScheduleRequested)))):
                return storeDeferredKeystoneSchedule(noteSplitId: id, state: &state)

                // The deferred store succeeded and flipped the note-split screen to `.confirmed` via
                // its OWN `.splitConfirmed` (dispatched by `storeDeferredKeystoneSchedule`) — the
                // entries are durably in the engine now, so the stash can be released. A no-op for
                // the unrelated legacy re-entry `.splitConfirmed` (driven by `stateEvents` observing
                // `.readyToPropose`), where this is already `nil`.
            case .path(.element(id: _, action: .noteSplit(.splitConfirmed))):
                state.pendingKeystoneScheduleStore = nil
                return .none

                // MARK: - BackgroundDelivery

            case .path(.element(id: _, action: .backgroundDelivery(.delegate(.continued(let backgroundAllowed))))):
                if !backgroundAllowed {
                    migrationManager.setManualDelivery(true)
                }
                return .run { send in
                    await send(.pushNextPermissionStep(await nextPermissionStepResult()))
                }

                // MARK: - Notifications

            case .path(.element(id: _, action: .notifications(.delegate(.continued)))):
                return .run { send in
                    await send(.pushNextPermissionStep(await nextPermissionStepResult()))
                }

                // MARK: - TransferPlan

            case .path(.element(id: _, action: .transferPlan(.delegate(.confirmed)))):
                guard case let .transferPlan(planState) = state.path.last else { return .none }

                // Rescheduled variant (`requiresSigning == false`): its confirm is a plain
                // acknowledgment of an already-committed reschedule (`scheduleFirstWindow()` ran
                // once already, at reschedule-initiation) — no re-sign, no terminal `.scheduled`
                // screen, straight to `.flowFinished` ("Got-it" per the spec).
                guard planState.requiresSigning else {
                    return .send(.flowFinished)
                }

                return transferPlanPostConfirmChain(variant: planState.variant, state: &state)

                // MARK: - ReviewTransfer

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.confirmed)))):
                let sendingState = MigrationSending.State(totalCount: 1)
                state.path.append(.sending(sendingState))
                return .none

                // MARK: - Keystone signing (MOB-1468)

            case .path(.element(id: _, action: .transferPlan(.delegate(.keystoneSignRequested(let pczts))))):
                state.pendingKeystoneSigning = .planCommit
                state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: pczts)))
                return .none

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.keystoneSignRequested(let pczts))))):
                state.pendingKeystoneSigning = .immediateReview
                state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: pczts)))
                return .none

            case .path(.element(id: _, action: .keystoneSign(.delegate(.getSignature)))):
                var scanState = Scan.State.initial
                scanState.checkers = [.keystoneMigrationBatchScanChecker]
                // MOB-1478 (W10): matches the design's single centered flash control (precedent:
                // `AddKeystoneHWWalletCoordFlowCoordinator` already sets `forceLibraryToHide`).
                scanState.instructions = String(localizable: .migrationKeystoneScanInstructions)
                scanState.forceLibraryToHide = true
                state.path.append(.scan(scanState))
                return .none

            case .path(.element(id: _, action: .scan(.foundPCZTBatch(let signed)))):
                guard let context = state.pendingKeystoneSigning else { return .none }

                // Empty batch, or a scan that doesn't re-pair 1:1 with the ORIGINAL unsigned batch
                // (still on the `keystoneSign` element beneath `scan` on the path): abandons the
                // signing session like a rejection (deferred pop of scan + sign back to the
                // initiating screen, context cleared) and never stores anything (no-partial-storage
                // invariant). The user re-initiates from the confirm button. MOB-1496 (W6 §2):
                // `rePairedKeystoneBatch` is the small pure re-pair-validation function — see its doc
                // for the exact mismatch table (short/long/empty batches all abandon).
                guard case let .keystoneSign(signState)? = state.path.dropLast().last,
                      let signedPczts = MigrationCoordFlow.rePairedKeystoneBatch(signed: signed, unsigned: signState.pczts),
                      let accountUUID = state.selectedWalletAccount?.id else {
                    return .send(.keystoneScanAbandoned)
                }

                // [MOB-1496] W2: the schedule that was just signed lives on the `.transferPlan`/
                // `.reviewTransfer` element still beneath `keystoneSign`+`scan` on the path (or, for
                // the dust lane, directly on `context` — see `pendingKeystoneSchedule`'s doc) — read
                // it now, before `resumeAfterKeystoneSigning` (triggered by
                // `.keystoneSigningSubmitted` below) pops back up past it.
                let schedule = pendingKeystoneSchedule(context: context, depthBelowTop: 2, state: state)
                // [MOB-1496] W6 §1: split the re-paired batch into its note-split sentinel entry
                // (present iff the run needed a split) and the schedule's own engine-id-paired
                // entries — ONLY the latter are safe to hand to `storeSignedMigrationTransactions`
                // (all-or-nothing, engine ids only; the real engine rejects a sentinel id outright —
                // the latent break this fixes).
                let (splitEntry, scheduleEntries) = MigrationCoordFlow.splitKeystoneBatch(signedPczts)

                return .run { [sdkSynchronizer, migrationManager, accountUUID, schedule, splitEntry, scheduleEntries] send in
                    guard let splitEntry else {
                        // No split: unchanged since W2 — store the schedule immediately.
                        let stored = (try? await sdkSynchronizer.storeSignedMigrationTransactions(accountUUID, scheduleEntries)) != nil
                        if stored {
                            if let schedule {
                                await migrationManager.recordCommittedSchedule(accountUUID, schedule)
                            }
                            await migrationManager.reconcile()
                        }
                        await send(.keystoneSigningSubmitted(context: context, splitPczt: nil, pendingScheduleStore: nil))
                        return
                    }
                    // Split present (MOB-1496 C-1b fix, fix-wave 2): store ONLY the split now — it
                    // creates the engine run (`storeSignedNoteSplit`/`store_signed_note_split_pczt`
                    // unconditionally starts a new one). The already-signed schedule entries are NOT
                    // stored here any more: Step 0 of the fix-wave-2 report traced the engine's phase
                    // machine and found the split's own broadcast-success record
                    // (`record_transfer_result`, `context.rs:1299-1303`) UNCONDITIONALLY overwrites the
                    // run's phase — a schedule store performed here, before the split even broadcasts,
                    // gets clobbered the instant the broadcast lands, stranding the run at
                    // `.readyToPropose` once the split mines (`context.rs:361-378`). The schedule rides
                    // along in `pendingScheduleStore` instead, resumed by
                    // `MigrationCoordFlowCoordinator.storeDeferredKeystoneSchedule` once the note-split
                    // screen's broadcast succeeds — the earliest point the trace proved safe.
                    guard (try? await sdkSynchronizer.storeSignedNoteSplit(accountUUID, splitEntry.pczt)) != nil else {
                        // Nothing was stored at all — abandon exactly like a re-pair failure: nothing
                        // to resume, same `keystoneScanAbandoned` semantics.
                        await send(.keystoneScanAbandoned)
                        return
                    }
                    let pendingScheduleStore = MigrationCoordFlow.PendingScheduleStore(
                        accountUUID: accountUUID,
                        scheduleEntries: scheduleEntries,
                        schedule: schedule
                    )
                    await send(
                        .keystoneSigningSubmitted(
                            context: context,
                            splitPczt: splitEntry.pczt,
                            pendingScheduleStore: pendingScheduleStore
                        )
                    )
                }

                // MARK: - Keystone signing (MOB-1480): simulator-only bypass

            case .path(.element(id: let id, action: .keystoneSign(.delegate(.simulateSignature)))):
                guard let context = state.pendingKeystoneSigning else { return .none }
                guard case let .keystoneSign(signState) = state.path[id: id] else { return .none }
                guard let accountUUID = state.selectedWalletAccount?.id else { return .none }

                // Simulator-only bypass: no physical device exists to scan a QR back, so the batch
                // is read straight off the already-pushed `keystoneSign` element's own state instead
                // of arriving via `.scan(.foundPCZTBatch)`. Unlike that real path (which abandons an
                // empty batch as a no-partial-storage safeguard against a failed scan), this button
                // exists purely to exercise the resume chain for manual QA, so an empty batch falls
                // back to a single fabricated placeholder rather than abandoning — the coordinator
                // never inspects PCZT contents either way. "Signing" is pretending the unsigned
                // bytes are already signed (MOB-1496 — same fabricated-data spirit as before).
                let signedPczts: [MigrationSignedTransferPczt] = signState.pczts.isEmpty
                    ? [MigrationSignedTransferPczt(id: "simulated", pczt: Data())]
                    : signState.pczts.map { MigrationSignedTransferPczt(id: $0.id, pczt: $0.pczt) }
                // [MOB-1496] W2: same schedule lookup as the real round-trip above, but the
                // simulator bypass never pushes `scan` — only `keystoneSign` sits above the
                // schedule-bearing element.
                let schedule = pendingKeystoneSchedule(context: context, depthBelowTop: 1, state: state)
                // [MOB-1496] W6 §1: same sentinel split as the real round-trip above — the fabricated
                // "simulated" placeholder id (used only when `signState.pczts` was itself empty)
                // never matches the sentinel id, so it always lands in `scheduleEntries`.
                let (splitEntry, scheduleEntries) = MigrationCoordFlow.splitKeystoneBatch(signedPczts)

                return .run { [sdkSynchronizer, migrationManager, accountUUID, schedule, splitEntry, scheduleEntries] send in
                    // Same split-first-then-defer shape + abandon-on-split-store-failure as the real
                    // round-trip above (MOB-1496 C-1b fix, fix-wave 2) — `keystoneScanAbandoned`'s pop
                    // count adapts to whichever caller reached it, so reusing it here (no `.scan` on
                    // this path) is safe.
                    guard let splitEntry else {
                        let stored = (try? await sdkSynchronizer.storeSignedMigrationTransactions(accountUUID, scheduleEntries)) != nil
                        if stored {
                            if let schedule {
                                await migrationManager.recordCommittedSchedule(accountUUID, schedule)
                            }
                            await migrationManager.reconcile()
                        }
                        await send(.keystoneSigningSubmitted(context: context, splitPczt: nil, pendingScheduleStore: nil))
                        return
                    }
                    guard (try? await sdkSynchronizer.storeSignedNoteSplit(accountUUID, splitEntry.pczt)) != nil else {
                        await send(.keystoneScanAbandoned)
                        return
                    }
                    let pendingScheduleStore = MigrationCoordFlow.PendingScheduleStore(
                        accountUUID: accountUUID,
                        scheduleEntries: scheduleEntries,
                        schedule: schedule
                    )
                    await send(
                        .keystoneSigningSubmitted(
                            context: context,
                            splitPczt: splitEntry.pczt,
                            pendingScheduleStore: pendingScheduleStore
                        )
                    )
                }

            case .keystoneSigningSubmitted(let context, let splitPczt, let pendingScheduleStore):
                return resumeAfterKeystoneSigning(
                    context: context,
                    splitPczt: splitPczt,
                    pendingScheduleStore: pendingScheduleStore,
                    state: &state
                )

            case .path(.element(id: _, action: .keystoneSign(.delegate(.rejected)))):
                // No-partial-storage invariant: nothing was stored — just pop back to the signing
                // source with its state untouched (plan/review still unsigned) and clear the
                // context. The pop is deferred to a follow-up self-action (mirrors
                // `sendNowCompleted`'s deferred pop) rather than done inline here: `.forEach(\.path,
                // action:)` still needs to deliver this SAME action to the `keystoneSign` element
                // after this case returns, and popping it first would leave `.forEach` with no
                // element to deliver to (a TCA "missing element" runtime error).
                return .send(.keystoneSignRejected)

            case .keystoneSignRejected:
                state.pendingKeystoneSigning = nil
                let _ = state.path.popLast()
                return .none

            case .keystoneScanAbandoned:
                state.pendingKeystoneSigning = nil
                // MOB-1496 (C-1 fix): as well as the real round-trip's re-pair-failure guard above
                // (`.scan` always on top there — pop 2, unchanged), this now also fires from the
                // split-store-failure branch of EITHER Keystone store effect above, including the
                // simulator bypass, which never pushes `.scan` (pop 1) — mirrors
                // `resumeAfterKeystoneSigning`'s identical "how many elements are actually on top"
                // check.
                let topElementIsScan = state.path.last?.is(\.scan) == true
                state.path.removeLast(topElementIsScan ? 2 : 1)
                return .none

                // MARK: - Sending

            case .path(.element(id: _, action: .sending(.delegate(.closed)))):
                if state.mode == .immediate {
                    migrationManager.acknowledgeComplete()
                    return .send(.flowFinished)
                }

                // MOB-1487 dust lane: this Sending sits over the complete screen ("Migrate
                // anyway") — closing it ends the flow with the same bookkeeping as "Got it".
                let hasCompleteBeneath = state.path.contains { $0.is(\.complete) }
                if hasCompleteBeneath {
                    migrationManager.acknowledgeComplete()
                    return .send(.flowFinished)
                }

                let hasStatusBeneath = state.path.contains { $0.is(\.status) }
                if hasStatusBeneath {
                    return .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] send in
                        await send(.sendNowCompleted(rows: await migrationManager.migrationTransfers(accountUUID)))
                    }
                }

                // Manual-first-transfer path: no `.status` yet on the path — push a fresh one.
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    await send(.pushHydratedStatus(await statusProgressState(accountUUID: accountUUID, isFlowRoot: false)))
                }

                // MARK: - Self: pushHydratedStatus / pushHydratedPathState / sendNowCompleted

            case .pushHydratedStatus(let statusState):
                state.path.append(.status(statusState))
                return .none

            case .pushHydratedPathState(let pathState):
                state.path.append(pathState)
                return .none

            case .sendNowCompleted(let rows):
                // Pop the Sending element and refresh the `.status` element now on top.
                let _ = state.path.popLast()
                guard let statusId = state.path.ids.last, case .status(var statusState) = state.path.last else {
                    return .none
                }
                statusState.rows = IdentifiedArrayOf(uniqueElements: rows)
                state.path[id: statusId] = .status(statusState)
                return .none

                // MARK: - Status

            case .path(.element(id: _, action: .status(.delegate(.sendNow)))):
                // MOB-1496 (fix-wave, review MINOR-5): `totalCount` used to be driven by the
                // overdue row count — vestigial once `MigrationSendingStore` stopped looping on it
                // (W5, ZIP-0318 MUST: at most one broadcast per screen regardless of how many
                // transfers are overdue). The cap is the contract now, so this no longer needs to
                // read `migrationTransfers` at all.
                return .run { send in
                    await send(.pushHydratedPathState(.sending(MigrationSending.State(totalCount: 1))))
                }

            case .path(.element(id: let id, action: .status(.delegate(.reschedule)))):
                if case .status(var statusState) = state.path[id: id] {
                    statusState.isRescheduling = true
                    state.path[id: id] = .status(statusState)
                }
                guard let accountUUID = state.selectedWalletAccount?.id else { return .none }
                // MOB-1478 (W7): lands `.rescheduleCompleted` on the SAME status element instead of
                // pushing a fresh `TransferPlan` — `MigrationStatus` itself now owns the
                // post-reschedule confirmation presentation. MOB-1496: `rescheduleStalledMigrationTransfer`
                // is replaced by `rescheduleOverdueMigrationTransfer` — its returned proposal isn't
                // consumed here either (never was); the coordinator re-reads fresh rows/summary
                // straight after, same as before.
                return .run { [migrationBGScheduler, sdkSynchronizer, migrationManager, accountUUID, id] send in
                    _ = try? await sdkSynchronizer.rescheduleOverdueMigrationTransfer(accountUUID)
                    await migrationBGScheduler.scheduleFirstWindow()
                    let rows = await migrationManager.migrationTransfers(accountUUID)
                    let totalDurationHours = await migrationManager.migrationSummary(accountUUID).estimatedDurationHours
                    await send(
                        .path(
                            .element(
                                id: id,
                                action: .status(.rescheduleCompleted(rows: rows, totalDurationHours: totalDurationHours))
                            )
                        )
                    )
                }

                // MARK: - Recovery

            case .path(.element(id: _, action: .recovery(.delegate(.recreate)))):
                guard let accountUUID = state.selectedWalletAccount?.id else { return .none }
                // `includeResidual: false` by design, same as the initial plan proposal
                // (`MigrationTransferPlanStore.onAppear`) — the re-created plan doesn't fold the
                // dust remainder in either; it stays on the separate post-completion "Migrate
                // anyway" lane.
                return .run { [sdkSynchronizer, migrationManager, accountUUID] send in
                    let restarted = try? await sdkSynchronizer.restartCurrentMigrationStep(accountUUID, includeResidual: false)
                    if restarted != nil {
                        // [MOB-1496] W2: reconcile so the fresh restart's state transition (e.g.
                        // off `.requiresAttention`) is observed promptly. The actual schedule
                        // commit — and its own reconcile — happens later, when this fresh plan is
                        // signed+stored (`MigrationTransferPlanStore`'s `.confirmTapped`, which this
                        // re-created plan funnels through unchanged).
                        await migrationManager.reconcile()
                    }
                    // [MOB-1496] R8-T1 (S3): no silent empty-schedule fallback on a restart
                    // failure — leave `injectedSchedule` nil so the pushed screen's own `onAppear`
                    // falls through to a fresh `proposeMigrationTransfers` attempt (the same path a
                    // first-run `.scheduled` plan takes: `state.injectedSchedule == nil` and
                    // `state.rows.isEmpty`) and surfaces ITS OWN propose-failure sheet
                    // (`failureReason == .propose`, Retry re-proposes) if that fails too.
                    // `MigrationRecovery` (the screen this action originates from) has no failure
                    // affordance of its own to route into — see this task's report for why this
                    // fallthrough was chosen over adding one.
                    let planState = recreatedPlanState(schedule: restarted)
                    await send(.pushHydratedPathState(.transferPlan(planState)))
                }

                // MARK: - Flow-root closes / terminal delegates -> .flowFinished

                // MOB-1487 dust lane: "Migrate anyway" sweeps the remainder through the Sending
                // screen pushed over the complete screen. MOB-1494: the copy is unified
                // ("migrated" everywhere) — `isDustLane` only selects the dust-sweep execution.
                // MOB-1496 (W6 §3): `migrateMigrationDust` (the software lane below) is a USK
                // composite — a Keystone account has no USK, so it forks here into a dedicated
                // propose -> PCZT-sign -> store -> execute lane instead, using the SAME house vendor
                // check `MigrationTransferPlan`/`MigrationReviewTransfer`'s `confirmTapped` already
                // use. Software is byte-for-byte unchanged below.
            case .path(.element(id: _, action: .complete(.delegate(.migrateAnyway)))):
                guard let account = state.selectedWalletAccount else { return .none }

                guard account.vendor != WalletAccount.Vendor.keystone else {
                    return .run { [sdkSynchronizer, accountUUID = account.id] send in
                        let schedule = (try? await sdkSynchronizer.proposeMigrationTransfers(accountUUID, true))
                            ?? MigrationSchedule(transfers: [], estimatedDurationHours: 0)
                        guard !schedule.transfers.isEmpty,
                              let pczts = try? await sdkSynchronizer.proposeMigrationPCZTs(accountUUID, schedule),
                              !pczts.isEmpty else {
                            // Below-threshold (or a propose/PCZT failure): today's existing
                            // below-threshold failure UX — the Keystone short-circuit inside
                            // `MigrationSendingStore.executeNextTransfer`'s dust branch reports it
                            // via the same failure sheet every other dust failure already uses.
                            await send(.pushHydratedPathState(.sending(MigrationSending.State(totalCount: 1, isDustLane: true))))
                            return
                        }
                        await send(.keystoneDustPCZTsProposed(schedule: schedule, pczts: pczts))
                    }
                }

                var sendingState = MigrationSending.State(totalCount: 1)
                sendingState.isDustLane = true
                state.path.append(.sending(sendingState))
                return .none

            case .keystoneDustPCZTsProposed(let schedule, let pczts):
                // MOB-1496 (W6 §3): batch-of-1, no sentinel (there is no split in the dust lane) —
                // the existing Keystone signing context/machinery (scan -> re-pair -> store) handles
                // it uniformly alongside the schedule/review lanes.
                state.pendingKeystoneSigning = .dust(schedule)
                state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: pczts)))
                return .none

            case .path(.element(id: _, action: .complete(.delegate(.done)))):
                migrationManager.acknowledgeComplete()
                return .send(.flowFinished)

            case .path(.element(id: _, action: .status(.delegate(.done)))),
                 .path(.element(id: _, action: .scheduled(.delegate(.done)))),
                 .path(.element(id: _, action: .recovery(.delegate(.close)))),
                 .path(.element(id: _, action: .reviewTransfer(.delegate(.closed)))):
                return .send(.flowFinished)

            default: return .none
            }
        }
    }

    // MARK: - TransferPlan: shared post-confirm chain (software `.confirmed` + Keystone `planCommit`)

    /// Scheduled/recreated push `.scheduled`; manual pushes `.sending` (totalCount 1, current
    /// network-privacy options) — then schedules the first background window either way. Shared by
    /// the software `TransferPlan.delegate(.confirmed)` row and the Keystone `planCommit` resume
    /// (`resumeAfterKeystoneSigning`), which both reach this point with a signed+stored schedule
    /// (and, when needed, an already-signed+submitted note split — MOB-1478 W4).
    private func transferPlanPostConfirmChain(
        variant: MigrationTransferPlan.State.Variant,
        state: inout MigrationCoordFlow.State
    ) -> Effect<MigrationCoordFlow.Action> {
        switch variant {
        case .scheduled, .recreated:
            state.path.append(.scheduled(MigrationScheduled.State()))
        case .manual:
            let sendingState = MigrationSending.State(totalCount: 1)
            state.path.append(.sending(sendingState))
        }
        return .run { [migrationBGScheduler] _ in await migrationBGScheduler.scheduleFirstWindow() }
    }

    // MARK: - Keystone signing (MOB-1468): resume after store

    /// Pops back to the signing-source element and either resumes whichever chain `context`
    /// represents (no split) or routes a signed split PCZT to the note-split progress phase first
    /// (MOB-1496 W6):
    /// - `.planCommit`/`.immediateReview`/`.dust` with `splitPczt == nil`: identical to before —
    ///   `resumeCommittedMigrationChain(context:state:)` proceeds straight to the post-commit screen,
    ///   mirroring how the equivalent software `.confirmed` row would proceed.
    /// - `splitPczt != nil`: a note-split sentinel rode the batch — pushes `MigrationNoteSplit`
    ///   carrying the signed PCZT the SAME way the existing Keystone resubmit lane receives one
    ///   (`State.signedNoteSplitPczt`), WITH `splitStored: true` (MOB-1496 C-1 fix: the store effect
    ///   above already called `storeSignedNoteSplit` before this ever runs), then dispatches that
    ///   screen's OWN `.retryTapped` so its existing `resubmitSignedNoteSplit` effect
    ///   (`stopSyncBeforeMigrationBroadcast()` -> `broadcastStoredNoteSplit(account, options)`, no
    ///   re-store since `splitStored` is already `true`) broadcasts it with the existing
    ///   success/failure/retry UX — no new UI, no duplicated broadcast logic.
    ///   `pendingKeystoneSplitResume` stashes `context` so that screen's own `.continued` can land on
    ///   `resumeCommittedMigrationChain` too, once the broadcast is confirmed. MOB-1496 (C-1b fix,
    ///   fix-wave 2): `pendingScheduleStore` (non-`nil` exactly when `splitPczt` is) stashes into
    ///   `pendingKeystoneScheduleStore` alongside it — the schedule store itself is deferred to
    ///   `storeDeferredKeystoneSchedule`, triggered once that screen's broadcast succeeds.
    ///
    /// MOB-1480: how much to pop depends on which caller reached here. The real QR round-trip
    /// pushes `scan` on top of `keystoneSign` (2 elements to unwind back to the signing source); the
    /// simulator-only bypass (`keystoneSign(.delegate(.simulateSignature))`) never pushes `scan` at
    /// all (1 element to unwind). Rather than trust the caller, this reads the actual top of the
    /// path — `.scan` on top means the real round-trip ran (unchanged behavior, still always finds
    /// `.scan` there), anything else means the bypass ran.
    ///
    /// Clears `pendingKeystoneSigning` in every case.
    private func resumeAfterKeystoneSigning(
        context: MigrationCoordFlow.KeystoneSigningContext,
        splitPczt: Data?,
        pendingScheduleStore: MigrationCoordFlow.PendingScheduleStore?,
        state: inout MigrationCoordFlow.State
    ) -> Effect<MigrationCoordFlow.Action> {
        state.pendingKeystoneSigning = nil
        let topElementIsScan = state.path.last?.is(\.scan) == true
        state.path.removeLast(topElementIsScan ? 2 : 1)

        if let splitPczt {
            state.pendingKeystoneSplitResume = context
            state.pendingKeystoneScheduleStore = pendingScheduleStore
            state.path.append(
                .noteSplit(
                    MigrationNoteSplit.State(
                        phase: .splitting,
                        isFlowRoot: false,
                        signedNoteSplitPczt: splitPczt,
                        // MOB-1496 (C-1 fix): the store effect above already stored this split (it
                        // had to, to create the run the schedule store joined) — this screen only
                        // ever needs to (re)broadcast it, never re-store.
                        splitStored: true
                    )
                )
            )
            guard let newId = state.path.ids.last else { return .none }
            return .send(.path(.element(id: newId, action: .noteSplit(.retryTapped))))
        }

        return resumeCommittedMigrationChain(context: context, state: &state)
    }

    /// MOB-1496 (C-1b fix, fix-wave 2): runs the schedule store the batch-commit step deferred until
    /// the Keystone split's broadcast landed — see this file's header comment and Step 0 of the
    /// fix-wave-2 report for the engine phase-machine citations this order is built to survive.
    /// Triggered by the note-split screen's `.delegate(.storeScheduleRequested)`, sent automatically
    /// the instant its broadcast succeeds and again on every subsequent store-retry tap (a store
    /// failure never re-signs or re-broadcasts the already-safe split — only the store itself
    /// retries, per `MigrationNoteSplit.State.awaitingScheduleStore`). On success, flips that screen
    /// to `.confirmed` via its own `.splitConfirmed` (which also releases `pendingKeystoneScheduleStore`
    /// — see that case above); on failure, re-presents its EXISTING failure sheet
    /// (`.scheduleStoreFailed`) with the entries still stashed for the next retry. A no-op if nothing
    /// is stashed (defensive — should not happen for a live `.storeScheduleRequested` sender).
    private func storeDeferredKeystoneSchedule(
        noteSplitId: StackElementID,
        state: inout MigrationCoordFlow.State
    ) -> Effect<MigrationCoordFlow.Action> {
        guard let pending = state.pendingKeystoneScheduleStore else { return .none }
        return .run { [sdkSynchronizer, migrationManager, pending, noteSplitId] send in
            let stored = (try? await sdkSynchronizer.storeSignedMigrationTransactions(pending.accountUUID, pending.scheduleEntries)) != nil
            guard stored else {
                await send(.path(.element(id: noteSplitId, action: .noteSplit(.scheduleStoreFailed))))
                return
            }
            if let schedule = pending.schedule {
                await migrationManager.recordCommittedSchedule(pending.accountUUID, schedule)
            }
            await migrationManager.reconcile()
            await send(.path(.element(id: noteSplitId, action: .noteSplit(.splitConfirmed))))
        }
    }

    /// MOB-1496 (W6): the shared "schedule/dust transfer is fully committed and ready to proceed"
    /// resume — reused by `resumeAfterKeystoneSigning` directly (no-split batch) and by the
    /// note-split screen's own `.delegate(.continued)` (split batch, once its broadcast is
    /// confirmed), so both land on the identical post-commit routing the software path's `.confirmed`
    /// row would reach.
    private func resumeCommittedMigrationChain(
        context: MigrationCoordFlow.KeystoneSigningContext,
        state: inout MigrationCoordFlow.State
    ) -> Effect<MigrationCoordFlow.Action> {
        switch context {
        case .planCommit:
            guard case let .transferPlan(planState) = state.path.last else { return .none }
            return transferPlanPostConfirmChain(variant: planState.variant, state: &state)

        case .immediateReview:
            let sendingState = MigrationSending.State(totalCount: 1)
            state.path.append(.sending(sendingState))
            return .none

        case .dust:
            // MOB-1496 (W6 §3): the transfer is already proposed/signed/stored by this point —
            // execute via the dust Sending lane's EXISTING `executeNextPendingMigrationTransfer`
            // path (`isDustLane: false`), never `migrateMigrationDust` (a USK composite that would
            // re-propose and re-store from scratch).
            let sendingState = MigrationSending.State(totalCount: 1, isDustLane: false)
            state.path.append(.sending(sendingState))
            return .none
        }
    }

    // MARK: - MOB-1496 (W2): schedule lookup for the Keystone store-success write point

    /// Locates the `MigrationSchedule` that was signed for `context`, read off the `.transferPlan`/
    /// `.reviewTransfer` element still beneath `keystoneSign` (+ `scan`, on the real round-trip) at
    /// the point the signed PCZTs are about to be stored — `depthBelowTop` is how many elements sit
    /// above it on the path (2 for the real scan round-trip: `scan` + `keystoneSign`; 1 for the
    /// simulator bypass, which never pushes `scan`) — mirrors how `signState.pczts` above reads the
    /// unsigned batch off the same stack position. `nil` when that element carries no schedule of
    /// its own (a fixture/test state that never populated one) — the caller then skips
    /// `recordCommittedSchedule` rather than persisting nothing. MOB-1496 (W6 §3): `.dust` carries
    /// its schedule directly on the context instead — the coordinator proposed it itself
    /// (`.keystoneDustPCZTsProposed`), so there is no path element to peek at all.
    private func pendingKeystoneSchedule(
        context: MigrationCoordFlow.KeystoneSigningContext,
        depthBelowTop: Int,
        state: MigrationCoordFlow.State
    ) -> MigrationSchedule? {
        switch context {
        case .planCommit:
            guard case let .transferPlan(planState)? = state.path.dropLast(depthBelowTop).last else { return nil }
            return planState.schedule

        case .immediateReview:
            guard case let .reviewTransfer(reviewState)? = state.path.dropLast(depthBelowTop).last else { return nil }
            return reviewState.schedule

        case .dust(let schedule):
            return schedule
        }
    }

    // MARK: - MOB-1496 (W6 §1/§2): Keystone batch re-pairing + sentinel split

    /// The sentinel id `MigrationTransferPlanStore`/`MigrationReviewTransferStore`'s
    /// `requestKeystoneSignature` wrap the note-split PCZT under, when a batch needs one (a
    /// typed-payload mismatch between the split PCZT — raw `Data` — and the schedule's own
    /// `MigrationUnsignedTransferPczt`-typed entries; see those methods' docs). Must match the
    /// literal both producer sites use.
    static let keystoneNoteSplitSentinelId = "note-split"

    /// MOB-1496 (W6 §2): re-pairs a scanned Keystone batch's signed bytes
    /// (`parseMigrationPCZTBatch`'s order-preserved `[Data]`) against the ORIGINAL unsigned batch's
    /// ids, by position — `nil` on ANY mismatch (a short batch, a long batch, or an empty parse),
    /// since a mismatched count means the scan can't be safely re-paired with the ids the firmware
    /// was asked to sign. The caller then abandons the whole session (`keystoneScanAbandoned`
    /// semantics — nothing stored) exactly as an empty/rejected scan already did.
    static func rePairedKeystoneBatch(
        signed: [Data],
        unsigned: [MigrationUnsignedTransferPczt]
    ) -> [MigrationSignedTransferPczt]? {
        guard !signed.isEmpty, signed.count == unsigned.count else { return nil }
        return zip(unsigned, signed).map { MigrationSignedTransferPczt(id: $0.id, pczt: $1) }
    }

    /// MOB-1496 (W6 §1): splits a re-paired batch into its note-split sentinel entry (present iff the
    /// run needed a split) and the schedule's own engine-id-paired entries — ONLY the schedule
    /// entries are safe to hand to `storeSignedMigrationTransactions` (all-or-nothing, engine ids
    /// only; the real engine rejects a sentinel id outright — the latent break this fixes).
    static func splitKeystoneBatch(
        _ paired: [MigrationSignedTransferPczt]
    ) -> (splitEntry: MigrationSignedTransferPczt?, scheduleEntries: [MigrationSignedTransferPczt]) {
        let splitEntry = paired.first { $0.id == keystoneNoteSplitSentinelId }
        let scheduleEntries = paired.filter { $0.id != keystoneNoteSplitSentinelId }
        return (splitEntry, scheduleEntries)
    }

    // MARK: - Tor bottom sheet (MOB-1478 W2): present + confirm/dismiss

    /// Presents the Tor sheet fresh (toggle reset to its default-ON state — MOB-1494) and stashes
    /// `destination` to resume once the user confirms or swipes the sheet away. The immediate
    /// destination gets the "your full balance" body variant; the scheduled one "your balance".
    private func presentTorSheet(
        destination: MigrationCoordFlow.PendingTorDestination,
        state: inout MigrationCoordFlow.State
    ) {
        state.torSheetState = MigrationTorSheet.State(usesFullBalanceCopy: destination == .reviewTransfer)
        state.pendingTorDestination = destination
        state.isTorSheetPresented = true
    }

    /// "Got it" and swipe-to-dismiss both land here (the spec treats them identically): persists
    /// whatever `isTorOn` is currently showing exactly as `MigrationNetworkPrivacyStore` did, dismisses
    /// the sheet, then resumes the stashed destination. A no-op if nothing is pending (defensive
    /// against a stray `torSheetPresentationChanged(false)` after "Got it" already handled it).
    private func confirmTorSheet(state: inout MigrationCoordFlow.State) -> Effect<MigrationCoordFlow.Action> {
        guard let destination = state.pendingTorDestination else { return .none }
        state.pendingTorDestination = nil
        state.isTorSheetPresented = false

        migrationManager.setNetworkPrivacyOptions(state.torSheetState.isTorOn)

        switch destination {
        case .reviewTransfer:
            state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
            return .none

        case .permissionChain:
            return .run { send in
                await send(.pushNextPermissionStep(await nextPermissionStepResult()))
            }
        }
    }

    // MARK: - Re-entry

    /// Maps `manager.reentryRoute()` onto the flow-root screen State to append, hydrated from SDK
    /// members per the MOB-1466 spec's re-entry table. `.entry` appends nothing (Entry is the
    /// coordinator's own root screen, already showing).
    private func reentryPathState(accountUUID: AccountUUID?) async -> MigrationCoordFlow.Path.State? {
        switch await migrationManager.reentryRoute() {
        case .recovery(let isExpired):
            return .recovery(await recoveryState(accountUUID: accountUUID, isExpired: isExpired, isFlowRoot: true))

        case .statusResume:
            return .status(await statusResumeState(accountUUID: accountUUID, isFlowRoot: true))

        case .statusProgress:
            return .status(await statusProgressState(accountUUID: accountUUID, isFlowRoot: true))

        case .complete:
            return .complete(await completeState(accountUUID: accountUUID, isFlowRoot: true))

        case .noteSplitProgress:
            return .noteSplit(MigrationNoteSplit.State(phase: .splitting, isFlowRoot: true))

        case .reviewManual(let step, let total):
            return .reviewTransfer(await reviewManualState(accountUUID: accountUUID, step: step, total: total, isFlowRoot: true))

        case .entry:
            return nil
        }
    }

    // MARK: - Permission-step routing

    /// Shared helper (used after How This Works and each permission screen's continue/skip):
    /// computes the next needed screen in order — `backgroundDelivery` iff background refresh isn't
    /// `.available` -> `notifications` iff authorization is still `.notDetermined` (granted/denied
    /// both skip, per §5 S4) -> `transferPlan`. MOB-1478 (W2): Tor resolution no longer lives in
    /// this chain. MOB-1487 (round 3): there is no gate left to run, either — `useTor` is force-set
    /// and persisted unconditionally immediately before this is called, from How This Works.
    private func nextPermissionStepResult() async -> MigrationCoordFlow.PermissionStepResult {
        if await migrationBGScheduler.backgroundRefreshStatus() != .available {
            return MigrationCoordFlow.PermissionStepResult(pathState: .backgroundDelivery(MigrationBackgroundDelivery.State()))
        }

        if await userNotifications.authorizationStatus() == .notDetermined {
            // MOB-1478 (W8): mirrors `freshPlanVariant()`'s ternary — today `.manual` was
            // unreachable since this always defaulted to `.scheduled`.
            let variant: MigrationNotifications.State.Variant = migrationManager.isManualDelivery() ? .manual : .scheduled
            return MigrationCoordFlow.PermissionStepResult(pathState: .notifications(MigrationNotifications.State(variant: variant)))
        }

        return MigrationCoordFlow.PermissionStepResult(pathState: .transferPlan(MigrationTransferPlan.State(variant: freshPlanVariant())))
    }

    /// Fresh-entry plan variant: manual delivery (background delivery declined) shows the manual
    /// copy and its confirm sends the first transfer now (§6.3); otherwise the scheduled variant.
    private func freshPlanVariant() -> MigrationTransferPlan.State.Variant {
        migrationManager.isManualDelivery() ? .manual : .scheduled
    }

    // MARK: - Recovery: TransferPlan hydration

    /// Recovery `.recreate`'s follow-up plan screen: `restartCurrentMigrationStep()` returns a
    /// fresh `MigrationSchedule`, injected via `injectedSchedule` so the screen's own `onAppear`
    /// populates rows (no coordinator-side duplication of that row-building logic). This variant
    /// DOES sign — `requiresSigning` stays at its default `true`.
    private func recreatedPlanState(schedule: MigrationSchedule?) -> MigrationTransferPlan.State {
        var state = MigrationTransferPlan.State(variant: .recreated)
        state.injectedSchedule = schedule
        return state
    }

    private func recoveryState(accountUUID: AccountUUID?, isExpired: Bool, isFlowRoot: Bool) async -> MigrationRecovery.State {
        let rows = await migrationManager.migrationTransfers(accountUUID)
        let (first, last) = expiredOrInvalidBounds(rows: rows)
        return MigrationRecovery.State(
            reason: isExpired ? .expired : .notesSpent,
            firstTransfer: first,
            lastTransfer: last,
            isFlowRoot: isFlowRoot
        )
    }

    private func statusResumeState(accountUUID: AccountUUID?, isFlowRoot: Bool) async -> MigrationStatus.State {
        let rows = await migrationManager.migrationTransfers(accountUUID)
        let summary = await migrationManager.migrationSummary(accountUUID)
        let stalledRow = rows.first { $0.status == MigrationTransferRow.Status.overdue }
        var state = MigrationStatus.State(
            presentation: .resume,
            rows: IdentifiedArrayOf(uniqueElements: rows),
            totalDurationHours: summary.estimatedDurationHours,
            stalledNumber: (stalledRow?.index ?? 0) + 1,
            stalledHoursAgo: stalledRow?.hoursFromNow ?? 0,
            isFlowRoot: isFlowRoot
        )
        state.isSendNowDisabled = await migrationManager.sendGate() != MigrationSendGate.allowed
        // [MOB-1496] W3 review fix C: hydrated here the same way `isSendNowDisabled` is, right
        // above — otherwise the footer briefly reads "about 0 mins" for a frame at re-entry, before
        // `onAppear`'s own `.statusLoaded` lands (`.resume` is the only presentation that renders
        // it). Same shared formula `MigrationStatusStore.loadStatus` uses, so the two can't drift.
        state.syncPrivacyBufferMinutes = MigrationStatus.syncPrivacyBufferMinutes(
            from: sdkSynchronizer.migrationPrivacySyncBufferDuration()
        )
        return state
    }

    private func statusProgressState(accountUUID: AccountUUID?, isFlowRoot: Bool) async -> MigrationStatus.State {
        let rows = await migrationManager.migrationTransfers(accountUUID)
        let summary = await migrationManager.migrationSummary(accountUUID)
        var state = MigrationStatus.State(
            presentation: .progress,
            rows: IdentifiedArrayOf(uniqueElements: rows),
            totalDurationHours: summary.estimatedDurationHours,
            isFlowRoot: isFlowRoot
        )
        state.isSendNowDisabled = await migrationManager.sendGate() != MigrationSendGate.allowed
        // [MOB-1496] W3 review fix C: see `statusResumeState`'s twin hydration above — this
        // presentation doesn't render the footer today, but hydrating both builders identically
        // (matching `isSendNowDisabled`'s own precedent) keeps them from drifting if that changes.
        state.syncPrivacyBufferMinutes = MigrationStatus.syncPrivacyBufferMinutes(
            from: sdkSynchronizer.migrationPrivacySyncBufferDuration()
        )
        return state
    }

    private func completeState(accountUUID: AccountUUID?, isFlowRoot: Bool) async -> MigrationComplete.State {
        let summary = await migrationManager.migrationSummary(accountUUID)
        return MigrationComplete.State(
            totalTransferred: summary.transferred,
            dust: summary.dust,
            transfersSent: summary.transfersSent,
            transfersTotal: summary.transfersTotal,
            durationHours: summary.estimatedDurationHours,
            isFlowRoot: isFlowRoot,
            // MOB-1487: a previously locked remainder re-enters on the locked confirmation
            // instead of re-offering resolution (offered/none derive from `dust` otherwise).
            dustResolution: migrationManager.isMigrationDustLocked()
                ? MigrationComplete.State.DustResolution.locked
                : nil
        )
    }

    private func reviewManualState(accountUUID: AccountUUID?, step: Int, total: Int, isFlowRoot: Bool) async -> MigrationReviewTransfer.State {
        let rows = await migrationManager.migrationTransfers(accountUUID)
        let nextRow = rows.first { $0.status == MigrationTransferRow.Status.active }
            ?? rows.first { $0.status == MigrationTransferRow.Status.overdue }
        return MigrationReviewTransfer.State(
            mode: .manualStep(number: step, total: total),
            amount: nextRow?.amount ?? Zatoshi.zero,
            // Standard ZIP-317 marginal fee (`MigrationReviewTransfer.State.standardFee`'s value —
            // that constant is `fileprivate` to its own file, so it's mirrored here literally).
            fee: Zatoshi(100_000),
            isFlowRoot: isFlowRoot
        )
    }

    /// 1-based `(first, last)` bounds among rows flagged `.expired` or `.invalid`; falls back to
    /// `(1, total)` when none match (mirrors `MigrationDerivations.expiredBounds`'s fallback shape).
    private func expiredOrInvalidBounds(rows: [MigrationTransferRow]) -> (first: Int, last: Int) {
        let flaggedIndexes = rows
            .filter { $0.status == MigrationTransferRow.Status.expired || $0.status == MigrationTransferRow.Status.invalid }
            .map { $0.index + 1 }

        guard let first = flaggedIndexes.min(), let last = flaggedIndexes.max() else {
            return (1, rows.count)
        }

        return (first, last)
    }
}
