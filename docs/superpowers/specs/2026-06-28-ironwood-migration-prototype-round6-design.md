# Ironwood Migration Prototype — Round 6: Done on C6 dismisses the complete banner

**Date:** 2026-06-28
**Status:** Approved
**Type:** Prototype / simulated migration (dummy SDK behind `MigrationSDKClient`)

## Problem

Round 5 made the Home SmartBanner show "Migration complete" and **persist until debug Reset**.
The user now wants: **tapping "Done" on the C6 "Migration Complete" screen should make the banner
stop showing the completion state.** This refines the round-5 lifetime decision for the Done action.

## Why a flag (not just state)

The banner is driven by `migrationSDK.stateStream()`, and the migration state stays `.complete`
after Done — so "stop showing" needs an explicit *acknowledged* signal. The engine's `mutate {}`
already **persists the snapshot and re-emits the current state** on its `CurrentValueSubject`, which
is exactly the re-evaluation trigger the SmartBanner needs (no dedupe on the subject).

## Design

1. **`MigrationSnapshot`** — add persisted `completionAcknowledged: Bool` (default `false`; `false`
   in `seededDefault`; the memberwise-init param is defaulted to `false`). Debug **Reset** reseeds →
   re-arms the banner for the next demo. (Only one full construction site: `seededDefault`.)
2. **`DummyMigrationEngine`** — `isCompletionAcknowledged()` (read) and `acknowledgeCompletion()`
   (`mutate { $0.completionAcknowledged = true }` → persists + re-emits `.complete`).
3. **SDK boundary** (`MigrationSDKInterface` + `MigrationSDKLiveKey`) —
   `isMigrationCompleteAcknowledged: () -> Bool` and `acknowledgeMigrationComplete: () -> Void`.
4. **`SmartBannerStore.migrationStateUpdated`** — when `.complete`, show **only if not
   acknowledged**; otherwise (non-complete) show only while Orchard funds remain. If it shouldn't
   show and the migration banner is open → `closeAndCleanupBanner`.
5. **`MigrationCoordFlowCoordinator`** — at `.status(.delegate(.done))` **and**
   `.immediateReview(.delegate(.finished))`, if `getMigrationState() == .complete`, call
   `acknowledgeMigrationComplete()` before dismissing. Gating on `.complete` leaves the in-progress
   and scheduled-success Done buttons unaffected. (The immediate path also ends in `.complete`.)

## Behavior

complete → banner "Migration complete" → "More" → C6 → **Done → banner gone**, and it stays gone
across app relaunch (the flag is persisted). Debug **Reset** brings the banner back for re-demo.

## Testing

- **Engine** (`DummyMigrationEngineTests.acknowledgeCompletionMarksAndPersistsFlag`): drive a single
  immediate transfer to `.complete`; `isCompletionAcknowledged()` is `false`, then
  `acknowledgeCompletion()` makes it `true` while the state stays `.complete`.
- **SmartBanner** (`SmartBannerMigrationCompleteTests.acknowledgedCompleteClosesBanner`): with
  `isMigrationCompleteAcknowledged = { true }` and the banner open, `.migrationStateUpdated(.complete)`
  drives `closeAndCleanupBanner`. The existing round-5 tests still cover the unacknowledged
  (banner-shows) case.

## Files

- Modify: `secant/Sources/Dependencies/MigrationSDK/MigrationStateStore.swift`
- Modify: `secant/Sources/Dependencies/MigrationSDK/DummyMigrationEngine.swift`
- Modify: `secant/Sources/Dependencies/MigrationSDK/MigrationSDKInterface.swift`
- Modify: `secant/Sources/Dependencies/MigrationSDK/MigrationSDKLiveKey.swift`
- Modify: `secant/Sources/Features/SmartBanner/SmartBannerStore.swift`
- Modify: `secant/Sources/Features/CoordFlows/MigrationCoordFlowCoordinator.swift`
- Test: `zodlTests/MigrationTests/DummyMigrationEngineTests.swift`
- Test: `zodlTests/SmartBannerTests/SmartBannerMigrationCompleteTests.swift`

## Non-goals / notes

- The banner copy is unchanged (still "Migration complete" / dust-aware subtitle / "More").
- Adding a non-optional field to the persisted JSON reseeds any *in-flight* migration persisted by an
  older build once on first launch (the loader already falls back to the seeded default on a decode
  mismatch). Harmless for the prototype; Reset does the same.
