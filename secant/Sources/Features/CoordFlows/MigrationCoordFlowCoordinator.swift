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
//  (TransferPlan/ReviewTransfer): each delegates a sign request instead of signing locally, which
//  sets `pendingKeystoneSigning` and pushes `keystoneSign`; `keystoneSign(.delegate(.getSignature))`
//  pushes `scan`; the scan completion applies/consumes the device's response and resumes whichever
//  chain the source represents, popping both pushed elements and clearing the context.
//  `keystoneSign(.delegate(.rejected))` pops back to the signing source with its state untouched (no
//  partial storage ever happens on that path). See the "Keystone signing" section below.
//
//  MOB-1513 (R8): the two sources ride DIFFERENT device protocols now, matching Android's lane
//  split exactly:
//  - TransferPlan (`.keystoneSignRequested(pczts)`, scheduled/recovery — engine PCZTs with engine
//    ids) rides the BATCH bridge: batch checker scan, `decodeKeystoneSignBatchPart`,
//    `applyKeystoneBatchSignatures`, store into the engine.
//  - ReviewTransfer (`.keystoneImmediateSignRequested(unsigned:redacted:)`, the engine-external
//    immediate send-max PCZT — and the dust "Migrate anyway" producer) rides the PRODUCTION
//    single-PCZT ceremony: `urEncoderForPCZT` QR over the redacted copy, production
//    `keystonePCZTScanChecker` scan (`.foundPCZT` — the device echoes the FULL signed PCZT),
//    production stamp firmware gate, then the unchanged proofs+combine submit. The batch bridge is
//    structurally wrong for this lane — its apply FFI numeric-parses every PCZT id as an engine
//    `MigrationTxId`, and the immediate PCZT has none (the sentinel string id made apply throw on
//    every ceremony; the then-silent abandon turned that into the QA-reported infinite scan loop).
//
//  MOB-1513 (R9): RESTORES the batch ceremony's per-round cap the R5 rewire below dropped — the
//  ≤35 chunker it removed was DEVICE SAFETY (a real Keystone OOM'd on an oversized batch; Android's
//  production `KeystoneBatchChunking.kt` kept chunking throughout), not imagined-protocol
//  bookkeeping. The cap returns at `KeystoneBatchChunking.maxItemsPerRound` (32 = the wallet-team
//  budget of 96 actions per signing round ÷ ~3 actions per transfer), enforced as a flat item count
//  exactly like Android. `beginKeystoneCeremony` arms round 0 over the batch's first slice;
//  `.keystoneBatchSignaturesApplied` accumulates each round's applied signatures in
//  `State.keystoneBatchRounds` and re-arms `keystoneSign` (fresh request id) until the last round,
//  which feeds the FULL accumulated set into the unchanged store machinery. The firmware gate runs
//  on round 0 only; every ceremony-ending route resets the rounds state (nothing stores unless all
//  rounds complete). The sign screen shows "Round X of Y" for multi-round ceremonies.
//
//  MOB-1513: replaces the imagined pre-real-SDK shape (the device echoing back signed PCZTs,
//  `Scan.Action.foundPCZTBatch([Pczt])`, app-side re-pairing via `rePairedKeystoneBatch`, and a
//  ≤35-PCZTs-per-QR-session multi-round chunker — `chunkKeystoneBatch`/`keystoneRounds`/
//  `keystoneRoundIndex`/`keystoneAccumulatedSigned`/`.keystoneAdvanceToNextRound`, all REMOVED) with
//  the real four-call bridge: `buildKeystoneSignBatchQRParts` builds ONE animated QR over the whole
//  batch (fountain-encoded; the SDK decides the frame count, never the app), the scan screen feeds
//  each frame to `decodeKeystoneSignBatchPart` (owns its own decode session — no `keystoneHandler`
//  fountain-decoder involved for this checker), and the completed decode's signatures-only response
//  applies via `applyKeystoneBatchSignatures`, which does the positional pairing itself. The batch
//  minimum-firmware gate reads the decode envelope's OWN reported version
//  (`KeystoneBatchDecodeResult.firmwareVersion`) directly (the single-PCZT ceremony's gate reads
//  the production PCZT stamp instead — see the firmware-gate sections' docs for the two floors).
//
//  MOB-1513: replaces the imagined pre-real-SDK shape (the device echoing back signed PCZTs,
//  `Scan.Action.foundPCZTBatch([Pczt])`, app-side re-pairing via `rePairedKeystoneBatch`, and a
//  ≤35-PCZTs-per-QR-session multi-round chunker — `chunkKeystoneBatch`/`keystoneRounds`/
//  `keystoneRoundIndex`/`keystoneAccumulatedSigned`/`.keystoneAdvanceToNextRound`, all REMOVED) with
//  the real four-call bridge: `buildKeystoneSignBatchQRParts` builds ONE animated QR over the whole
//  batch (fountain-encoded; the SDK decides the frame count, never the app), the scan screen feeds
//  each frame to `decodeKeystoneSignBatchPart` (owns its own decode session — no `keystoneHandler`
//  fountain-decoder involved for this checker), and the completed decode's signatures-only response
//  applies via `applyKeystoneBatchSignatures`, which does the positional pairing itself. The
//  minimum-firmware gate now reads the decode envelope's OWN reported version
//  (`KeystoneBatchDecodeResult.firmwareVersion`) directly, rather than scanning a stamp out of signed
//  PCZT bytes (`firstUnsupportedKeystoneFirmwareVersion`, also REMOVED) — see the firmware-gate
//  section's doc for the floor value and why it differs from the single-transaction Keystone flow's
//  own gate.
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
//  MOB-1480 added a simulator-only Keystone bypass (a "Simulate signed result" button skipping the
//  physical-device round-trip); removed by MOB-1458 along with the rest of the migration debug
//  simulator. `resumeAfterKeystoneSigning`'s pop-count read (top-of-path `.scan` -> pop 2, else pop
//  1) predates that removal and is left as a defensive read of actual path state rather than an
//  assumption.
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
//  MOB-1496 (W6): the Keystone `.scan(.foundKeystoneBatchSignatures)` store step applied the device's
//  signatures before storing anything — MOB-1513 moved that pairing itself into the SDK
//  (`applyKeystoneBatchSignatures`; this file's own app-side `rePairedKeystoneBatch` is gone) — and
//  a throw from that call abandons the session exactly like `keystoneScanAbandoned` already
//  did for an empty batch. It then splits any note-split sentinel entry out of the re-paired batch
//  (`MigrationCoordFlow.splitKeystoneBatch`) so `storeSignedMigrationTransactions` only ever receives
//  engine-id entries; when a split WAS present, `resumeAfterKeystoneSigning` routes it to a freshly
//  pushed `MigrationNoteSplit` screen by dispatching that screen's OWN `.retryTapped` (its existing
//  `resubmitSignedNoteSplit` lane) instead of resuming the schedule/review chain immediately —
//  `pendingKeystoneSplitResume` stashes what to resume with once that screen's `.continued` fires,
//  landing on the SAME `resumeCommittedMigrationChain` helper `resumeAfterKeystoneSigning` uses
//  directly for a no-split batch.
//
//  MOB-1496 (W-B): "Migrate anyway" (`.complete(.delegate(.migrateAnyway))`) is rewired onto the
//  same immediate (send-max) lane the entry-screen migration uses, for BOTH vendors — the old
//  engine-schedule-based dust composite (`SDKSynchronizerClient.migrateMigrationDust`,
//  `proposeMigrationTransfers`'s old residual-folding variant, `KeystoneSigningContext.dust`,
//  `.keystoneDustPCZTsProposed`) is retired entirely. Unlock-first is LOAD-BEARING: locked notes
//  are excluded from send-max note selection, so `unlockMigrationResidual` must run before
//  `proposeImmediateMigration` — a residual locked via "Lock balance" would otherwise propose
//  `Zatoshi.zero` silently. Software pushes `MigrationSending.State(immediateProposal:)` directly
//  (Complete -> Sending, no `ReviewTransfer` hop); Keystone builds the proposal's PCZT via
//  `createPCZTFromProposal` and arms `KeystoneSigningContext.immediateReview` — the SAME context
//  (and the SAME `submitImmediateKeystoneTransaction` post-signing step) the entry-screen
//  immediate lane's Keystone ceremony already uses, via `.migrateAnywayImmediateKeystonePCZTProposed`
//  (Complete -> keystoneSign -> scan, unchanged shape). A propose/unlock failure on either vendor
//  pushes `MigrationSending.State(isFailurePresented: true)` — the same generic failure sheet every
//  other lane's broadcast failure already shows, reused rather than inventing new UI.
//
//  MOB-1496 (final review R6, C-1 fix): W6's store order was backwards against the real engine —
//  `storeSignedNoteSplitPCZT` unconditionally starts a NEW run, while `storeSignedMigrationTransactions`
//  uses-or-creates the active (newest non-terminal) run; storing the schedule first let the split's
//  later store create a second run that shadowed the schedule's forever. The `.scan(.foundKeystoneBatchSignatures)`
//  store step now stores the split FIRST (when present) — creating the run the schedule store then
//  joins — and abandons (same `keystoneScanAbandoned` semantics the re-pair-failure guard already
//  used) if that store itself fails, since nothing was persisted yet. The old `submitSignedNoteSplit` composite
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
//  just set; the run then never advances again once the split mines
//  (`context.rs:361-378`), stranding the committed schedule. Step 0 of the fix-wave-2 report traced
//  the denom-advance guard (fires from `PreparingDenominations`/`WaitingDenomConfirmations`, never
//  `BroadcastScheduled`) and found storing the schedule right after the split's broadcast SUCCEEDS —
//  not waiting for on-chain confirmation — is the earliest point provably safe (mining cannot occur in
//  that synchronous window). The `.scan(.foundKeystoneBatchSignatures)` store step now stores
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
//  by an adversarial whole-PR review. #20 (cleanup, done first): the real `.scan(.foundKeystoneBatchSignatures)`
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
//  clearnet and no R2/R12 unavailable notice was ever shown. Both branches now
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
//  MOB-1497 (T4, Q3'26 canvas): two changes.
//  - Switch Server routing: `.torSheet(.delegate(.switchServer))` is no longer inert — it dismisses
//    the sheet, clears `pendingTorDestination`, persists NOTHING (the run's snapshot stays
//    provisional), and emits the new `switchServerRequested` store action. `Root` runs the same
//    teardown as `flowFinished` (release the send-wait hold, `clearProvisionalNetworkSnapshot`,
//    `clearAbandonedNetworkSnapshot`) and then routes to Server Setup instead of closing to Home.
//  - R13 retirement: the broadcast-server disclosure is fully removed. The `broadcastDisclosureHost`
//    /`showsBroadcastDisclosure` helpers and `reviewTransferImmediateState` are deleted; the three
//    former hydration sites (Entry `.immediate` flag-on skip, How This Works `.transferPlan` via
//    `nextPermissionStepResult`, and `confirmTorSheet`'s `.reviewTransfer` re-peek) now construct
//    their pushed screens with no host threading. `isIdentityCustom` (the sheet's custom-vs-toggle
//    classifier) is the only snapshot reader left. The TransferPlan/ReviewTransfer footers and the
//    `migrationTorSheet.disclosure` string go with them.
//
//  MOB-1497 (T8, Q3'26 canvas): threads the new `MigrationSending.State.isManualStepLane` discriminator
//  at its two production sources — `transferPlanPostConfirmChain`'s `.manual` case (the manual-delivery
//  run's first transfer) and the `.reviewTransfer(.delegate(.confirmed))` case (every later manual-step
//  confirm, told apart from an immediate-mode confirm by peeking the `MigrationReviewTransfer` element
//  still on top of the path). See `MigrationSendingStore.swift`'s header doc for why this needed a new
//  field at all — the two modes converge on the identical `.confirmed` delegate, so nothing upstream of
//  this coordinator can tell them apart.
//
//  MOB-1513 (B4 — confirm redesign + "Splitting Funds" removal): the confirm chain is sign-only now
//  (see `MigrationCommitPipeline.commitSoftware`), and the W6/C-1b mid-Keystone-commit note-split
//  detour narrated above is retired. Landing on B9 Migration Scheduled fires the coordinator-owned
//  FIRST-DELIVERY KICK (`runFirstDeliveryKick`): the first prep broadcasts there over the existing
//  next-due lane, and a Keystone commit's deferred schedule store (C-1b ordering preserved: only
//  after a prep broadcast lands) runs inside the same kick, releasing
//  `pendingKeystoneScheduleStore` via `.deferredKeystoneScheduleStored`. Kick failures are silent —
//  the run stays `splitPendingConfirmation`, surfaced by the migration progress banner/route, and
//  BG windows + foreground reconcile retry preps naturally.
//
//  MOB-1513 (C7, Figma Error & Recovery row 3): the EXPIRED-transfer recovery lane's `.recreate`
//  used to land directly on Scheduled (software) or start the Keystone ceremony immediately
//  (Keystone) — the approved Figma spec's Error & Recovery row 3 instead promises a Confirm
//  Transfer Plan review screen between the recovery screen and Scheduled, matching the
//  `.notesSpent` lane's own recreated-plan screen. Both `.expired` branches now push that SAME
//  `.recreated` presentation (`recreatedPlanState`) with `requiresSigning: false` (nothing left to
//  sign — the software refresh already re-signed in place, the Keystone batch is already proposed)
//  and the new `isExpiredRecoveryReview` flag; `.transferPlan(.delegate(.confirmed))` reads that
//  flag to route to the new `expiredRecoveryReviewConfirmed` instead of the pre-existing
//  `requiresSigning == false` rescheduled-variant branch (a plain `.flowFinished` acknowledgment,
//  unchanged and still reachable — `isExpiredRecoveryReview` is what tells the two apart, since
//  both are `.recreated`/`requiresSigning == false`). The Keystone lane's already-proposed batch
//  rides the pushed screen's own new `pendingKeystoneRecoveryBatch` field (`MigrationTransferPlanStore.swift`)
//  rather than coordinator state, so backing out of the review screen without confirming discards
//  it for free (TCA tears the popped element's state down) — no new pop-handling needed. The
//  ceremony's own completion/store/abandon semantics (`resumeCommittedMigrationChain`'s
//  `.recoveryRefresh` case, `keystoneScanAbandoned`'s recovery-refresh skip-cancel branch) are
//  byte-identical; only WHEN `.recoveryRefresh(schedule:)` gets armed moves, from the propose
//  landing to the review screen's own Confirm.
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
                // MOB-1513 (H3 guard): genuine flow start ONLY (the guard above) — record this
                // instance's owner and arm the "propose-consuming migration screen is on screen for
                // this account" signal synchronously, before the async re-entry lookup below even
                // resolves. See `MigrationCoordFlow.State.presentedMigrationFlowAccountUUID`'s doc
                // and `MigrationManagerImpl.presentedFlowAccountUUIDs`'s doc for the full
                // arm/disarm site list this pairs with.
                let accountUUID = state.selectedWalletAccount?.id
                state.presentedMigrationFlowAccountUUID = accountUUID
                migrationManager.setMigrationFlowPresented(accountUUID, true)
                return .run { [accountUUID] send in
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
                migrationManager.setMigrationMode(state.selectedWalletAccount?.id, mode)

                switch mode {
                case .immediate:
                    // Skip the Tor sheet iff the app-wide Tor setup flag is on AND the account's
                    // sync server is not identity-custom. MOB-1497 (R9-T3, finding 1): a custom
                    // server's snapshot forces clearnet — skipping straight through would silently
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
                    // here rather than moving to presentation). MOB-1497 (T4): the R13 footer this
                    // once hydrated is retired, but forming stays awaited — the provisional snapshot
                    // must exist before anything downstream reads it, and `formNetworkSnapshot` is a
                    // fast, local-only call (R7: zero network calls), so this is not a perceptible
                    // nav delay. R9-T6 (finding 8): that claim holds under contention too — forming
                    // no longer serializes through the app-wide `transactionGuard`, so it can no
                    // longer queue for minutes behind an unrelated in-flight broadcast the way it
                    // used to (see `MigrationManagerLiveKey.swift`'s `migrationNetworkOptions` doc).
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
                            await send(.pushHydratedPathState(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate))))
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
                // MOB-1497 (T4): the custom-server variant's "Switch Server" button — leave the
                // migration flow for Server Setup. Dismiss the sheet and drop the stashed
                // destination, but persist NOTHING for the abandoned attempt: no `confirmTorSheet`,
                // no `setNetworkPrivacyOptions`, no `confirmProvisionalTorChoice`. The run's network
                // snapshot stays PROVISIONAL, so Root's `.switchServerRequested` teardown (the same
                // one `.flowFinished` runs) discards it. The coordinator owns no navigation outside
                // its own `path`, so it signals Root via the sibling `switchServerRequested` action
                // to open Server Setup with back-to-Home.
                state.isTorSheetPresented = false
                state.pendingTorDestination = nil
                return .send(.switchServerRequested)

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

                // MOB-1513 (B4): the first-delivery kick's deferred Keystone schedule store landed —
                // the entries are durably in the engine now, so the stash can be released and any
                // armed state-event re-arm cancelled (a no-op when none is armed — the happy path).
            case .deferredKeystoneScheduleStored(let accountUUID):
                state.pendingKeystoneScheduleStore = nil
                return .cancel(id: MigrationCoordFlow.CancelID.deferredScheduleStoreRearm(accountUUID))

                // MOB-1513 (B4 fix wave): the kick exhausted its bounded attempts with the deferred
                // store still pending — arm the SILENT state-event re-arm. Payload rides the action/
                // effect (never re-read from state): this flow is a permanent `Scope` child of Root,
                // so the subscription survives a flow close (teardown resets STATE only) and the
                // store still happens once a prep broadcast lands, whoever lands it.
                // `cancelInFlight: true` keeps at most one re-arm alive.
            case .firstDeliveryKickFailed(let pendingScheduleStore, let accountUUID):
                return .publisher {
                    migrationManager.stateEvents(accountUUID)
                        .map { _ in
                            MigrationCoordFlow.Action.deferredKeystoneScheduleResolveDue(
                                pendingScheduleStore: pendingScheduleStore,
                                accountUUID: accountUUID
                            )
                        }
                }
                .cancellable(id: MigrationCoordFlow.CancelID.deferredScheduleStoreRearm(accountUUID), cancelInFlight: true)

            case .deferredKeystoneScheduleResolveDue(let pendingScheduleStore, let accountUUID):
                return .run { send in
                    await resolveDeferredScheduleStore(
                        accountUUID: accountUUID,
                        pendingScheduleStore: pendingScheduleStore,
                        send: send
                    )
                }

                // MARK: - BackgroundDelivery

            case .path(.element(id: _, action: .backgroundDelivery(.delegate(.continued(let backgroundAllowed))))):
                if !backgroundAllowed {
                    migrationManager.setManualDelivery(state.selectedWalletAccount?.id, true)
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

                guard planState.requiresSigning else {
                    // MOB-1513 (C7, Figma Error & Recovery row 3): the expired-recovery review
                    // screen is ALSO `requiresSigning == false` (nothing left to sign by the time
                    // it's shown — see its two construction sites, `recreatedPlanState`) but must
                    // NOT just acknowledge like the rescheduled variant below: software lands on
                    // Scheduled, Keystone resumes the already-proposed ceremony.
                    // `isExpiredRecoveryReview` is the discriminator — `variant`/`requiresSigning`
                    // alone can't tell the two `requiresSigning == false` screens apart (this one is
                    // also `.recreated`, the same variant the pre-existing `.notesSpent`/restart lane
                    // uses).
                    if planState.isExpiredRecoveryReview {
                        return expiredRecoveryReviewConfirmed(
                            schedule: planState.schedule,
                            pendingKeystoneRecoveryBatch: planState.pendingKeystoneRecoveryBatch,
                            state: &state
                        )
                    }
                    // Rescheduled variant: its confirm is a plain acknowledgment of an
                    // already-committed reschedule (`scheduleFirstWindow()` ran once already, at
                    // reschedule-initiation) — no re-sign, no terminal `.scheduled` screen, straight
                    // to `.flowFinished` ("Got-it" per the spec).
                    return .send(.flowFinished)
                }

                return transferPlanPostConfirmChain(variant: planState.variant, schedule: planState.schedule, state: &state)

                // MARK: - ReviewTransfer

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.confirmed)))):
                // MOB-1497 (T8, Q3'26 canvas): both `MigrationReviewTransfer.State.Mode` cases
                // delegate this SAME `.confirmed` action, so the element still on top of the path
                // (peeked BEFORE the push below — `StackState.append` never pops) is the only place
                // left to tell a manual-step confirm (one of several hand-walked transfers) apart
                // from an immediate one-shot sweep, to select the pushed screen's success wording.
                //
                // MOB-1513: this confirm only ever fires for a SOFTWARE account — a Keystone
                // immediate-mode confirm forks to `requestKeystoneSignature` instead (never
                // `.confirmed`), so `reviewState.immediateProposal` is threaded here unconditionally
                // for the non-manual-step branch: it is guaranteed populated (the guard chain in
                // `MigrationReviewTransferStore.confirmTapped` never reaches this delegate with a nil
                // proposal) and `nil` is impossible for a Keystone account by construction. `keep 1`:
                // a send-max proposal is a single transaction BY CONSTRUCTION
                // (`Proposal.transactionCount() == 1`) — not an artifact of the old engine schedule
                // this replaced, which merely happened to also be one transfer.
                let isManualStepLane: Bool
                var immediateProposal: ImmediateMigrationProposal?
                if case .reviewTransfer(let reviewState) = state.path.last, case .manualStep = reviewState.mode {
                    isManualStepLane = true
                } else {
                    isManualStepLane = false
                    if case .reviewTransfer(let reviewState) = state.path.last {
                        immediateProposal = reviewState.immediateProposal
                    }
                }
                let sendingState = MigrationSending.State(
                    totalCount: 1,
                    isManualStepLane: isManualStepLane,
                    immediateProposal: immediateProposal
                )
                state.path.append(.sending(sendingState))
                return .none

                // MARK: - Keystone signing (MOB-1468)

            case .path(.element(id: _, action: .transferPlan(.delegate(.keystoneSignRequested(let pczts))))):
                state.pendingKeystoneSigning = .planCommit
                state.pendingKeystoneSigningAccountUUID = state.selectedWalletAccount?.id
                beginKeystoneCeremony(pczts: pczts, state: &state)
                return .none

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.keystoneImmediateSignRequested(let unsigned, let redacted))))):
                // MOB-1513 (R8): the immediate lane rides the PRODUCTION single-PCZT ceremony —
                // see `beginImmediateKeystoneCeremony`'s doc for why it never enters the batch
                // bridge the scheduled/recovery lanes use.
                state.pendingKeystoneSigning = .immediateReview
                state.pendingKeystoneSigningAccountUUID = state.selectedWalletAccount?.id
                beginImmediateKeystoneCeremony(unsigned: unsigned, redacted: redacted, state: &state)
                return .none

            case .path(.element(id: _, action: .keystoneSign(.delegate(.getSignature)))):
                guard case let .keystoneSign(signState)? = state.path.last else { return .none }
                var scanState = Scan.State.initial
                if signState.redactedSinglePczt != nil {
                    // MOB-1513 (R8): single-PCZT ceremony — the PRODUCTION checker: the device
                    // echoes the full signed PCZT as a `zcash-pczt` UR (`parseZcashPczt`), no batch
                    // decode session and no request-id correlation involved. Reset the shared BC-UR
                    // fountain decoder so a retry ceremony never inherits a previous session's
                    // accumulated frames (`SendConfirmation.getSignatureTapped` precedent).
                    keystoneHandler.resetQRDecoder()
                    scanState.checkers = [.keystonePCZTScanChecker]
                } else {
                    // MOB-1513: the batch scan session needs THIS ceremony's correlation token, so
                    // `decodeKeystoneSignBatchPart` can reject a scan of an unrelated/stale
                    // response.
                    scanState.checkers = [.keystoneMigrationBatchScanChecker]
                    scanState.keystoneBatchRequestId = signState.requestId
                }
                // MOB-1478 (W10): matches the design's single centered flash control (precedent:
                // `AddKeystoneHWWalletCoordFlowCoordinator` already sets `forceLibraryToHide`).
                scanState.instructions = String(localizable: .migrationKeystoneScanInstructions)
                scanState.forceLibraryToHide = true
                state.path.append(.scan(scanState))
                return .none

                // MARK: - MOB-1513 (R8): Keystone signing — immediate lane's single-PCZT round-trip

            case .path(.element(id: _, action: .scan(.foundPCZT(let signedPczt)))):
                // One-shot guard — `keystoneImmediateSubmitInFlight`'s doc has the duplicate-frame
                // race; a duplicate for an in-flight submit is DROPPED (`.none`), never abandoned.
                guard !state.keystoneImmediateSubmitInFlight else { return .none }

                guard case .immediateReview? = state.pendingKeystoneSigning,
                      case let .keystoneSign(signState)? = state.path.dropLast().last,
                      let accountUUID = state.selectedWalletAccount?.id else {
                    return .send(.keystoneScanAbandoned)
                }

                // MOB-1513 (R8): the immediate ceremony's minimum-firmware gate is the PRODUCTION
                // one — the stamp the device writes into every signed PCZT's proprietary fields
                // (`Data.keystoneFirmwareVersion()`, MOB-1510) against the `SendConfirmation` floor
                // (3.0.0). The batch envelope's version (and its separate 3.0.2 floor) never enters
                // this lane. An unstamped PCZT is necessarily below minimum (the stamp ships since
                // firmware 2.4.6), never merely "unknown" — same reasoning as `SendConfirmation`'s
                // gate.
                let detectedFirmware = signedPczt.keystoneFirmwareVersion()
                guard let detectedFirmware, detectedFirmware >= KeystoneFirmwareVersion.minimumSupported else {
                    state.detectedKeystoneFirmwareVersion = detectedFirmware?.versionString
                    state.keystoneFirmwareGateMinimumVersion = KeystoneFirmwareVersion.minimumSupported.versionString
                    state.isKeystoneFirmwareGatePresented = true
                    return .send(.keystoneScanAbandoned)
                }

                // The scanned payload IS the device-signed PCZT — hand it with the retained
                // unredacted original (still on the `keystoneSign` element beneath `scan`) to the
                // unchanged proofs+combine+submit step. Armed across the WHOLE leg — cleared in
                // `.keystoneImmediateSubmitted` / `.keystoneImmediateSubmitFailed` /
                // `.keystoneScanAbandoned`.
                state.keystoneImmediateSubmitInFlight = true
                // MOB-1513 (R10): the scan screen stays on top for this whole leg (proofs +
                // broadcast) — arm its "Signing…" hold so it isn't silent while this runs.
                if let scanId = state.path.ids.last, case .scan(var scanState) = state.path[id: scanId] {
                    scanState.isKeystoneSigningInProgress = true
                    state.path[id: scanId] = .scan(scanState)
                }
                return submitImmediateKeystoneTransaction(
                    accountUUID: accountUUID,
                    unsignedPczt: signState.pczts.first?.pczt ?? Data(),
                    signedPczt: signedPczt
                )

            case .keystoneImmediateSubmitFailed:
                // MOB-1513 (R8, F2): same pop/clear shape as `.keystoneScanAbandoned`'s navigation
                // half — but the failure is VISIBLE: the retained Review element comes back with its
                // existing commit-failure sheet armed (Retry re-runs the whole ceremony from a fresh
                // PCZT+redact). No stray-run cancel here: the immediate proposal is engine-external,
                // no engine run was ever created for this ceremony. The dust producer ("Migrate
                // anyway") has a `.complete` element beneath instead — it falls back to the generic
                // Sending failure-sheet push its own propose-failure path already uses.
                state.keystoneImmediateSubmitInFlight = false
                // MOB-1513 (R8, review fix): ceremony already torn down (a reject after a
                // swipe-back off `scan` mid-proving cleared `pendingKeystoneSigning` — the
                // tombstone)? The scan/sign elements are gone, the pop below would delete the
                // user's current screen, and they already walked away from this ceremony — drop
                // the late failure silently (it's logged at the throw site).
                guard case .immediateReview? = state.pendingKeystoneSigning else { return .none }
                state.pendingKeystoneSigning = nil
                state.pendingKeystoneSigningAccountUUID = nil
                let topElementIsScan = state.path.last?.is(\.scan) == true
                state.path.removeLast(topElementIsScan ? 2 : 1)
                // MOB-1458: same dust-lane "Migrate anyway" flag fix (see `clearMigrateAnywayInFlight`'s
                // doc) — placed ahead of the branch below so it runs whichever screen the pop landed
                // on. This lane's leak is not currently user-visible (the `.sending` pushed below over
                // a retained `.complete` ends the flow before `.complete` could reappear), but the
                // clear is free and keeps it that way if this fallback's behavior ever changes — do
                // NOT delete this as dead code.
                clearMigrateAnywayInFlight(state: &state)
                if let reviewId = state.path.ids.last, case .reviewTransfer(var reviewState) = state.path.last {
                    reviewState.isConfirming = false
                    reviewState.isFailurePresented = true
                    reviewState.failureReason = MigrationReviewTransfer.State.FailureReason.commit
                    state.path[id: reviewId] = .reviewTransfer(reviewState)
                    return .none
                }
                state.path.append(.sending(MigrationSending.State(isFailurePresented: true, totalCount: 1)))
                return .none

            case .path(.element(id: _, action: .keystoneSign(.delegate(.buildFailed)))):
                // MOB-1513: `buildKeystoneSignBatchQRParts` threw — no QR was ever shown, so `.scan`
                // was never pushed either (the user never got as far as tapping "Get Signature").
                // Deferred to a follow-up self-action for the same reason `.rejected` defers to
                // `.keystoneSignRejected`: `.forEach(\.path, action:)` still needs to deliver THIS
                // action to the `keystoneSign` element after this case returns.
                return .send(.keystoneScanAbandoned)

            case .path(.element(id: _, action: .scan(.foundKeystoneBatchSignatures(let data, let firmwareVersion)))):
                // MOB-1513 (final review, I-1 fix): one-shot guard against a late-frame duplicate
                // completion — see `keystoneBatchApplyInFlight`'s doc for the full race this guards
                // against. A duplicate for an already in-flight ceremony is DROPPED here (`.none`),
                // never routed through `keystoneScanAbandoned` — nothing went wrong; the first
                // delivery is simply still being applied/stored.
                guard !state.keystoneBatchApplyInFlight else { return .none }

                guard let context = state.pendingKeystoneSigning,
                      case let .keystoneSign(signState)? = state.path.dropLast().last,
                      let accountUUID = state.selectedWalletAccount?.id else {
                    return .send(.keystoneScanAbandoned)
                }

                // MOB-1513: the minimum-firmware gate reads the decode envelope's OWN reported
                // version (`KeystoneBatchDecodeResult.firmwareVersion`) directly. MOB-1513 (final
                // review, I-1 fix): "this runs exactly once" used to be a bare assumption here (there
                // is only ever one QR session per ceremony) — the `keystoneBatchApplyInFlight` guard
                // above now actually ENFORCES it, so a duplicate late-frame delivery is dropped before
                // it ever reaches this gate a second time for the same ceremony. Below the floor
                // (`ZcashLightClientKit.KeystoneFirmwareVersion` is `Comparable`), or no version
                // reported at all, presents the firmware-gate sheet and abandons exactly like an apply
                // failure would (`keystoneScanAbandoned` semantics — no retry without a physical
                // device firmware update). See `keystoneMigrationBatchMinimumFirmware`'s doc for why
                // this floor and mechanism differ from the single-transaction Keystone flow's own
                // gate.
                // MOB-1513 (R9): the gate runs on ROUND 0 ONLY (Android parity) — the same physical
                // device signs every round of a multi-round ceremony, and gating a later round
                // would make the user scan through every remaining round only to be blocked at the
                // very end. A `nil` rounds state (defensive — every batch ceremony sets it) gates
                // like round 0.
                let isFirstKeystoneRound = (state.keystoneBatchRounds?.roundIndex ?? 0) == 0
                guard !isFirstKeystoneRound
                    || (firmwareVersion.map { $0 >= MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware } ?? false) else {
                    state.detectedKeystoneFirmwareVersion = firmwareVersion?.versionString
                    // MOB-1513 (R8): the sheet's copy echoes whichever floor actually applied —
                    // this batch trip uses the batch-protocol floor; the immediate single-PCZT
                    // trip below uses the production stamp floor (3.0.0).
                    state.keystoneFirmwareGateMinimumVersion = MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware.versionString
                    state.isKeystoneFirmwareGatePresented = true
                    return .send(.keystoneScanAbandoned)
                }

                // MOB-1513: `applyKeystoneBatchSignatures` does the positional pairing itself now (the
                // app-side `rePairedKeystoneBatch` this replaced is gone) — but it's `async throws`,
                // so this hands off to a `.run` effect rather than continuing inline. Both
                // `unsignedPczts` (needed by the immediate lane's post-scan submit) and the applied
                // `signed` result ride the follow-up action; nothing here touches `state.path`, so it
                // is still exactly `[..., keystoneSign, scan]` when `.keystoneBatchSignaturesApplied`
                // is handled below.
                let unsignedPczts = signState.pczts
                // MOB-1513 (final review, I-1 fix): armed right before the apply effect dispatches —
                // cleared in `.keystoneBatchSignaturesApplied` (below) and `.keystoneScanAbandoned`.
                state.keystoneBatchApplyInFlight = true
                // MOB-1513 (R10): the scan screen stays on top for this whole leg (apply + store) —
                // arm its "Signing…" hold so it isn't silent while this runs.
                if let scanId = state.path.ids.last, case .scan(var scanState) = state.path[id: scanId] {
                    scanState.isKeystoneSigningInProgress = true
                    state.path[id: scanId] = .scan(scanState)
                }
                return .run { [sdkSynchronizer, unsignedPczts, data] send in
                    do {
                        // MOB-1513 (R8 finding 1): sentinel-prefixed prep ids never cross the FFI —
                        // see `sanitizedForBatchApply`/`reattachOriginalIds`.
                        let signed = try await sdkSynchronizer.applyKeystoneBatchSignatures(
                            MigrationCoordFlow.sanitizedForBatchApply(unsignedPczts),
                            data
                        )
                        await send(
                            .keystoneBatchSignaturesApplied(
                                context: context,
                                accountUUID: accountUUID,
                                unsignedPczts: unsignedPczts,
                                signed: MigrationCoordFlow.reattachOriginalIds(from: unsignedPczts, onto: signed)
                            )
                        )
                    } catch {
                        // MOB-1513 (R8, F3): log before abandoning — the silent discard here is
                        // what made the original immediate-lane loop undiagnosable from QA logs.
                        LoggerProxy.error("[MOB-1513] Keystone batch signature apply failed: \(error)")
                        await send(.keystoneScanAbandoned)
                    }
                }

            case .path(.element(id: _, action: .scan(.keystoneBatchDecodeFailed))):
                // MOB-1513 (final review, C1 fix): `decodeKeystoneSignBatchPart` threw on a scanned
                // frame — a stale, mismatched, or corrupt response, including the SDK's own
                // request-id-mismatch throw at completion. `.scan` is still the top path element here
                // (this fires before `.foundKeystoneBatchSignatures` ever would), so this reuses
                // `keystoneScanAbandoned`'s pop-2 semantics to unwind scan + keystoneSign back to the
                // initiating screen — the same "abandon like a rejected scan" treatment the
                // apply-signature and firmware-gate failures above already get. No new UI.
                return .send(.keystoneScanAbandoned)

            case .keystoneBatchSignaturesApplied(let context, let accountUUID, let unsignedPczts, let signed):
                // MOB-1513 (final review, I-1 fix): the apply step landed — clear the one-shot guard
                // here, the success-continuation clearing point `keystoneBatchApplyInFlight`'s doc
                // names. Scan's own intake gate (`isAnythingFound`) already flipped synchronously
                // when THIS action was forwarded to the `scan` path element (`.forEach(\.path,
                // action:)` runs after this file's own `Reduce` — see `MigrationCoordFlowStore.body`),
                // so no NEW camera frame can start a fresh decode past this point; only a frame
                // already mid-decode from the same original race could still land, and the guard
                // covers that window by staying armed for exactly as long as this apply step takes.
                state.keystoneBatchApplyInFlight = false
                // MOB-1513 (R8): retained DEFENSIVELY — the live immediate lane rides the
                // single-PCZT `.scan(.foundPCZT)` round-trip and never arms a batch scan session,
                // so a batch completion can no longer carry this context in practice. (The batch
                // apply above would in fact throw for the immediate sentinel id — the FFI
                // numeric-parses ids — which is exactly why R8 rerouted the lane.)
                // MOB-1513: the immediate lane diverges entirely from here on — no engine schedule to
                // read, no store step at all (nothing was ever proposed through the engine). See
                // `submitImmediateKeystoneTransaction`'s doc.
                if case .immediateReview = context {
                    return submitImmediateKeystoneTransaction(
                        accountUUID: accountUUID,
                        unsignedPczt: unsignedPczts.first?.pczt ?? Data(),
                        signedPczt: signed.first?.pczt ?? Data()
                    )
                }

                // MOB-1513 (R9, review fix): tombstone — a reject/abandon can land while THIS
                // apply effect is still in flight (swipe-back off `scan`, then Reject — the same
                // documented race the R8 completions guard against with this exact check). The
                // ceremony is over: `pendingKeystoneSigning` and `keystoneBatchRounds` are cleared
                // and the path popped. A late applied completion must store NOTHING — without this
                // guard the nil rounds state below would masquerade as a single-round ceremony and
                // store THIS ROUND'S SLICE as if it were the whole batch (a partial store, the
                // exact invariant breach this round exists to prevent). Dropping is safe: the
                // engine still holds the run's transactions awaiting signatures and re-serves the
                // still-unsigned batch on the next ceremony entry.
                guard state.pendingKeystoneSigning != nil else { return .none }

                // MOB-1513 (R9): accumulate this round's applied signatures and, if the capped
                // ceremony has rounds left, arm the next one instead of storing — the stores run
                // exactly once, over the FULL accumulated batch, after the last round (Android
                // parity: `MigrationKeystoneScanVM` accumulates per round and finalizes with the
                // full set). The pop-2 + push keeps the path shape `[..., source, keystoneSign]`
                // constant regardless of how many rounds a large migration needs, and the fresh
                // `MigrationKeystoneSign.State` gives the next round its own request id. A `nil`
                // rounds state (defensive) treats `signed` as the whole batch — today's
                // single-round behavior.
                let fullSigned: [MigrationSignedTransferPczt]
                if var rounds = state.keystoneBatchRounds {
                    rounds.accumulatedSigned.append(contentsOf: signed)
                    let totalRounds = KeystoneBatchChunking.totalRounds(itemCount: rounds.allPczts.count)
                    let nextRoundIndex = rounds.roundIndex + 1
                    if nextRoundIndex < totalRounds {
                        rounds.roundIndex = nextRoundIndex
                        state.keystoneBatchRounds = rounds
                        let slice = KeystoneBatchChunking.roundSlice(roundIndex: nextRoundIndex, itemCount: rounds.allPczts.count)
                        let topElementIsScan = state.path.last?.is(\.scan) == true
                        state.path.removeLast(topElementIsScan ? 2 : 1)
                        state.path.append(
                            .keystoneSign(
                                MigrationKeystoneSign.State(
                                    pczts: Array(rounds.allPczts[slice]),
                                    roundIndex: nextRoundIndex,
                                    totalRounds: totalRounds
                                )
                            )
                        )
                        return .none
                    }
                    state.keystoneBatchRounds = nil
                    fullSigned = rounds.accumulatedSigned
                } else {
                    fullSigned = signed
                }

                // [MOB-1496] W2: the schedule that was just signed lives on the `.transferPlan`/
                // `.reviewTransfer` element still beneath `keystoneSign`+`scan` on the path (or, for
                // the dust lane, directly on `context` — see `pendingKeystoneSchedule`'s doc) — read
                // it now, before `resumeAfterKeystoneSigning` (triggered by
                // `.keystoneSigningSubmitted` below) pops back up past it.
                let schedule = pendingKeystoneSchedule(context: context, depthBelowTop: 2, state: state)
                // [MOB-1496] (final engine, plural preps): split the signed batch into its
                // preparation (note-split) entries — zero, one, or many — and the schedule's own
                // engine-id-paired entries — ONLY the latter are safe to hand to
                // `storeSignedMigrationTransactions` (all-or-nothing, engine ids only; the real
                // engine rejects a sentinel-prefixed id outright).
                let (prepEntries, scheduleEntries) = MigrationCoordFlow.splitKeystoneBatch(fullSigned)

                return storeKeystoneSignedBatch(
                    context: context,
                    accountUUID: accountUUID,
                    schedule: schedule,
                    prepEntries: prepEntries,
                    scheduleEntries: scheduleEntries
                )

            case .keystoneSigningSubmitted(let context, let pendingScheduleStore):
                return resumeAfterKeystoneSigning(
                    context: context,
                    pendingScheduleStore: pendingScheduleStore,
                    state: &state
                )

            case .keystoneImmediateSubmitted(let txId):
                // MOB-1513: same pop/clear shape as `resumeAfterKeystoneSigning`'s own first four
                // lines (duplicated rather than shared — this lane's completion diverges immediately
                // after: `.success` phase with a known txid, not a resume into `resumeCommittedMigrationChain`).
                state.keystoneImmediateSubmitInFlight = false
                // MOB-1513 (R8, review fix): the ceremony may have been torn down while this
                // coordinator-level effect was in flight (a reject after a swipe-back off `scan`
                // mid-proving — `.keystoneSignRejected` cleared `pendingKeystoneSigning`, the
                // tombstone). The scan/sign elements are gone and the pop-count read below would
                // delete whatever screen the user backed onto instead. The broadcast DID land,
                // so still surface the success — but push it over the CURRENT top without popping
                // anything.
                guard case .immediateReview? = state.pendingKeystoneSigning else {
                    state.path.append(.sending(MigrationSending.State(phase: .success, txId: txId, totalCount: 1)))
                    return .none
                }
                state.pendingKeystoneSigning = nil
                state.pendingKeystoneSigningAccountUUID = nil
                let topElementIsScan = state.path.last?.is(\.scan) == true
                state.path.removeLast(topElementIsScan ? 2 : 1)
                state.path.append(.sending(MigrationSending.State(phase: .success, txId: txId, totalCount: 1)))
                return .none

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
                state.pendingKeystoneSigningAccountUUID = nil
                // MOB-1513 (R8, review fix): a reject can land while a post-scan leg is still in
                // flight (the user swipe-backs off `scan` mid-proving and taps Reject — the
                // coordinator-level submit/apply effects survive the pop). Clear BOTH in-flight
                // guards so the next ceremony starts clean; clearing `pendingKeystoneSigning` above
                // doubles as the tombstone the late completions check before touching the path
                // (see `.keystoneImmediateSubmitted`/`.keystoneImmediateSubmitFailed`).
                state.keystoneBatchApplyInFlight = false
                state.keystoneImmediateSubmitInFlight = false
                // MOB-1513 (R9): a reject mid-sequence discards the whole capped ceremony —
                // accumulated rounds included (no-partial-storage invariant; nothing was stored).
                state.keystoneBatchRounds = nil
                let _ = state.path.popLast()
                // MOB-1458: the pop above can land back on a still-live `.complete` (the dust lane —
                // `beginImmediateKeystoneCeremony` only ever appends over it) whose `isMigratingAnyway`
                // this reject would otherwise leave stranded `true` forever. See
                // `clearMigrateAnywayInFlight`'s doc for why this scans rather than threading an id.
                clearMigrateAnywayInFlight(state: &state)
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
                // would silently resume signing these same, by-then-stale PCZTs.
                //
                // MOB-1513 (final review, N-1 fix): this is the shared sink for every terminal
                // failure of the signing session — deliberately described as open-ended rather than
                // re-enumerated exhaustively (a prior version of this comment listed four call sites
                // and had already drifted stale by the time of this fix, missing four more). Currently
                // that's: the `keystoneSign` build failure; the `.foundKeystoneBatchSignatures`
                // guard-failure fallback (missing `pendingKeystoneSigning`/`signState`/account); BOTH
                // firmware-gate guards (batch envelope and — MOB-1513 R8 — the single-PCZT stamp);
                // the scan-side decode failure (`.scan(.keystoneBatchDecodeFailed)`); the
                // apply-signature failure; the single-PCZT round-trip's guard-failure fallback
                // (`.scan(.foundPCZT)` with a missing context/signState/account); and both the
                // no-preps and with-preps store failures inside `storeKeystoneSignedBatch`.
                // MOB-1513 (R8): the immediate lane's post-signing submit failure is NO LONGER one
                // of them — it routes through `.keystoneImmediateSubmitFailed` (same pop, but arms
                // the Review element's failure sheet and skips the stray-run cancel below, since the
                // engine-external immediate proposal never created a run).
                // v1 semantics hold for all of them, current and future additions alike: abandon
                // discards everything, the user re-runs the ceremony from a fresh preview, so
                // cancelling the stray run is correct here regardless of which guard sent this action.
                //
                // MOB-1513 (final review, I-1 fix): also clears `keystoneBatchApplyInFlight` — every
                // failure route above ends the signing session exactly like the success continuation
                // (`.keystoneBatchSignaturesApplied`) does, so the next ceremony never inherits a
                // stale `true` left over from this one. MOB-1513 (R8): same for the single-PCZT
                // ceremony's own in-flight guard.
                state.keystoneBatchApplyInFlight = false
                state.keystoneImmediateSubmitInFlight = false
                // MOB-1513 (R9): every abandon route discards the capped ceremony's accumulated
                // rounds too — nothing was stored (the stores only ever run after the LAST round),
                // and the engine re-serves the still-unsigned batch on the next attempt.
                state.keystoneBatchRounds = nil
                let pendingContext = state.pendingKeystoneSigning
                let hadPendingCeremony = pendingContext != nil
                state.pendingKeystoneSigning = nil
                state.pendingKeystoneSigningAccountUUID = nil
                // MOB-1496 (C-1 fix): the real round-trip's failure guards above (`.scan` always on
                // top there — pop 2) and the split-store-failure branch of the Keystone store effect
                // (no `.scan` pushed — pop 1) both land here — mirrors `resumeAfterKeystoneSigning`'s
                // identical "how many elements are actually on top" check. MOB-1513: a
                // `MigrationKeystoneSign.Delegate.buildFailed` abandon never pushed `.scan` either
                // (the build failed before `.getSignature` could push it), so it takes the same
                // pop-1 path.
                let topElementIsScan = state.path.last?.is(\.scan) == true
                state.path.removeLast(topElementIsScan ? 2 : 1)
                // MOB-1458: same dust-lane "Migrate anyway" flag fix as `.keystoneSignRejected` above
                // — see `clearMigrateAnywayInFlight`'s doc. Deliberately ahead of the
                // `hadPendingCeremony` guard below: the stray-run cancellation and this UI-flag clear
                // are independent concerns, and the latter must still fire when there is no run to
                // cancel.
                clearMigrateAnywayInFlight(state: &state)

                guard hadPendingCeremony, let accountUUID = state.selectedWalletAccount?.id else { return .none }
                // MOB-1458 (final review C1): the abandon-cancels-the-stray-run premise above
                // ("`pendingKeystoneSigning != nil` ⇒ THIS ceremony created the run ⇒ cancelling is a
                // safe abandon") holds for `.planCommit`/`.immediateReview`, whose ceremony's own
                // `proposeKeystoneBatch`/`createPCZTFromProposal` created the run — but NOT for
                // `.recoveryRefresh`, whose ceremony operates on the long-committed, possibly
                // partially-delivered run that the EXPIRED-transfer refresh rebuilt in place (refresh
                // only rebuilds expired rows; it does not create the run). Cancelling here (a build
                // failure, the firmware gate, an apply failure, or a store failure) would discard the
                // user's committed run without consent — and restart was demoted to an explicit alert
                // choice this very round. Skip the cancel; the rebuilt rows simply re-expire and
                // recovery re-offers, matching the documented process-death behavior.
                if case .recoveryRefresh? = pendingContext { return .none }
                return .run { [sdkSynchronizer, accountUUID] _ in
                    // Fire-and-forget: a failure here just leaves the stray run for the next attempt
                    // to encounter (and cancel) itself, same as today.
                    _ = try? await sdkSynchronizer.restartCurrentMigrationStep(accountUUID)
                }

                // MARK: - Keystone firmware update (MOB-1513)

            case .keystoneFirmwareGatePresentationChanged(let isPresented):
                state.isKeystoneFirmwareGatePresented = isPresented
                if !isPresented {
                    state.detectedKeystoneFirmwareVersion = nil
                    state.keystoneFirmwareGateMinimumVersion = nil
                }
                return .none

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
                // MOB-1458 (code review — F3): deliberately NOT gated behind device authentication
                // (Michal, code review) — record this as a considered exemption, not a gap, if it
                // comes up again. The transfer this pushes `MigrationSending` to broadcast is already
                // SIGNED — signing happened back at the gated plan commit — and the background
                // executor broadcasts that very same signed transfer, unattended, with no
                // authentication, the moment its delivery window opens; this tap just runs that same
                // unauthenticated broadcast in the foreground, sooner. A prompt here would not guard
                // anything the background path doesn't already do without one — it would only be
                // friction a user bypasses by waiting for the next automatic window, never a real
                // security boundary. Contrast the manual-delivery Confirm this file DOES gate
                // (`.reviewTransfer(.delegate(.confirmed))`'s manual-step body): `reentryRoute()`
                // routes manual mode to `.reviewManual`, never `.statusResume`, and manual mode has no
                // automatic/background delivery at all — that tap is the ONLY authorisation moment a
                // manual transfer ever gets, so it must gate. This one doesn't need to.
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

                // MOB-1458 (Task 2): the recovery `.recreate` primary action splits on the attention
                // reason the recovery screen carries (`.expired` == `.transferExpired`, `.notesSpent`
                // == `.invalidTransfer` — see `MigrationManagerLiveKey.reentryRoute`). The reason is
                // read off the `.recovery` element on top of the path (the visible screen when its own
                // button fired), mirroring how `.transferPlan(.delegate(.confirmed))` peeks its plan
                // state.
                //
                // - `.transferExpired`: rebuild the expired transfers IN PLACE first via
                //   `refreshStaleMigrationTransfers` — software re-signs (real usk), then records +
                //   reconciles the committed schedule immediately (record-before-navigation: the SDK
                //   has already re-signed in place by the time the refresh returns, so the app-side
                //   record must not wait on anything the user could still back out of — see that
                //   branch's own doc). MOB-1513 (C7, Figma Error & Recovery row 3 — whose own bullet
                //   copy promises this step): rather than landing straight on Scheduled, this now
                //   shows a Confirm Transfer Plan review screen first; ITS Confirm is what actually
                //   pushes Scheduled (`expiredRecoveryReviewConfirmed`). Keystone re-serves ONLY the
                //   rebuilt rows through the existing QR ceremony (nil usk), but the ceremony no
                //   longer starts as soon as the batch is proposed either — it proposes, then shows
                //   the SAME review screen, and THAT screen's Confirm is what starts the ceremony. A
                //   full restart is offered only as the failure alert's fallback.
                // - `.invalidTransfer`: keep the pre-Task-2 restart behavior (`.recoveryRestartRequested`).
                //
                // MOB-1458 (final review I3): single-flight — set `isRecovering` on the recovery
                // element (disabling its Continue button, showing a spinner) and no-op a second
                // `.recreate` that arrives while one is already in flight. The coordinator owns the
                // async work, so it owns the flag, exactly like `.status(.delegate(.reschedule))` sets
                // `isRescheduling`. The flag is cleared on the failure alert below and reset by the
                // recovery screen's own `.onAppear` when it re-appears after navigating away.
                //
                // MOB-1458 (code review — F2): device-authentication gate. This handler used to run
                // the whole rebuild/re-sign/record body directly. Review found the gate on the
                // EXPIRED-recovery review screen's own Confirm guards only navigation: by the time
                // that screen appears, the software lane has already derived the real spending key,
                // re-signed every rebuilt transfer, and recorded+reconciled the committed schedule
                // (the Keystone lane has already refreshed and proposed a fresh PCZT batch) — ALL with
                // no authentication. Declining on the review screen left a fully committed run for the
                // background executor to deliver anyway. The gate belongs HERE instead, on the tap
                // that actually starts that work, for BOTH vendors: `isRecovering` is set BEFORE
                // prompting (so a second tap arriving mid-prompt still no-ops on the guard above) and
                // cleared on a refusal (`recoveryRecreateAuthenticationCancelled`), exactly as it
                // already was on the failure alert below. `id`/`account`/`reason` are captured HERE,
                // at tap time, and ride `recoveryRecreateAuthenticated` rather than being re-read from
                // `state` after the `authenticate()` await — which then runs the ORIGINAL body
                // verbatim (see that case).
            case .path(.element(id: let id, action: .recovery(.delegate(.recreate)))):
                guard case .recovery(var recoveryState) = state.path[id: id] else { return .none }
                guard !recoveryState.isRecovering else { return .none }
                guard let account = state.selectedWalletAccount else { return .none }
                // Read the reason out BEFORE mutating `recoveryState`: `gated`'s arguments are
                // `@autoclosure`, so they are evaluated inside the effect and would otherwise
                // capture the mutable local rather than its value at tap time.
                let reason = recoveryState.reason
                recoveryState.isRecovering = true
                state.path[id: id] = .recovery(recoveryState)

                return localAuthentication.gated(
                    success: .recoveryRecreateAuthenticated(id: id, account: account, reason: reason),
                    cancelled: .recoveryRecreateAuthenticationCancelled(id: id)
                )

                // MOB-1458 (F2): the gate above passed — the ORIGINAL `.recovery(.delegate(.recreate))`
                // body, moved here verbatim (see that case's doc for the full rebuild/re-sign/record
                // rationale per reason/vendor). `account`/`reason` ride the action rather than being
                // re-read off `state` post-await; `id` isn't needed by this body (nothing here writes
                // back to the `.recovery` element on success — same as before this fix) but rides
                // along for symmetry with the cancellation below.
            case .recoveryRecreateAuthenticated(_, let account, let reason):
                switch reason {
                case .notesSpent:
                    return .send(.recoveryRestartRequested)

                case .expired:
                    // Keystone: refresh with a nil usk (rebuilt rows return UNSIGNED), then propose the
                    // rebuilt batch off the RETURNED schedule. MOB-1513 (C7): the ceremony no longer
                    // starts as soon as the propose succeeds — `recoveryRefreshKeystonePCZTProposed`
                    // stashes the batch on a freshly pushed Confirm Transfer Plan review screen instead
                    // (see that case's doc), and ITS OWN Confirm drives the existing QR ceremony. The
                    // returned schedule is the ONLY value echoed downstream (into `proposeKeystoneBatch`
                    // and, at store time, `recordCommittedSchedule`).
                    guard account.vendor != WalletAccount.Vendor.keystone else {
                        return .run { [sdkSynchronizer, account] send in
                            do {
                                let schedule = try await sdkSynchronizer.refreshStaleMigrationTransfers(account.id, nil)
                                let pczts = try await MigrationCommitPipeline.proposeKeystoneBatch(
                                    schedule: schedule,
                                    account: account,
                                    sdkSynchronizer: sdkSynchronizer
                                )
                                await send(.recoveryRefreshKeystonePCZTProposed(pczts: pczts, schedule: schedule))
                            } catch {
                                await send(.recoveryRefreshFailed)
                            }
                        }
                    }

                    // Software: derive the account's real usk and refresh — the engine re-signs every
                    // rebuilt transfer in place, so on success the run is committed + re-signed and the
                    // flow lands directly on the Scheduled screen with the returned schedule (NOT the
                    // consent plan screen — amounts are unchanged, there is no new consent decision).
                    // A nil usk here would strand the rebuilt rows awaiting a ceremony that never comes,
                    // so a software account must never take the Keystone branch above. A missing
                    // `zip32AccountIndex` on a software account is a "can't happen" — but route it to the
                    // same failure alert rather than a silent `.none`, so the recover button never dies
                    // without feedback.
                    guard let zip32AccountIndex = account.zip32AccountIndex else {
                        return .send(.recoveryRefreshFailed)
                    }
                    let networkType = zcashSDKEnvironment.network().networkType
                    return .run { [sdkSynchronizer, migrationManager, walletStorage, mnemonic, derivationTool, networkType, zip32AccountIndex, account] send in
                        do {
                            let usk = try MigrationSpendingKeyDerivation.deriveUSK(
                                zip32AccountIndex: zip32AccountIndex,
                                walletStorage: walletStorage,
                                mnemonic: mnemonic,
                                derivationTool: derivationTool,
                                networkType: networkType
                            )
                            let schedule = try await sdkSynchronizer.refreshStaleMigrationTransfers(account.id, usk)
                            // Persist the RETURNED schedule as the committed truth BEFORE reconcile —
                            // the SDK keeps no app-facing schedule post-refresh (the refreshed heights/
                            // duration live only in the returned value; see MIGRATING.md), and
                            // `migrationSummary`/`migrationTransfers`/the Home banner all render from the
                            // locally persisted `committedSchedule`. Without this the app would keep
                            // showing the STALE pre-refresh schedule. Matches `commitSoftware`'s
                            // sign -> record -> reconcile order and the Keystone lane's store-time record.
                            // MOB-1513 (C7): this ordering is UNCHANGED even though a review screen sits
                            // between this point and Scheduled now (below) — the SDK has already
                            // re-signed the rebuilt rows IN PLACE by the time `refreshStaleMigrationTransfers`
                            // returns, so the app-side record must not be deferred until that screen's
                            // Confirm: if the user backs out mid-flow from there, the app must still
                            // reflect the re-signed run, never the stale pre-refresh one.
                            await migrationManager.recordCommittedSchedule(account.id, schedule)
                            // Reconcile on success, mirroring the restart path — the refresh's state
                            // transition (e.g. off `.requiresAttention`) is observed promptly.
                            await migrationManager.reconcile()
                            // MOB-1513 (C7, Figma Error & Recovery row 3): lands on the SAME Confirm
                            // Transfer Plan review screen the design now specifies between recovery and
                            // Scheduled, instead of jumping straight there — see `recreatedPlanState`'s
                            // doc. `requiresSigning: false` (the refresh above already re-signed
                            // everything); its own Confirm (`isExpiredRecoveryReview`,
                            // `expiredRecoveryReviewConfirmed`) is what pushes `.scheduled` next,
                            // hydrated from THIS schedule.
                            let planState = recreatedPlanState(schedule: schedule, requiresSigning: false, isExpiredRecoveryReview: true)
                            await send(.pushHydratedPathState(.transferPlan(planState)))
                        } catch {
                            await send(.recoveryRefreshFailed)
                        }
                    }
                }

                // MOB-1458 (F2): the gate above was refused — clear `isRecovering` so the recovery
                // screen's Continue button is tappable again; no alert, no toast, no navigation,
                // matching every other device-authentication refusal in this file.
            case .recoveryRecreateAuthenticationCancelled(let id):
                if case .recovery(var recoveryState) = state.path[id: id] {
                    recoveryState.isRecovering = false
                    state.path[id: id] = .recovery(recoveryState)
                }
                return .none

                // MOB-1458 (Task 2): the `.invalidTransfer` recovery lane AND the expired-recovery
                // failure alert's "restart the step" action both land here — the pre-Task-2
                // recovery-recreate behavior, factored out so both share it. The re-created plan
                // doesn't fold the dust remainder in — same as the initial plan proposal
                // (`MigrationTransferPlanStore.onAppear`); it stays on the separate post-completion
                // "Migrate anyway" lane.
            case .recoveryRestartRequested:
                guard let accountUUID = state.selectedWalletAccount?.id else { return .none }
                return .run { [sdkSynchronizer, migrationManager, accountUUID] send in
                    let restarted = try? await sdkSynchronizer.restartCurrentMigrationStep(accountUUID)
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

                // MOB-1458 (Task 2): the Keystone expired-recovery refresh succeeded and proposed the
                // rebuilt batch. MOB-1513 (C7, Figma Error & Recovery row 3): no longer arms
                // `.recoveryRefresh(schedule:)`/starts the ceremony directly — pushes the SAME Confirm
                // Transfer Plan review screen the software lane gets first, hydrated from the returned
                // schedule, with the already-proposed batch riding the pushed screen's OWN
                // `pendingKeystoneRecoveryBatch` rather than coordinator state (see that field's doc:
                // a pop-back without confirming then discards it for free, TCA tearing the element
                // down). The ceremony itself starts only once THAT screen's Confirm fires
                // (`expiredRecoveryReviewConfirmed`), which is where `.recoveryRefresh(schedule:)`
                // actually gets armed now.
            case .recoveryRefreshKeystonePCZTProposed(let pczts, let schedule):
                let batch = MigrationTransferPlan.State.PendingKeystoneRecoveryBatch(pczts: pczts, schedule: schedule)
                let planState = recreatedPlanState(
                    schedule: schedule,
                    requiresSigning: false,
                    isExpiredRecoveryReview: true,
                    pendingKeystoneRecoveryBatch: batch
                )
                state.path.append(.transferPlan(planState))
                return .none

                // MOB-1458 (Task 2): a refresh (or the Keystone batch propose after it) threw — offer
                // the restart-or-cancel alert. No automatic retry.
            case .recoveryRefreshFailed:
                // MOB-1458 (final review I3): clear the in-flight flag before presenting the alert —
                // the alert shows OVER the still-top recovery screen (no navigation, so its own
                // `.onAppear` won't fire to reset it), and Cancel must leave a tappable Continue button.
                if let recoveryId = state.path.ids.last, case .recovery(var recoveryState) = state.path[id: recoveryId] {
                    recoveryState.isRecovering = false
                    state.path[id: recoveryId] = .recovery(recoveryState)
                }
                state.alert = AlertState.recoveryRefreshFailed()
                return .none

                // MOB-1458 (Task 2): the refresh-failure alert's primary action restarts the step;
                // cancel (`.dismiss`) is handled by `.ifLet` and makes no further calls.
            case .alert(.presented(.restartRequested)):
                return .send(.recoveryRestartRequested)

            case .alert:
                return .none

                // MARK: - Flow-root closes / terminal delegates -> .flowFinished

                // MOB-1458: gates the dust sweep behind device authentication before ANY of the
                // unlock/propose/broadcast machinery below runs — a real spend must never fire off
                // an unauthenticated tap. `localAuthentication.authenticate()` covers Face ID /
                // Touch ID / passcode, and itself already returns `true` on a device with no
                // passcode set (nothing left to gate on then) — so there is nothing to pass in and
                // no new strings to add here. A refusal returns silently: no alert, no toast, no
                // navigation — the user simply stays on Complete with the button live again, exactly
                // like `SendConfirmationStore.sendTapped`/`SwapAndPayCoordFlowCoordinator`'s own
                // confirm taps already do (and matches the Android wallet). The authenticated
                // continuation is deferred to `.migrateAnywayAuthenticated` below, which carries the
                // ENTIRE pre-MOB-1458 handler body verbatim.
                //
                // MOB-1458 (code review — F4/F6): `account` is captured HERE, at tap time, and rides
                // both continuations (`migrateAnywayAuthenticated`'s success,
                // `migrateAnywayAuthenticationCancelled`'s refusal) rather than being re-read from
                // `@Shared` once the prompt resolves — this file's own long-lived-effect convention
                // (see `runFirstDeliveryKick`'s doc: this case lives in `coordinatorReduce()`, not
                // under `.forEach(\.path,…)`, so nothing auto-cancels it on a pop either way).
                // `CancelID.migrateAnywayAuthentication`, keyed by account like
                // `CancelID.deferredScheduleStoreRearm` (MOB-1509: this coordinator is a single
                // permanent `Scope` shared by every account), covers the whole gate+continuation
                // chain — both `.cancellable` sites below share it. The `nil`-account branch is a
                // "can't happen" (Complete only ever shows for the selected account's own run) but,
                // like the software recovery lane's `zip32AccountIndex` guard, still routes to the
                // SAME clearing action the refusal uses rather than silently stranding the caller's
                // `isMigratingAnyway` flag with no prompt ever shown.
            case .path(.element(id: let id, action: .complete(.delegate(.migrateAnyway)))):
                guard let account = state.selectedWalletAccount else {
                    return .send(.migrateAnywayAuthenticationCancelled(id: id))
                }
                return localAuthentication.gated(
                    success: .migrateAnywayAuthenticated(id: id, account: account),
                    cancelled: .migrateAnywayAuthenticationCancelled(id: id)
                )
                .cancellable(id: MigrationCoordFlow.CancelID.migrateAnywayAuthentication(account.id), cancelInFlight: true)

                // MOB-1458 (F2/F4): the refusal arm of both gates in this file clears the tapped
                // screen's own in-flight flag so its button goes live again — no alert, no toast, no
                // navigation either way.
            case .migrateAnywayAuthenticationCancelled(let id):
                if case .complete(var completeState) = state.path[id: id] {
                    completeState.isMigratingAnyway = false
                    state.path[id: id] = .complete(completeState)
                }
                return .none

                // MOB-1496 (W-B): "Migrate anyway" now rides the SAME immediate (send-max) lane the
                // entry-screen migration uses, for both vendors — see this file's header doc.
                // Unlock-first is LOAD-BEARING: a locked residual is excluded from send-max note
                // selection, so `proposeImmediateMigration` must never run before
                // `unlockMigrationResidual` completes. A propose/unlock failure on EITHER vendor
                // falls back to the same generic Sending-screen failure sheet
                // (`isFailurePresented: true`) every other broadcast failure already uses — no new
                // UI. Entry-screen immediate migrations must NEVER call `unlockMigrationResidual`
                // (a locked residual staying excluded from later sweeps is correct-by-construction);
                // this is the ONE call site that does.
                //
                // MOB-1458: reached only once `.complete(.delegate(.migrateAnyway))` above has
                // already authenticated — this case is otherwise byte-for-byte the pre-MOB-1458
                // handler, moved down verbatim (MOB-1458 code review, F4: each catch now also sends
                // `.migrateAnywayFailed(id:)` ahead of the existing failure-sheet push, and both
                // effects share the gate's `CancelID.migrateAnywayAuthentication`).
            case .migrateAnywayAuthenticated(let id, let account):
                guard account.vendor != WalletAccount.Vendor.keystone else {
                    return .run { [sdkSynchronizer, accountUUID = account.id] send in
                        do {
                            _ = try await sdkSynchronizer.unlockMigrationResidual(accountUUID)
                            let proposal = try await sdkSynchronizer.proposeImmediateMigration(accountUUID)
                            let pczt = try await sdkSynchronizer.createPCZTFromProposal(accountUUID, proposal.proposal)
                            // MOB-1513 (R8): redacted-for-signer wire copy — the production
                            // single-PCZT ceremony's QR payload, exactly like
                            // `MigrationReviewTransferStore.requestKeystoneSignature`.
                            let redacted = try await sdkSynchronizer.redactPCZTForSigner(Pczt(pczt))
                            await send(
                                .migrateAnywayImmediateKeystonePCZTProposed(unsigned: pczt, redacted: redacted)
                            )
                        } catch {
                            LoggerProxy.error("[MOB-1513] Migrate-anyway Keystone propose/PCZT/redact failed: \(error)")
                            await send(.migrateAnywayFailed(id: id))
                            await send(.pushHydratedPathState(.sending(MigrationSending.State(isFailurePresented: true, totalCount: 1))))
                        }
                    }
                    .cancellable(id: MigrationCoordFlow.CancelID.migrateAnywayAuthentication(account.id))
                }

                return .run { [sdkSynchronizer, accountUUID = account.id] send in
                    do {
                        _ = try await sdkSynchronizer.unlockMigrationResidual(accountUUID)
                        let proposal = try await sdkSynchronizer.proposeImmediateMigration(accountUUID)
                        await send(.pushHydratedPathState(.sending(MigrationSending.State(totalCount: 1, immediateProposal: proposal))))
                    } catch {
                        await send(.migrateAnywayFailed(id: id))
                        await send(.pushHydratedPathState(.sending(MigrationSending.State(isFailurePresented: true, totalCount: 1))))
                    }
                }
                .cancellable(id: MigrationCoordFlow.CancelID.migrateAnywayAuthentication(account.id))

                // MOB-1458 (F4): the unlock/propose (or Keystone PCZT build+redact) leg above threw —
                // clear `isMigratingAnyway` on the `.complete` element with the given id so a user who
                // pops back from the failure sheet this is paired with finds "Migrate anyway" tappable
                // again, exactly like the refusal above.
            case .migrateAnywayFailed(let id):
                if case .complete(var completeState) = state.path[id: id] {
                    completeState.isMigratingAnyway = false
                    state.path[id: id] = .complete(completeState)
                }
                return .none

            case .migrateAnywayImmediateKeystonePCZTProposed(let unsigned, let redacted):
                // Mirrors `.reviewTransfer(.delegate(.keystoneImmediateSignRequested))`'s handler
                // exactly — this hop reaches the identical `.immediateReview` single-PCZT ceremony
                // from a different starting screen (Complete instead of ReviewTransfer).
                state.pendingKeystoneSigning = .immediateReview
                state.pendingKeystoneSigningAccountUUID = state.selectedWalletAccount?.id
                beginImmediateKeystoneCeremony(unsigned: unsigned, redacted: redacted, state: &state)
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

    /// Scheduled/recreated hydrate + push `.scheduled` (MOB-1458 W-E — an async peek is needed to
    /// hydrate, so this follows the `pushHydratedPathState` idiom rather than appending
    /// synchronously); manual pushes `.sending` (totalCount 1, current network-privacy options)
    /// synchronously, unchanged. Either way, schedules the first background window after. Shared by
    /// the software `TransferPlan.delegate(.confirmed)` row and the Keystone `planCommit` resume
    /// (`resumeAfterKeystoneSigning`), which both reach this point with a signed schedule.
    ///
    /// MOB-1513 (B4): the confirm chain is sign-only now — nothing has broadcast by the time this
    /// runs. The `.scheduled`/`.recreated` branch fires the FIRST-DELIVERY KICK right after landing
    /// on B9 Migration Scheduled ("splits execute immediately"): `runFirstDeliveryKick` broadcasts
    /// the next due transaction (the first prep, when the run has any) over the existing next-due
    /// lane, and — for a Keystone commit whose schedule store was deferred
    /// (`state.pendingKeystoneScheduleStore`) — runs that deferred store once the broadcast lands.
    /// The `.manual` branch keeps its Sending-screen delivery (that screen's own `onAppear`
    /// broadcast IS the first-delivery mechanism there) and fires the kick ONLY when a deferred
    /// Keystone schedule store is pending — the kick then owns the prep broadcast + store handshake,
    /// and the Sending screen's own concurrent attempt resolves to a nil next-due naturally (the
    /// SDK's per-account broadcast flow is single-flight).
    ///
    /// Software `.scheduled`/`.recreated` commits recorded their schedule at confirm, so
    /// `scheduledState`'s summary read is fully hydrated; a Keystone deferred commit hasn't recorded
    /// yet, so it hydrates via `deferredScheduledState` (see its doc).
    private func transferPlanPostConfirmChain(
        variant: MigrationTransferPlan.State.Variant,
        schedule: MigrationSchedule?,
        state: inout MigrationCoordFlow.State
    ) -> Effect<MigrationCoordFlow.Action> {
        let accountUUID = state.selectedWalletAccount?.id
        let pendingScheduleStore = state.pendingKeystoneScheduleStore
        switch variant {
        case .scheduled, .recreated:
            return .run { [migrationBGScheduler, accountUUID, schedule, pendingScheduleStore] send in
                let scheduledState = pendingScheduleStore != nil
                    ? await deferredScheduledState(accountUUID: accountUUID, schedule: schedule)
                    : await scheduledState(accountUUID: accountUUID, schedule: schedule)
                await send(.pushHydratedPathState(.scheduled(scheduledState)))
                await migrationBGScheduler.scheduleFirstWindow()
                await runFirstDeliveryKick(accountUUID: accountUUID, pendingScheduleStore: pendingScheduleStore, send: send)
            }
        case .manual:
            // MOB-1497 (T8, Q3'26 canvas): the manual-delivery run's FIRST transfer — same "sent"
            // success wording as every subsequent manual-step confirm (see the
            // `.reviewTransfer(.delegate(.confirmed))` case above).
            let sendingState = MigrationSending.State(totalCount: 1, isManualStepLane: true)
            state.path.append(.sending(sendingState))
            return .run { [migrationBGScheduler, accountUUID, pendingScheduleStore] send in
                await migrationBGScheduler.scheduleFirstWindow()
                if pendingScheduleStore != nil {
                    await runFirstDeliveryKick(accountUUID: accountUUID, pendingScheduleStore: pendingScheduleStore, send: send)
                }
            }
        }
    }

    // MARK: - MOB-1513 (C7): expired-recovery review screen's own post-confirm chain

    /// The expired-transfer recovery review screen's Confirm (Figma Error & Recovery row 3) —
    /// reached only via `MigrationTransferPlan.State.isExpiredRecoveryReview` (see the
    /// `.transferPlan(.delegate(.confirmed))` case above). Deliberately NOT routed through
    /// `transferPlanPostConfirmChain`: that helper also fires `scheduleFirstWindow()`/the first-
    /// delivery kick, side effects a fresh plan commit needs but this lane's refresh already doesn't
    /// — nothing was newly scheduled here, so re-running them would be new behavior this task never
    /// asked for, not a preserved one.
    ///
    /// Software: `recordCommittedSchedule`/`reconcile` already ran, BEFORE this screen was even
    /// pushed (see the `.expired` software branch's own doc) — this is nothing more than a hydrate-
    /// and-push, the exact same `scheduledState` hydration `transferPlanPostConfirmChain`'s
    /// `.scheduled`/`.recreated` branch uses. Confirm never re-signs or re-records here.
    ///
    /// Keystone: the batch was already proposed (`recoveryRefreshKeystonePCZTProposed`) and rides on
    /// THIS screen's own `pendingKeystoneRecoveryBatch` (never coordinator state — see that field's
    /// doc for why). Confirm arms `.recoveryRefresh(schedule:)` and starts the ceremony exactly like
    /// the original `.recoveryRefreshKeystonePCZTProposed` handler did before this review step
    /// existed — the ceremony's own completion/store/abandon semantics (`resumeCommittedMigrationChain`'s
    /// `.recoveryRefresh` case, `keystoneScanAbandoned`'s recovery-refresh skip-cancel branch) are
    /// untouched, so it still lands on Scheduled the same way once signing completes.
    private func expiredRecoveryReviewConfirmed(
        schedule: MigrationSchedule?,
        pendingKeystoneRecoveryBatch: MigrationTransferPlan.State.PendingKeystoneRecoveryBatch?,
        state: inout MigrationCoordFlow.State
    ) -> Effect<MigrationCoordFlow.Action> {
        guard let pendingKeystoneRecoveryBatch else {
            let accountUUID = state.selectedWalletAccount?.id
            return .run { [accountUUID, schedule] send in
                let scheduled = await scheduledState(accountUUID: accountUUID, schedule: schedule)
                await send(.pushHydratedPathState(.scheduled(scheduled)))
            }
        }
        state.pendingKeystoneSigning = .recoveryRefresh(schedule: pendingKeystoneRecoveryBatch.schedule)
        state.pendingKeystoneSigningAccountUUID = state.selectedWalletAccount?.id
        beginKeystoneCeremony(pczts: pendingKeystoneRecoveryBatch.pczts, state: &state)
        return .none
    }

    /// MOB-1458 (W-E): hydrates `MigrationScheduled.State` from the manager's summary PLUS the
    /// just-committed `schedule` in scope. `totalAmount`/`sentCount`/`totalCount` are cumulative
    /// across the whole logical run (not just this commit): `summary.transfersSent`/`transfersTotal`
    /// already fold in the persisted `sentRecords` from any PRIOR schedule the same run committed
    /// (`MigrationScheduleStorage.recordCommittedSchedule`'s "preserves sentRecords" doc), so a
    /// `.recreated` re-entry (some transfers already broadcast under an earlier schedule for this
    /// run) reports the WHOLE run's numbers — consistent with those cumulative counts, not just the
    /// fresh schedule's own. `totalAmount` mirrors that: `summary.transferred` (already-sent value)
    /// plus `schedule`'s own (not-yet-sent) transfer sum. For a genuinely fresh `.scheduled` commit
    /// `transferred`/`transfersSent` are naturally `.zero`/`0` (nothing persisted sent yet), so this
    /// collapses to exactly the new schedule's own totals — matching the B9 canvas's "Transfers 0
    /// of 6". `durationHours`/`dustAmount` come straight from the summary: `estimatedDurationHours`
    /// is the fresh schedule's own remaining-time estimate; `dust` rides the SDK's stored-plan
    /// residual (non-terminal migration state, so `residualAfterMigration` returns the STORED
    /// value, not a live replan — verified against `rust/src/migration.rs`), which is final/stable
    /// at this moment, not a value that can silently change while this screen is up.
    private func scheduledState(accountUUID: AccountUUID?, schedule: MigrationSchedule?) async -> MigrationScheduled.State {
        let summary = await migrationManager.migrationSummary(accountUUID)
        let newScheduleAmount = schedule?.transfers.reduce(Zatoshi.zero) { $0 + $1.amount } ?? Zatoshi.zero
        return MigrationScheduled.State(
            // `summary.transferred` is only `nil` on the W1 fallback (no committed schedule) —
            // impossible here, since this screen hydrates right after `recordCommittedSchedule` has
            // already run; `Zatoshi.zero` is the correct additive identity regardless (nothing
            // ALREADY sent to add on top of the fresh schedule's own total).
            totalAmount: (summary.transferred ?? Zatoshi.zero) + newScheduleAmount,
            sentCount: summary.transfersSent,
            totalCount: summary.transfersTotal,
            // Same reasoning as `totalAmount` above — `summary.estimatedDurationHours` is only
            // `nil` on the W1 fallback, which a just-committed schedule has already left; `0` never
            // surfaces in practice, but is the correct fallback if it somehow did.
            durationHours: summary.estimatedDurationHours ?? 0,
            dustAmount: summary.dust
        )
    }

    /// MOB-1513 (B4): `scheduledState`'s twin for the Keystone DEFERRED-store window — B9 is pushed
    /// before `recordCommittedSchedule` has run (the kick records only after its prep broadcast
    /// lands), so `migrationSummary`'s schedule-derived fields would read the PREVIOUS payload (a
    /// `.recreated` re-entry) or the degraded progress-only fallback (a fresh commit — whose `dust`
    /// would even read the whole unmigrated balance). The schedule-derived numbers come from the
    /// in-hand `schedule` instead, combined with the summary's prior-sent bookkeeping (correct in
    /// both windows: prior payload for `.recreated`, zeros for fresh), and `dustAmount` reads the
    /// SDK's stored-run residual live (the run IS stored engine-side at this point — the same
    /// residual-first precedence `MigrationDerivations.summary` applies). Post-store, the regular
    /// `scheduledState` numbers and these agree by construction.
    private func deferredScheduledState(accountUUID: AccountUUID?, schedule: MigrationSchedule?) async -> MigrationScheduled.State {
        let summary = await migrationManager.migrationSummary(accountUUID)
        let newScheduleAmount = schedule?.transfers.reduce(Zatoshi.zero) { $0 + $1.amount } ?? Zatoshi.zero
        var residual: Zatoshi?
        if let accountUUID {
            residual = (try? await sdkSynchronizer.residualAfterMigration(accountUUID)) ?? nil
        }
        return MigrationScheduled.State(
            // Unlike `scheduledState`, this window genuinely CAN hit the W1 fallback (called
            // BEFORE `recordCommittedSchedule` runs — see this method's own doc): `nil` there means
            // "no prior schedule's sent total exists yet", so `Zatoshi.zero` is the mathematically
            // correct amount to add, not a placeholder.
            totalAmount: (summary.transferred ?? Zatoshi.zero) + newScheduleAmount,
            sentCount: summary.transfersSent,
            totalCount: summary.transfersSent + (schedule?.transfers.count ?? 0),
            // `schedule` (the in-hand fresh proposal) is the real primary source and always wins
            // when present; `summary.estimatedDurationHours` only backs it up when `schedule` is
            // nil too (defensive), and `0` only if BOTH are unavailable.
            durationHours: schedule?.estimatedDurationHours ?? summary.estimatedDurationHours ?? 0,
            dustAmount: residual ?? Zatoshi.zero
        )
    }

    // MARK: - MOB-1513 (B4): post-confirm first-delivery kick

    /// The coordinator-owned background task fired right after landing on B9 Migration Scheduled
    /// (design: "everything signed at once, splits execute immediately, transfers per offsets") —
    /// broadcasts the next due transaction over the EXISTING next-due lane, exactly the closure the
    /// BG-window path uses (`executeNextPendingMigrationTransfer`: serves preps AND transfers,
    /// proves at broadcast — the one-time Orchard proving-key build happens HERE, off the confirm
    /// tap, not under it — is retry-idempotent, and is per-account single-flight SDK-side; the
    /// transaction guard lives inside its LiveKey, never wrapped here). Stop-sync first, exactly
    /// like every other broadcast lane.
    ///
    /// Per-attempt outcomes (all SILENT — B4 controller resolution 3: broadcast failure needs NO
    /// UI; the run stays `splitPendingConfirmation` engine-side, the progress banner/route reflect
    /// it, and BG windows + foreground reconcile retry preps naturally):
    /// - Landed (`.success`, or the landed-but-record-failed
    ///   `ZcashError.migrationRecordFailedAfterBroadcast`): `recordTransferBroadcast` (the
    ///   had-broadcast/episode chokepoint — its prep-phase guard keeps a prep out of the schedule's
    ///   sent records), then the deferred Keystone schedule store when one is pending, then
    ///   `reconcile()` so the banner/status pick the fresh state up promptly.
    /// - `nil` (nothing due) with NO pending store: a valid, silent no-op (e.g. a no-split
    ///   schedule whose first transfer isn't due yet) — nudge the gate only.
    /// - `nil` WITH a pending store: a prep broadcast has necessarily ALREADY landed — the stash
    ///   only exists for a preps-carrying run whose first prep is due immediately, so an exhausted
    ///   next-due means every currently-due prep is broadcast-recorded (possibly by a concurrent
    ///   BG-window lane; the SDK's single-flight typically answers `nil` exactly then). That is the
    ///   C-1b-safe point, so run the deferred store now (also how a retry attempt resolves a store
    ///   that failed after an earlier attempt's landed broadcast).
    /// - Failure result / thrown error: classify+route (`routeBroadcastFailure` — R16
    ///   rotation/Tor-hold bookkeeping only, same re-arm-only treatment as the BG lane; the
    ///   background Tor prompt latch stays BG-lane-only) and nudge `refreshMigrationSyncGate()`
    ///   (the stop above was never followed by a landed broadcast).
    ///
    /// MOB-1513 (B4 fix wave) — a Keystone deferred store must NEVER be stranded by one flaky
    /// attempt (the pre-fix one-shot kick was: a Tor bootstrap flake at confirm time left the stash
    /// unread forever while BG windows later broadcast the prep WITHOUT the store, stranding the
    /// run once it mined). Two silent recovery layers when `pendingScheduleStore != nil`:
    /// 1. Bounded in-kick retries: up to `firstDeliveryKickMaxAttempts` attempts,
    ///    `firstDeliveryKickRetryDelay` apart (covers the transient confirm-time flake). The
    ///    software lane keeps its single attempt — the engine holds everything it needs and BG
    ///    windows retry preps naturally there.
    /// 2. State-event re-arm: exhausting the attempts sends `.firstDeliveryKickFailed`, which
    ///    subscribes to `migrationManager.stateEvents` and runs one `resolveDeferredScheduleStore`
    ///    per emission (see that method's doc) until the store lands.
    ///
    /// Lifecycle (corrected in review): `MigrationCoordFlow` is a permanent `Scope` child of Root
    /// (`RootStore.swift`), NOT a dismissable presentation — closing the flow ("Got it",
    /// `.flowFinished`) resets coordinator STATE and runs Root's cleanup effects, but cancels no
    /// in-flight effects. This kick, the re-arm subscription, and their captured
    /// `pendingScheduleStore` payloads therefore run to completion after a close by design (which
    /// is also why the payload always rides closures/actions and is never re-read from state).
    /// The remaining ACCEPTED loss window is app death while the store is still pending (the stash
    /// is in-memory only, per the plan's no-new-persistence constraint) — the existing recovery
    /// flow (restart + fresh ceremony) is the way out, same as pre-B4's force-quit window.
    private func runFirstDeliveryKick(
        accountUUID: AccountUUID?,
        pendingScheduleStore: MigrationCoordFlow.PendingScheduleStore?,
        send: Send<MigrationCoordFlow.Action>
    ) async {
        guard let accountUUID else { return }
        let maxAttempts = pendingScheduleStore != nil ? Self.firstDeliveryKickMaxAttempts : 1
        for attempt in 1...maxAttempts {
            let resolved = await attemptFirstDelivery(
                accountUUID: accountUUID,
                pendingScheduleStore: pendingScheduleStore,
                send: send
            )
            if resolved { return }
            guard attempt < maxAttempts else { break }
            try? await clock.sleep(for: Self.firstDeliveryKickRetryDelay)
        }
        if let pendingScheduleStore {
            await send(.firstDeliveryKickFailed(pendingScheduleStore: pendingScheduleStore, accountUUID: accountUUID))
        }
    }

    /// MOB-1513 (B4 fix wave): one attempt of the first-delivery kick — see `runFirstDeliveryKick`'s
    /// doc for the outcome table. Returns `true` when the kick's job is done (broadcast landed and
    /// any pending store resolved, or nothing was due and no store was pending), `false` when a
    /// retry could still help (broadcast failed, or a landed broadcast's deferred store failed —
    /// the next attempt's `nil` arm retries the store without re-broadcasting).
    private func attemptFirstDelivery(
        accountUUID: AccountUUID,
        pendingScheduleStore: MigrationCoordFlow.PendingScheduleStore?,
        send: Send<MigrationCoordFlow.Action>
    ) async -> Bool {
        let options = await migrationManager.migrationNetworkOptions(accountUUID)
        await sdkSynchronizer.stopSyncBeforeMigrationBroadcast()
        do {
            let result = try await sdkSynchronizer.executeNextPendingMigrationTransfer(accountUUID, options)
            switch result {
            case .some(let result):
                if case MigrationTransferResult.success = result {
                    return await finishLandedFirstDelivery(
                        accountUUID: accountUUID,
                        result: result,
                        pendingScheduleStore: pendingScheduleStore,
                        send: send
                    )
                }
                _ = await migrationManager.routeBroadcastFailure(accountUUID, result: result)
                await migrationManager.refreshMigrationSyncGate()
                return false

            case nil:
                guard let pendingScheduleStore else {
                    await migrationManager.refreshMigrationSyncGate()
                    return true
                }
                // A prep broadcast already landed (see the `nil`-with-pending-store outcome in
                // `runFirstDeliveryKick`'s doc) — run the deferred store now. The stop above was
                // not followed by a landed broadcast in THIS attempt, so still nudge the gate.
                let resolved = await resolvePendingScheduleStore(pendingScheduleStore, send: send)
                await migrationManager.refreshMigrationSyncGate()
                return resolved
            }
        } catch ZcashError.migrationRecordFailedAfterBroadcast {
            // The broadcast DID land; only the engine's own recording of it failed — same
            // landed-broadcast continuation as `.success`, with the empty-txId placeholder every
            // other lane uses for this error.
            return await finishLandedFirstDelivery(
                accountUUID: accountUUID,
                result: MigrationTransferResult.success(txId: ""),
                pendingScheduleStore: pendingScheduleStore,
                send: send
            )
        } catch {
            _ = await migrationManager.routeBroadcastFailure(accountUUID, error: error)
            await migrationManager.refreshMigrationSyncGate()
            return false
        }
    }

    /// The kick's landed-broadcast continuation: had-broadcast/episode bookkeeping first (mirrors
    /// the pre-B4 order — record before the deferred store), then — MOB-1496 C-1b, re-homed — the
    /// deferred Keystone schedule store `storeKeystoneSignedBatch` stashed: the prep broadcast just
    /// landed, which is the earliest point the C-1b trace proved safe to store the schedule.
    /// Returns whether the kick's job is fully done — `false` only when the deferred store failed
    /// (kept silent; the retry/re-arm layers retry the store, never the already-landed broadcast).
    private func finishLandedFirstDelivery(
        accountUUID: AccountUUID,
        result: MigrationTransferResult,
        pendingScheduleStore: MigrationCoordFlow.PendingScheduleStore?,
        send: Send<MigrationCoordFlow.Action>
    ) async -> Bool {
        await migrationManager.recordTransferBroadcast(accountUUID, result)

        guard let pendingScheduleStore else {
            await migrationManager.reconcile()
            return true
        }

        return await resolvePendingScheduleStore(pendingScheduleStore, send: send)
    }

    /// The deferred Keystone schedule store itself (`storeSignedMigrationTransactions` ->
    /// `recordCommittedSchedule` -> `reconcile` -> release the stash via
    /// `.deferredKeystoneScheduleStored`). A store failure returns `false` with NOTHING recorded and
    /// no reconcile — mirroring the pre-B4 handshake's "no premature reconcile before the schedule
    /// store settles" — leaving the retry/re-arm layers to try again.
    private func resolvePendingScheduleStore(
        _ pendingScheduleStore: MigrationCoordFlow.PendingScheduleStore,
        send: Send<MigrationCoordFlow.Action>
    ) async -> Bool {
        guard (try? await sdkSynchronizer.storeSignedMigrationTransactions(pendingScheduleStore.accountUUID, pendingScheduleStore.scheduleEntries)) != nil else {
            return false
        }
        if let schedule = pendingScheduleStore.schedule {
            await migrationManager.recordCommittedSchedule(pendingScheduleStore.accountUUID, schedule)
        }
        await migrationManager.reconcile()
        await send(.deferredKeystoneScheduleStored(pendingScheduleStore.accountUUID))
        return true
    }

    /// MOB-1513 (B4 fix wave): one silent resolve attempt per `stateEvents` emission while the
    /// re-arm is active (`.firstDeliveryKickFailed` armed it after the kick's bounded attempts
    /// exhausted). Runs the SAME single attempt the kick does — probe the next-due lane, store on a
    /// landed or exhausted outcome, stay silent on failure — so whichever lane lands the prep (a
    /// BG-window broadcast, this probe itself once the network recovers, or foreground reconcile
    /// observing the mined prep and emitting the state change that triggered this) leads to the
    /// deferred store, which cancels the re-arm via `.deferredKeystoneScheduleStored`. Emissions
    /// are change-driven and rare (`pushStateIfChanged`), so per-event single attempts stay cheap;
    /// `stateEvents` replays the current value on subscribe, which doubles as one immediate retry.
    private func resolveDeferredScheduleStore(
        accountUUID: AccountUUID,
        pendingScheduleStore: MigrationCoordFlow.PendingScheduleStore,
        send: Send<MigrationCoordFlow.Action>
    ) async {
        _ = await attemptFirstDelivery(
            accountUUID: accountUUID,
            pendingScheduleStore: pendingScheduleStore,
            send: send
        )
    }

    // MARK: - Keystone signing (MOB-1468): resume after store

    /// Pops back to the signing-source element and resumes whichever chain `context` represents —
    /// `resumeCommittedMigrationChain(context:state:)` proceeds straight to the post-commit screen,
    /// mirroring how the equivalent software `.confirmed` row would proceed.
    ///
    /// MOB-1513 (B4): a batch that carried preparation (note-split) entries no longer detours
    /// through a "Splitting Funds" screen — the preps are already stored (the ceremony's store
    /// effect ran `storeSignedNoteSplits` before this), the flow lands on B9 Migration Scheduled
    /// like any other commit, and the post-confirm first-delivery kick broadcasts the first prep
    /// and runs the deferred schedule store (`pendingScheduleStore`, stashed here into
    /// `state.pendingKeystoneScheduleStore` — MOB-1496 C-1b: the schedule may only store after a
    /// prep broadcast lands) — see `runFirstDeliveryKick`'s doc.
    ///
    /// The real QR round-trip pushes `scan` on top of `keystoneSign` (2 elements to unwind back to
    /// the signing source). Rather than trust the caller, this reads the actual top of the path —
    /// `.scan` on top (the QR round-trip's only shape) pops 2; anything else pops 1, a defensive
    /// fallback that predates the MOB-1458 removal of a former simulator-only bypass caller that
    /// never pushed `scan`.
    ///
    /// Clears `pendingKeystoneSigning` in every case.
    private func resumeAfterKeystoneSigning(
        context: MigrationCoordFlow.KeystoneSigningContext,
        pendingScheduleStore: MigrationCoordFlow.PendingScheduleStore?,
        state: inout MigrationCoordFlow.State
    ) -> Effect<MigrationCoordFlow.Action> {
        state.pendingKeystoneSigning = nil
        state.pendingKeystoneSigningAccountUUID = nil
        // MOB-1513 (R9): belt — the last-round store handoff already cleared the rounds state.
        state.keystoneBatchRounds = nil
        let topElementIsScan = state.path.last?.is(\.scan) == true
        state.path.removeLast(topElementIsScan ? 2 : 1)

        state.pendingKeystoneScheduleStore = pendingScheduleStore

        return resumeCommittedMigrationChain(context: context, state: &state)
    }

    /// MOB-1496 (W6; MOB-1513 B4): the shared post-commit resume — `resumeAfterKeystoneSigning`
    /// lands here for EVERY `planCommit` batch now (with or without preps — the with-preps
    /// note-split detour is retired), so the ceremony reaches the identical post-commit routing the
    /// software path's `.confirmed` row would.
    private func resumeCommittedMigrationChain(
        context: MigrationCoordFlow.KeystoneSigningContext,
        state: inout MigrationCoordFlow.State
    ) -> Effect<MigrationCoordFlow.Action> {
        switch context {
        case .planCommit:
            guard case let .transferPlan(planState) = state.path.last else { return .none }
            return transferPlanPostConfirmChain(variant: planState.variant, schedule: planState.schedule, state: &state)

        case .immediateReview:
            // MOB-1513/MOB-1496 (W-B): unreachable in practice — `submitImmediateKeystoneTransaction`
            // intercepts `.immediateReview` at the real `.scan(.foundKeystoneBatchSignatures)` round-trip, the sole
            // caller of `resumeAfterKeystoneSigning`, before it ever reaches this function, for BOTH
            // producers of this context (the entry-screen immediate lane and "Migrate anyway") — the
            // immediate lane's single ordinary-send PCZT (`createPCZTFromProposal`) never carries
            // note-split preps for the split-routing branch above to route here either. Kept only for
            // this switch's exhaustiveness; if it ever DID run, it would incorrectly push a fresh
            // `.sending` broadcast attempt for a transaction `submitImmediateKeystoneTransaction` already
            // submitted.
            let sendingState = MigrationSending.State(totalCount: 1)
            state.path.append(.sending(sendingState))
            return .none

        case .recoveryRefresh(let schedule):
            // MOB-1458 (Task 2): the Keystone expired-recovery ceremony lands on the SAME Scheduled
            // screen the software lane pushes, hydrated from the RETURNED post-refresh schedule.
            //
            // NORMAL refresh (no preps): `storeKeystoneSignedBatch` already stored + recorded +
            // reconciled the schedule inline (`pendingKeystoneScheduleStore == nil`), so this is the
            // no-kick, software-symmetric landing — a refresh re-spends existing funding notes on
            // fresh scheduled heights and the rebuilt transfers deliver via the existing next-due
            // machinery.
            //
            // MOB-1458 (final review I2, defensive): if a refresh ever DID serve preparation
            // (note-split) entries (candidate path: a prior `.keystoneSignRejected` left the run's
            // preps unsigned → they expire → a recovery refresh re-serves them),
            // `storeKeystoneSignedBatch` deferred the schedule store into `pendingKeystoneScheduleStore`
            // — so run the SAME first-delivery kick the `planCommit` lane uses (broadcast the prep, then
            // the deferred `storeSignedMigrationTransactions` + `recordCommittedSchedule`), and hydrate
            // via `deferredScheduledState`, rather than dropping the signed transfers + committed
            // schedule on the floor while the UI reports success. Whether that path is engine-reachable
            // is unconfirmed; this is cheap and harmless if unreachable. Split into two effects so the
            // NORMAL (no-stash) path never even CAPTURES `migrationBGScheduler` — reading an
            // `@Dependency` at capture time resolves it, which would otherwise force every no-preps
            // recovery test to stub a BG-scheduler member it never calls.
            let accountUUID = state.selectedWalletAccount?.id
            guard let pendingScheduleStore = state.pendingKeystoneScheduleStore else {
                return .run { [accountUUID, schedule] send in
                    let scheduled = await scheduledState(accountUUID: accountUUID, schedule: schedule)
                    await send(.pushHydratedPathState(.scheduled(scheduled)))
                }
            }
            return .run { [migrationBGScheduler, accountUUID, schedule, pendingScheduleStore] send in
                let scheduled = await deferredScheduledState(accountUUID: accountUUID, schedule: schedule)
                await send(.pushHydratedPathState(.scheduled(scheduled)))
                await migrationBGScheduler.scheduleFirstWindow()
                await runFirstDeliveryKick(accountUUID: accountUUID, pendingScheduleStore: pendingScheduleStore, send: send)
            }
        }
    }

    // MARK: - MOB-1496 (R8-T2 #20): shared Keystone signed-batch store sequence

    /// The store sequence for a signed Keystone batch — called by the real `.scan(.foundKeystoneBatchSignatures)`
    /// round-trip (its only caller since MOB-1458 removed the simulator-only bypass that used to
    /// share it; the two ran this as token-identical twins before this extraction, when two prior
    /// ordering fixes, C-1/C-1b — see this file's header comment — had to be applied to both in
    /// lockstep).
    ///
    /// No preps: stores the schedule immediately, exactly as before. R8-T2 (#5 fix): success
    /// bookkeeping (`.keystoneSigningSubmitted`, which drives `resumeAfterKeystoneSigning` into
    /// `transferPlanPostConfirmChain`'s `scheduleFirstWindow()`) fires ONLY when the store call
    /// actually succeeds — the code this replaced discarded a thrown error into a bare `Bool`
    /// (`(try? await ...) != nil`) and fired `.keystoneSigningSubmitted` regardless, landing on the
    /// terminal "Migration Scheduled" screen with nothing stored in the engine and no schedule
    /// recorded. On failure this abandons instead (`keystoneScanAbandoned` semantics — same as an
    /// apply-signature failure or the prep-store failure below), the honest-failure surface.
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
    /// below: storing preps (and letting them broadcast) before the schedule is stored. MOB-1513
    /// (B4): the deferred store's home moved from the retired "Splitting Funds" handshake to the
    /// post-confirm first-delivery kick — see `runFirstDeliveryKick`'s doc.
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
                do {
                    try await sdkSynchronizer.storeSignedMigrationTransactions(accountUUID, scheduleEntries)
                } catch {
                    // MOB-1513 (R8, F3): log before abandoning — same observability treatment as
                    // the apply/submit catches.
                    LoggerProxy.error("[MOB-1513] Keystone schedule store failed: \(error)")
                    await send(.keystoneScanAbandoned)
                    return
                }
                if let schedule {
                    await migrationManager.recordCommittedSchedule(accountUUID, schedule)
                }
                await migrationManager.reconcile()
                await send(.keystoneSigningSubmitted(context: context, pendingScheduleStore: nil))
                return
            }
            // Preps present (MOB-1496 C-1b fix, fix-wave 2 — still in force under the final engine,
            // see this method's doc): store ONLY the preps now. The already-signed schedule entries
            // are NOT stored here any more: Step 0 of the fix-wave-2 report traced the engine's phase
            // machine and found a prep's own broadcast-success record
            // (`record_transfer_result`, `context.rs:1299-1303`) UNCONDITIONALLY overwrites the run's
            // phase — a schedule store performed here, before the preps even broadcast, gets
            // clobbered the instant a broadcast lands, stranding the run so it never advances again once
            // the prep mines (`context.rs:361-378`). The schedule rides along in
            // `pendingScheduleStore` instead; MOB-1513 (B4): the deferred store now runs inside the
            // post-confirm first-delivery kick (`runFirstDeliveryKick`), right after its prep
            // broadcast lands — the earliest point the trace proved safe.
            do {
                try await sdkSynchronizer.storeSignedNoteSplits(accountUUID, prepEntries)
            } catch {
                // Nothing was stored at all — abandon exactly like an apply-signature failure:
                // nothing to resume, same `keystoneScanAbandoned` semantics. MOB-1513 (R8, F3):
                // logged first, same observability treatment as the apply/submit catches.
                LoggerProxy.error("[MOB-1513] Keystone note-split store failed: \(error)")
                await send(.keystoneScanAbandoned)
                return
            }
            let pendingScheduleStore = MigrationCoordFlow.PendingScheduleStore(
                accountUUID: accountUUID,
                scheduleEntries: scheduleEntries,
                schedule: schedule
            )
            await send(.keystoneSigningSubmitted(context: context, pendingScheduleStore: pendingScheduleStore))
        }
    }

    // MARK: - MOB-1513: Keystone signing — immediate lane's post-signing submit

    /// The immediate lane's Keystone post-signing step — dispatched by the PRODUCTION single-PCZT
    /// round-trip's `.scan(.foundPCZT)` case (MOB-1513 R8; the batch round-trip's own
    /// `.immediateReview` intercept above is retained defensively but unreachable — the immediate
    /// lane never arms a batch scan session anymore). An `ImmediateMigrationProposal` is
    /// engine-external, so there is no `MigrationSchedule` to store and no engine run this ceremony
    /// ever created (`proposeKeystoneBatch`, `storeSignedMigrationTransactions`, and the whole "run
    /// created at PCZT-build time" story this file's header documents at length are ALL specific to
    /// the engine's own schedule/prep machinery — `createPCZTFromProposal` never touches any of
    /// it). Instead, the signed PCZT is proved and broadcast RIGHT HERE via
    /// `MigrationCommitPipeline.commitImmediateKeystone` (guarded
    /// `createAndSubmitTransactionFromPCZT`) — unlike the software lane, a Keystone-signed PCZT can
    /// only be finalized once, immediately after the signature comes back; there is no engine-held
    /// "signed and stored, broadcast whenever the Sending screen next appears" indirection available
    /// for a proposal the engine never held to begin with. `signedPczt` is the device-echoed signed
    /// PCZT (`parseZcashPczt` — the same half `SendConfirmation`'s production combine consumes);
    /// `unsignedPczt` is the retained unredacted original the proofs run over.
    ///
    /// On success, `.keystoneImmediateSubmitted(txId:)` pops back exactly like a no-preps
    /// `resumeAfterKeystoneSigning` would, then pushes `MigrationSending.State` ALREADY in `.success`
    /// phase with the real txid — the broadcast already happened here, so there is nothing left for
    /// that screen's `onAppear` to (re-)execute. `totalCount: 1`/success semantics otherwise match the
    /// software lane's identically (see `MigrationSendingStore`'s header doc).
    ///
    /// On failure, `.keystoneImmediateSubmitFailed` (MOB-1513 R8, F2) pops exactly like an abandon
    /// but arms the Review element's existing commit-failure sheet — the failure is VISIBLE and
    /// retryable (Retry re-runs the whole ceremony from a fresh PCZT+redact). Still a deliberate
    /// simplification over a "retry just the broadcast" lane (which would need to persist the
    /// already-signed PCZT bytes across a retry, infrastructure this ceremony doesn't have for a
    /// proposal the engine never stored) — flagged in this task's report. The thrown error is
    /// logged (R8, F3): the silent discard here is exactly what made the original QA loop
    /// undiagnosable.
    private func submitImmediateKeystoneTransaction(
        accountUUID: AccountUUID,
        unsignedPczt: Data,
        signedPczt: Data
    ) -> Effect<MigrationCoordFlow.Action> {
        .run { [sdkSynchronizer, accountUUID, unsignedPczt, signedPczt] send in
            do {
                let txId = try await MigrationCommitPipeline.commitImmediateKeystone(
                    unsignedPczt: unsignedPczt,
                    signedPczt: signedPczt,
                    accountUUID: accountUUID,
                    sdkSynchronizer: sdkSynchronizer
                )
                await send(.keystoneImmediateSubmitted(txId: txId))
            } catch {
                LoggerProxy.error("[MOB-1513] immediate Keystone post-signing submit failed (proofs/combine/broadcast): \(error)")
                await send(.keystoneImmediateSubmitFailed)
            }
        }
    }

    // MARK: - MOB-1496 (W2): schedule lookup for the Keystone store-success write point

    /// Locates the `MigrationSchedule` that was signed for `context`, read off the `.transferPlan`
    /// element still beneath `keystoneSign` + `scan` at the point the signed PCZTs are about to be
    /// stored — `depthBelowTop` is how many elements sit above it on the path (2 for the real scan
    /// round-trip: `scan` + `keystoneSign`) — mirrors how `signState.pczts` above reads the unsigned
    /// batch off the same stack position. `nil` when that element carries no schedule of its own (a
    /// fixture/test state that never populated one) — the caller then skips `recordCommittedSchedule`
    /// rather than persisting nothing.
    ///
    /// MOB-1513/MOB-1496 (W-B): `.immediateReview` always returns `nil` — `MigrationReviewTransfer
    /// .State` (and, since W-B, "Migrate anyway") carry no engine schedule at all; the immediate
    /// lane's `ImmediateMigrationProposal` is engine-external. This branch is unreachable in
    /// practice — the call site above intercepts `.immediateReview` via
    /// `submitImmediateKeystoneTransaction` before ever reaching this function — but stays for the
    /// switch's exhaustiveness.
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
            return nil

        case .recoveryRefresh(let schedule):
            // MOB-1458 (Task 2): the ceremony launched off the Recovery screen with no `.transferPlan`
            // element on the path — the RETURNED post-refresh schedule rides the context itself, so
            // `storeKeystoneSignedBatch` records exactly it (the only value echoed downstream).
            return schedule
        }
    }

    // MARK: - MOB-1513: Keystone signing ceremony (capped QR rounds — MOB-1513 R9)

    /// Starts the QR signing ceremony for `pczts`, capped at
    /// `KeystoneBatchChunking.maxItemsPerRound` PCZTs per animated-QR round trip — the
    /// device-safety cap MOB-1513 R9 restored (the R5 rewire onto the real batch protocol removed
    /// E3's chunker together with the genuinely-obsolete imagined-protocol machinery, but the cap
    /// was device safety, not protocol bookkeeping: Android observed a real Keystone OOM on an
    /// oversized batch and its production `KeystoneBatchChunking.kt` kept chunking throughout).
    ///
    /// A batch within the cap is ONE animated QR session over every PCZT of the signing context —
    /// behavior-identical to the uncapped ceremony. A larger batch signs across several rounds:
    /// each round is a full, self-contained ceremony over its `KeystoneBatchChunking.roundSlice`
    /// (fresh `MigrationKeystoneSign.State` — fresh request id), driven by the round-advance branch
    /// of `.keystoneBatchSignaturesApplied`; the applied signatures accumulate in
    /// `state.keystoneBatchRounds` and nothing stores until the last round lands. Within a round,
    /// `Synchronizer.buildKeystoneSignBatchQRParts` is a fountain encoder and the SDK decides the
    /// frame count.
    private func beginKeystoneCeremony(pczts: [MigrationUnsignedTransferPczt], state: inout MigrationCoordFlow.State) {
        let totalRounds = KeystoneBatchChunking.totalRounds(itemCount: pczts.count)
        state.keystoneBatchRounds = MigrationCoordFlow.KeystoneBatchRounds(allPczts: pczts)
        let slice = KeystoneBatchChunking.roundSlice(roundIndex: 0, itemCount: pczts.count)
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: Array(pczts[slice]),
                    roundIndex: 0,
                    totalRounds: totalRounds
                )
            )
        )
    }

    /// MOB-1513 (R8): starts the IMMEDIATE lane's SINGLE-PCZT signing ceremony — the PRODUCTION
    /// `SignWithKeystone` pipeline (the sign screen computes `urEncoderForPCZT` live over
    /// `redacted`; `.getSignature` pushes a scan session with the production
    /// `keystonePCZTScanChecker`; the device echoes the FULL signed PCZT; the post-scan step is the
    /// unchanged proofs+combine `submitImmediateKeystoneTransaction`). NEVER the batch bridge: the
    /// batch apply FFI (`decode_signed_pairs`) numeric-parses every PCZT id as an engine
    /// `MigrationTxId`, and this lane's engine-external ordinary-send PCZT has none — the sentinel
    /// string id made `applyKeystoneBatchSignatures` throw on EVERY ceremony, which the silent
    /// abandon then turned into the QA-reported infinite scan loop. Android draws the same lane
    /// boundary (its immediate Keystone lane is the ordinary single-PCZT pipeline; the batch bridge
    /// is scheduled/automatic-mode machinery on both platforms). `pczts` carries the UNREDACTED
    /// original under the inert state-side sentinel id — the post-scan submit reads it
    /// positionally, and it never reaches the SDK.
    private func beginImmediateKeystoneCeremony(unsigned: Data, redacted: Data, state: inout MigrationCoordFlow.State) {
        state.keystoneImmediateSubmitInFlight = false
        // MOB-1513 (R9): the single-PCZT ceremony never chunks — a leftover rounds state from an
        // earlier batch ceremony must not leak into this one (defensive; every ceremony-ending
        // route already clears it).
        state.keystoneBatchRounds = nil
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: unsigned)],
                    redactedSinglePczt: redacted
                )
            )
        )
    }

    // MARK: - MOB-1458: dust-lane "Migrate anyway" in-flight flag — Keystone ceremony exit cleanup

    /// Clears `MigrationComplete.State.isMigratingAnyway` on the first `.complete` element found by
    /// scanning `state.path.ids`, if one exists and the flag is actually set — a no-op otherwise.
    ///
    /// Why this exists: `beginImmediateKeystoneCeremony` above only ever APPENDS `.keystoneSign` (and,
    /// once "Get Signature" is tapped, `.scan`) on top of whatever screen requested the ceremony — it
    /// never pops or replaces that screen. For the dust lane ("Migrate anyway" over Migration
    /// Complete), that screen is a still-live `.complete` element whose `isMigratingAnyway` was set
    /// `true` by `MigrationComplete.migrateAnywayTapped` before the ceremony ever started. The two
    /// clear sites that already existed for this flag — `.migrateAnywayAuthenticationCancelled` /
    /// `.migrateAnywayFailed`, above — key off the tap-time `id` they each captured, but that id is
    /// useless to the ceremony's own terminal exits (`.keystoneSignRejected`, `.keystoneScanAbandoned`,
    /// `.keystoneImmediateSubmitFailed`): those three are POSITIONAL pops shared with the non-dust
    /// lanes (`.transferPlan`'s `.planCommit` context, `.reviewTransfer`'s own `.immediateReview`
    /// context) and carry no `.complete` id of their own. Without this helper, a
    /// reject/abandon/submit-fail on the dust lane landed the user back on Complete with the button
    /// permanently disabled and `migrateAnywayTapped`'s own single-flight guard
    /// (`!state.isMigratingAnyway`) swallowing every further tap — the dead-button bug this fixes.
    ///
    /// Scanning `state.path.ids` (rather than threading the tap-time id through all three exits) is
    /// deliberate: those three actions are shared with the non-dust lanes, which have no other reason
    /// to carry a `.complete` id around — widening their signatures for this one flag's bookkeeping
    /// would be worse than a small lookup here. It is safe because at most one dust ceremony can be
    /// mid-flight per account (`CancelID.migrateAnywayAuthentication`, keyed by account, plus
    /// `MigrationComplete.State.isMigratingAnyway`'s own single-flight guard on the tap itself), so
    /// there is never more than one `.complete` element with the flag genuinely set to find.
    ///
    /// A no-op when no `.complete` element is on the path at all — the normal case for every non-dust
    /// lane reaching these same three exits (`.transferPlan`/`.reviewTransfer` sits beneath them
    /// instead, never `.complete`) — and equally a no-op once the flag is already `false`. Either way
    /// it must not disturb anything else on the path.
    ///
    /// `.keystoneImmediateSubmitFailed`'s call site is not user-visible TODAY — that handler's
    /// fallback pushes `.sending` over the retained `.complete`, and closing `.sending` ends the whole
    /// flow before `.complete` (and its by-then-stale flag) could ever be seen again. It gets the
    /// clear anyway: the call is free, and it stops the leak from becoming reachable the moment that
    /// fallback's behavior changes. Do not delete it as dead code.
    ///
    /// An `onAppear`-driven self-heal on `MigrationComplete` (mirroring
    /// `MigrationRecovery.State.isRecovering`'s reset in `MigrationRecoveryStore.swift`) was
    /// considered and rejected: it would work in the app, but the clear would then live in view
    /// lifecycle that `TestStore` cannot drive, so a regression that deleted this helper would not
    /// fail any test. Explicit clears at the exact exit points stay assertable.
    private func clearMigrateAnywayInFlight(state: inout MigrationCoordFlow.State) {
        for id in state.path.ids {
            guard case .complete(var completeState) = state.path[id: id] else { continue }
            guard completeState.isMigratingAnyway else { return }
            completeState.isMigratingAnyway = false
            state.path[id: id] = .complete(completeState)
            return
        }
    }

    // MARK: - MOB-1496 (W6 §1): Keystone batch sentinel split

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

    // MARK: - MOB-1513 (B4 fix wave): first-delivery kick retry knobs + re-arm cancellation

    /// Effect-cancellation ids for the coordinator's own long-lived effects.
    enum CancelID: Hashable {
        /// The state-event re-arm `.firstDeliveryKickFailed` starts — cancelled by
        /// `.deferredKeystoneScheduleStored` once THAT account's deferred store lands. Keyed by
        /// account (B4 fix wave): `MigrationCoordFlow` is one permanent `Scope` child of Root, so two
        /// accounts migrating in parallel (MOB-1509) share this single coordinator. A payload-free id
        /// let account B's `cancelInFlight` arm — or its store's `.cancel` — tear down account A's
        /// still-armed re-arm, stranding A's run; keying by account isolates each re-arm subscription.
        case deferredScheduleStoreRearm(AccountUUID)
        /// MOB-1458 (code review — F4/F6): "Migrate anyway"'s device-authentication gate PLUS the
        /// unlock/propose/PCZT continuation that follows a pass — both `.cancellable` sites in
        /// `.complete(.delegate(.migrateAnyway))`/`.migrateAnywayAuthenticated` share this id, keyed
        /// by account for the SAME reason as `deferredScheduleStoreRearm` above (one shared
        /// coordinator across parallel per-account migrations). `cancelInFlight: true` on the gate
        /// is a defensive backstop against a genuinely concurrent second chain for the same account —
        /// the primary double-tap guard is `MigrationComplete.State.isMigratingAnyway`, owned by the
        /// tapped screen itself.
        case migrateAnywayAuthentication(AccountUUID)
    }

    /// Total broadcast attempts one kick makes when a Keystone deferred schedule store is pending
    /// (the software lane keeps a single attempt — see `runFirstDeliveryKick`'s doc). Three covers
    /// the transient confirm-time Tor/network flake without turning the kick into a long-running
    /// poller — the state-event re-arm takes over after that.
    static let firstDeliveryKickMaxAttempts = 3

    /// Pause between the kick's bounded attempts — long enough for a Tor bootstrap flake to clear,
    /// short enough that a healthy retry still lands "immediately" in product terms.
    static let firstDeliveryKickRetryDelay = Duration.seconds(15)

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

    /// MOB-1513 (R8 finding 1): strips the `note-split#` sentinel prefix off every prep entry's id
    /// — down to the bare (numeric) engine id — before the batch is handed to
    /// `applyKeystoneBatchSignatures`. The SDK's apply FFI historically numeric-parsed EVERY id it
    /// received (`decode_signed_pairs` -> `transfer_id_from_c`), so a sentinel-prefixed id made
    /// apply throw after every successful scan, abandoning any scheduled ceremony that carried a
    /// preparation transaction. The SDK-side contract fix (apply ids opaque, SDK PR #1834) makes
    /// ids pass-through, but this app-side sanitization is kept as defense-in-depth: it is correct
    /// against BOTH SDK generations, and the ceremony's own sentinel bookkeeping never needs to
    /// cross the FFI at all. Pair with `reattachOriginalIds` on the result — apply echoes ids back
    /// positionally, and every downstream consumer (`splitKeystoneBatch`, the stores) expects the
    /// ORIGINAL sentinel-prefixed ids.
    static func sanitizedForBatchApply(_ pczts: [MigrationUnsignedTransferPczt]) -> [MigrationUnsignedTransferPczt] {
        pczts.map { entry in
            guard entry.id.hasPrefix(keystoneNoteSplitSentinelPrefix) else { return entry }
            return MigrationUnsignedTransferPczt(
                id: String(entry.id.dropFirst(keystoneNoteSplitSentinelPrefix.count)),
                pczt: entry.pczt
            )
        }
    }

    /// MOB-1513 (R8 finding 1): re-attaches the ceremony's ORIGINAL (possibly sentinel-prefixed)
    /// ids onto the signed pairs `applyKeystoneBatchSignatures` returned — positional, per the
    /// apply contract (output order and count equal the input's). See `sanitizedForBatchApply`'s
    /// doc for the pairing. Defensive: a count mismatch would mean the SDK broke that contract —
    /// the signed result is then returned untouched rather than zip-truncating entries away.
    static func reattachOriginalIds(
        from originals: [MigrationUnsignedTransferPczt],
        onto signed: [MigrationSignedTransferPczt]
    ) -> [MigrationSignedTransferPczt] {
        guard originals.count == signed.count else { return signed }
        return zip(originals, signed).map { original, signedEntry in
            MigrationSignedTransferPczt(id: original.id, pczt: signedEntry.pczt)
        }
    }

    // MARK: - MOB-1513: Keystone migration-batch minimum-firmware gate

    /// Keystone "cypherpunk" firmware floor for migration batch signing: 3.0.2 is the first firmware
    /// that supports this protocol at all — older firmware either can't sign the batch correctly or
    /// won't report a version in the response envelope, which is why the gate below treats "no
    /// version reported" the same as "below floor". Checked directly against
    /// `KeystoneBatchDecodeResult.firmwareVersion` (the decode envelope's OWN reported version, an
    /// `ZcashLightClientKit.KeystoneFirmwareVersion` — `Comparable` by major/minor/build) — there is
    /// no PCZT-embedded firmware stamp to fall back on in this protocol (see that type's doc).
    ///
    /// Deliberately distinct from (and unrelated to) the single-transaction Keystone flow's own
    /// floor, `KeystoneFirmwareVersion.minimumSupported` (`Features/SendConfirmation/
    /// KeystoneFirmwareVersion.swift`, 3.0.0) — that flow reads its version from a stamp embedded in
    /// the signed PCZT bytes, a mechanism the batch protocol has no equivalent of. The two
    /// `KeystoneFirmwareVersion` types (this file's imported `ZcashLightClientKit` one and the app's
    /// own single-transaction-flow one) share a bare name; every reference in this file to the SDK's
    /// type is written out module-qualified for exactly that reason.
    static let keystoneMigrationBatchMinimumFirmware = ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 0, build: 2)

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
            // MOB-1497 (T4): the R13 disclosure footer is retired — there is nothing left to
            // re-peek, so the immediate Review Transfer pushes with no host threading.
            // `pushHydratedPathState` keeps the push symmetric with the `.permissionChain` case's
            // own dispatch below.
            return .send(.pushHydratedPathState(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate))))

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
    /// MOB-1497 (T4): the R13 `broadcastDisclosureHost` hydration this branch once did is retired —
    /// the Transfer Plan no longer carries a disclosure footer, so a fresh plan is now constructed
    /// with just its variant.
    private func nextPermissionStepResult() async -> MigrationCoordFlow.PermissionStepResult {
        if await migrationBGScheduler.backgroundRefreshStatus() != .available {
            return MigrationCoordFlow.PermissionStepResult(pathState: .backgroundDelivery(MigrationBackgroundDelivery.State()))
        }

        if await userNotifications.authorizationStatus() == .notDetermined {
            // MOB-1478 (W8): mirrors `freshPlanVariant()`'s ternary — today `.manual` was
            // unreachable since this always defaulted to `.scheduled`.
            let variant: MigrationNotifications.State.Variant = migrationManager.isManualDelivery(nil) ? .manual : .scheduled
            return MigrationCoordFlow.PermissionStepResult(pathState: .notifications(MigrationNotifications.State(variant: variant)))
        }

        return MigrationCoordFlow.PermissionStepResult(
            pathState: .transferPlan(MigrationTransferPlan.State(variant: freshPlanVariant()))
        )
    }

    /// Fresh-entry plan variant: manual delivery (background delivery declined) shows the manual
    /// copy and its confirm sends the first transfer now (§6.3); otherwise the scheduled variant.
    private func freshPlanVariant() -> MigrationTransferPlan.State.Variant {
        migrationManager.isManualDelivery(nil) ? .manual : .scheduled
    }

    // MARK: - MOB-1497 (T2): identity-custom classification

    /// Identity-custom classification straight off the formed snapshot's OWN `syncProvider` (R2/R8:
    /// identity-based, never re-derived by re-classifying some other host). `nil` snapshot
    /// (defensive — forming should always have produced one) reads as NOT custom, the safer default
    /// (shows the toggle sheet rather than silently hiding Tor as unavailable). MOB-1497 (T4): the
    /// R13 `showsBroadcastDisclosure`/`broadcastDisclosureHost` companions this used to sit beside
    /// are gone with the disclosure footers — this is the sole remaining snapshot classifier, read
    /// only by `torSheetState` to pick the sheet's custom vs. toggle variant.
    private static func isIdentityCustom(_ snapshot: MigrationNetworkSnapshot?) -> Bool {
        guard let snapshot else { return false }
        if case ServerProvider.custom = snapshot.syncProvider { return true }
        return false
    }

    // MARK: - Recovery: TransferPlan hydration

    /// Recovery `.recreate`'s follow-up plan screen: `restartCurrentMigrationStep()` returns a
    /// fresh `MigrationSchedule`, injected via `injectedSchedule` so the screen's own `onAppear`
    /// populates rows (no coordinator-side duplication of that row-building logic). The
    /// `.notesSpent`/restart lane's plan DOES sign — `requiresSigning` stays at its default `true`.
    ///
    /// MOB-1513 (C7, Figma Error & Recovery row 3): also backs the EXPIRED-transfer recovery's
    /// review screen — both the software lane (after `refreshStaleMigrationTransfers` +
    /// `recordCommittedSchedule` + `reconcile` have already run) and the Keystone lane (after the
    /// batch is proposed, before it's signed) push this SAME `.recreated` presentation with
    /// `requiresSigning: false` (nothing left to sign) and `isExpiredRecoveryReview: true` — the
    /// discriminator `.transferPlan(.delegate(.confirmed))` reads to route to
    /// `expiredRecoveryReviewConfirmed` instead of the rescheduled variant's plain `.flowFinished`
    /// acknowledgment. `pendingKeystoneRecoveryBatch` carries the Keystone lane's already-proposed
    /// PCZTs so its Confirm can start the ceremony without re-proposing; `nil` for the software lane
    /// and the pre-existing `.notesSpent` call site (both unaffected — every new parameter here
    /// defaults to matching their prior behavior exactly).
    private func recreatedPlanState(
        schedule: MigrationSchedule?,
        requiresSigning: Bool = true,
        isExpiredRecoveryReview: Bool = false,
        pendingKeystoneRecoveryBatch: MigrationTransferPlan.State.PendingKeystoneRecoveryBatch? = nil
    ) -> MigrationTransferPlan.State {
        var state = MigrationTransferPlan.State(variant: .recreated, requiresSigning: requiresSigning)
        state.injectedSchedule = schedule
        state.isExpiredRecoveryReview = isExpiredRecoveryReview
        state.pendingKeystoneRecoveryBatch = pendingKeystoneRecoveryBatch
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
    /// FORWARD-looking ETA derived from the row's committed schedule height against the live chain
    /// tip (`MigrationDerivations.transferRows`, MOB-1513 A3 — no longer the old `nonSentPosition × 6`
    /// placeholder cadence this doc used to cite). It floors to `0` once the row's height is
    /// at-or-behind the tip, which is always true for the STALLED (overdue) row this screen shows —
    /// but is no longer `0` BY CONSTRUCTION for every first non-sent row in general: one with a
    /// future committed height now legitimately carries a nonzero forward ETA. Reusing it here read
    /// as "0 hours ago" forever on the real SDK path.
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
        // MOB-1487: a previously locked remainder re-enters on the locked confirmation instead
        // of re-offering resolution (offered/none derive from `dust` otherwise).
        // MOB-1496 (W-A #7): `residualAfterMigration` (which `summary.dust` derives from) falls
        // through to a fresh spendable-based plan once the migration state is terminal — after a
        // lock, the locked notes are excluded from that fresh plan, so `summary.dust` silently
        // reads zero post-lock. The balance-derived `migrationLockedAmount` (the account's
        // Orchard `lockedValue`) is both the lock signal AND the amount that stay correct after
        // the lock, so the locked confirmation card shows the real locked remainder on re-entry.
        let lockedAmount = await migrationManager.migrationLockedAmount(accountUUID)
        return MigrationComplete.State(
            totalTransferred: summary.transferred,
            dust: lockedAmount > Zatoshi.zero ? lockedAmount : summary.dust,
            transfersSent: summary.transfersSent,
            transfersTotal: summary.transfersTotal,
            durationHours: summary.estimatedDurationHours,
            isFlowRoot: isFlowRoot,
            dustResolution: lockedAmount > Zatoshi.zero
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
            // Standard ZIP-317 marginal fee — the manual per-step review has no proposal object of
            // its own to read a fee from (unlike MOB-1513's immediate lane, whose
            // `ImmediateMigrationProposal.fee` is the real thing), so this literal mirrors the
            // precedent used throughout the migration flow for a single-transfer fee display.
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

// MARK: - MOB-1513: display form for the SDK's Keystone firmware version

extension ZcashLightClientKit.KeystoneFirmwareVersion {
    /// Dotted `major.minor.build` display form, for the migration Keystone batch-signing firmware-
    /// gate sheet's copy (`MigrationCoordFlowView`). Module-qualified everywhere in this file — see
    /// `MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware`'s doc for why.
    var versionString: String {
        "\(major).\(minor).\(build)"
    }
}
