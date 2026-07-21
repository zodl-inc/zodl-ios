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
//  MOB-1496 (R8-T2, remediation round 8): three fixes to the Keystone-coordinator cluster, confirmed
//  by an adversarial whole-PR review. #20 (cleanup, done first): the real `.scan(.foundPCZTBatch)`
//  store effect and the `.simulateSignature` bypass's were token-identical twins — two prior ordering
//  fixes (C-1/C-1b, above) each had to be applied to both in lockstep. Extracted into the single
//  `storeKeystoneSignedBatch` helper both now call, so a future ordering change has one call site
//  instead of two to fix. #5: inside that helper, the no-split branch fired `.keystoneSigningSubmitted`
//  (-> terminal "Migration Scheduled" screen, `scheduleFirstWindow()`) UNCONDITIONALLY — even when
//  `storeSignedMigrationTransactions` itself threw, the thrown error was discarded into a bare `Bool`
//  two lines up. Success bookkeeping now fires only on an actual successful store; a failure abandons
//  the session instead (`keystoneScanAbandoned` semantics), the same honest-failure surface the
//  split-store-failure branch already used below it — `MigrationNoteSplit`'s store-only retry
//  affordance was investigated and rejected as the reuse target for the no-split case (structurally
//  split-specific; see `storeKeystoneSignedBatch`'s doc). #14: `sendNowCompleted` popped the path
//  unconditionally before checking anything — the Sending success screen's Close button stays enabled
//  during its own async close effect, so a double-tap queued two `.sendNowCompleted` deliveries and
//  the second one popped the `.status` element the first had already landed on, dumping the user out
//  to Entry mid-run. It now pops only when the top element is still `.sending`.
//
//  MOB-1496 (final engine, plural preps): the SDK's singular Keystone note-split pair
//  (`createUnsignedNoteSplitPCZT: Data` / `storeSignedNoteSplitPCZT`) is replaced by a plural one —
//  `createUnsignedNoteSplitPCZTs -> [MigrationUnsignedTransferPczt]` / `storeSignedNoteSplitPCZTs` —
//  because the final engine builds N preparation transactions, not one split transaction (empty
//  array = none needed). `keystoneNoteSplitSentinelId` (one fabricated id) becomes
//  `keystoneNoteSplitSentinelPrefix`: each prep entry rides the batch as `prefix + <engine id>`
//  (a genuine per-transaction id the engine itself issues now, not a fabricated placeholder).
//  `splitKeystoneBatch` partitions by prefix instead of exact match, strips the prefix back off
//  every prep entry, and returns `prepEntries: [MigrationSignedTransferPczt]` (was
//  `splitEntry: MigrationSignedTransferPczt?`) alongside `scheduleEntries`; `storeKeystoneSignedBatch`
//  keys its no-prep branch off `prepEntries.isEmpty` and stores the whole array via
//  `storeSignedNoteSplits`. `.keystoneSigningSubmitted`'s `splitPczt: Data?` becomes
//  `signedPreps: [MigrationSignedTransferPczt]?` (nil = no preps, kept Optional so the no-prep branch
//  stays explicit) end to end through `resumeAfterKeystoneSigning` into `MigrationNoteSplit.State`.
//  `MigrationCommitPipeline.proposeKeystoneBatch` folds the propose unconditionally now (no more
//  `mode == .scheduled` gate before consulting a split) — see two engine facts that drove this: (1)
//  the immediate flag only rewrites transfer heights, so an immediate-mode batch can carry preps too
//  (the v1 "immediate is structurally split-free" premise is obsolete); (2) the run is created at
//  PCZT-BUILD time (`createUnsignedNoteSplitPCZTs`/`createUnsignedMigrationTransferPCZTs`), not by
//  either store call, superseding the C-1/C-1b narrative above insofar as it claimed the STORE was
//  run-creating — the store ordering itself (preps before schedule) is UNCHANGED, since C-1b's
//  phase-machine reasoning (a prep's broadcast-success record overwriting the run's phase) is
//  independent of when the run was created. Fact (2) also means a Keystone ceremony abandoned after
//  its batch was proposed leaves a stray non-terminal run that the engine will silently resume
//  (serving stale, already-superseded PCZTs) on the next attempt unless explicitly cancelled — see
//  `.keystoneScanAbandoned`'s abandon-reconciliation hook and `RootInitialization`'s external-teardown
//  twin for the fire-and-forget `restartCurrentMigrationStep` cancel this requires.
//
//  MOB-1497: the Tor-choice RESOLUTION points — the Tor sheet's confirm (`confirmTorSheet`, both
//
//  MOB-1497 (T1): the Tor-choice RESOLUTION points — the Tor sheet's confirm (`confirmTorSheet`, both
//  destinations) and the sheet-skipped app-wide-Tor-on shortcuts (Entry's `.immediate` case and How
//  This Works' `.continueTapped`, both lanes) — now also call `migrationManager.formNetworkSnapshot`
//  right after the Tor choice persists, forming the run's provisional network snapshot at the same
//  moment the choice is made rather than later at the first broadcast-bearing read. See
//  `MigrationManagerLiveKey.swift`'s header doc for the full snapshot-lifecycle change this is one
//  half of (the other half — `clearProvisionalNetworkSnapshot` at flow teardown — lives in
//  `RootCoordinator.swift`, since that is where `Root` actually pops `migrationCoordFlow`). R9-T3:
//  this "persists, then forms" ordering describes the shortcuts' NON-CUSTOM outcome specifically —
//  see the R9-T3 paragraph below for the identity-custom detour finding 1 added, which persists
//  nothing and forms only inside the sheet it presents instead.
//
//  MOB-1497 (T2 — sheet UX for R2/R3/R11/R12/R13): forming moves again, from confirm to PRESENTATION:
//  - `presentTorSheet` (the old synchronous state-writer) is replaced by the async `torSheetState
//    (usesFullBalanceCopy:accountUUID:)`, called from BOTH sheet-presentation sites (Entry `.immediate`'s flag-off branch,
//    How This Works `.continueTapped`'s flag-off branch). It calls `formNetworkSnapshot` itself (T1's
//    per-presentation re-form-when-provisional rule now doubles as the per-presentation re-roll — a
//    fresh sheet always shows a fresh roll, "correct by construction"), then reads the result back via
//    the new `migrationManager.networkSnapshot` (a non-forming peek) to thread `broadcastEndpoint.host`
//    and identity-custom classification (from the snapshot's OWN `syncProvider` — never re-derived)
//    into `MigrationTorSheet.State`, dispatched via the new `torSheetStateReady` action.
//  - `confirmTorSheet` no longer calls `formNetworkSnapshot` at all — presentation already formed the
//    snapshot the user was shown, and confirm must not re-roll it out from under them. It calls the
//    new `migrationManager.confirmProvisionalTorChoice(account, isTorOn)` instead (skipped for an
//    identity-custom confirm, which has no toggle value to persist that way — R2 forced `useTor` false
//    at forming already); `setNetworkPrivacyOptions` was originally unconditional here too — R9-T3
//    (finding 6) gated it behind the SAME `!isCustomServer` check, so the custom confirm now persists
//    neither (see `confirmTorSheet`'s own doc for why).
//  - The sheet-SKIPPED shortcuts keep forming exactly where they did in T1 (unchanged trigger point),
//    but now ALSO thread the formed host into the pushed destination's `broadcastDisclosureHost`
//    (R13, for the sheet-skipped provider users who never see the sheet's own disclosure line) via
//    `reviewTransferImmediateState`/`nextPermissionStepResult`'s shared `broadcastDisclosureHost`
//    helper — `nil` for an identity-custom user (their server IS the sync server, nothing to
//    disclose).
//  - `torSheetPresentationChanged(false)` (swipe-dismiss): an explicit "Got it" always clears
//    `pendingTorDestination` itself first, so a swipe firing afterward is a harmless echo (existing
//    guard, unchanged). A GENUINE swipe (still pending) with the toggle showing OFF on a provider
//    sheet is the one case R3/R11 newly has to guard — swiping away carries no warning-alert
//    confirmation, so persisting that OFF choice would be exactly the unwarned-opt-out R3 forbids.
//    Minimal-change fix (documented at the call site): that specific combination is treated as a full
//    cancel — nothing persisted, flow does not advance — rather than trying to route a mid-dismiss
//    gesture through the alert. Every other combination (ON, or identity-custom) keeps its existing
//    "persist the shown choice and resume" semantics unchanged.
//
//  R7-T2 fix-wave 1 (Important-1): the R13 disclosure (sheet line + both TransferPlan/ReviewTransfer
//  footers) was gated on `isIdentityCustom` — right for R2/R12's unavailable variant, wrong for R13,
//  since `MigrationManagerLiveKey.createNetworkSnapshot`'s empty-candidates branch (testnet's single
//  shipped endpoint; the defensive no-other-family fallback) also sets `broadcastProvider ==
//  syncProvider` without the snapshot being identity-custom — those users kept the toggle sheet
//  (correctly) but saw a "different server" claim that wasn't true. The disclosure now has its own
//  gate, `showsBroadcastDisclosure` (below) — `broadcastProvider != syncProvider` — read at every
//  hydration site (T3, below, changes WHERE that read happens for the sheet-confirmed route).
//  R2/R12's own unavailable-variant gate (`isCustomServer`/`isIdentityCustom`) is untouched.
//
//  MOB-1497 (T3): the custom-server Tor sheet's redesign moves the R13 disclosure fully off the sheet
//  itself — `MigrationTorSheet.State` drops `broadcastHost`/`showsBroadcastDisclosure` entirely (the
//  redesigned unavailable variant has a risks card instead of a disclosure line, and the provider
//  toggle card's own disclosure line is deleted too). `torSheetState` (presentation) correspondingly
//  stops threading those two fields; `confirmTorSheet`'s `.reviewTransfer` case (confirmation) now
//  re-peeks the already-formed snapshot through the shared `broadcastDisclosureHost` helper instead of
//  reading them back off the sheet's state — the same helper `reviewTransferImmediateState`/
//  `nextPermissionStepResult`'s `.transferPlan` branch (the sheet-SKIPPED routes) already used, so all
//  three R13-footer hydration sites are now uniform. The TransferPlan/ReviewTransfer confirm footers
//  themselves are unchanged (still Task 4's to rework). The sheet also gains two new custom-variant
//  actions/delegates — `continueWithoutTorTapped` (same `.delegate(.gotIt)` contract the old
//  custom-server "Got it" had) and `switchServerTapped` (a new `Delegate.switchServer`, produced here
//  but not yet acted on — `.torSheet(.delegate(.switchServer))` is an explicit no-op below, wired for
//  real in T4).
//
//  MOB-1497 (R9-T3, findings 6+1): the flag-on skip gate the comment above calls out as untouched by
//  fix-wave 1 IS this round's finding 1 — both flag-on shortcuts (Entry `.immediate`, How This Works
//  `.continueTapped`) checked only `walletStorage.exportTorSetupFlag()`, persisting `useTor = true`
//  and pushing straight through even for an identity-custom sync server: the formed snapshot forces
//  clearnet AND the pushed screen's R13 footer is nil by construction (same-server), so those users
//  were silently routed over clearnet with no R2/R12 unavailable notice ever shown. Both branches now
//  check `migrationManager.isSyncServerIdentityCustom()` — a synchronous, snapshot-free read, checked
//  BEFORE either persisting or forming — and branch: identity-custom detours to the SAME
//  unavailable-variant sheet the flag-off branch presents (which forms its own snapshot there),
//  never calling `setNetworkPrivacyOptions` on the detour; non-custom keeps the exact prior skip
//  behavior (persist, then form, then push). Finding 6 (fixed first, since the detour would
//  otherwise re-expose it): the sheet's own `confirmTorSheet` no longer persists the custom sheet's
//  forced `isTorOn == false` as the stored cross-run preference either (see that function's doc) —
//  a circumstance of being on a custom server, not a preference, so persisting it would silently
//  defeat the default-ON hardening (or an earlier explicit provider choice) the moment the user
//  later switches to a provider server.
//
//  MOB-1497 (R9-T3 fix, C1 — post-review): finding 1's first version detected identity-custom via
//  `torSheetState` (forms internally) even on what was ABOUT to become the non-custom branch,
//  inverting that branch's persist/form order against base (33e8dbaf): forming BAKES IN whatever
//  `setNetworkPrivacyOptions` had most recently persisted (`MigrationNetworkSnapshot.useTor`'s doc —
//  a LATER persist does not correct an already-formed snapshot), so forming before this shortcut's
//  own persist could silently bake in a stale OFF choice left over from an earlier off-warning pick,
//  producing a silent clearnet migration broadcast with no sheet and no warning — the exact harm
//  class this feature exists to prevent. `isSyncServerIdentityCustom` (`MigrationManagerClient`,
//  `MigrationManagerImpl.createNetworkSnapshot`'s own `isCustomServer` computation, exposed
//  snapshot-free) replaces `torSheetState` as the detection call in both flag-on branches so
//  detecting never forms; the non-custom branch is now the untouched base sequence byte-for-byte.
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
                    // Skip the Tor sheet iff the app-wide Tor setup flag is on AND the account's
                    // sync server is not identity-custom. MOB-1497 (R9-T3, finding 1): a custom
                    // server's snapshot forces clearnet AND the pushed Review screen's R13 footer is
                    // nil by construction (same-server) — skipping straight through would silently
                    // route those users over clearnet with no unavailable-server notice ever shown.
                    //
                    // R9-T3 fix (C1): detection is `migrationManager.isSyncServerIdentityCustom()` —
                    // a SYNCHRONOUS, snapshot-free read — checked BEFORE entering the effect at all,
                    // deliberately NOT `torSheetState`'s own `isCustomServer` (which requires forming
                    // first). The non-custom branch below must run `setNetworkPrivacyOptions` BEFORE
                    // `formNetworkSnapshot`, exactly like base: forming BAKES IN whatever is
                    // currently persisted (`MigrationNetworkSnapshot.useTor`'s doc — a later persist
                    // does not correct an already-formed snapshot), so a first version of this fix
                    // that detected via `torSheetState` formed before persisting and could silently
                    // bake in a stale OFF choice from an earlier off-warning pick — the exact silent-
                    // clearnet regression this detection avoids by never forming to decide.
                    //
                    // Non-custom: EXACT base sequence, byte-for-byte — `useTor` implicitly `true`,
                    // persisted synchronously BEFORE the effect the same way the sheet's own confirm
                    // does, THEN formed, Review pushed directly.
                    // Identity-custom: detours to the SAME unavailable-variant sheet the flag-OFF
                    // branch presents (which forms its own snapshot there — that's fine, the ONE form
                    // this branch ever does), WITHOUT calling `setNetworkPrivacyOptions` (finding 6:
                    // the custom sheet offers no choice, so persisting its forced value would
                    // silently overwrite a real stored preference) — `confirmTorSheet`'s existing
                    // `.reviewTransfer` destination then drives the flow onward exactly as the skip
                    // would have.
                    //
                    // MOB-1497 (T1): the flag-on shortcut is a Tor-choice RESOLUTION point exactly
                    // like the sheet's own confirm — it forms the run's (provisional) network
                    // snapshot here too, right after the choice persists (T2: unchanged trigger
                    // point — there's no sheet to present on the non-custom branch, so forming stays
                    // here rather than moving to presentation). T2: now awaited (not fire-and-forget)
                    // so the pushed Review Transfer's footer can carry the formed host (R13) —
                    // `formNetworkSnapshot`/the immediately-following peek are both fast, local-only
                    // calls (R7: zero network calls), so this isn't a perceptible nav delay. R9-T6
                    // (finding 8): this claim now actually holds under contention too — forming no
                    // longer serializes through the app-wide `transactionGuard`, so it can no longer
                    // queue for minutes behind an unrelated in-flight broadcast the way it used to
                    // (see `MigrationManagerLiveKey.swift`'s `migrationNetworkOptions` doc).
                    if walletStorage.exportTorSetupFlag() == true {
                        guard !migrationManager.isSyncServerIdentityCustom() else {
                            return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                                let sheetState = await torSheetState(usesFullBalanceCopy: true, accountUUID: accountUUID)
                                await send(.torSheetStateReady(sheetState, destination: .reviewTransfer))
                            }
                        }
                        migrationManager.setNetworkPrivacyOptions(true)
                        return .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] send in
                            await migrationManager.formNetworkSnapshot(accountUUID)
                            let reviewState = await reviewTransferImmediateState(accountUUID: accountUUID)
                            await send(.pushHydratedPathState(.reviewTransfer(reviewState)))
                        }
                    }
                    return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                        let sheetState = await torSheetState(usesFullBalanceCopy: true, accountUUID: accountUUID)
                        await send(.torSheetStateReady(sheetState, destination: .reviewTransfer))
                    }

                case .privateScheduled:
                    state.path.append(.howItWorks(MigrationHowItWorks.State()))
                    return .none
                }

                // MARK: - HowItWorks (MOB-1478 W3, MOB-1487 round 3)

            case .path(.element(id: _, action: .howItWorks(.delegate(.continueTapped)))):
                // MOB-1494 (round 4): same Tor gate as the immediate lane — the app-wide Tor setup
                // flag skips the sheet with `useTor` implicitly on (persisted, so background sends
                // read the same value — MOB-1487's persist-fix); otherwise the toggle sheet is
                // shown and the permission chain resumes from its confirm/dismiss. MOB-1497 (T1):
                // same Tor-choice-resolution snapshot forming as the immediate lane's flag-on
                // shortcut above — sequenced ahead of the permission-step push (not merely
                // concurrent with it) so the snapshot is guaranteed formed before anything
                // downstream could read it (T2: `nextPermissionStepResult`'s own `.transferPlan`
                // branch is exactly that downstream reader now — see its doc for the R13 footer
                // hydration).
                //
                // MOB-1497 (R9-T3, finding 1): the flag-on shortcut now also detects
                // identity-custom BEFORE skipping, same reasoning/reuse as Entry `.immediate`'s
                // twin branch above — see that branch's doc for the full rationale (R9-T3 fix, C1:
                // detection is the synchronous, snapshot-free `migrationManager
                // .isSyncServerIdentityCustom()`, never `torSheetState`'s own `isCustomServer` —
                // that requires forming first, which would bake in a stale persisted Tor choice on
                // the non-custom branch below if forming ran before this shortcut's own persist).
                // A custom server detours to this same sheet (the flag-off path below), never
                // persisting a choice (finding 6); non-custom keeps this shortcut EXACTLY as
                // before — persist, then form, then push, byte-for-byte.
                if walletStorage.exportTorSetupFlag() == true {
                    guard !migrationManager.isSyncServerIdentityCustom() else {
                        return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                            let sheetState = await torSheetState(usesFullBalanceCopy: false, accountUUID: accountUUID)
                            await send(.torSheetStateReady(sheetState, destination: .permissionChain))
                        }
                    }
                    migrationManager.setNetworkPrivacyOptions(true)
                    return .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] send in
                        await migrationManager.formNetworkSnapshot(accountUUID)
                        await send(.pushNextPermissionStep(await nextPermissionStepResult()))
                    }
                }
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    let sheetState = await torSheetState(usesFullBalanceCopy: false, accountUUID: accountUUID)
                    await send(.torSheetStateReady(sheetState, destination: .permissionChain))
                }

                // MARK: - Tor bottom sheet (MOB-1478 W2)

            case .torSheet(.delegate(.gotIt)):
                return confirmTorSheet(state: &state)

            case .torSheet(.delegate(.switchServer)):
                // MOB-1497 (T3): the custom-server variant's new "Switch Server" button — wiring the
                // actual server switch is T4's job. The file's `default: return .none` catch-all
                // (below) would cover this anyway (the switch isn't exhaustive over `torSheet`'s
                // nested delegate cases), but it's spelled out explicitly so a reader doesn't have to
                // go hunting for that to know the tap is deliberately inert for now.
                // Wired in the next commit (T4).
                return .none

            case .torSheetStateReady(let sheetState, let destination):
                // MOB-1497 (T2): presentation-time forming/hydration resolved — actually show the
                // sheet now, mirroring the old (synchronous) `presentTorSheet`'s state writes.
                state.torSheetState = sheetState
                state.pendingTorDestination = destination
                state.isTorSheetPresented = true
                return .none

            case .torSheetPresentationChanged(let isPresented):
                state.isTorSheetPresented = isPresented
                // `false` covers both an explicit "Got it" (which already ran `confirmTorSheet`
                // itself, so `pendingTorDestination` is already `nil` and this is a harmless no-op
                // below) and a swipe-to-dismiss, which never routed through `.delegate(.gotIt)` at
                // all — the swipe path's own trigger.
                guard !isPresented, state.pendingTorDestination != nil else { return .none }

                // MOB-1497 (T2, R3/R11): a GENUINE swipe-dismiss (still pending — an explicit
                // "Got it" would have cleared it already) showing a provider sheet with the toggle
                // OFF carries no warning-alert confirmation — persisting that OFF choice here would
                // be exactly the unwarned opt-out R3 forbids. Minimal-change fix: treat this one
                // combination as a full cancel (nothing persisted, `state.path` untouched — the flow
                // does not advance) rather than trying to route a mid-dismiss gesture through the
                // alert (which would fight the native swipe animation). Every other combination —
                // ON, or identity-custom (R12's disclosure already stood in for the warning) — keeps
                // the existing "persist the shown choice and resume" semantics via `confirmTorSheet`,
                // unchanged.
                if !state.torSheetState.isCustomServer && !state.torSheetState.isTorOn {
                    state.pendingTorDestination = nil
                    return .none
                }
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
                // [MOB-1496] (final engine, plural preps): split the re-paired batch into its
                // preparation (note-split) entries — zero, one, or many — and the schedule's own
                // engine-id-paired entries — ONLY the latter are safe to hand to
                // `storeSignedMigrationTransactions` (all-or-nothing, engine ids only; the real
                // engine rejects a sentinel-prefixed id outright).
                let (prepEntries, scheduleEntries) = MigrationCoordFlow.splitKeystoneBatch(signedPczts)

                return storeKeystoneSignedBatch(
                    context: context,
                    accountUUID: accountUUID,
                    schedule: schedule,
                    prepEntries: prepEntries,
                    scheduleEntries: scheduleEntries
                )

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
                // [MOB-1496] (final engine, plural preps): same sentinel-prefix split as the real
                // round-trip above — the fabricated "simulated" placeholder id (used only when
                // `signState.pczts` was itself empty) never carries the prefix, so it always lands in
                // `scheduleEntries`.
                let (prepEntries, scheduleEntries) = MigrationCoordFlow.splitKeystoneBatch(signedPczts)

                // [MOB-1496] R8-T2 (#20): was a token-identical twin of the real round-trip's store
                // effect above (two prior ordering fixes, C-1/C-1b, had to be applied to both in
                // lockstep) — both now call the same helper.
                return storeKeystoneSignedBatch(
                    context: context,
                    accountUUID: accountUUID,
                    schedule: schedule,
                    prepEntries: prepEntries,
                    scheduleEntries: scheduleEntries
                )

            case .keystoneSigningSubmitted(let context, let signedPreps, let pendingScheduleStore):
                return resumeAfterKeystoneSigning(
                    context: context,
                    signedPreps: signedPreps,
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
                // MOB-1496 (abandon reconciliation): read BEFORE clearing — a live
                // `pendingKeystoneSigning` here means a PCZT batch was already proposed for this
                // ceremony (it's only ever set once `proposeKeystoneBatch` succeeds — see its three
                // setters above), which means the final engine already created and persisted the
                // WHOLE run at that point (preps and schedule transfers alike — see
                // `SDKSynchronizerInterface.proposeNoteSplitPCZTs`'s doc). The engine always resumes a
                // stored non-terminal run on the next attempt, ignoring any newer preview, so
                // abandoning here without cancelling would leave that run stranded — a later re-entry
                // would silently resume signing these same, by-then-stale PCZTs. This fires from BOTH
                // the real round-trip's re-pair-failure guard above AND the split-store-failure branch
                // of either Keystone store effect (including the simulator bypass) — v1 semantics hold
                // for all of them: abandon discards everything, the user re-runs the ceremony from a
                // fresh preview, so cancelling the stray run is correct here regardless of which path
                // sent this action.
                let hadPendingCeremony = state.pendingKeystoneSigning != nil
                state.pendingKeystoneSigning = nil
                // MOB-1496 (C-1 fix): as well as the real round-trip's re-pair-failure guard above
                // (`.scan` always on top there — pop 2, unchanged), this now also fires from the
                // split-store-failure branch of EITHER Keystone store effect above, including the
                // simulator bypass, which never pushes `.scan` (pop 1) — mirrors
                // `resumeAfterKeystoneSigning`'s identical "how many elements are actually on top"
                // check.
                let topElementIsScan = state.path.last?.is(\.scan) == true
                state.path.removeLast(topElementIsScan ? 2 : 1)

                guard hadPendingCeremony, let accountUUID = state.selectedWalletAccount?.id else { return .none }
                return .run { [sdkSynchronizer, accountUUID] _ in
                    // Fire-and-forget: a failure here just leaves the stray run for the next attempt
                    // to encounter (and cancel) itself, same as today.
                    _ = try? await sdkSynchronizer.restartCurrentMigrationStep(accountUUID, false)
                }

                // MARK: - Sending

            case .path(.element(id: _, action: .sending(.delegate(.closed)))):
                if state.mode == .immediate {
                    // R8-T3 (V18): no longer acknowledges here — the engine may still be
                    // genuinely `.inProgress` at this point (completion needs mined-confirmed
                    // AND `orchard_spendable == 0`, not merely "the last broadcast succeeded"),
                    // so acknowledging unconditionally on close risked wiping a still-live run's
                    // own schedule/snapshot records. The run's completion UX now arrives via
                    // `reconcile()` once the engine actually reports `.complete` — the
                    // dust-over-complete branch below and the Complete screen's "Got it" remain
                    // the two acknowledge call sites (both genuinely post-`.complete`).
                    return .send(.flowFinished)
                }

                // MOB-1487 dust lane: this Sending sits over the complete screen ("Migrate
                // anyway") — closing it ends the flow with the same bookkeeping as "Got it".
                let hasCompleteBeneath = state.path.contains { $0.is(\.complete) }
                if hasCompleteBeneath {
                    // R8-T3 (V18): acknowledge is async + account-scoped now — `.merge`d with the
                    // navigation send rather than awaited before it, so closing the flow is never
                    // gated on the acknowledge call finishing.
                    return .merge(
                        .send(.flowFinished),
                        .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] _ in
                            await migrationManager.acknowledgeComplete(accountUUID)
                        }
                    )
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
                // [MOB-1496] R8-T2 (#14): guarded BEFORE popping — the Sending success-phase Close
                // button stays enabled while its own `.sending(.delegate(.closed))` handler's async
                // effect is in flight, and that handler spawns a FRESH effect per delivery, so a
                // double-tap (both taps landing while `.sending` is still on top, since the pop only
                // happens once `.sendNowCompleted` itself is handled) queues TWO deliveries here.
                // Popping unconditionally (the pre-fix behavior) let the second delivery pop the
                // `.status` element the first had already landed on, dumping the user out to Entry
                // mid-run. Requiring `.sending` still on top makes a second delivery a no-op.
                guard state.path.last?.is(\.sending) == true else { return .none }
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
                // R8-T6: `entersViaSendNow` threads the lane context so `MigrationSendingStore`
                // routes `onAppear` through the silence-window gate-check/wait flow instead of the
                // immediate stop+broadcast every other lane still uses (dust, immediate/manual/
                // plan-first review, Keystone) — those never consulted `sendGate()` and still don't.
                return .run { send in
                    await send(
                        .pushHydratedPathState(.sending(MigrationSending.State(totalCount: 1, entersViaSendNow: true)))
                    )
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
                // R8-T3 (V18): async + account-scoped now, `.merge`d with the navigation send —
                // see the `.sending(.delegate(.closed))` dust-lane branch above for the same
                // treatment and its rationale.
                return .merge(
                    .send(.flowFinished),
                    .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] _ in
                        await migrationManager.acknowledgeComplete(accountUUID)
                    }
                )

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
    /// represents (no preps) or routes the signed preparation (note-split) entries to the note-split
    /// progress phase first (MOB-1496 W6, reshaped for the final engine's plural preps):
    /// - `.planCommit`/`.immediateReview`/`.dust` with `signedPreps == nil`: identical to before —
    ///   `resumeCommittedMigrationChain(context:state:)` proceeds straight to the post-commit screen,
    ///   mirroring how the equivalent software `.confirmed` row would proceed.
    /// - `signedPreps != nil`: one or more sentinel-prefixed prep entries rode the batch — pushes
    ///   `MigrationNoteSplit` carrying the signed array the SAME way the existing Keystone resubmit
    ///   lane receives one (`State.signedNoteSplitPczt`), WITH `splitStored: true` (the store effect
    ///   above already called `storeSignedNoteSplits` before this ever runs), then dispatches that
    ///   screen's OWN `.retryTapped` so its existing `resubmitSignedNoteSplit` effect
    ///   (`stopSyncBeforeMigrationBroadcast()` -> `broadcastStoredNoteSplit(account, options)`, no
    ///   re-store since `splitStored` is already `true`) broadcasts it with the existing
    ///   success/failure/retry UX — no new UI, no duplicated broadcast logic.
    ///   `pendingKeystoneSplitResume` stashes `context` so that screen's own `.continued` can land on
    ///   `resumeCommittedMigrationChain` too, once the broadcast is confirmed. MOB-1496 (C-1b fix,
    ///   fix-wave 2): `pendingScheduleStore` (non-`nil` exactly when `signedPreps` is) stashes into
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
        signedPreps: [MigrationSignedTransferPczt]?,
        pendingScheduleStore: MigrationCoordFlow.PendingScheduleStore?,
        state: inout MigrationCoordFlow.State
    ) -> Effect<MigrationCoordFlow.Action> {
        state.pendingKeystoneSigning = nil
        let topElementIsScan = state.path.last?.is(\.scan) == true
        state.path.removeLast(topElementIsScan ? 2 : 1)

        if let signedPreps {
            state.pendingKeystoneSplitResume = context
            state.pendingKeystoneScheduleStore = pendingScheduleStore
            state.path.append(
                .noteSplit(
                    MigrationNoteSplit.State(
                        phase: .splitting,
                        isFlowRoot: false,
                        signedNoteSplitPczt: signedPreps,
                        // MOB-1496 (C-1 fix): the store effect above already stored these preps (it
                        // had to, to create the run the schedule store joined) — this screen only
                        // ever needs to (re)broadcast them, never re-store.
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

    // MARK: - MOB-1496 (R8-T2 #20): shared Keystone signed-batch store sequence

    /// The store sequence for a signed Keystone batch — shared by the real `.scan(.foundPCZTBatch)`
    /// round-trip and the `.simulateSignature` bypass, which ran this as token-identical twins before
    /// this extraction (two prior ordering fixes, C-1/C-1b — see this file's header comment — had to
    /// be applied to both in lockstep; the next such change would have silently forked them again).
    ///
    /// No preps: stores the schedule immediately, exactly as before. R8-T2 (#5 fix): success
    /// bookkeeping (`.keystoneSigningSubmitted`, which drives `resumeAfterKeystoneSigning` into
    /// `recordCommittedSchedule`/`reconcile()` and, from there, `transferPlanPostConfirmChain`'s
    /// `scheduleFirstWindow()`) now fires ONLY when the store call actually succeeds — the code this
    /// replaced discarded a thrown error into a bare `Bool` (`(try? await ...) != nil`) and fired
    /// `.keystoneSigningSubmitted` regardless, landing on the terminal "Migration Scheduled" screen
    /// with nothing stored in the engine and no schedule recorded. On failure this abandons instead
    /// (`keystoneScanAbandoned` semantics — same as a re-pair failure or the prep-store failure
    /// below): `MigrationNoteSplit`, the deferred-schedule path's own store-only retry affordance
    /// (`MigrationCoordFlowCoordinator.storeDeferredKeystoneSchedule`), was investigated and rejected
    /// as the reuse target for THIS, the no-prep case — it is structurally split-specific (`Phase`
    /// is `.splitting`/`.confirmed` only, its Keystone retry fork always ends in
    /// `broadcastStoredNoteSplit`, and its copy is literally "Splitting Funds…"/"Split
    /// Confirmed!"/"Split Failed" — presenting any of that for a batch that was never split would
    /// misinform the user), and both its files (`MigrationNoteSplitStore`/`View`) are out of this
    /// task's scope to extend into hosting a generic no-prep retry. See this task's report for the
    /// full reuse-vs-abandon analysis.
    ///
    /// Preps present (one or many, MOB-1496 final engine's plural `[MigrationUnsignedTransferPczt]`
    /// preparation transactions — superseding the pre-final-engine singular split): unchanged
    /// ordering — stores the preps first via `storeSignedNoteSplits`, abandons on ITS OWN failure
    /// (nothing stored yet, so nothing to resume), and defers the schedule store into
    /// `pendingScheduleStore` (C-1b fix) rather than storing it here. NOTE: C-1's ORIGINAL premise
    /// for storing preps first — "this store unconditionally starts a new engine run, so it must
    /// precede the schedule's uses-or-creates store" — no longer holds under the final engine: the
    /// run is created at PCZT-build time (`proposeNoteSplitPCZTs`, already committed long before this
    /// store runs — see `SDKSynchronizerInterface`'s doc), and `storeSignedNoteSplits`/
    /// `storeSignedMigrationTransactions` are now order-independent per-transaction signature
    /// applications over that one run. What still motivates this ordering is C-1b, immediately
    /// below: storing preps (and letting them broadcast) before the schedule is stored.
    private func storeKeystoneSignedBatch(
        context: MigrationCoordFlow.KeystoneSigningContext,
        accountUUID: AccountUUID,
        schedule: MigrationSchedule?,
        prepEntries: [MigrationSignedTransferPczt],
        scheduleEntries: [MigrationSignedTransferPczt]
    ) -> Effect<MigrationCoordFlow.Action> {
        .run { [sdkSynchronizer, migrationManager, context, accountUUID, schedule, prepEntries, scheduleEntries] send in
            guard !prepEntries.isEmpty else {
                // No preps: store the schedule immediately. R8-T2 (#5): success bookkeeping gated on
                // the store's actual result — see this method's doc.
                guard (try? await sdkSynchronizer.storeSignedMigrationTransactions(accountUUID, scheduleEntries)) != nil else {
                    await send(.keystoneScanAbandoned)
                    return
                }
                if let schedule {
                    await migrationManager.recordCommittedSchedule(accountUUID, schedule)
                }
                await migrationManager.reconcile()
                await send(.keystoneSigningSubmitted(context: context, signedPreps: nil, pendingScheduleStore: nil))
                return
            }
            // Preps present (MOB-1496 C-1b fix, fix-wave 2 — still in force under the final engine,
            // see this method's doc): store ONLY the preps now. The already-signed schedule entries
            // are NOT stored here any more: Step 0 of the fix-wave-2 report traced the engine's phase
            // machine and found a prep's own broadcast-success record
            // (`record_transfer_result`, `context.rs:1299-1303`) UNCONDITIONALLY overwrites the run's
            // phase — a schedule store performed here, before the preps even broadcast, gets
            // clobbered the instant a broadcast lands, stranding the run at `.readyToPropose` once
            // the prep mines (`context.rs:361-378`). The schedule rides along in
            // `pendingScheduleStore` instead, resumed by
            // `MigrationCoordFlowCoordinator.storeDeferredKeystoneSchedule` once the note-split
            // screen's broadcast succeeds — the earliest point the trace proved safe.
            guard (try? await sdkSynchronizer.storeSignedNoteSplits(accountUUID, prepEntries)) != nil else {
                // Nothing was stored at all — abandon exactly like a re-pair failure: nothing to
                // resume, same `keystoneScanAbandoned` semantics.
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
                    signedPreps: prepEntries,
                    pendingScheduleStore: pendingScheduleStore
                )
            )
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

    /// The sentinel PREFIX `MigrationCommitPipeline.proposeKeystoneBatch` wraps each preparation
    /// (note-split) entry's engine id under, so a whole batch of preps can ride the same typed
    /// `[MigrationUnsignedTransferPczt]` QR ceremony as the schedule's own entries while still being
    /// distinguishable from them afterward. MOB-1496 (final engine, plural preps): superseded the
    /// original single fabricated `"note-split"` id — the final engine's `createUnsignedNoteSplitPCZTs`
    /// returns a real per-transaction engine id for every prep it builds (zero, one, or many), so the
    /// app now prefixes the GENUINE id rather than inventing one from nothing. `splitKeystoneBatch`
    /// strips this prefix back off before handing prep entries to `storeSignedNoteSplits`, which needs
    /// their bare engine ids.
    static let keystoneNoteSplitSentinelPrefix = "note-split#"

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

    /// MOB-1496 (final engine, plural preps): splits a re-paired batch into its preparation
    /// (note-split) entries — present iff the run needed any, now zero-or-MANY rather than
    /// zero-or-one — and the schedule's own engine-id-paired entries; ONLY the schedule entries are
    /// safe to hand to `storeSignedMigrationTransactions` (all-or-nothing, engine ids only; the real
    /// engine rejects a sentinel-prefixed id outright). Each prep entry's id is stripped back down to
    /// its bare engine id (undoing `proposeKeystoneBatch`'s prefix-wrap) before being returned, since
    /// `storeSignedNoteSplits` needs the id the engine itself issued, not the app-side wrapper.
    static func splitKeystoneBatch(
        _ paired: [MigrationSignedTransferPczt]
    ) -> (prepEntries: [MigrationSignedTransferPczt], scheduleEntries: [MigrationSignedTransferPczt]) {
        var prepEntries: [MigrationSignedTransferPczt] = []
        var scheduleEntries: [MigrationSignedTransferPczt] = []
        for entry in paired {
            if entry.id.hasPrefix(keystoneNoteSplitSentinelPrefix) {
                let engineId = String(entry.id.dropFirst(keystoneNoteSplitSentinelPrefix.count))
                prepEntries.append(MigrationSignedTransferPczt(id: engineId, pczt: entry.pczt))
            } else {
                scheduleEntries.append(entry)
            }
        }
        return (prepEntries, scheduleEntries)
    }

    // MARK: - Tor bottom sheet (MOB-1478 W2): present + confirm/dismiss

    /// MOB-1497 (T2): resolves a fully-hydrated `MigrationTorSheet.State` for a FRESH presentation —
    /// replaces the old (synchronous) `presentTorSheet`. Forms the run's (provisional) network
    /// snapshot (T1's per-presentation re-form-when-provisional rule now doubles as the
    /// per-presentation re-roll — a fresh sheet always shows a fresh roll), then reads it back via the
    /// non-forming `networkSnapshot` peek to classify identity-custom — off the snapshot's OWN
    /// `syncProvider`, never re-derived with separate classification logic (R2/R8) — into the sheet's
    /// state. Identity-custom forces `isTorOn` false (T1 already forces the snapshot's `useTor` false
    /// for a custom server; there is no toggle to draw ON here either — see `MigrationTorSheet.State
    /// .isCustomServer`'s doc). The immediate destination gets the "your full balance" body variant;
    /// the scheduled one "your balance" — same `usesFullBalanceCopy` convention as before.
    ///
    /// MOB-1497 (T3): no longer threads `broadcastEndpoint.host`/`showsBroadcastDisclosure` into the
    /// sheet's state — the redesigned custom variant has no disclosure line of its own to feed (see
    /// `MigrationTorSheetView`'s doc), so R13 has no reader left here. `confirmTorSheet`'s
    /// `.reviewTransfer` case re-peeks the snapshot itself instead, through the same
    /// `broadcastDisclosureHost` helper the sheet-SKIPPED routes already used.
    private func torSheetState(usesFullBalanceCopy: Bool, accountUUID: AccountUUID?) async -> MigrationTorSheet.State {
        await migrationManager.formNetworkSnapshot(accountUUID)
        let snapshot = await migrationManager.networkSnapshot(accountUUID)
        let isCustomServer = Self.isIdentityCustom(snapshot)

        var sheetState = MigrationTorSheet.State(usesFullBalanceCopy: usesFullBalanceCopy)
        sheetState.isCustomServer = isCustomServer
        if isCustomServer {
            sheetState.isTorOn = false
        }
        return sheetState
    }

    /// "Got it" (both the toggle-ON direct path and the off-warning alert's "Proceed without Tor" —
    /// `MigrationTorSheet` only ever emits `.delegate(.gotIt)` once the choice is fully resolved),
    /// the custom variant's `continueWithoutTorTapped` (MOB-1497 T3 — same `.delegate(.gotIt)`
    /// contract the old custom-server "Got it" had), and swipe-to-dismiss (for every combination
    /// except the one R3/R11 newly guards — see `torSheetPresentationChanged`'s doc) all land here:
    /// persists whatever `isTorOn` is currently showing exactly as `MigrationNetworkPrivacyStore` did,
    /// dismisses the sheet, then resumes the stashed destination. A no-op if nothing is pending
    /// (defensive against a stray `torSheetPresentationChanged(false)` after "Got it" already handled
    /// it).
    ///
    /// MOB-1497 (T2): does NOT call `formNetworkSnapshot` any more — presentation already formed the
    /// snapshot the user was just shown (see `torSheetState` above), and confirm must not re-roll it
    /// out from under them. Instead calls the new `confirmProvisionalTorChoice`, which mutates ONLY
    /// `useTor` on that already-formed provisional snapshot — skipped for an identity-custom confirm
    /// (single acknowledge CTA, no toggle value to persist that way; R2 already forced `useTor` false
    /// at forming).
    ///
    /// MOB-1497 (R9-T3, finding 6): `setNetworkPrivacyOptions` is now skipped for an identity-custom
    /// confirm too, same guard as `confirmProvisionalTorChoice` above — the custom sheet is the
    /// informational unavailable variant (no toggle, single acknowledge CTA), so its forced
    /// `isTorOn == false` is a circumstance of being on a custom server, not a preference the user
    /// chose. Persisting it as the stored cross-run preference would silently overwrite an earlier
    /// real choice (default ON, or the user's own explicit provider pick) the moment they later
    /// switch back to a provider server — sheetless snapshot-forming lanes (e.g. the dust mini-run's
    /// `ensureNetworkSnapshot`) read that stored value directly and would silently fall back to
    /// clearnet with no R11 warning ever shown. The custom confirm now persists NOTHING: the stored
    /// preference keeps whatever it already was.
    private func confirmTorSheet(state: inout MigrationCoordFlow.State) -> Effect<MigrationCoordFlow.Action> {
        guard let destination = state.pendingTorDestination else { return .none }
        state.pendingTorDestination = nil
        state.isTorSheetPresented = false

        let isTorOn = state.torSheetState.isTorOn
        let isCustomServer = state.torSheetState.isCustomServer
        let accountUUID = state.selectedWalletAccount?.id

        if !isCustomServer {
            migrationManager.setNetworkPrivacyOptions(isTorOn)
            migrationManager.confirmProvisionalTorChoice(accountUUID, isTorOn)
        }

        switch destination {
        case .reviewTransfer:
            // MOB-1497 (T3): `MigrationTorSheet.State` no longer carries `broadcastHost`/
            // `showsBroadcastDisclosure` (the redesigned custom variant dropped the sheet's own
            // disclosure line entirely) — re-peek the snapshot through the same non-forming
            // `broadcastDisclosureHost` helper the sheet-SKIPPED routes already use, rather than
            // reading it back off the sheet's state. Nothing has re-formed the snapshot since
            // presentation, so this reads the identical data the old code carried through
            // `torSheetState`, just fetched again instead of ferried.
            return .run { [accountUUID] send in
                var reviewState = MigrationReviewTransfer.State(mode: .immediate)
                reviewState.broadcastDisclosureHost = await broadcastDisclosureHost(accountUUID: accountUUID)
                await send(.pushHydratedPathState(.reviewTransfer(reviewState)))
            }

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
    ///
    /// MOB-1497 (T2, R13): the `.transferPlan` branch also hydrates `broadcastDisclosureHost` — this
    /// is the ONE place a fresh Transfer Plan is ever constructed (both the sheet-confirmed
    /// `.permissionChain` route and the flag-on skip route funnel through here), so hydrating it
    /// unconditionally covers both without either caller needing to know which one it is. Reads the
    /// snapshot `formNetworkSnapshot` already formed earlier in whichever chain got here — never
    /// forms one itself.
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

        var planState = MigrationTransferPlan.State(variant: freshPlanVariant())
        planState.broadcastDisclosureHost = await broadcastDisclosureHost(accountUUID: nil)
        return MigrationCoordFlow.PermissionStepResult(pathState: .transferPlan(planState))
    }

    /// Fresh-entry plan variant: manual delivery (background delivery declined) shows the manual
    /// copy and its confirm sends the first transfer now (§6.3); otherwise the scheduled variant.
    private func freshPlanVariant() -> MigrationTransferPlan.State.Variant {
        migrationManager.isManualDelivery() ? .manual : .scheduled
    }

    // MARK: - MOB-1497 (T2, R13): shared disclosure/identity-custom helpers

    /// Identity-custom classification straight off the formed snapshot's OWN `syncProvider` (R2/R8:
    /// identity-based, never re-derived by re-classifying some other host). `nil` snapshot
    /// (defensive — forming should always have produced one) reads as NOT custom, the safer default
    /// (shows the toggle sheet rather than silently hiding Tor as unavailable).
    private static func isIdentityCustom(_ snapshot: MigrationNetworkSnapshot?) -> Bool {
        guard let snapshot else { return false }
        if case ServerProvider.custom = snapshot.syncProvider { return true }
        return false
    }

    /// R7-T2 fix-wave 1 (Important-1): whether the R13 disclosure (sheet line + both footers) should
    /// render — true iff the formed snapshot's broadcast server differs from its sync server
    /// (`broadcastProvider != syncProvider`). Deliberately NOT the same test as `isIdentityCustom`
    /// above: `MigrationManagerLiveKey.createNetworkSnapshot`'s empty-candidates branch sets
    /// `broadcastProvider = syncProvider` for testnet (single shipped endpoint) and the defensive
    /// no-other-family fallback too, even though neither classifies as identity-custom — those users
    /// keep the toggle sheet (`isIdentityCustom` stays false) but must not see a disclosure line
    /// claiming a server difference that doesn't exist. Identity-custom snapshots always fall out of
    /// this the same way (their broadcast endpoint is forced to the sync endpoint at forming), so
    /// this still reads `false` for R2/R12 custom users without needing to special-case them here.
    /// `nil` snapshot (defensive) reads as `true`, matching the pre-fix gate's fallback
    /// (`!isIdentityCustom(nil)`).
    private static func showsBroadcastDisclosure(_ snapshot: MigrationNetworkSnapshot?) -> Bool {
        guard let snapshot else { return true }
        return snapshot.broadcastProvider != snapshot.syncProvider
    }

    /// The formed snapshot's broadcast host when the R13 disclosure should render (see
    /// `showsBroadcastDisclosure`'s doc — covers identity-custom, testnet, and the defensive
    /// same-server fallback uniformly); `nil` otherwise or when no snapshot is persisted yet. Shared
    /// by the sheet-SKIPPED footers (`reviewTransferImmediateState` / `nextPermissionStepResult`'s
    /// `.transferPlan` branch above) AND (MOB-1497 T3) the sheet-CONFIRMED footer
    /// (`confirmTorSheet`'s `.reviewTransfer` case) — never forms; every caller has already run
    /// `formNetworkSnapshot` earlier in its own chain.
    private func broadcastDisclosureHost(accountUUID: AccountUUID?) async -> String? {
        guard let snapshot = await migrationManager.networkSnapshot(accountUUID) else { return nil }
        guard Self.showsBroadcastDisclosure(snapshot) else { return nil }
        return snapshot.broadcastEndpoint.host
    }

    /// `.reviewTransfer(mode: .immediate)`, hydrated with the R13 disclosure footer — used by the
    /// Entry `.immediate` flag-on skip branch (the sheet-confirmed route hydrates its own
    /// `MigrationReviewTransfer.State` inline, in `confirmTorSheet`'s `.reviewTransfer` case, using
    /// the same `broadcastDisclosureHost` helper this does).
    private func reviewTransferImmediateState(accountUUID: AccountUUID?) async -> MigrationReviewTransfer.State {
        var reviewState = MigrationReviewTransfer.State(mode: .immediate)
        reviewState.broadcastDisclosureHost = await broadcastDisclosureHost(accountUUID: accountUUID)
        return reviewState
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
            // R8-T5 (#13): NOT `stalledRow?.hoursFromNow` — see `liveStalledHoursAgo`'s doc for why
            // that field always reads `0` here.
            stalledHoursAgo: await liveStalledHoursAgo(accountUUID: accountUUID, hasStalledRow: stalledRow != nil),
            isFlowRoot: isFlowRoot
        )
        // [MOB-1496] W3 review fix C: hydrated here (not left to `onAppear`'s own `.statusLoaded`)
        // so the footer doesn't briefly read "about 0 mins" for a frame at re-entry (`.resume` is
        // the only presentation that renders it). Same shared formula `MigrationStatusStore
        // .loadStatus` uses, so the two can't drift. R8-T6: `isSendNowDisabled` no longer needs a
        // twin hydration here — it's computed straight off `state.rows` (already set above), which
        // this constructor call already populated.
        state.syncPrivacyBufferMinutes = MigrationStatus.syncPrivacyBufferMinutes(
            from: sdkSynchronizer.migrationPrivacySyncBufferDuration()
        )
        // MOB-1497 (R7 final review, Important-1): same "hydrate every `.statusLoaded`-covered field
        // at re-entry too" precedent as `syncPrivacyBufferMinutes` right above (MOB-1496 W3 review
        // fix C) — otherwise the Tor line would briefly be absent for a frame at re-entry, before
        // `onAppear`'s own `.statusLoaded` lands.
        state.isTorHoldActive = migrationManager.isMigrationTorHoldActive(accountUUID)
        return state
    }

    /// R8-T5 (#13): the resume screen's "was scheduled N hours ago" header / "Overdue · Nh ago" row
    /// caption used to read `stalledRow?.hoursFromNow` — but `MigrationTransferRow.hoursFromNow` is a
    /// FORWARD-looking, position-based ETA for FUTURE (pending) rows (`MigrationDerivations
    /// .transferRows`: `nonSentPosition × 6`, unchanged by this fix — future-row semantics stay
    /// exactly as they are), and is therefore `0` BY CONSTRUCTION for the first non-sent row, which
    /// is always the STALLED (overdue) one on this screen. Reusing it here read as "0 hours ago"
    /// forever on the real SDK path.
    ///
    /// The honest source: the engine's live `rescheduleOverdueMigrationTransfer` probe — the SAME
    /// call `MigrationBGSchedulerImpl.arm`/`RootInitialization.classifyMigrationAccount` already use
    /// for this exact transfer's `nextExecutableAfterHeight` — converted to elapsed hours via a BLOCK
    /// DELTA against the LIVE chain tip (`latestState().latestBlockHeight`, the same synchronous,
    /// no-await source `MigrationManagerLiveKey.isIronwoodActivated()`/`isNextTransferDue()` already
    /// read for their own height gates), at ~75s/block, floored.
    ///
    /// R8-T5 review (Important-1): this used to convert the height via `estimateTimestamp` instead.
    /// That call (`BundleCheckpointSource.estimateTimestamp`) snaps to the nearest BUNDLED CHECKPOINT
    /// at-or-below the height, with no interpolation — bundled checkpoints are coarse (up to ~52h
    /// spacing near the tip even when freshly shipped) and go stale between SDK releases, so once
    /// `nextExecutableAfterHeight` runs ahead of the newest shipped checkpoint the estimate snaps
    /// back to that stale checkpoint's time and OVERSTATES the elapsed hours — by days, in the worst
    /// case (checkpoint time is always ≤ true block time, so the error only ever goes one way). The
    /// two other `estimateTimestamp` callers (`MigrationBGSchedulerImpl.arm`'s window,
    /// `RootInitialization.classifyMigrationAccount`) never surfaced this because they fold the
    /// estimate into `max(preferredExecutableAt, now + margin)` — the `now + margin` floor masks an
    /// under-shot estimate. This helper is the first to show the converted value RAW, as a
    /// backward-looking "N hours ago" anchor, so the checkpoint coarseness/staleness became directly
    /// user-visible. A block delta at a fixed ~75s/block is precise regardless of checkpoint
    /// staleness, so it replaces `estimateTimestamp` here entirely.
    ///
    /// Falls back to `0` (today's behavior) when there's no stalled row, no resolvable account, no
    /// live proposal, or the tip isn't known yet (`tip == 0`, before the first server round-trip —
    /// same fail-safe-sentinel idiom as `isIronwoodActivated()`: an unknown tip is not a low one, so
    /// it must not be subtracted from) — a best-effort read that must never crash or block the
    /// screen.
    private func liveStalledHoursAgo(accountUUID: AccountUUID?, hasStalledRow: Bool) async -> Int {
        guard hasStalledRow, let accountUUID else { return 0 }

        // Double-optional flatten (mirrors `runMigrationSession`'s identical pattern in
        // `RootInitialization.swift`): a thrown read and a genuinely-empty probe both mean "no real
        // due data to report" here.
        let proposalResult = try? await sdkSynchronizer.rescheduleOverdueMigrationTransfer(accountUUID)
        guard let proposal = proposalResult ?? nil else {
            return 0
        }

        let tip = sdkSynchronizer.latestState().latestBlockHeight
        guard tip > 0 else { return 0 }

        let secondsPerBlock = 75.0
        let elapsedHours = Double(tip - proposal.nextExecutableAfterHeight) * secondsPerBlock / 3600.0
        return max(0, Int(elapsedHours.rounded(.down)))
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
        // [MOB-1496] W3 review fix C: see `statusResumeState`'s twin hydration above — this
        // presentation doesn't render the footer today, but hydrating both builders identically
        // keeps them from drifting if that changes.
        state.syncPrivacyBufferMinutes = MigrationStatus.syncPrivacyBufferMinutes(
            from: sdkSynchronizer.migrationPrivacySyncBufferDuration()
        )
        // MOB-1497 (R7 final review, Important-1): see `statusResumeState`'s twin hydration above —
        // this presentation doesn't render the Tor line today either, but hydrating both builders
        // identically keeps them from drifting if that changes.
        state.isTorHoldActive = migrationManager.isMigrationTorHoldActive(accountUUID)
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
