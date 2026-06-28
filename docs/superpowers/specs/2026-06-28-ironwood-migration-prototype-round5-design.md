# Ironwood Migration Prototype — Round 5: "Migration complete" SmartBanner → C6

**Date:** 2026-06-28
**Status:** Awaiting approval
**Type:** Prototype / simulated migration (dummy SDK behind `MigrationSDKClient`)

## Problem

When the migration's **last transfer is sent**, the user should land on Home, see the
SmartBanner switch to a **"Migration complete"** state, and tap **"More"** to open the
already-built **C6 "Migration Complete"** screen (with the dust variant when a sub-threshold
remainder stays in Orchard).

Today that path is broken for the **background-completion → Home** case:

- `SmartBannerStore.migrationStateUpdated` computes
  `shouldShow = hasBalance && migrationState != .complete`
  ([SmartBannerStore.swift:563](../../../secant/Sources/Features/SmartBanner/SmartBannerStore.swift)).
  So when the state flips to `.complete`, the migration banner is **closed and cleaned up** —
  it disappears entirely instead of switching to "Migration complete."
- The banner copy (`migrationBannerTitle` / `Info` / `Button` in
  [SmartBannerContent.swift:41](../../../secant/Sources/Features/SmartBanner/SmartBannerContent.swift))
  has **no `.complete` case** — it would otherwise fall through to "Migration Required."

Net effect: after a background completion there is **no migration banner on Home at all**, so the
user has no way to reach C6 from Home. (If the user happens to be *inside* the flow on the
progress/Resume screen when the last transfer lands, `MigrationStatusView` already swaps to C6 via
the state stream — that case is fine.)

## What already works (no changes)

- **C6 screen** (`MigrationCompleteView`) and its dust / no-dust variants.
- `MigrationStatusView` renders C6 when `store.isComplete`
  ([MigrationStatusView.swift:28](../../../secant/Sources/Features/Migration/MigrationStatus/MigrationStatusView.swift)).
- Coordinator `.start` routes `.complete → .status(.progress) → C6`
  ([MigrationCoordFlowCoordinator.swift:26](../../../secant/Sources/Features/CoordFlows/MigrationCoordFlowCoordinator.swift)).
- Tapping the banner's CTA → `.smartBannerContentTapped` → (priority is `.priorityMigration`) →
  `.migrationScreenRequested` → Home routes into the migration flow
  ([SmartBannerStore.swift:300](../../../secant/Sources/Features/SmartBanner/SmartBannerStore.swift)).
- In-flow live swap to C6 via `migrationSDK.stateStream()` on the status screen.

So the fix is **only** the banner's show-logic + complete copy. Tapping "More" already lands on C6.

## Decisions (from clarification)

1. **Reach C6 after background completion:** banner-driven only. The banner switches to
   "Migration complete"; tapping **"More"** opens C6. **No** auto full-screen takeover.
2. **Banner lifetime:** the "Migration complete" banner **persists while the migration state is
   `.complete`** (tapping "More" reopens C6 any time). It is cleared only by the debug **Reset**
   (which returns the engine to the seeded `notStarted` state and re-shows the "Migration Required"
   banner). No new "acknowledged" flag.

## Design

### 1. `SmartBannerStore` — show the banner on `.complete`, capture dust

Add one stored field to `State` (drives the dust-aware copy; `State` stays `Equatable`):

```swift
/// PROTOTYPE: residual Orchard dust at completion — drives the complete banner's subtitle.
var migrationDust: Zatoshi = .zero
```

Rewrite `.migrationStateUpdated` so `.complete` shows (and never suppresses) the banner:

```swift
case let .migrationStateUpdated(migrationState):
    state.migrationState = migrationState
    // `.complete` is shown as a celebratory / dust-info banner that persists until debug Reset;
    // tapping "More" reopens the C6 summary. Otherwise show only while Orchard funds remain.
    let hasBalance = migrationSDK.simulatedOrchardBalance().amount > 0
    let shouldShow = migrationState == .complete || hasBalance
    if shouldShow {
        state.migrationDust = migrationSDK.migrationSummary().dust
        return .send(.triggerPriority(.priorityMigration))
    } else if state.priorityContent == .priorityMigration {
        return .send(.closeAndCleanupBanner)
    }
    return .none
```

Notes:
- `migrationState` and `migrationDust` are updated in `State` **before** the early return, so the
  banner copy re-renders even when `.triggerPriority(.priorityMigration)` is a no-op (the banner was
  already open showing in-progress and `openBannerRequest` short-circuits on equal priority).
- After debug **Reset**, the stream emits `.notStarted` with a seeded Orchard balance, so
  `hasBalance` is true → the "Migration Required" banner returns. Correct.

### 2. `SmartBannerContent` — add `.complete` copy (dust-aware)

```swift
var migrationBannerTitle: String {
    switch store.migrationState {
    case .complete: return "Migration complete"
    case let .requiresAttention(.transferStalled(transferNumber)): return "Transfer \(transferNumber) waiting"
    case .inProgress: return "Migration in Progress"
    case .requiresAttention: return "Action Needed"
    default: return "Migration Required"
    }
}

var migrationBannerInfo: String {
    switch store.migrationState {
    case .complete:
        return store.migrationDust.amount > 0
            ? "Dust balance stays in Orchard for now"
            : "Your funds are now in Ironwood"
    case .requiresAttention(.transferStalled): return "Tap to reschedule or send now"
    case .inProgress: return "Transfers are sending in the background"
    case .requiresAttention: return "A transfer needs your attention"
    default: return "Move your funds to Ironwood"
    }
}

var migrationBannerButton: String {
    switch store.migrationState {
    case .complete: return "More"
    case .requiresAttention(.transferStalled): return "More"
    case .inProgress: return "View"
    case .requiresAttention: return "Resolve"
    default: return "Migrate"
    }
}
```

The dust copy ("Dust balance stays in Orchard for now") matches the provided screenshot.

### 3. Tapping "More"

No change. `.smartBannerContentTapped` already maps `priorityMigration → .migrationScreenRequested`,
Home routes into the flow, and `.start` lands on `.status(.progress)` → C6.

## Localization

No `Localizable.xcstrings` changes expected. The migration banner uses `Text(migrationBannerTitle)`
(a computed `String` variable), and String Catalog auto-extraction only captures **string-literal**
`Text("…")`, not `Text(variable)`. (Build may still re-sync the catalog cosmetically as in prior
rounds; if so it is English-safe and gets committed.)

## Testing

New file `zodlTests/SmartBannerTests/SmartBannerMigrationCompleteTests.swift` (Swift Testing,
`@Suite(.serialized)` — exercises the `priorityContent` global-ish reducer state):

- **`completeStateOpensMigrationBanner`** — with `mainQueue = .immediate` and `migrationSDK`
  stubbed (`simulatedOrchardBalance = { .zero }`, `migrationSummary = { dust: 31_000 … }`):
  send `.migrationStateUpdated(.complete)`; assert `migrationState == .complete`,
  `migrationDust == Zatoshi(31_000)`; `receive(.triggerPriority(.priorityMigration))` →
  `receive(.openBannerRequest)` (sets `priorityContent == .priorityMigration`) →
  `receive(.openBanner)` (`isOpen == true`). Proves the banner is **shown**, not cleaned up.
- **`noBalanceNotCompleteClosesMigrationBanner`** — pre-set `priorityContent = .priorityMigration`,
  stub `simulatedOrchardBalance = { .zero }`; send `.migrationStateUpdated(.notStarted)`; assert it
  drives `.closeAndCleanupBanner` (regression guard that the gate still hides the banner when there
  is nothing to migrate).

Only `migrationSDK` (two closures) and `mainQueue` are touched on this action path — `.onAppear`
(which subscribes to network/sync/shielding streams) is **not** sent, so no other dependencies need
stubbing. Existing engine/worker suites in `DummyMigrationEngineTests.swift` remain the safety net
for the `.complete` state transition itself.

## Files

- Modify: `secant/Sources/Features/SmartBanner/SmartBannerStore.swift`
  (add `migrationDust`; rewrite `.migrationStateUpdated`)
- Modify: `secant/Sources/Features/SmartBanner/SmartBannerContent.swift`
  (add `.complete` cases to the three banner-copy computed properties)
- Create: `zodlTests/SmartBannerTests/SmartBannerMigrationCompleteTests.swift`

## Out of scope / non-goals

- No auto full-screen presentation of C6 (decision 1).
- No "acknowledged / dismiss" flag for the complete banner (decision 2).
- No change to the C6 screen, the coordinator, the engine, or the background worker.
- Keystone "Migrate with Privacy" hardware-signing path remains unimplemented (unchanged; out of
  scope for this round).

## Verification

- Build the `zodl-testnet` scheme (Xcode MCP if available; else `xcodebuild … -skipMacroValidation
  -skipPackagePluginValidation`).
- Run the migration + SmartBanner suites (scheme `zodl-internal`, target `zodlTests`).
- Smoke (debug panel): Seed → drive to completion via "Run background task now" (or
  `Jump → Complete` / `Complete with dust`) → return to Home → banner reads "Migration complete"
  (dust subtitle in the dust case) → tap "More" → C6 renders → "Done" dismisses, banner persists.
