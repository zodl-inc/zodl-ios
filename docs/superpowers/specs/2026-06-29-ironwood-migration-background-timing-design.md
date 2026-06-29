# Ironwood migration — realistic background execution timing

**Date:** 2026-06-29
**Ticket:** MOB-1451
**Status:** Proposed (awaiting approval)

## Problem

The simulated Orchard → Ironwood migration broadcasts its scheduled transfers from a background
task (`MigrationBackgroundWorker`). Today the simulation fires a transfer roughly **every 60
seconds** (`firstRunDelay`, `rescheduleDelay`, and the resume/recreate `scheduleNextRun(60)` calls),
and there is **no notion of "last app activity"** anywhere in the app.

In reality the background task is expected to:

1. Run **about once a night/day**, sending **one** transfer per run.
2. Only run when there has been **at least one hour** since the user last had the app open.

"One transfer per run" is already true (`runMigrationStep` executes exactly one
`executeNextPendingTransfer`). This change adds the **nightly cadence** and the **1-hour idle gap**,
and the activity tracking those require.

## Decisions (confirmed)

- **Time scale: realistic.** Each subsequent transfer is scheduled for the next **night window**,
  with the `BGProcessingTaskRequest.earliestBeginDate` floor anchored to the **start of the night
  (9 PM)** — not a precise hour — so iOS gets the whole night to find a slot (`earliestBeginDate`
  is only a floor and has no window-end). If migration starts while it is already night, the floor
  is **now**, so the rest of tonight is used. The idle gap is a literal **1 hour**. A multi-transfer
  migration therefore spans several nights; on-demand demoing uses the existing MigrationDebug panel.
- **Debug "▶︎ Run background task now" always bypasses the guard** — it sends a transfer
  immediately, exactly as it does today.

## Scope

In scope — the **background** execution path only:

- `MigrationBackgroundWorker` (the iOS `BGTaskScheduler`-fired path) gains the idle-gap guard.
- The four nightly-cadence scheduling call sites change from 60 s to the next nightly window.
- New "last app activity" tracking, stamped from the app lifecycle and read by the worker.

Out of scope — these are **foreground, user-initiated** sends and are intentionally **not**
gated (the user is active by definition):

- "Immediate" migration mode (`MigrationImmediateReviewStore`) — signs + sends inline.
- "Resume Migration → Send now" and recovery "recreate" sends (`MigrationCoordFlowCoordinator`)
  call `executeNextPendingTransfer` directly, not the worker. Their *rescheduling* of the next
  background run does move to the nightly window, but the send itself stays immediate.

## Design

### 1. New dependency — `MigrationActivityClient`

A small dependency client (matching the existing ~41 clients) that records and reads the last time
the app was actively in use. Persisted (survives the background-task relaunch) via the existing
`UserDefaultsClient`.

```swift
@DependencyClient
struct MigrationActivityClient: Sendable {
    /// Stamp "the app was used" with the current time.
    var recordActivity: @Sendable () -> Void
    /// The last recorded activity time, or nil if never recorded.
    var lastActivity: @Sendable () -> Date?
}
```

- **Interface** `Dependencies/MigrationActivity/MigrationActivityInterface.swift` — the client +
  `DependencyValues.migrationActivity`.
- **LiveKey** `Dependencies/MigrationActivity/MigrationActivityLiveKey.swift` — stores a `Date`
  under key `"migration.lastAppActivity"` via `@Dependency(\.userDefaults)`
  (`setValue(Date(), key)` / `objectForKey(key) as? Date`). `recordActivity` uses `Date()` for
  "now". The macro-generated `testValue` (no-op / nil) is sufficient; no TestKey needed.

The client is registered in the project (target membership via the Xcode MCP).

### 2. Stamp "last app activity" from the lifecycle

In `RootStore`/`RootInitialization`, add `@Dependency(\.migrationActivity)` and call
`migrationActivity.recordActivity()` on the existing lifecycle actions:

- `.appDelegate(.didFinishLaunching)` — cold start.
- `.appDelegate(.willEnterForeground)` — returning to foreground.
- `.appDelegate(.didEnterBackground)` — **the key one**: marks the end of an active session.

The latest stamp wins. Because background tasks only fire while the app is *not* foreground, the
relevant stamp at run time is the last `didEnterBackground` (or launch/foreground) — i.e. "when the
user last had the app open."

### 3. Idle-gap guard in `MigrationBackgroundWorker`

`runMigrationStep` gains a trigger so the debug button can bypass the guard:

```swift
enum MigrationRunTrigger: Sendable {
    case scheduledTask   // real iOS BGTask — enforces the 1-hour idle gap
    case manual          // debug "Run now" — bypasses the gap (sends immediately)
}

func runMigrationStep(trigger: MigrationRunTrigger) async -> MigrationStepOutcome
```

New worker members:

```swift
@Dependency(\.migrationActivity) var migrationActivity
@Dependency(\.date) var date
private let minActivityGap: TimeInterval = 60 * 60   // 1 hour
```

`performStep`, **before** the existing sync/execute logic, when `trigger == .scheduledTask`:

- Read `migrationActivity.lastActivity()`.
- If a stamp exists and `date.now - lastActivity < minActivityGap`:
  - Reschedule the task for `lastActivity + 1 h` via
    `migrationBGScheduler.scheduleNextRun(minActivityGap - elapsed)`.
  - Return a new outcome `.tooSoonAfterActivity` (no transfer sent, no notification).
- Otherwise (no stamp, or gap satisfied), proceed exactly as today.

`trigger == .manual` skips the guard entirely and runs the existing logic immediately.

On a **successful** transfer, the success-path reschedule changes from
`scheduleNextRun(rescheduleDelay)` (60 s) to `scheduleNextNightlyRun()` (see §4). `rescheduleDelay`
is removed; `minActivityGap` replaces it as the worker's timing constant.

### 4. Nightly scheduling — `MigrationBGScheduler`

**Why not "3 AM exactly":** `BGProcessingTaskRequest.earliestBeginDate` is only a **floor** — iOS
will not start before it but picks the actual moment itself (and there is **no deadline / window-end
API**, so eligibility is `[earliestBeginDate, ∞)`). Scheduling for a precise 3 AM means a migration
started at 3:30 AM waits until *tomorrow* 3 AM (~23.5 h), wasting tonight. To give iOS the widest
window we anchor the floor to the **start of the night** (9 PM), and use **now** when we are already
inside the night so the rest of tonight is usable. Because there is no hard end, a run is never lost
— if iOS can't run it overnight it runs later.

Scheduler closures:

```swift
@DependencyClient
struct MigrationBGScheduler: Sendable {
    /// Explicit floor, `now + earliestInSeconds`. Used only by the idle-gap deferral (retry past
    /// `lastActivity + 1 h`).
    var scheduleNextRun: @Sendable (_ earliestInSeconds: TimeInterval) -> Void   // kept
    /// FIRST run after signing: eligible from the start of the night, or now if already in the
    /// night — so a mid-night start uses the rest of tonight.
    var scheduleFirstRun: @Sendable () -> Void                                   // new
    /// SUBSEQUENT run after a transfer: eligible from the NEXT night's 9 PM (~one per night,
    /// anchored so the time-of-day doesn't drift).
    var scheduleNightlyRun: @Sendable () -> Void                                 // new
    var cancel: @Sendable () -> Void
}
```

Pure, unit-testable window helper (Foundation-only, lives in the interface file):

```swift
enum MigrationNightlyWindow {
    static let windowStartHour = 21   // 9 PM — floor anchor / start of the night
    static let windowEndHour = 6      // 6 AM — defines "inside the night"

    /// hour ≥ 21 || hour < 6
    static func isWithinNight(_ date: Date, calendar: Calendar = .current) -> Bool

    /// First-run floor: `now` if inside the night, else today's 21:00.
    static func firstRunBegin(after now: Date, calendar: Calendar = .current) -> Date

    /// Subsequent-run floor: the start (21:00) of the next night — today 21:00 if `now` is before
    /// 21:00 (incl. early-morning runs), else tomorrow 21:00. Self-corrects back to night if a run
    /// lands in daytime.
    static func nextNightBegin(after now: Date, calendar: Calendar = .current) -> Date
}
```

`liveValue` submits a `BGProcessingTaskRequest` with `earliestBeginDate` from the matching helper
(`Date()` as `now`), `requiresNetworkConnectivity = true`, `requiresExternalPower = false` (not
gated on charging → more opportunities). `noOp` adds no-ops for the two new closures. (No jitter for
the prototype — the night window already provides spread; can be added for the real SDK.)

### 5. Switch the four cadence call sites to the night window

- `MigrationTransferPlanStore` — first run after signing: `scheduleFirstRun()`
  (`firstRunDelay` removed).
- `MigrationBackgroundWorker` — success-path reschedule: `scheduleNightlyRun()`.
- `MigrationCoordFlowCoordinator` — `reschedule` (stalled) and `recreate` (invalid):
  `scheduleNightlyRun()`.

### 6. Observability — new run-log outcome

The worker records every run via `recordBackgroundRun`. Add the skip outcome so a real
guard-skipped run is visible in the debug run log:

- `MigrationStepOutcome.tooSoonAfterActivity` (new).
- `MigrationBackgroundRun.Outcome.skippedTooSoon` (new) — summary
  `"Too soon after activity (skipped)"`, severity `.neutral`.
- `MigrationDebugStore.message(for:)` handles the new outcome (the exhaustive switch must compile;
  the debug button bypasses the guard, so this branch is informational).

These are plain Swift strings (the existing run-log/notification strings are not localized), so
**no `Localizable.xcstrings` changes** are expected.

## Files touched

New:
- `Dependencies/MigrationActivity/MigrationActivityInterface.swift`
- `Dependencies/MigrationActivity/MigrationActivityLiveKey.swift`
- `zodlTests/MigrationTests/MigrationBackgroundTimingTests.swift`

Edited:
- `Dependencies/MigrationSDK/MigrationBackgroundWorker.swift` — trigger param, idle guard, nightly reschedule, new outcome
- `Dependencies/MigrationSDK/MigrationStateStore.swift` — `Outcome.skippedTooSoon`
- `Dependencies/MigrationBGScheduler/MigrationBGSchedulerInterface.swift` — `scheduleFirstRun` + `scheduleNightlyRun` + `MigrationNightlyWindow`
- `Dependencies/MigrationBGScheduler/MigrationBGSchedulerLiveKey.swift` — window-anchored impls + noOp
- `Features/Migration/MigrationTransferPlan/MigrationTransferPlanStore.swift` — nightly first run
- `Features/CoordFlows/MigrationCoordFlowCoordinator.swift` — nightly reschedule (×2)
- `Features/MigrationDebug/MigrationDebugStore.swift` — `.manual` trigger + new outcome message
- `AppDelegate.swift` — `.scheduledTask` trigger
- `Features/Root/RootStore.swift` + `RootInitialization.swift` — stamp activity on lifecycle

## Testing (Swift Testing)

New `@Suite` covering:

1. **`MigrationNightlyWindow`** (pure, deterministic, fixed `calendar`):
   - `firstRunBegin`: 3:30 AM (inside night) → `now`; 11 PM (inside night) → `now`; 2 PM (daytime)
     → today 21:00; 7 AM (just after window) → today 21:00.
   - `nextNightBegin`: 3 AM → today 21:00 (next night); 11 PM → tomorrow 21:00; 2 PM → today 21:00.
   - `isWithinNight`: true for 21:00, 23:30, 03:30, 05:59; false for 06:00, 12:00, 20:59.
2. **Worker idle guard** via `withDependencies` (`migrationActivity`, `date`, `migrationSDK`,
   `migrationBGScheduler`):
   - `.scheduledTask`, activity 30 min ago → `.tooSoonAfterActivity`, **no** transfer executed,
     `scheduleNextRun` called with ≈ remaining seconds.
   - `.scheduledTask`, activity 2 h ago → transfer executes (`.result(.success)`).
   - `.scheduledTask`, no activity stamp → transfer executes.
   - `.manual`, activity 1 min ago → transfer executes (bypass).

Notes: the worker reads `migrationActivity.lastActivity` (overridden inline per test) and
`date.now` (`.constant(fixedNow)`), so no real `UserDefaults` is touched. Any suite that exercises
the live activity client against a real/named `UserDefaults` is marked `@Suite(.serialized)`.

## Non-goals / accepted limitations

- iOS ultimately decides when a `BGProcessingTask` actually runs; `earliestBeginDate` is only a
  floor. The simulation controls intent (nightly window + 1-hour floor), not guaranteed wall-clock.
- On-launch re-submission of the migration task mid-migration is **not** added here (the existing
  self-rescheduling chain covers steady state). Flagged as a possible follow-up.
- The deferral when too-soon targets `lastActivity + 1 h` (honors the minimum gap and keeps the
  migration progressing), not "skip the whole night."
