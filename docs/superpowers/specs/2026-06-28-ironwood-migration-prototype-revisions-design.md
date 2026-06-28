# Ironwood Migration Prototype — Revisions Spec

**Date:** 2026-06-28
**Status:** Approved
**Builds on:** `2026-06-28-ironwood-migration-prototype-design.md`

## Goal

Fix 7 issues in the simulated Orchard→Ironwood migration prototype so the team can walk the flow end-to-end with designs matched:

1. Reuse the existing `SmartBanner` system for the "Migration Required" home banner instead of a custom banner.
2. Add a real "Migration Complete" terminal screen and stop offering migration once it is done.
3. Fix the (broken) debug-panel entry point.
4. Make the private/scheduled path produce **5–8** transfers with the balance **randomly divided** between them.
5. Redesign the immediate-path "Review Transfer" screen to match Figma.
6. Surface the note-split as a visible transaction simulation with a **15 second** confirmation wait.
7. Fix back-navigation: opening the flow from the home banner and tapping back must return to Home, not the entry screen.

## Principles (unchanged from the original prototype)

- All behavior stays behind the `MigrationSDKClient` dependency boundary so the real Rust/Swift SDK can drop in.
- The dummy engine (`DummyMigrationEngine`) is the single source of simulated state, persisted via `MigrationStateStore`.
- UI copy stays inline English to match the existing migration screens (no new `xcstrings`). The app name is always **ZODL**.

## Root cause discovered

The coordinator never calls `migrationSDK.selectMigrationMode(mode)` when the user chooses the private path
(`MigrationCoordFlowCoordinator.swift`, `.entry(.delegate(.chose(mode)))`). The engine's mode therefore stays
unset, `isNoteSplitNeeded()` returns `false`, the flow skips the note-split screen, `snapshot.notes` stays empty,
and `buildSchedule` falls back to a single transfer. This single missing call explains **both** "split screens
missing" and "only 1 transfer".

## Design

### A. Engine (`DummyMigrationEngine.swift`)

- `selectMigrationMode` is now invoked by the coordinator before branching; the engine records `snapshot.mode`.
- **Note generation → random 5–8, randomly divided.** `prepareSplit` uses
  `count = snapshot.noteCountOverride ?? Int.random(in: 5...8)`. The net amount (`orchard − fee`) is divided into
  `count` positive amounts that sum **exactly** to net, using randomized weights. The debug `noteCount` override
  still wins (so tests/debug are deterministic). These notes become the scheduled transfers 1:1.
- `splitConfirmDelay`: `3s → 15s`.
- `buildSchedule`: transfer `i` (0-based) executable at `height + bucketBlocks*i` (transfer 1 = "Ready now",
  later transfers spaced one bucket apart); `estimatedDurationHours = 6 * (count - 1)` (≈ 24h for 5 transfers).
  Defensive: private mode with empty `notes` still produces 5–8 randomly-divided transfers.
- Completion path already sets `orchard = .zero` and `state = .complete` (persisted) — verified correct.

### B. Mock fiat

Designs show `$` values. Add a documented prototype constant (~`$100.2 / ZEC`, derived from the design's
`12.458 ZEC ≈ $1,248.32`) and a `mockFiatString(for: Zatoshi)` helper. Clearly a placeholder — not a real rate.
Location: a small `Utils`/Migration helper reachable by the migration views.

### 1. Reuse SmartBanner for "Migration Required"

- **Remove** the custom `migrationBanner()` from `HomeView`, and `migrationBannerVisible` / `migrationBannerVariant`
  / `migrationBannerColor` plus the `migrationStateChanged` subscription from `HomeStore`.
- **Add** to `SmartBanner`: a highest-priority `priorityMigration` case, evaluation driven by the migration state,
  and a subscription to `migrationSDK.stateStream()` (moved out of Home). Content (`SmartBannerContent.swift`):
  icon + "Migration Required" / "Move your funds to Ironwood", with variants for in-progress and needs-attention.
  The banner auto-clears when the state becomes `.complete`.
- **Tap** → SmartBanner emits a delegate → `Home` maps it to the existing `.migrationBannerTapped` →
  `RootCoordinator` opens the flow (reusing existing wiring).
- Priority: migration ranks above wallet-backup/shielding so it reliably shows in the demo (prototype choice).

### 2. Migration Complete screen + never offered again

- New shared **`MigrationCompleteView`** matching Figma **C6**: dark hero with green check-rings,
  "Migration Complete" / "Your ZEC is now in the Ironwood pool.", optional amber **dust card**, a SUMMARY block
  (Transferred / Remaining dust if any / Transfers "N of N sent" / Duration), and a **Done** button → Home.
- Terminal for **both** paths: immediate (Review → Sending → Complete) and scheduled (status screen renders
  Complete when `state == .complete`).
- Banner hides on `.complete` (§1) and state is persisted, so migration is not offered again. `.start` routes to
  the Complete screen if the flow is somehow reopened while complete.

### 3. Fix debug entry (long-press Home balance)

- Move `.onLongPressGesture { showMigrationDebug = true }` + the `.sheet(MigrationDebugView)` off the (removed)
  banner and onto the **Home balance/header** view (a non-`Button` target, so the gesture fires reliably).
  DEBUG-only; always reachable, including after completion.

### 4. Private path: 5–8 randomly-divided transfers

- Root cause fixed in §G (call `selectMigrationMode`); the split populates `notes`, so `MigrationTransferPlan`
  shows all 5–8.
- **Redesign `MigrationTransferPlanView`** to match Figma **B4**: numbered rows joined by a connecting line,
  per-transfer amount + fiat, relative time ("Ready now", "~6 hours", …), a Destination "Ironwood" row, a Summary
  "N transfers · ~Xh" row, and a **Confirm** button.

### 5. Redesign "Review Transfer" (immediate) — Figma A2

- Rebuild `MigrationImmediateReviewView` review state: title "Review Transfer", subtitle
  ("Your full Orchard balance will be transferred to Ironwood in a single on-chain transfer."), a "Your Transfer"
  header + "Once confirmed, this transfer cannot be cancelled.", one numbered row
  ("Transfer 1 of 1 / Send immediately / amount + fiat"), an amber **Privacy Disclaimer** card with info icon, and
  a **Confirm** button. Sending → spinner; done → `MigrationCompleteView`.

### 6. Note-split transaction simulation — Figma B3a/B3b

- Keep the `confirm → splitting → confirmed` state machine; **redesign** `MigrationNoteSplitView`: app icon +
  spinner (B3a) / green seal check (B3b), titles "Splitting Funds…" / "Split Confirmed!", subtitle
  ("Splitting your balance into transfer-sized notes. This is a send-to-self — your ZEC stays in Orchard."), a card
  (Transaction ID / Amount / Fee), a "Transaction in Progress" info card, and a disabled button while splitting →
  **Continue** when confirmed. Wait is now **15 s**.

### 7. Back navigation from banner

- When opened from the banner mid-migration, `.start` pushes status(`.progress`) / recovery onto the entry root, so
  the system back button pops to the entry screen ("Move to Ironwood"). **Fix:** deep-entry screens
  (status in `.progress`, recovery) get `.navigationBarBackButtonHidden(true)` + a custom leading chevron that sends
  `.dismiss` (closes the coordinator → Home). Forward-navigation screens keep the default back.
- Bonus: redesign the in-progress status screen to match Figma **B8** (per-transfer status list + progress bar),
  since that is what you land on from the banner.

### G. Coordinator change (the key bug)

- `.entry(.delegate(.chose(mode)))` now `await migrationSDK.selectMigrationMode(mode)` **before** branching, so
  `isNoteSplitNeeded()` is correct and the private path runs the split.

## Files

**Edit:**
- `Dependencies/MigrationSDK/DummyMigrationEngine.swift`
- `Dependencies/MigrationSDK/MigrationSDKInterface.swift` / `MigrationSDKLiveKey.swift` (only if a fiat/helper hook is needed)
- `Features/SmartBanner/SmartBannerStore.swift`, `Features/SmartBanner/SmartBannerContent.swift`
- `Features/Home/HomeStore.swift`, `Features/Home/HomeView.swift`
- `Features/CoordFlows/MigrationCoordFlowCoordinator.swift`, `Features/CoordFlows/MigrationCoordFlowView.swift`
- `Features/Migration/MigrationNoteSplit/MigrationNoteSplitView.swift`
- `Features/Migration/MigrationTransferPlan/MigrationTransferPlanView.swift`
- `Features/Migration/MigrationImmediateReview/MigrationImmediateReviewStore.swift` + `…View.swift`
- `Features/Migration/MigrationStatus/MigrationStatusStore.swift` + `…View.swift`
- `Features/Migration/MigrationRecovery/MigrationRecoveryView.swift`

**Create:**
- `Features/Migration/MigrationComplete/MigrationCompleteView.swift` (shared presentation component)
- A small migration fiat helper (location TBD during implementation)

**Tests:**
- Update `zodlTests/MigrationTests/DummyMigrationEngineTests.swift`: random count ∈ 5…8, division sums to net,
  split→confirm transition (drive `confirmSplitNow` to avoid the 15 s wait).

## Non-blocking notes (final report)

- Mock fiat uses a hardcoded prototype rate.
- The migration banner ranks above sync-status banners for demo visibility.
- Copy stays inline English (no new xcstrings), matching existing migration screens.
