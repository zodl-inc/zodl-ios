# Adopt the updated SDK Ironwood migration API

**Date:** 2026-06-30
**Ticket:** MOB-1455
**Driver:** SDK branch `michal/MOB-1455-2-ironwood-migration-sdk-impl` pivoted the migration crate to
canonical `zcash_protocol` types (PCZT pivot). The app links that SDK locally
(`../zcash-swift-wallet-sdk`), so the in-flight migration surface in ZODL must be corrected to compile
and to adopt the one new recovery method. Source: `ZODL-APP-MIGRATION-INTEGRATION-HANDOFF.md`.

## Goal

1. **Compile against the updated SDK** by following two field renames at the single SDK↔app boundary.
2. **Adopt `refreshStaleTransfers`** as the live engine's "reschedule stalled transfer" recovery,
   replacing the heavier `restartCurrentMigrationStep` fallback.

This is a pre-release API (never shipped in a tagged SDK version), so these are corrections to an
in-flight surface, not breaking changes against a release.

## Background — the layered architecture (unchanged)

```
UI (Stores/Views)
  → MigrationSDKClient            (MigrationSDKInterface.swift)  — app Zatoshi types, non-throwing
  → LiveMigrationEngine           (LiveMigrationEngine.swift)    — cache + refresh loop, Gateway struct
  → Gateway.live()                (MigrationSDKLiveKey.swift)    — wires to @Dependency(\.sdkSynchronizer)
  → SDKSynchronizerClient         (SDKSynchronizer*.swift)       — thin SDK-typed wrappers, tx guard
  → SDK Synchronizer.migration*   (ZcashLightClientKit)
```

`MigrationTypeMapping.swift` is the **single place** SDK types (`ZcashLightClientKit.*`, `UInt64`/
`UInt32`) meet the app's `Zatoshi`/`BlockHeight` mirrors. The app's own model field names
(`MigrationModels.swift`) already are `amount` / `remainingOrchard`, so nothing downstream of the
boundary changes — both renames are absorbed entirely inside the mapping file (and its tests).

`PreparedTx.rawTx → rawPczt` and the internal extract-then-submit broadcast change need **no app
change**: the app references neither `PreparedTx` nor `rawTx`/`rawPczt` (verified by grep). Broadcasting
stays encapsulated inside the already-guarded `migrationSubmitNoteSplit` /
`migrationExecuteNextPendingTransfer` wrappers.

## Part A — Field renames (required to compile)

The wire format is unchanged (plain `u64`); only Swift property/parameter names changed.

| Old SDK name | New SDK name | Type |
|---|---|---|
| `MigrationProgress.remainingOrchardZatoshi` | `MigrationProgress.remainingOrchard` | `UInt64` |
| `TransferProposal.amountZatoshi` | `TransferProposal.amount` | `UInt64` |

### App source — `secant/Sources/Dependencies/MigrationSDK/MigrationTypeMapping.swift` (3 edits)

- L57 (App→SDK init label): `amountZatoshi: migrationZatoshiToUInt64(amount)` → `amount: migrationZatoshiToUInt64(amount)`
- L98 (SDK→App property read): `migrationUInt64ToZatoshi(amountZatoshi)` → `migrationUInt64ToZatoshi(amount)`
- L120 (SDK→App property read): `migrationUInt64ToZatoshi(remainingOrchardZatoshi)` → `migrationUInt64ToZatoshi(remainingOrchard)`

### Tests (compile fix for the test target)

`zodlTests/MigrationTests/MigrationTypeMappingTests.swift` (7 edits): SDK init labels and property
reads at L48, L63, L92, L108, L122, L136, L167 (`amountZatoshi` → `amount`,
`remainingOrchardZatoshi` → `remainingOrchard`).

`zodlTests/MigrationTests/LiveMigrationEngineTests.swift` (2 edits): the `sdkProgress` helper
(L80, `remainingOrchardZatoshi` → `remainingOrchard`) and the `sdkTransfer` helper (L86,
`amountZatoshi` → `amount`).

> App-type constructions in `MigrationStateStoreTests.swift` and `MigrationBackgroundTimingTests.swift`
> already use `amount` / `remainingOrchard` (they build the app model, not the SDK type) — no change.

## Part B — Adopt `refreshStaleTransfers`

New SDK method:

```swift
func refreshStaleTransfers(spendingKey: UnifiedSpendingKey, for account: AccountUUID) async throws -> UInt32
```

Re-anchors / re-proves / re-signs the active run's scheduled transfers when their anchor is too old to
broadcast; returns how many were refreshed. It **does not broadcast** — it signs and persists fresh
PCZTs, exactly like `signAndStoreMigrationSchedule`.

**Integration point.** The app already exposes a wired-up "reschedule stalled" recovery:
`MigrationStatus` → `.reschedule` delegate → `MigrationCoordFlowCoordinator` →
`migrationSDK.rescheduleStalledTransfer()` → `LiveMigrationEngine.rescheduleStalled()`. Today that
falls back to `restart()` (`restartCurrentMigrationStep`, re-proposes a whole new schedule), with a
code comment stating *"the SDK has no separate reschedule/recreate primitive"* — now outdated.
`refreshStaleTransfers` is precisely that lighter primitive for the stalled/overdue case.

The public `MigrationSDKClient.rescheduleStalledTransfer` surface stays `() async -> Void`; the engine
logs the refreshed count for observability but does not surface it (no UI consumer needs it). The
`recreateInvalidTransfer` (invalid-note) path keeps using `restart()` — there is no lighter primitive
for that case.

### B1 — `SDKSynchronizerInterface.swift`

Add one closure var alongside the migration wrappers (place after `migrationRestartCurrentStep`):

```swift
var migrationRefreshStaleTransfers: @Sendable (
    _ spendingKey: UnifiedSpendingKey,
    _ account: AccountUUID
) async throws -> UInt32
```

### B2 — `SDKSynchronizerLive.swift`

Wire it **unguarded** (parity with `migrationSignAndStoreSchedule`: signs + persists, never
broadcasts → no transaction guard). Place after `migrationRestartCurrentStep`:

```swift
// Re-anchors/re-proves/re-signs stale transfers; signs + persists but does NOT broadcast, so —
// like signAndStoreMigrationSchedule — it is not wrapped in the transaction guard.
migrationRefreshStaleTransfers: { spendingKey, account in
    try await synchronizer.refreshStaleTransfers(spendingKey: spendingKey, for: account)
},
```

### B3 — `SDKSynchronizerTest.swift` (4 sites)

- `testValue`: `migrationRefreshStaleTransfers: unimplemented("\(Self.self).migrationRefreshStaleTransfers", placeholder: UInt32(0))`
- `noOp`: `migrationRefreshStaleTransfers: { _, _ in 0 }`
- `testSynchronizer` factory param (with default): `migrationRefreshStaleTransfers: @escaping @Sendable (UnifiedSpendingKey, AccountUUID) async throws -> UInt32 = { _, _ in 0 }`
- `testSynchronizer` assignment: `migrationRefreshStaleTransfers: migrationRefreshStaleTransfers`

### B4 — `LiveMigrationEngine.swift`

Add to `Gateway` (key derived internally by the live gateway, like `submitNoteSplit`/`signAndStore`,
so the engine-facing closure takes only `account`):

```swift
var refreshStale: @Sendable (AccountUUID) async throws -> UInt32
```

Rewrite `rescheduleStalled()` to use it, and split the now-outdated shared comment so it reflects that
only the invalid path still maps to `restart()`:

```swift
/// Stalled/overdue recovery: re-anchor/re-prove/re-sign the scheduled transfers via the SDK's
/// `refreshStaleTransfers`. Lighter than `restart()` (which re-proposes a whole new schedule).
func rescheduleStalled() async {
    guard let account = await gateway.currentAccountID() else {
        logSkipped("refreshStaleTransfers")
        return
    }
    do {
        let refreshed = try await gateway.refreshStale(account)
        logger.info("Migration refreshStaleTransfers refreshed \(refreshed, privacy: .public) transfer(s).")
        await refresh()
    } catch {
        logFailure("refreshStaleTransfers", error)
    }
}

/// Invalid-note recovery: the SDK has no lighter primitive, so re-propose the current step.
func recreateInvalid() async { _ = await restart() }
```

### B5 — `MigrationSDKLiveKey.swift` — `Gateway.live()`

Add the `refreshStale` closure, deriving the USK internally exactly as `submitNoteSplit`/`signAndStore`
do (place after `restartCurrentStep`):

```swift
refreshStale: { account in
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    let spendingKey = try MigrationSDKClient.currentAccountSpendingKey()
    return try await sdkSynchronizer.migrationRefreshStaleTransfers(spendingKey, account)
},
```

> The `dummy()` factory and `DummyMigrationEngine.rescheduleStalled()` are **unchanged** — the
> simulation path is a separate engine type and does not go through the SDK gateway.

### B6 — `LiveMigrationEngineTests.swift`

- Add a defaulted `refreshStale` parameter to the single `makeGateway(...)` factory and pass it into
  the `Gateway(...)` construction. The new default (`{ _ in 0 }`) means none of the 22 existing
  `makeGateway` call sites need changes.
- Add a test: `rescheduleStalledRefreshesStaleTransfers()` — inject a `refreshStale` that records it
  was called (and a `restartCurrentStep` that fails if called), call `engine.rescheduleStalled()`,
  assert the refresh closure ran and restart did not.

## Out of scope / no change required

- `ClosureSynchronizer` / `CombineSynchronizer` adapters — the SDK does not expose migration there.
- `NetworkPrivacyOptions` is accepted-but-ignored by the SDK in v1; the app keeps passing it unchanged.
- No UI/string/model changes — the public `MigrationSDKClient` surface is unchanged.

## Verification

1. **Build** `secant-testnet` via the Xcode MCP (`BuildProject`) — must compile clean against the
   updated SDK.
2. **Tests** — run `zodlTests` (scheme `zodl-internal`) via the Xcode MCP, focused on `MigrationTests`:
   `MigrationTypeMappingTests` (renames) and `LiveMigrationEngineTests` (renames + new
   reschedule-refreshes-stale test). All Swift Testing.
3. Carry caveats to the final report: on-device proving makes `refreshStaleTransfers` costly (budget in
   spinners / BGTask limits); end-to-end broadcast is not yet verified on a seeded wallet (SDK side is
   compile/offline-test verified only).

## Risks

- **Guarding decision for `refreshStaleTransfers`:** left unguarded by parity with
  `signAndStoreMigrationSchedule` (signs/persists, no broadcast). If the reviewer believes re-anchoring
  against the chain tip is sensitive to a concurrent `switchTo(endpoint:)`, it can be moved under
  `transactionGuard.withSubmission { }` in B2 — but that contradicts the established app rule that only
  the two broadcasting calls are guarded. Flagged for review, not blocking.
