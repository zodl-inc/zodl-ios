# Design — Wire the real SDK migration API into ZODL + disable voting

**Date:** 2026-06-30
**Branch:** `michal/MOB-1455-connect-prototype-to-sdk`
**Source handoff:** `../ZODL-APP-MIGRATION-INTEGRATION-HANDOFF.md`

## Goals

1. **Goal 1 — Live migration.** Replace the simulated `DummyMigrationEngine` with a live engine backed
   by the SDK's public async `Synchronizer` migration API (13 methods), exposed through the app's
   `sdkSynchronizer` dependency.
2. **Goal 2 — Disable voting.** The local SDK **excludes `Rust/Voting` from compilation**, so the app's
   voting layer cannot compile. Compile it out behind an `#if VOTING_ENABLED` flag (off), keeping all
   files on disk. Reversible by defining the flag once the SDK voting stack is restored.

## Decisions (locked with the user)

- Voting is disabled at **compile time** via `#if VOTING_ENABLED` (NOT a runtime feature flag). Files stay
  in the project navigator. No `FeatureFlags` change.
- Goal 1 acceptance bar: **green `zodl-internal` build + Swift Testing unit tests** (type mapping,
  error→fallback, cache refresh, with SDK calls faked). True end-to-end migration is **deferred** (no
  synced-wallet/Orchard-funds fixture exists here).
- **No dummy fallback toggle.** `liveValue` uses the live engine only; `DummyMigrationEngine` is kept
  solely for `previewValue`/tests.
- Workflow: this spec is the **only approval gate**. After approval, implement autonomously with TDD.

---

## Background — why this shape

The migration **UI is fully built** and drives a TCA dependency `MigrationSDKClient`
(`@Dependency(\.migrationSDK)`), defined in `Dependencies/MigrationSDK/`. Its interface is a Swift mirror
of a Kotlin draft and is deliberately **sync / non-throwing / key-hiding / app-typed**:

- Mostly **synchronous getters** (`getMigrationState`, `getMigrationProgress`, `isNoteSplitNeeded`, …).
- Async methods are **non-throwing**.
- Signing methods **don't take a key**.
- Types are **app-local, `Zatoshi`-based** (in `Models/Migration/MigrationModels.swift`).

The SDK's public API is the opposite: **`async throws`**, takes **`for account: AccountUUID`**, signing
methods take **`spendingKey: UnifiedSpendingKey`**, and types are **`UInt64`-based** (in the SDK's
`Model/Migration.swift`). A live engine must bridge these five mismatches behind the existing closure
wiring — exactly the seam `MigrationSDKLiveKey.live()` was built for.

### Name-collision hazard (critical)

The app and the SDK both define `MigrationState`, `MigrationProgress`, `NoteSplitProposal`,
`MigrationSchedule`, `TransferProposal`, `TransferResult`, `NetworkPrivacyOptions`, `AttentionReason`.
Because the app types live in the **same module**, an unqualified name resolves to the **app** type even
when `ZcashLightClientKit` is imported. **Every reference to an SDK migration type must be fully qualified
as `ZcashLightClientKit.<Type>`** in the SDK client and the converters. The converters are the single
place the two type families meet.

---

## GOAL 1 — Live migration

### Step A — expose the 13 SDK migration methods on `sdkSynchronizer`

**`SDKSynchronizerInterface.swift`** — add 13 `@Sendable async throws` closures returning **SDK-qualified**
types. Proposed names (consistent `migration*` prefix, discoverable in the large client):

| Closure | SDK call | Broadcasts? |
|---|---|---|
| `migrationState(AccountUUID) -> ZcashLightClientKit.MigrationState` | `migrationState(for:)` | no |
| `migrationProgress(AccountUUID) -> ZcashLightClientKit.MigrationProgress?` | `migrationProgress(for:)` | no |
| `migrationIsNoteSplitNeeded(AccountUUID) -> Bool` | `isNoteSplitNeeded(for:)` | no |
| `migrationPrepareNoteSplit(AccountUUID) -> ZcashLightClientKit.NoteSplitProposal` | `prepareNoteSplit(for:)` | no |
| `migrationSubmitNoteSplit(proposal, USK, options, AccountUUID) -> ZcashLightClientKit.TransferResult` | `submitNoteSplit(…)` | **YES** |
| `migrationProposeTransfers(AccountUUID) -> ZcashLightClientKit.MigrationSchedule` | `proposeMigrationTransfers(for:)` | no |
| `migrationSignAndStoreSchedule(schedule, USK, AccountUUID) -> Void` | `signAndStoreMigrationSchedule(…)` | no (pre-signs only) |
| `migrationIsSyncRequiredBeforeNextTransfer(AccountUUID) -> Bool` | `isSyncRequiredBeforeNextTransfer(for:)` | no |
| `migrationExecuteNextPendingTransfer(options, AccountUUID) -> ZcashLightClientKit.TransferResult?` | `executeNextPendingTransfer(…)` | **YES** |
| `migrationHasOverdueTransfers(AccountUUID) -> Bool` | `hasOverdueTransfers(for:)` | no |
| `migrationHasInvalidTransfers(AccountUUID) -> Bool` | `hasInvalidTransfers(for:)` | no |
| `migrationRestartCurrentStep(AccountUUID) -> ZcashLightClientKit.MigrationSchedule` | `restartCurrentMigrationStep(for:)` | no |
| `migrationInitializePostUpgrade(AccountUUID) -> Void` | `initializePostUpgrade(for:)` | no |

**`SDKSynchronizerLive.swift`** — implement each by calling `synchronizer.<method>`. **The two
broadcasters** (`migrationSubmitNoteSplit`, `migrationExecuteNextPendingTransfer`) **must wrap their body
in `transactionGuard.withSubmission { … }`** — identical to the existing `createProposedTransactions` /
`createTransactionFromPCZT` closures (`@Dependency(\.transactionGuard)` resolved **inside** the closure).
The other 11 are unguarded. Per CLAUDE.md the guard is a **non-reentrant FIFO mutex** — it lives **only**
here, never at call sites, never nested.

**TestKey** — `@DependencyClient` synthesizes `testValue`; add overrides only if a test needs them.

### Step B — `LiveMigrationEngine` (new, parallel to `DummyMigrationEngine`)

New file `Dependencies/MigrationSDK/LiveMigrationEngine.swift`. Mirrors the dummy's holder + Combine-subject
shape (`@unchecked Sendable`, `OSAllocatedUnfairLock` cache, `CurrentValueSubject<MigrationState, Never>`),
but backs onto the SDK. It resolves the five mismatches:

**1. Sync getters ⇒ cache.** A lock-guarded `LiveMigrationCache` holds the last-known app-typed snapshot:
`state`, `progress?`, `noteSplitNeeded`, `syncRequired`, `overdue`, `invalid`, `orchard` (Orchard balance),
and the last `schedule?` (for summary/rows). An async `refresh()` calls the SDK, maps to app types, updates
the cache, and emits on the subject. `refresh()` runs: once at init, **after every mutating call**, and on
a **periodic timer** (cancellable `Task` loop, ~10–15 s). Sync getters and `stateStream` read the cache.

**2. Non-throwing.** Every SDK call is wrapped; on error the engine **logs via the app's logging facility
(`os.Logger`/`LoggerProxy`, never `print`)** and returns a sensible fallback: last-known state for getters,
`.networkError(retryable: true)` for `submitSplit`/`executeNext`, unchanged/empty schedule for
`propose`/`restart`.

**3. Type mapping.** New file `Dependencies/MigrationSDK/MigrationTypeMapping.swift` with explicit,
total converters (the only place SDK-qualified types appear besides the SDK client):

| App (`Zatoshi`/`Int`/`BlockHeight`) | SDK (`UInt64`/`UInt32`) | Notes |
|---|---|---|
| `MigrationState` | `ZcashLightClientKit.MigrationState` | SDK→app for the cache |
| `MigrationProgress{completedTransfers:Int, totalTransfers:Int, remainingOrchard:Zatoshi, nextTransferReadyAtHeight:BlockHeight?}` | `{UInt32, UInt32, remainingOrchardZatoshi:UInt64, UInt32?}` | field rename `remainingOrchard`↔`remainingOrchardZatoshi` |
| `NoteSplitProposal{outputNotes:[Zatoshi], fee:Zatoshi}` | `{[UInt64], UInt64}` | app→SDK for submit |
| `MigrationSchedule{transfers:[TransferProposal], estimatedDurationHours:Int}` | `{[TransferProposal], UInt32}` | both directions |
| `TransferProposal{id, amount:Zatoshi, anchorHeight, nextExecutableAfterHeight, expiryHeight: BlockHeight}` | `{id, amountZatoshi:UInt64, UInt32×3}` | field rename `amount`↔`amountZatoshi` |
| `NetworkPrivacyOptions{useTor, submissionEndpoint}` | identical | app→SDK |
| `TransferResult.success(txId:)` | `.success(txid:)` | label differs; `.networkError(retryable:)`, `.invalidNote`, `.expired` map 1:1 |
| `AttentionReason{.invalidTransfer(transferId:), .transferExpired, .syncRequiredBeforeNext, .transferStalled(transferNumber:)}` | `{.invalidTransfer(transferId:), .transferExpired, .syncRequiredBeforeNext}` | **`.transferStalled` has no SDK source** |

Scalar conversions: `Zatoshi(Int64(u64))` / `UInt64(z.amount)` (amount is non-negative);
`BlockHeight(u32)` / `UInt32(blockHeight)`.

**`.transferStalled` mapping:** the SDK never emits it. Live "overdue" is surfaced via the SDK bool
`hasOverdueTransfers` (served by `migrationHasOverdueTransfers`), not by synthesizing
`.requiresAttention(.transferStalled)`. SDK→app state mapping therefore never produces `.transferStalled`;
the converter is total without it. Any UI path that keys **exclusively** on `.transferStalled` (vs. the
`hasOverdueTransfers` getter) will not trigger on the live path — noted as a FINAL REPORT item to verify.

**4. Account + USK sourcing.** Reuse the **Send** flow's exact path (`SendConfirmationStore`):

```
storedWallet = try walletStorage.exportWallet()
seedBytes    = try mnemonic.toSeed(storedWallet.seedPhrase.value())
network      = zcashSDKEnvironment.network().networkType
zip32Index   = selectedWalletAccount.zip32AccountIndex      // @Shared(.inMemory(.selectedWalletAccount))
USK          = try derivationTool.deriveSpendingKey(seedBytes, zip32Index, network)
account      = selectedWalletAccount.id                     // AccountUUID
```

Encapsulated in a small injectable **`LiveMigrationGateway`** (struct of `@Sendable` closures: account id,
spending-key provider, Orchard balance, plus one closure per SDK migration method). `.live` (built in
`MigrationSDKLiveKey.live()`) wires each closure to `@Dependency(\.sdkSynchronizer)` + the sourcing above,
resolved lazily at call time so dependency overrides apply. Tests inject a **fake gateway** with canned
results/throws — no full SDK double needed. Orchard balance comes from
`sdkSynchronizer.getAccountsBalances()[account].orchardBalance` (exact field verified in impl).

**5. Prototype-only surface** (kept app-side, wiring unchanged):

| App closure | Live behavior |
|---|---|
| `selectMigrationMode` | persist `mode` in `MigrationStateStore` (app-only concept; may not affect SDK) |
| `isMigrationCompleteAcknowledged` / `acknowledgeMigrationComplete` | `MigrationStateStore.completionAcknowledged` |
| `recordBackgroundRun` / `backgroundRunLog` / `clearBackgroundRunLog` | `MigrationRunLogStore` (unchanged) |
| `simulatedOrchardBalance` | real Orchard balance from the cache |
| `migrationSummary` / `migrationTransfers` | derive from cached `MigrationSchedule` + `MigrationProgress` + state (mirror the dummy's `summary()`/`transferRows()`; per-transfer status derived positionally from `completedTransfers`) |
| `debug.*` (reset/seed/advanceHeight/confirmSplitNow/armNextTransferResult/jumpTo/snapshotDescription) | **no-ops** in live (MigrationDebug panel goes inert) |
| `rescheduleStalledTransfer` / `recreateInvalidTransfer` | map to `migrationRestartCurrentStep`, then `refresh()` |
| `initializePostUpgrade` | call `migrationInitializePostUpgrade(account)` |

`MigrationStateStore` is reused only for the two app-only bits (`mode`, `completionAcknowledged`); its
simulation fields are unused on the live path.

### Step C — wire & keep the dummy

`MigrationSDKLiveKey.live()` builds `LiveMigrationEngine` (with `.live` gateway) and wires every closure to
it. Add `static let previewValue = Self.ephemeral()` so SwiftUI previews keep using the deterministic dummy.
`DummyMigrationEngine`, `MigrationStateStore`, `MigrationSDKTestKey` are untouched.

### Known gap — NetworkPrivacyOptions ignored by SDK (v1)

The SDK accepts but **ignores** `NetworkPrivacyOptions` (Tor/secondary endpoint deferred). The
`MigrationNetworkPrivacy` screen's selections won't take effect on the live path. Keep the screen as a
(currently cosmetic) placeholder; don't promise Tor in copy. FINAL REPORT item.

---

## GOAL 2 — Disable voting (`#if VOTING_ENABLED`, off)

**Root cause:** the SDK's `Package.swift` excludes `Rust/Voting` from the `ZcashLightClientKit` target
(*"Voting is gated off on this Ironwood branch"*), so ~30 voting symbols (`VotingRustBackend`,
`VotingShareDelegation`, `VotingHotkey`, `VotingRoundState`, …) are **absent from the compiled module**.
The app's voting layer references them and **cannot compile**. (The 18 s build aborted after the first two
`cannot find type 'VotingShareDelegation'` errors; the full set is far larger.)

**Mechanism:** introduce Swift compilation condition **`VOTING_ENABLED`**, left **undefined** in all build
configs, so `#if VOTING_ENABLED` is false everywhere. Re-enable later by adding `VOTING_ENABLED` to
`SWIFT_ACTIVE_COMPILATION_CONDITIONS`. No files deleted; nothing removed from target membership; no build
settings changed by this work (flag stays off).

**Compile out** (wrap whole-file bodies in `#if VOTING_ENABLED` / `#endif`):
- `Dependencies/VotingCryptoClient/*` (uses `VotingRustBackend` — the hard break)
- `Dependencies/VotingAPIClient/*`, `Dependencies/VotingStorageClient/*`, `Dependencies/VotingModels/*`
- `Features/Voting/*`, `Features/CoordFlows/VotingCoordFlow/*`
- `zodlTests/VotingTests/*` (5 files)

**Keep compiled** (no excluded-symbol coupling; referenced by Root):
- `Dependencies/VotingMetadataProvider/*` (0 references to excluded SDK voting symbols)
- `Models/VotingMetadata.swift`, `Models/RoundListItem.swift`
- ⇒ **`Root` (`RootStore`/`RootInitialization`) needs no changes** — its `@Dependency(\.votingMetadata)`
  usage stays valid.

**Gate the external seams** with inline `#if VOTING_ENABLED` (these reference compiled-out `VotingCoordFlow`
types) — `Features/Settings/`:
- `SettingsStore.swift`: `@Presents var votingCoordFlow`, `case votingCoordFlow(...)`,
  `case coinholderPollingTapped` + its no-op handler, and the `.ifLet(\.$votingCoordFlow, …)` binding.
- `SettingsView.swift`: the "Coinholder Polling" `ActionRow` and the `votingCoordFlow` `.fullScreenCover`.
- `SettingsCoordinator.swift`: the `.coinholderPollingTapped` and `.votingCoordFlow(.presented(.dismissFlow))`
  cases.
- Any Settings **tests** that exercise voting → gate likewise.

Root's `isSensitiveFlowActive` keeps `.settings` classified sensitive (the comment about voting living under
Settings stays; harmless).

**Boundary method:** the keep/cut split above is the expected boundary; the exact file set is **finalized by
iterating builds to green** (wrap the known-broken set, build, gate any residual reference, repeat). If a
kept file (e.g. `VotingMetadataProvider`) turns out to reference a compiled-out type, either gate that
reference or extend the cut — decided empirically, not guessed.

---

## TDD plan

New tests in `zodlTests/MigrationTests/` (Swift Testing — `@Suite`/`@Test`/`#expect`/`#require`; mark
`@Suite(.serialized)` if a suite touches global/`@Shared` state):

1. **`MigrationTypeMappingTests.swift`** (write first, red → implement converters → green):
   - SDK→app and app→SDK for each type; `Zatoshi↔UInt64`, `BlockHeight↔UInt32`.
   - `.success(txId)`↔`.success(txid)`; all `TransferResult` / `AttentionReason` cases.
   - Edge cases: `nil` progress, empty schedule, zero amounts, large `UInt64` near `Int64.max`.
2. **`LiveMigrationEngineTests.swift`** (red → implement engine → green) using a **fake `LiveMigrationGateway`**:
   - `refresh()` populates the cache and emits app state on `stateStream`.
   - Sync getters reflect the cache after refresh.
   - Error→fallback: a throwing gateway leaves last-known state and returns the documented fallbacks.
   - Mutating ops call the right gateway closure with mapped args, then refresh.
   - `debug.*` are no-ops; `selectMode`/`acknowledgeComplete` persist via an ephemeral store.

Goal 2 has no runtime behavior to unit-test (compile-time gating). Verification = green build + the existing
non-voting suites still pass; voting suites are compiled out.

**New files** (sources + tests) are created via the **Xcode MCP `XcodeWrite`** so they get correct target
membership (per the user's global CLAUDE.md).

---

## Verification

- Build **`zodl-internal`** via Xcode MCP `BuildProject`. If a **macro isn't trusted**, **STOP and ask** the
  user to allow it (per CLAUDE.md), then retry — do **not** fall back to the CLI.
- Run `zodlTests` migration suites via Xcode MCP `RunSomeTests`; confirm the full suite still builds.
- SwiftLint (build phase): no `print`/`NSLog`, interpolation not `+`, `TODO: [#<issue>]`, "ZODL" uppercase.
- Update `CHANGELOG.md` (migration wired to live SDK; voting compiled out behind `VOTING_ENABLED`).

## Files touched

**New:** `Dependencies/MigrationSDK/LiveMigrationEngine.swift`,
`Dependencies/MigrationSDK/MigrationTypeMapping.swift`,
`zodlTests/MigrationTests/MigrationTypeMappingTests.swift`,
`zodlTests/MigrationTests/LiveMigrationEngineTests.swift`.

**Modified (Goal 1):** `Dependencies/SDKSynchronizer/SDKSynchronizerInterface.swift`,
`Dependencies/SDKSynchronizer/SDKSynchronizerLive.swift`,
`Dependencies/MigrationSDK/MigrationSDKLiveKey.swift` (+ `SDKSynchronizerTest.swift` only if needed).

**Modified (Goal 2):** ~`#if`-wrapped voting sources (VotingCryptoClient, VotingAPIClient,
VotingStorageClient, VotingModels, Features/Voting, VotingCoordFlow, VotingTests) + Settings seams
(`SettingsStore`/`SettingsView`/`SettingsCoordinator`).

**Docs:** `CHANGELOG.md`, this spec.

## Risks / known gaps (for FINAL REPORT)

- **No live E2E** — needs a synced testnet wallet with Orchard funds. Validated by unit tests + build only.
- **`NetworkPrivacyOptions` ignored by SDK** — Tor/secondary-endpoint screen is cosmetic on the live path.
- **`.transferStalled`** — live relies on `hasOverdueTransfers`; verify no UI path depends solely on the
  `.transferStalled` state.
- **`migrationSummary`/`migrationTransfers`** derived approximately from `MigrationProgress.completedTransfers`
  (the SDK doesn't expose per-transfer sent/pending status beyond the count).
- **Voting disabled, not removed** — restore by defining `VOTING_ENABLED` once the SDK voting stack is
  migrated to valargroup `zcash_voting 1.0.0`.
