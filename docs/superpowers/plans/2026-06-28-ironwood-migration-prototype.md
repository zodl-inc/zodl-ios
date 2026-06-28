# Ironwood Migration Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a fully simulated Orchard→Ironwood migration flow driven by a dummy SDK, with real iOS background-task execution, local notifications, a Home-screen entry banner, and DEBUG controls to drive every state.

**Architecture:** All simulation lives behind one boundary — `MigrationSDKClient.liveValue` → `DummyMigrationEngine` (persisted). The Swift SDK types mirror `MigrationSdk.kt` 1:1. Everything around it (a `MigrationCoordFlow` modeled on `SendCoordFlow`, BGTaskScheduler wiring in `AppDelegate`, a new `LocalNotificationClient`, the `SmartBanner` entry, on-launch reconciliation) is production-shaped so the real SDK drops into the same shape.

**Tech Stack:** Swift 6, SwiftUI, The Composable Architecture (TCA, modern macros), swift-dependencies (`@DependencyClient`), ZcashLightClientKit (`Zatoshi`, `BlockHeight`), BGTaskScheduler, UserNotifications, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-28-ironwood-migration-prototype-design.md`

## Global Constraints

- **Builds/tests via Xcode MCP** (`mcp__xcode__BuildProject`, `RunSomeTests`); scheme `zodl-internal`, dev target `secant-testnet`. If a build fails on Swift macro trust, STOP and ask the user to allow macros (do not fall back to CLI `-skipMacroValidation`).
- **Swift 6 strict concurrency:** dependency closures are `@Sendable`; use `@preconcurrency import ZcashLightClientKit` where SDK types aren't `Sendable`.
- **Swift style:** explicit type names, never `.init(...)` shorthand. **No semicolons.** Prefer `OSAllocatedUnfairLock` over `NSLock` (import `os`).
- **App name in all copy is `ZODL`** (never "Zodl"/"zodl"). Does not change identifiers (`zodl_internal`, scheme names, bundle IDs, task identifiers).
- **Tests:** Swift Testing only (`@Suite`/`@Test`/`#expect`/`#require`), never XCTest. Mark suites touching persisted/global state `@Suite(.serialized)`.
- **Lint:** no `print`/`NSLog`/`debugPrint` in app code; string interpolation not concatenation; no force-unwrap / IUO; 4-space indent; 150-char line; 600-line file warning. `TODO:` must reference an issue (`TODO: [#MOB-1451]`).
- **Type order:** nested types → static props → constants → vars → computed → init → methods → protocol-conformance extensions.
- **All prototype-only additions** (not in the Kotlin draft) are marked with a `// PROTOTYPE` comment.

---

## Task 0: Recon — project file-membership model & SDK type conformances

**Goal:** Lock down two facts that change how every later task is executed.

- [ ] **Step 1:** Determine whether the Xcode project uses synchronized folder groups (no pbxproj edits needed to add files) or classic file references.

Run: `grep -c "PBXFileSystemSynchronizedRootGroup" "secant.xcodeproj/project.pbxproj"`
- If `> 0`: files created in `secant/Sources/...` are auto-included → no project edits, screen features can be created in parallel.
- If `0`: each new file must be added to the target via Xcode MCP `XcodeWrite` (or pbxproj edit) → serialize file creation.

Record the result at the top of execution notes; it gates parallelism in Tasks 9–16 and 19.

- [ ] **Step 2:** Confirm `Zatoshi` and `BlockHeight` conformances used by the model/persistence layer.

Check in the resolved ZcashLightClientKit source: `Zatoshi` is `Equatable`/`Hashable`/`Codable`? `BlockHeight` is `typealias BlockHeight = Int`?
- If `Zatoshi` is **not** `Codable`: the persistence snapshot (Task 3) stores amounts as `Int64` and converts at the boundary. Public model types still use `Zatoshi`.

- [ ] **Step 3:** Sanity build the baseline (no changes yet) to confirm the toolchain is green.

Run: `mcp__xcode__BuildProject` for `secant-testnet`. Expected: build succeeds.

---

## Task 1: Migration model types

**Files:**
- Create: `secant/Sources/Models/Migration/MigrationModels.swift`

**Interfaces — Produces** (the coordination contract; copy names/types exactly in later tasks):

```swift
import Foundation
import ZcashLightClientKit

// PROTOTYPE: not in the Kotlin draft — conveys the entry choice to the engine.
public enum MigrationMode: String, Equatable, Sendable, Codable {
    case immediate
    case privateScheduled
}

public struct NetworkPrivacyOptions: Equatable, Sendable, Codable {
    public var useTor: Bool
    public var submissionEndpoint: String?
    public init(useTor: Bool, submissionEndpoint: String? = nil) {
        self.useTor = useTor
        self.submissionEndpoint = submissionEndpoint
    }
}

public struct NoteSplitProposal: Equatable, Sendable, Codable {
    public var outputNotes: [Zatoshi]   // amounts
    public var fee: Zatoshi
}

public struct TransferProposal: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var amount: Zatoshi
    public var anchorHeight: BlockHeight
    public var nextExecutableAfterHeight: BlockHeight
    public var expiryHeight: BlockHeight
}

public struct MigrationSchedule: Equatable, Sendable, Codable {
    public var transfers: [TransferProposal]
    public var estimatedDurationHours: Int
}

public struct MigrationProgress: Equatable, Sendable, Codable {
    public var completedTransfers: Int
    public var totalTransfers: Int
    public var remainingOrchard: Zatoshi
    public var nextTransferReadyAtHeight: BlockHeight?
}

public enum AttentionReason: Equatable, Sendable, Codable {
    case invalidTransfer(transferId: String)
    case transferExpired
    case syncRequiredBeforeNext
}

public enum MigrationState: Equatable, Sendable, Codable {
    case notStarted
    case splitPendingConfirmation
    case readyToPropose
    case inProgress(MigrationProgress)
    case requiresAttention(AttentionReason)
    case complete
}

public enum TransferResult: Equatable, Sendable, Codable {
    case success(txId: String)
    case networkError(retryable: Bool)
    case invalidNote
    case expired
}
```

- [ ] **Step 1:** Create the file with the types above. If Task 0 found `Zatoshi` non-`Codable`, add a `Codable` conformance via an extension in this file (encode `.amount` as `Int64`), or drop `Codable` from public types and rely on the Task-3 snapshot for persistence — pick based on Task 0 and note the choice.
- [ ] **Step 2:** Build (`BuildProject`, `secant-testnet`). Expected: succeeds.
- [ ] **Step 3:** Commit `feat: [MOB-1451] migration model types`.

---

## Task 2: MigrationSDKClient interface

**Files:**
- Create: `secant/Sources/Dependencies/MigrationSDK/MigrationSDKInterface.swift`

**Interfaces — Consumes:** all types from Task 1.
**Interfaces — Produces:**

```swift
import ComposableArchitecture
import Combine
import ZcashLightClientKit

@DependencyClient
public struct MigrationSDKClient: Sendable {
    // State
    public var getMigrationState: @Sendable () -> MigrationState = { .notStarted }
    public var stateStream: @Sendable () -> AnyPublisher<MigrationState, Never> = { Empty().eraseToAnyPublisher() }   // PROTOTYPE convenience (Kotlin "consider Flow")
    public var getMigrationProgress: @Sendable () -> MigrationProgress?
    // Note splitting
    public var isNoteSplitNeeded: @Sendable () -> Bool = { false }
    public var prepareNoteSplit: @Sendable () async -> NoteSplitProposal = { NoteSplitProposal(outputNotes: [], fee: .zero) }
    public var submitNoteSplit: @Sendable (NoteSplitProposal) async -> TransferResult = { _ in .success(txId: "") }
    // Proposal
    public var proposeMigrationTransfers: @Sendable () async -> MigrationSchedule = { MigrationSchedule(transfers: [], estimatedDurationHours: 0) }
    public var signAndStoreMigrationSchedule: @Sendable (MigrationSchedule) async -> Void
    // Background execution
    public var isSyncRequiredBeforeNextTransfer: @Sendable () -> Bool = { false }
    public var executeNextPendingTransfer: @Sendable (NetworkPrivacyOptions) async -> TransferResult?
    // Reconciliation
    public var hasOverdueTransfers: @Sendable () -> Bool = { false }
    public var hasInvalidTransfers: @Sendable () -> Bool = { false }
    // Recovery
    public var restartCurrentMigrationStep: @Sendable () async -> MigrationSchedule = { MigrationSchedule(transfers: [], estimatedDurationHours: 0) }
    // Lifecycle
    public var initializePostUpgrade: @Sendable () -> Void
    // PROTOTYPE additions
    public var selectMigrationMode: @Sendable (MigrationMode) -> Void
    public var simulatedOrchardBalance: @Sendable () -> Zatoshi = { .zero }
    public var debug: MigrationDebugControls = .noOp
}

public extension DependencyValues {
    var migrationSDK: MigrationSDKClient {
        get { self[MigrationSDKClient.self] }
        set { self[MigrationSDKClient.self] = newValue }
    }
}

// PROTOTYPE: debug surface, driven by the MigrationDebug panel.
public struct MigrationDebugControls: Sendable {
    public var reset: @Sendable () async -> Void = {}
    public var seed: @Sendable (_ orchard: Zatoshi, _ noteCount: Int) async -> Void = { _, _ in }
    public var advanceHeight: @Sendable (_ blocks: Int) async -> Void = { _ in }
    public var runBackgroundTaskNow: @Sendable () async -> Void = {}
    public var armNextTransferResult: @Sendable (TransferResult) async -> Void = { _ in }
    public var jumpTo: @Sendable (MigrationDebugTarget) async -> Void = { _ in }
    public static let noOp = MigrationDebugControls()
}

public enum MigrationDebugTarget: Equatable, Sendable {
    case overdue, invalidTransfer, syncRequired, complete, completeWithDust
}
```

- [ ] **Step 1:** Create the interface file (with `testValue` left to the macro; add `static let noOp` in Task 4 alongside live).
- [ ] **Step 2:** Build. Expected: succeeds (macro generates `testValue`).
- [ ] **Step 3:** Commit `feat: [MOB-1451] MigrationSDKClient interface`.

---

## Task 3: Persistence — MigrationStateStore

**Files:**
- Create: `secant/Sources/Dependencies/MigrationSDK/MigrationStateStore.swift`
- Test: `Tests/.../MigrationStateStoreTests.swift` (follow the repo's test target layout discovered in Task 0)

**Interfaces — Produces:**

```swift
// Codable snapshot of the whole simulation. Amounts stored as Int64 if Zatoshi isn't Codable.
struct MigrationSnapshot: Equatable, Sendable, Codable {
    var orchardZats: Int64
    var notesZats: [Int64]
    var currentHeight: BlockHeight
    var mode: MigrationMode
    var state: MigrationState
    var transfers: [StoredTransfer]
    var networkPrivacy: NetworkPrivacyOptions
    var armedFailure: TransferResult?
    var dustThresholdZats: Int64
    static var seededDefault: MigrationSnapshot { /* ~12.458 ZEC, 1 note, height 2_500_000 */ }
}

struct StoredTransfer: Equatable, Sendable, Codable {
    var proposal: TransferProposal
    var status: Status
    enum Status: Equatable, Sendable, Codable { case pending, sent(txId: String), invalid, expired }
}

struct MigrationStateStore: Sendable {
    var load: @Sendable () -> MigrationSnapshot
    var save: @Sendable (MigrationSnapshot) -> Void
    var clear: @Sendable () -> Void
    static func live(fileURL: URL) -> MigrationStateStore   // JSON in Application Support
    static func ephemeral() -> MigrationStateStore          // in-memory, for tests
}
```

- [ ] **Step 1 (test first):** Write `MigrationStateStoreTests` — `ephemeral()` round-trips a snapshot (save then load equals input); `live(fileURL:)` with a temp file round-trips and `clear()` resets to `seededDefault`.
- [ ] **Step 2:** Run the tests (`RunSomeTests`). Expected: FAIL (types/functions missing).
- [ ] **Step 3:** Implement `MigrationStateStore` + `MigrationSnapshot`/`StoredTransfer` with JSON encode/decode to the file URL; `seededDefault` ≈ 12.458 ZEC.
- [ ] **Step 4:** Run tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat: [MOB-1451] migration state persistence`.

---

## Task 4: DummyMigrationEngine + live/noOp dependency values

**Files:**
- Create: `secant/Sources/Dependencies/MigrationSDK/DummyMigrationEngine.swift`
- Create: `secant/Sources/Dependencies/MigrationSDK/MigrationSDKLiveKey.swift`
- Create: `secant/Sources/Dependencies/MigrationSDK/MigrationSDKTestKey.swift`
- Test: `Tests/.../DummyMigrationEngineTests.swift`

**Interfaces — Consumes:** Task 1 types, Task 2 client, Task 3 store.
**Interfaces — Produces:** `MigrationSDKClient.liveValue`, `MigrationSDKClient.noOp`; an `actor DummyMigrationEngine` whose methods back every client closure, publishing state via a `CurrentValueSubject<MigrationState, Never>`.

Engine behavior (implement to satisfy the tests below):
- `prepareNoteSplit` → split `orchard` into `min(noteCountTarget, …)` notes, sizes varied by index, `fee` small fixed.
- `submitNoteSplit` → state `.splitPendingConfirmation`; `confirmSplit()` (called by a short `Task.sleep` and by debug) → `.readyToPropose`.
- `proposeMigrationTransfers` → for `.immediate`: 1 transfer with `nextExecutableAfterHeight == currentHeight`; for `.privateScheduled`: N transfers, `nextExecutableAfterHeight = currentHeight + bucket*(i+1)`, `expiryHeight = nextExecutableAfterHeight + expiryWindow`, `estimatedDurationHours` from N·6.
- `signAndStoreMigrationSchedule` → store transfers `pending`, state `.inProgress(progress)`.
- `executeNextPendingTransfer` → if `armedFailure` set, consume it and return it (and set `.requiresAttention` for invalid/expired); else mark next pending `sent`, reduce `orchard`, recompute progress; when none remain → `.complete` (or dust state if remainder ≤ dustThreshold).
- `hasOverdueTransfers` → any `pending` with `nextExecutableAfterHeight ≤ currentHeight` that wasn't executed in its window (model: more than one pending due).
- `hasInvalidTransfers` → any `invalid`/`expired`, or `orchard > 0` with no valid pending.
- `restartCurrentMigrationStep` → drop invalid/expired, re-propose for remaining `orchard`, state `.readyToPropose`→ returns schedule.
- `initializePostUpgrade` → set `minAnchorHeight = currentHeight`.
- debug controls map directly onto engine mutations (seed/advanceHeight/runBackgroundTaskNow→`executeNextPendingTransfer`/armNextTransferResult/jumpTo).

- [ ] **Step 1 (test first):** Write `DummyMigrationEngineTests` (`@Suite(.serialized)`, using `MigrationStateStore.ephemeral()`):
  - seed 10 ZEC → `isNoteSplitNeeded()` true; `prepareNoteSplit()` returns ≥2 notes summing ≤ balance.
  - private flow: submit split → state `.splitPendingConfirmation`; confirm → `.readyToPropose`; propose → N transfers with strictly increasing `nextExecutableAfterHeight`; sign → `.inProgress` with `totalTransfers == N`.
  - execute all transfers → progress increments → final `.complete`, `remainingOrchard == .zero`.
  - immediate flow: select `.immediate`, propose → exactly 1 transfer executable now; execute → `.complete`.
  - arm `.invalidNote` → execute → `.requiresAttention(.invalidTransfer)`; `hasInvalidTransfers()` true; `restartCurrentMigrationStep()` returns a schedule for the remainder.
  - overdue: advance height past two windows without executing → `hasOverdueTransfers()` true.
- [ ] **Step 2:** Run tests. Expected: FAIL.
- [ ] **Step 3:** Implement `DummyMigrationEngine` + `MigrationSDKLiveKey` (`liveValue` builds an engine over `MigrationStateStore.live(...)`, wires every closure; `stateStream` from the subject) + `MigrationSDKTestKey` (`noOp`).
- [ ] **Step 4:** Run tests. Expected: PASS.
- [ ] **Step 5:** Build. Commit `feat: [MOB-1451] dummy migration engine + live client`.

---

## Task 5: LocalNotificationClient

**Files:**
- Create: `secant/Sources/Dependencies/LocalNotification/LocalNotificationInterface.swift`
- Create: `secant/Sources/Dependencies/LocalNotification/LocalNotificationLiveKey.swift`
- Create: `secant/Sources/Dependencies/LocalNotification/LocalNotificationTestKey.swift`

**Interfaces — Produces:**

```swift
@DependencyClient
struct LocalNotificationClient: Sendable {
    var requestAuthorization: @Sendable () async -> Bool = { false }
    var post: @Sendable (_ title: String, _ body: String, _ identifier: String) async -> Void
    var removeAll: @Sendable () async -> Void
}
extension DependencyValues { var localNotification: LocalNotificationClient { get/set } }
```

- [ ] **Step 1:** Implement interface + `DependencyValues` + `liveValue` (wrap `UNUserNotificationCenter.current()`: `requestAuthorization(options: [.alert, .sound])`, build `UNMutableNotificationContent`, schedule with `nil` trigger for immediate) + `noOp`.
- [ ] **Step 2:** Build. Expected: succeeds.
- [ ] **Step 3:** Commit `feat: [MOB-1451] local notification client`.

---

## Task 6: MigrationBGScheduler

**Files:**
- Create: `secant/Sources/Dependencies/MigrationBGScheduler/MigrationBGSchedulerInterface.swift`
- Create: `secant/Sources/Dependencies/MigrationBGScheduler/MigrationBGSchedulerLiveKey.swift`

**Interfaces — Produces:**

```swift
enum MigrationBGTask { static let identifier = "co.electriccoin.ironwood_migration" }

@DependencyClient
struct MigrationBGScheduler: Sendable {
    var scheduleNextRun: @Sendable (_ earliestInSeconds: TimeInterval) -> Void   // submit BGProcessingTaskRequest
    var cancel: @Sendable () -> Void
}
extension DependencyValues { var migrationBGScheduler: MigrationBGScheduler { get/set } }
```

- [ ] **Step 1:** Implement interface + live (`BGTaskScheduler.shared.submit` of a `BGProcessingTaskRequest(identifier:)` with `earliestBeginDate`, `requiresNetworkConnectivity = true`, `requiresExternalPower = false`; `cancel` → `cancel(taskRequestWithIdentifier:)`) + `noOp`.
- [ ] **Step 2:** Build. Commit `feat: [MOB-1451] migration background scheduler`.

---

## Task 7: AppDelegate background-task wiring + Info.plist identifiers

**Files:**
- Modify: `secant/Sources/AppDelegate.swift` (register handler in `registerTasks()`, add `scheduleMigrationBackgroundTask()`, add a handler that runs the migration step)
- Modify (all targets): `secant/secant-mainnet-Info.plist`, `secant/secant-testnet-Info.plist`, `secant/zashi-testnet-Info.plist`, `zashi-internal-Info.plist`, `secant-distrib-Info.plist` — add `co.electriccoin.ironwood_migration` to `BGTaskSchedulerPermittedIdentifiers`.

**Interfaces — Consumes:** `MigrationSDKClient`, `LocalNotificationClient`, `MigrationBGScheduler`.
**Interfaces — Produces:** a reusable `@Sendable func runMigrationStep() async` (used by both the BG handler and the DEBUG "run now") that: if `isSyncRequiredBeforeNextTransfer()` returns (decoupled — no sync here); else `executeNextPendingTransfer(options)` → on `.success` post success notification + `scheduleNextRun` if more pending; on failure post one generic error notification. Place `runMigrationStep` where both AppDelegate and the debug panel can call it (e.g. a small `MigrationBackgroundWorker` in the MigrationSDK folder, taking the three dependencies).

- [ ] **Step 1:** Create `MigrationBackgroundWorker` with `runMigrationStep()` using `@Dependency`. Add a unit test that, with a seeded committed schedule (ephemeral engine), one `runMigrationStep()` marks exactly one transfer sent and requests one notification (assert via a spy `LocalNotificationClient`).
- [ ] **Step 2:** Run test. Expected FAIL → implement → PASS.
- [ ] **Step 3:** Register `MigrationBGTask.identifier` handler in `AppDelegate.registerTasks()` (call `runMigrationStep` then `task.setTaskCompleted`, with `expirationHandler`). Add `scheduleMigrationBackgroundTask()`.
- [ ] **Step 4:** Add the identifier to all five Info.plist files.
- [ ] **Step 5:** Build. Commit `feat: [MOB-1451] migration background task wiring`.

---

## Task 8: MigrationCoordFlow skeleton + Root integration

**Files:**
- Create: `secant/Sources/Features/CoordFlows/MigrationCoordFlowStore.swift`
- Create: `secant/Sources/Features/CoordFlows/MigrationCoordFlowView.swift`
- Create: `secant/Sources/Features/CoordFlows/MigrationCoordFlowCoordinator.swift`
- Modify: `secant/Sources/Features/Root/RootStore.swift` (add `case migrationCoordFlow` to `Path`, `var migrationCoordFlowState`, `case migrationCoordFlow(MigrationCoordFlow.Action)`, `Scope`)
- Modify: `secant/Sources/Features/Root/RootView.swift` (render `MigrationCoordFlowView` when `path == .migrationCoordFlow`, trailing transition)
- Modify: `secant/Sources/Features/Root/RootCoordinator.swift` (handle a `.migrationRequested` entry → set `state.path = .migrationCoordFlow`; handle flow `.dismiss` → `state.path = nil`)

**Pattern:** copy `SendCoordFlow` exactly. `@Reducer enum Path` with the screen cases (added in Tasks 9–16), `State { var path = StackState<Path.State>(); var entryState = MigrationEntry.State() }`, `Action { case path(StackActionOf<Path>); case entry(MigrationEntry.Action); case dismiss }`. View: `NavigationStack(path:)` with root = `MigrationEntryView` and `destination:` switch. Coordinator: `coordinatorReduce()` listening to child delegate actions.

- [ ] **Step 1:** Create the three flow files with an empty `Path` enum and a placeholder root (temporary `Text` until Task 9). Wire Root (Path case, state, action, scope, view branch, coordinator launch/dismiss).
- [ ] **Step 2:** Build. Expected: succeeds.
- [ ] **Step 3:** Commit `feat: [MOB-1451] migration coordinator flow skeleton + Root wiring`.

---

## Tasks 9–16: Screen features

Each screen feature is `Features/Migration/<Name>/<Name>Store.swift` + `<Name>View.swift`, a `@Reducer struct` with `@ObservableState struct State`, `enum Action` (with a nested `enum Delegate` for signals the coordinator consumes), `@Dependency(\.migrationSDK)`. Views use `UIComponents` (`ZashiButton`, `ActionRow`, `PrivacyBadge`, `ZashiToggle`, progress views, `.applyScreenBackground()`, `ZashiText`) and match the Figma node screenshots (file key `1aeq8gleYh9Yr1l33TwELR`). Add each as a `MigrationCoordFlow.Path` case + `destination:` branch + coordinator routing. **If Task 0 found classic file references, add each new file to the target via Xcode MCP before building; if synchronized groups, no project edit.** Build after each feature.

Per feature: (1) write the Store with a TCA `TestStore` test for its key action (choice/confirm/toggle → expected delegate/state), (2) run → fail → implement → pass, (3) build, (4) commit.

### Task 9: MigrationEntry (root screen) — Figma `2630:11744` / `2539:63191`
- "Move to Ironwood": Orchard balance at risk, two `ActionRow`-style options (Migrate Immediately / Migrate with Privacy) with radio selection, `Next`. Footnote "Pool-crossing transfer amounts are visible on-chain". Balance-load error sub-state ("Couldn't load your Orchard balance" / Try again). On `Next`: `selectMigrationMode`, delegate `.chose(.immediate)` or `.chose(.privateScheduled)`.

### Task 10: MigrationNoteSplit — Figma `2670:14995/15235/15570`
- States in one feature: `confirm` (Split Your Wallet Funds: amount, fee, `Confirm` → `submitNoteSplit`), `splitting` (progress, disabled button), `confirmed` (Split Confirmed!, `Continue`). On reopen while `.splitPendingConfirmation` show the waiting variant (C1). Delegate `.continued`.

### Task 11: MigrationNetworkPrivacy — Figma `2673:4621/4744`
- Tor toggle (`ZashiToggle`/route-via-Tor), "What Happens Next" with/without Tor, `Next`. Tor-unavailable sub-state (C2) when debug-armed. Delegate `.confirmed(NetworkPrivacyOptions)`.

### Task 12: MigrationBackgroundDelivery — Figma (Allow Background Delivery)
- Explainer bullets, `Allow Background Access` (→ `localNotification.requestAuthorization`) and `Skip — I'll open the app`. Delegate `.continued`.

### Task 13: MigrationTransferPlan — Figma `2673:2683` area / Transfer Plan
- `proposeMigrationTransfers` on appear; list transfers (amount + ETA), summary (total, pool Orchard→Ironwood, count, fee, duration), `Confirm` → `signAndStoreMigrationSchedule` + `migrationBGScheduler.scheduleNextRun` + (if not already) `requestAuthorization`. Delegate `.scheduled`.

### Task 14: MigrationScheduled + MigrationProgress — Figma `2673:2683` (Scheduled), progress/C3/C6
- `MigrationScheduled`: success, `Done` → delegate `.done`.
- `MigrationProgress`: "N of M", next ETA, remaining Orchard; sync-step variant (`.syncRequiredBeforeNext`); complete + dust variants. Observes `stateStream`.

### Task 15: MigrationImmediateReview — Figma `2617:7260` (Review/Sending/Sent)
- States: `review` (amount, single transfer, `Confirm` → propose+sign+`executeNextPendingTransfer` in foreground), `sending`, `sent` (`View Transaction`/Close). Delegate `.finished`.

### Task 16: MigrationRecovery — Figma `2621:10289` (C5), C4 overdue
- Single simplified prompt (per product steer): overdue fallback ("transfers ready to send" → Send now / Reschedule) and invalid/expired re-create ("a transfer is no longer valid… we'll create a new one" → `restartCurrentMigrationStep`). Delegate `.recreate` / `.sendNow` / `.reschedule`.

---

## Task 17: SmartBanner entry

**Files:**
- Modify: `secant/Sources/Features/SmartBanner/SmartBannerStore.swift` (add a `migration` case to the priority/content enum; observe `migrationSDK.stateStream`; show when state ≠ `.notStarted`-only-and-not-needed, i.e. migration needed or in progress)
- Modify: `secant/Sources/Features/SmartBanner/SmartBannerView.swift` ("Migration Required" strip; centralize the color in one constant; default purple)
- Modify: `RootCoordinator` / Home wiring so tapping the strip sends `.migrationRequested` to Root.

- [ ] Step 1: add migration priority + content + stream subscription (TestStore test: when stream emits `.inProgress`, banner exposes migration content). Step 2: fail→implement→pass. Step 3: view strip + tap delegate. Step 4: build. Step 5: commit `feat: [MOB-1451] home migration banner`.

---

## Task 18: On-launch / foreground reconciliation

**Files:**
- Modify: `secant/Sources/Features/Root/RootInitialization.swift` (on `didFinishLaunching` and `willEnterForeground`: call `migrationSDK.getMigrationState` + `hasOverdueTransfers`/`hasInvalidTransfers`; refresh banner; if flow open, route to recovery/progress)

- [ ] Step 1: add reconciliation effect (TestStore test: foreground with overdue → routes to recovery). Step 2: fail→implement→pass. Step 3: build. Step 4: commit `feat: [MOB-1451] migration on-launch reconciliation`.

---

## Task 19: MigrationDebug panel + Advanced Settings entry

**Files:**
- Create: `secant/Sources/Features/MigrationDebug/MigrationDebugStore.swift`
- Create: `secant/Sources/Features/MigrationDebug/MigrationDebugView.swift`
- Modify: `secant/Sources/Features/Settings/AdvancedSettingsStore.swift` + `AdvancedSettingsView.swift` (add a `#if DEBUG` row "Migration Debug" → operation/navigation)

- [ ] Step 1: Build the panel driving `migrationSDK.debug` (reset, seed balance/notes, advance height, run background task now, arm next result, jump to state, toggle banner visibility + cycle color variant; live read-out of `MigrationState`/schedule). Step 2: wire a `#if DEBUG` Advanced Settings row. Step 3: build. Step 4: commit `feat: [MOB-1451] migration debug panel`.

---

## Task 20: Localization copy + final verification

**Files:**
- Modify: `secant/Resources/Localizable.xcstrings` (all migration strings, English; app name `ZODL`)

- [ ] **Step 1:** Add every user-facing string used in Tasks 9–19 to `Localizable.xcstrings` and switch views to `String(localizable:)` / `Text(localizable:)`. Build so the xcstrings accessor regenerates.
- [ ] **Step 2:** Full build (`BuildProject`, `secant-testnet`). Expected: succeeds, no SwiftLint errors.
- [ ] **Step 3:** Run the full migration test suite (`RunSomeTests` for the migration tests). Expected: all PASS.
- [ ] **Step 4:** Manual smoke (document in final report): debug seed → entry → private path → schedule → "run background task now" repeatedly → notifications + progress → complete; immediate path; arm failure → recovery.
- [ ] **Step 5:** Commit `feat: [MOB-1451] migration copy + final wiring`.

---

## Self-review (spec coverage)

- SDK 1:1 mirror → Tasks 1,2,4. Dummy + persistence + simulated balance → Tasks 3,4. Real BG send → Tasks 6,7. Notifications → Task 5,7. Debug controls incl. "run background task now" → Tasks 2,4,7,19. Self-contained state (~12.458 ZEC) → Task 3. Home banner (purple, variants) → Task 17,19. Coordinator flow + all screens incl. Path C (simplified) → Tasks 8–16. Reconciliation → Task 18. Immediate path → Tasks 9,15. Copy/ZODL → Task 20. Tests via Swift Testing/TestStore throughout. All spec sections covered.
