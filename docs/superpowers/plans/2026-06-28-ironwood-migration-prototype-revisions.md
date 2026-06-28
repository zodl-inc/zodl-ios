# Ironwood Migration Prototype — Revisions Plan

**Spec:** `docs/superpowers/specs/2026-06-28-ironwood-migration-prototype-revisions-design.md` (approved)
**Execution:** Autonomous (user pre-approved). Xcode MCP offline → `xcodebuild -skipMacroValidation` fallback.

## Order (keep the build green between phases)

1. **Engine + fiat helper** (Task 13) — random 5–8 split summing to net, 15 s delay, schedule timing, `mockFiatString`.
   TDD the engine logic in `DummyMigrationEngineTests`.
2. **MigrationCompleteView** (Task 15) — shared C6 presentation; pure view, data in.
3. **Coordinator** (Task 14) — `selectMigrationMode` await; `.start` → complete when complete; deep-entry back→dismiss plumbing (state flag / presentation).
4. **SmartBanner** (Task 16) — `priorityMigration`, stream subscription, content, tap delegate.
5. **Home** (Task 17) — remove custom banner + state; long-press on balance (DEBUG) → MigrationDebug sheet; wire SmartBanner delegate → `.migrationBannerTapped`.
6. **Screen redesigns** (Task 18) — NoteSplitView (B3a/B3b), TransferPlanView (B4), ImmediateReview store+view (A2 → complete).
7. **Status + Recovery** (Task 19) — Status in-progress (B8) + complete (C6) + deep-entry back; Recovery deep-entry back.
8. **Tests + build + smoke** (Task 20).

## Key signatures / contracts

- `MigrationCompleteView(transferred: Zatoshi, dust: Zatoshi, transfersSent: Int, transfersTotal: Int, durationHours: Int, tokenName: String, onDone: () -> Void)`.
- Fiat: `func mockFiatString(for amount: Zatoshi) -> String` (prototype constant rate ≈ $100.2/ZEC).
- Deep-entry back: screen sends `.delegate(.close)` / store exposes a `dismiss`-style delegate the coordinator maps to `.dismiss`. Status `.progress` and both recovery kinds show a leading chevron.
- Coordinator `.entry(.chose(mode))`: `.run { await migrationSDK.selectMigrationMode(mode); send(.modeSelected(mode)) }` then branch in `.modeSelected`.

## Notes
- Engine `splitAmount(_:into:)` becomes randomized but must sum exactly to net and keep every part > 0.
- Tests drive `debug.confirmSplitNow` (no 15 s wait); use `MigrationSDKClient.ephemeral()` for isolation.
