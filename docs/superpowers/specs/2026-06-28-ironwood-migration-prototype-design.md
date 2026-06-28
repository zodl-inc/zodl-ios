# Ironwood Migration Prototype — Design Spec

**Date:** 2026-06-28
**Branch:** `michal/MOB-1451-ironwood-migration-prototype`
**Status:** Awaiting approval

---

## 1. Goal

Build a **working, simulated** Orchard → Ironwood pool-migration flow in the ZODL iOS app so the
team can walk through the end-to-end experience and "feel" the future SDK API before the real Rust
SDK and final UI exist.

Everything is driven by a **dummy implementation of the migration SDK**. No real transactions are
broadcast. Instead, the dummy simulates note-splitting and scheduled transfers — including **real iOS
background-task execution** — so the entire chain (schedule → background send → notification →
on-launch reconciliation) can be exercised on device/simulator. **Debug controls** let us drive the
simulator deterministically and reproduce every state on demand.

### Designed for replacement (important)

This code may either (a) be evolved into the real implementation, or (b) serve purely as the
executable specification for a from-scratch rewrite. Either way the design optimizes for that:

- **All simulation lives behind one boundary** — `MigrationSDKClient.liveValue` and its
  `DummyMigrationEngine`. Swapping to the real SDK means replacing the live value; nothing else moves.
- **The Swift SDK types mirror the Kotlin `OrchardMigrationSdk` draft 1:1** (idiomatic Swift, same
  names/semantics) so the real Swift SDK drops into the same shape.
- **Everything around the SDK is production-shaped** — the TCA coordinator flow, the background-task
  wiring, local notifications, the Home banner, and reconciliation are written the way the real
  feature would be, not as throwaway scaffolding.

---

## 2. Non-goals & deliberate simplifications

- **No real broadcasts, no real Tor, no real anchor heights.** Heights/fees/amounts are simulated.
- **Error handling is simplified vs. the Figma.** Per product guidance, the Figma error/recovery
  screens are exaggerated. In this prototype, **any** background send failure (network, Tor, expiry,
  spent note, etc.) collapses to: *send failed → one local notification ("there was an error") → on
  next open, a single recovery prompt that re-creates the remaining migration.* We do **not** build
  distinct per-cause error UIs.
- **No multi-device / recovery / statelessness** (explicitly out of scope in the proposal).
- **Android-only screens are skipped** — `C7 · Battery Banner (Android denied)` has no iOS analogue.
- **Localization:** English copy only (taken from Figma), added to `Localizable.xcstrings` the normal
  way. The app name in all copy is **ZODL** (never "Zodl"), per project rule.

---

## 3. Background & terminology

- **Orchard** = current shielded pool (funds "at risk"). **Ironwood** = new pool. Migration moves
  funds Orchard → Ironwood. Ironwood addresses equal existing Orchard addresses; the wallet treats
  Ironwood as a distinct pool.
- **Two phases** (private path): **Phase 1 — Note splitting** (a send-to-self that breaks the balance
  into ~N smaller notes; mandatory before private migration) → **Phase 2 — Scheduled transfers**
  (N transfers at de-correlated, anchor-bucketed times, broadcast by background tasks).
- **Naming caution:** the proposal doc's "Path A" = the chosen *scheduled architecture*. The Figma's
  "Path A / Path B" = the two *user-facing options*. This spec uses the **user-facing** names:
  **Migrate Immediately** and **Migrate with Privacy**. "Path C" = error/recovery.

---

## 4. Architecture

Five layers, each independently understandable and testable:

```
┌──────────────────────────────────────────────────────────────────────┐
│ ENTRY            Home SmartBanner "Migration Required" strip            │
│                  + DEBUG entry in Advanced Settings                     │
└───────────────┬────────────────────────────────────────────────────────┘
                │ opens
┌───────────────▼────────────────────────────────────────────────────────┐
│ UI FLOW        MigrationCoordFlow (Store / View / Coordinator)          │
│                child screen features (Entry, NoteSplit, NetworkPrivacy,  │
│                BackgroundDelivery, TransferPlan, ImmediateReview,        │
│                Progress, Recovery, Scheduled/Complete)                   │
└───────────────┬─────────────────────────────────────┬──────────────────┘
                │ @Dependency(\.migrationSDK)          │ @Dependency(\.localNotification)
┌───────────────▼─────────────────────┐  ┌─────────────▼──────────────────┐
│ SDK BOUNDARY                         │  │ NOTIFICATIONS                   │
│ MigrationSDKClient (@DependencyClient)│  │ LocalNotificationClient        │
│  └ liveValue → DummyMigrationEngine  │  │  └ wraps UNUserNotificationCenter│
└───────────────┬──────────────────────┘  └────────────────────────────────┘
                │ persists
┌───────────────▼────────────────────────────────────────────────────────┐
│ SIMULATION     DummyMigrationEngine (actor) + JSON-file persistence       │
│                simulated Orchard balance, notes, block height, schedule,  │
│                per-transfer status, state machine, Combine state stream    │
└──────────────────────────────────────────────────────────────────────────┘

   BACKGROUND   AppDelegate registers/schedules BGProcessingTask
   (cross-cut)  "co.electriccoin.ironwood_migration"; handler runs the
                migration step via the engine + fires a notification.
                DEBUG "Run background task now" invokes the same handler path.
```

---

## 5. The migration SDK boundary (Swift mirror of `MigrationSdk.kt`)

A new dependency client under `secant/Sources/Dependencies/MigrationSDK/`, with supporting model
types under `secant/Sources/Models/Migration/`. Types mirror the Kotlin draft (Swift-idiomatic;
`Zatoshi` for amounts, `enum` for sealed classes, `Sendable` throughout).

### Model types

| Swift type | Mirrors Kotlin | Notes |
|---|---|---|
| `NetworkPrivacyOptions` | `NetworkPrivacyOptions` | `useTor: Bool`, `submissionEndpoint: String?` |
| `NoteSplitProposal` | `NoteSplitProposal` | `outputNotes: [Zatoshi]`, `fee: Zatoshi` |
| `TransferProposal` | `TransferProposal` | `id`, `amount: Zatoshi`, `anchorHeight`, `nextExecutableAfterHeight`, `expiryHeight` |
| `MigrationSchedule` | `MigrationSchedule` | `transfers: [TransferProposal]`, `estimatedDurationHours: Int` |
| `MigrationProgress` | `MigrationProgress` | `completedTransfers`, `totalTransfers`, `remainingOrchard: Zatoshi`, `nextTransferReadyAtHeight: BlockHeight?` |
| `MigrationState` | `MigrationState` (sealed) | `.notStarted`, `.splitPendingConfirmation`, `.readyToPropose`, `.inProgress(MigrationProgress)`, `.requiresAttention(AttentionReason)`, `.complete` |
| `AttentionReason` | `AttentionReason` (sealed) | `.invalidTransfer(id)`, `.transferExpired`, `.syncRequiredBeforeNext` |
| `TransferResult` | `TransferResult` (sealed) | `.success(txId)`, `.networkError(retryable)`, `.invalidNote`, `.expired` |
| `MigrationMode` | *(prototype addition)* | `.immediate` / `.privateScheduled` — see deviation note |

### Client closures (mirror `interface OrchardMigrationSdk`)

`@DependencyClient struct MigrationSDKClient: Sendable` — all closures `@Sendable`:

- `getMigrationState() -> MigrationState`
- `stateStream() -> AnyPublisher<MigrationState, Never>` *(added per the Kotlin "consider exposing as Flow" note; the UI observes this instead of polling)*
- `getMigrationProgress() -> MigrationProgress?`
- `isNoteSplitNeeded() -> Bool`
- `prepareNoteSplit() async -> NoteSplitProposal`
- `submitNoteSplit(NoteSplitProposal) async -> TransferResult`
- `proposeMigrationTransfers() async -> MigrationSchedule`
- `signAndStoreMigrationSchedule(MigrationSchedule) async`
- `isSyncRequiredBeforeNextTransfer() -> Bool`
- `executeNextPendingTransfer(NetworkPrivacyOptions) async -> TransferResult?`
- `hasOverdueTransfers() -> Bool`
- `hasInvalidTransfers() -> Bool`
- `restartCurrentMigrationStep() async -> MigrationSchedule`
- `initializePostUpgrade()`
- **Prototype additions (clearly marked `// PROTOTYPE`):**
  - `selectMigrationMode(MigrationMode)` — set by the entry screen (immediate vs private)
  - `debug: MigrationDebugControls` — namespaced debug hooks (see §8); compiled in DEBUG only

**Deviation note:** the Kotlin draft has no notion of "immediate" and no mode parameter. Because the
Figma offers Immediate vs Private at entry, the prototype conveys the choice via `selectMigrationMode`
and the engine returns a 1-transfer (immediate, executable now) or N-transfer (private) schedule from
the same `proposeMigrationTransfers()`. This is documented so the real SDK can decide how to model it.

`liveValue` → backed by `DummyMigrationEngine`. `testValue`/`noOp` provided for tests and previews.

---

## 6. DummyMigrationEngine (the simulator)

An `actor` (or `OSAllocatedUnfairLock`-guarded type) owning all simulated state; the single source of
truth behind the client.

**Simulated state (persisted):**
- `orchardBalance: Zatoshi` (default ≈ **12.458 ZEC** to match Figma), `notes: [Zatoshi]`
- `currentHeight: BlockHeight` (advances via background runs / debug)
- `mode: MigrationMode`, `state: MigrationState`
- `schedule: [TransferProposal]` with per-transfer status (`pending` / `sent(txId)` / `invalid` / `expired`)
- `networkPrivacy: NetworkPrivacyOptions`

**Persistence:** JSON file in Application Support (small `MigrationStateStore`). Persistence is
required because background tasks may run in a freshly relaunched process and because on-launch
reconciliation must see the committed schedule. State survives app restarts; the debug **Reset**
wipes it.

**Behavior:**
- `prepareNoteSplit` → split balance into ~N notes (N≈ balance-scaled, capped) with small randomized
  sizes; randomization varied by index (no `Math.random` needed).
- `submitNoteSplit` → `.splitPendingConfirmation`; a short simulated delay (or debug "confirm split")
  → `.readyToPropose`.
- `proposeMigrationTransfers` → builds the schedule. Each transfer:
  `nextExecutableAfterHeight = currentHeight + bucket·(i+1)` (bucket simulates the ~6h/288-block
  window, compressed for the prototype), `expiryHeight` further out. Immediate mode → exactly one
  transfer executable now.
- `signAndStoreMigrationSchedule` → `.inProgress`, schedule stored.
- `executeNextPendingTransfer` → marks the next due transfer `sent`, decrements `remainingOrchard`,
  advances state; returns `.success`. Returns `.networkError/.invalidNote/.expired` **only** when the
  debug panel has armed a failure for the next run (so failures are reproducible, not random).
- `hasOverdueTransfers` / `hasInvalidTransfers` → computed from `currentHeight` vs transfer windows
  and per-transfer status.
- `restartCurrentMigrationStep` → invalidates the broken transfer, re-proposes a schedule for the
  remaining balance (goes back through the normal confirm flow).
- Completion: when no Orchard balance remains → `.complete`. If a sub-threshold "dust" remainder is
  configured (debug), surface the dust-complete copy.

All state changes publish through a Combine subject feeding `stateStream()`.

---

## 7. Background sending & notifications

### Background task (real BGTaskScheduler)
- New identifier **`co.electriccoin.ironwood_migration`** added to `BGTaskSchedulerPermittedIdentifiers`
  in **every** target Info.plist (mainnet, testnet, zashi-testnet, zashi-internal, distrib).
  `UIBackgroundModes` already contains `processing`.
- **Register** the handler in `AppDelegate.registerTasks()` next to the existing tasks.
- **Schedule** a `BGProcessingTaskRequest` when the schedule is committed and after each run while
  transfers remain (`earliestBeginDate` short for the prototype). A thin `MigrationBGScheduler`
  helper wraps submit/cancel so it's isolated and testable.
- **Handler** (the production code path): if a transfer is due and no sync is required →
  `executeNextPendingTransfer` → on success fire a success notification and reschedule the next; on
  failure fire one generic error notification; then `setTaskCompleted`. Sync is **not** triggered in
  the task (decoupled, per the proposal). An `expirationHandler` completes cleanly.

### Local notifications (new `LocalNotificationClient`)
Under `secant/Sources/Dependencies/LocalNotification/`, wrapping `UNUserNotificationCenter`:
- `requestAuthorization() async -> Bool`
- `post(title:body:identifier:) async` (immediate) and a `schedule(after:)` variant
- `removeAll()`

Permission is requested at the point the user commits a scheduled migration (Allow Background
Delivery / schedule confirm), matching the flow.

### Demoability
Real BG tasks fire only when iOS decides. The **DEBUG "Run background task now"** control invokes the
exact same handler body, so the full background→send→notification→reconcile chain is testable on
demand without lldb. Real scheduling stays wired for authenticity.

---

## 8. Debug controls

A DEBUG-only `MigrationDebug` panel, reachable from a new DEBUG row in **Advanced Settings** (and the
Home-banner debug toggle). Drives `MigrationSDKClient.debug` → engine:

- **Reset migration** (back to `NotStarted`, wipe persisted state)
- **Set Orchard balance / note count** (seed the simulation)
- **Advance simulated block height** (push transfers into "due"/"overdue")
- **Run background task now** (fire the real handler path)
- **Force next transfer:** success / failure / invalid-note / expired
- **Jump to state:** overdue, requires-attention (invalid), sync-required, complete, complete-with-dust
- **Toggle Home banner** visibility + **cycle banner color variant** (purple / orange / red / blue)
- Read-out of current `MigrationState`, schedule, and per-transfer status

---

## 9. UI flow & screens

Built as a `MigrationCoordFlow` (Store/View/Coordinator) mirroring `SendCoordFlow`: a root entry
screen + a `StackState<Path.State>` of child screen features, launched from Root as a full-screen
path (`Root.Path.migrationCoordFlow`). Child screens emit delegate actions; the coordinator owns
navigation. Reusable UI from `UIComponents/` (`ZashiButton`, `ActionRow`, `PrivacyBadge`,
`ZashiToggle`, progress views, screen backgrounds, `ZashiText`).

**Screen features** (grouped to keep units focused; states that are one logical step share a feature):

| Feature | Covers (Figma) | Used by |
|---|---|---|
| `MigrationEntry` | Move to Ironwood + Immediate/Private choice; balance-load error sub-state | both |
| `MigrationNoteSplit` | Split Your Wallet Funds → Splitting… → Split Confirmed (states); C1 waiting-for-split on reopen | private |
| `MigrationBackgroundDelivery` | Allow Background Delivery (Allow / Skip) | private |
| `MigrationNetworkPrivacy` | Network Privacy (Tor toggle); C2 Tor-unavailable sub-state | both |
| `MigrationTransferPlan` | Transfer Plan (schedule review + Confirm) | private |
| `MigrationScheduled` | Migration Scheduled success | private |
| `MigrationImmediateReview` | Review Transfer → Sending… → Sent (states) | immediate |
| `MigrationProgress` | In-progress status (N of M, next ETA, remaining), C3 sync-step, C6 complete + dust | private |
| `MigrationRecovery` | C4 overdue/fallback-on-open, C5 invalid → re-create (single simplified prompt) | both |

### State → screen routing

| `MigrationState` | Shown |
|---|---|
| `.notStarted` | Home banner → `MigrationEntry` |
| `.splitPendingConfirmation` | `MigrationNoteSplit` (Splitting / waiting-for-confirm) |
| `.readyToPropose` | `MigrationTransferPlan` (after privacy + background screens) |
| `.inProgress` | `MigrationProgress` (banner reflects progress) |
| `.requiresAttention(.invalidTransfer/.transferExpired)` | `MigrationRecovery` (re-create) |
| `.requiresAttention(.syncRequiredBeforeNext)` | `MigrationProgress` sync-step |
| `.complete` | `MigrationProgress` complete (+ dust variant) |
| `hasOverdueTransfers` (on open) | `MigrationRecovery` fallback-on-open |

**Immediate path:** Entry → NetworkPrivacy → ImmediateReview(Review → Sending → Sent). Executes in
foreground (no BG task).

**Private path:** Entry → NoteSplit(Confirm → Splitting → Confirmed) → BackgroundDelivery →
NetworkPrivacy → TransferPlan(Confirm) → Scheduled → (background sends) → Progress → Complete.

---

## 10. Home entry (SmartBanner)

Add a `migration` priority to `SmartBanner` that renders the **"Migration Required"** strip when the
migration is needed or in progress (driven by `MigrationState` via `stateStream`). Tapping sends a
delegate up to Root, which opens `Root.Path.migrationCoordFlow`.

**Banner color variants** (the unfinalized strips): implement the **purple** variant as default, with
the color centralized in one place so it's a one-line swap; the DEBUG panel can cycle
purple/orange/red/blue to preview them. (In-progress vs attention states can map to different
variants later — not required now.)

---

## 11. Reconciliation (launch / foreground)

On `didFinishLaunching` and `willEnterForeground` (existing Root init hooks), run a migration
reconciliation: read `getMigrationState` + `hasOverdueTransfers`/`hasInvalidTransfers`, refresh the
banner, and — if the flow is open — route to the right screen (overdue → recovery, etc.). This is the
primary catch-up mechanism; notifications are best-effort. (Mirrors the proposal's "reconcile on every
launch".)

---

## 12. File / module layout (new + touched)

**New:**
- `Models/Migration/MigrationModels.swift` (+ split if large)
- `Dependencies/MigrationSDK/{MigrationSDKInterface,MigrationSDKLiveKey,MigrationSDKTestKey,DummyMigrationEngine,MigrationStateStore}.swift`
- `Dependencies/LocalNotification/{LocalNotificationInterface,LocalNotificationLiveKey,LocalNotificationTestKey}.swift`
- `Dependencies/MigrationBGScheduler/{...Interface,...LiveKey}.swift`
- `Features/CoordFlows/MigrationCoordFlow{Store,View,Coordinator}.swift`
- `Features/Migration/<Screen>/<Screen>{Store,View}.swift` (per §9)
- `Features/MigrationDebug/MigrationDebug{Store,View}.swift` (DEBUG)

**Touched:**
- `AppDelegate.swift` (register/schedule/handle migration BG task)
- `*-Info.plist` (all targets — add identifier)
- `Features/Root/{RootStore,RootView,RootCoordinator}.swift` (add `.migrationCoordFlow`)
- `Features/SmartBanner/SmartBanner{Store,View}.swift` (migration priority + banner)
- `Features/Settings/AdvancedSettings{Store,View}.swift` (DEBUG row → MigrationDebug)
- `Resources/Localizable.xcstrings` (new copy)

---

## 13. Approaches considered

- **SDK boundary:** (a) **mirror the Kotlin interface 1:1 behind a `@DependencyClient` [chosen]** —
  best spec-fidelity and drop-in replacement; (b) idiomatic Swift redesign — diverges from the SDK
  contract; (c) TCA reducer as the engine — couples simulation to UI, harder to swap. → (a).
- **Background sending:** (a) **real BGTaskScheduler + debug trigger [chosen, per request]** — tests
  the true production path; (b) timer — not real background; (c) manual only — not hands-off. → (a).
- **State source:** **self-contained simulated state [chosen]** — deterministic, runs on any build.
- **Flow structure:** **single coordinator flow [chosen]** — matches `SendCoordFlow`, one owner of
  navigation; vs. ad-hoc sheets.

---

## 14. Testing

- **Swift Testing** suites (never XCTest). `@Suite(.serialized)` for anything touching the persisted
  engine/global state.
- Unit-test `DummyMigrationEngine`: split proposal, schedule generation, execute/advance, overdue &
  invalid detection, restart, persistence round-trip.
- TCA `TestStore` tests for the coordinator's path routing and key screen features (entry choice,
  transfer-plan confirm → schedule stored, recovery re-create).
- Build/test via the **Xcode MCP** (BuildProject / RunSomeTests), per environment rules.

---

## 15. Assumptions & known guesses (non-blocking)

These are best-guess decisions where the spec/SDK is silent; flagged so they're easy to revisit:
1. Immediate mode is modeled as a 1-transfer schedule executed in foreground (see §5 deviation).
2. Bucket interval and split count are compressed/simplified constants for the prototype.
3. Banner default = purple; other variants previewable via debug.
4. Notification permission requested at schedule-commit time.
5. Tor "unavailable" is a debug-armed state (no real Tor probe).
6. Heights/fees are cosmetic simulated values.

---

## 16. Out of scope

Real broadcasts/SDK, real Tor, multi-device recovery, Android specifics, per-cause error UIs,
production-grade copy/localization beyond English, analytics.
