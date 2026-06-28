# Ironwood Migration Prototype — Round 4 (Failed / Stalled Migration Recovery) — Design / Spec

**Date:** 2026-06-28
**Branch:** `michal/MOB-1451-ironwood-migration-prototype`
**Predecessors:** round-1/2/3 specs in `docs/superpowers/specs/`

When a scheduled migration transfer **fails to send** (e.g. a network error) or its **background task doesn't run** (window missed), the migration must visibly enter an attention state — the Home SmartBanner switches, and opening the flow lands on a recovery screen where the user can act. This supersedes round-3's "network error is a silent retry" decision: network errors are **no longer silent**.

Two failure shapes, two screens (confirmed with the user):

- **Retryable stall** — transfer scheduled but not sent (network error / missed window). → **"Resume Migration"** screen (the B8 in-progress list, re-framed) with **Send now + Reschedule**.
- **Invalid/expired** — the pre-signed transfer is no longer valid (input note spent / anchor expired). → **"C5 · Transfer Invalid"** screen with **Re-create Transfer** (recreate the stale transfer in place + reschedule the rest) + **Learn more**.

## Global Constraints (carry over)

- Swift style: no `.init()` shorthand; no semicolons; `OSAllocatedUnfairLock` over `NSLock`.
- App name always `ZODL`. Tests: Swift Testing only; serialize global-state suites.
- Build/test: prefer Xcode MCP; CLI fallback `xcodebuild -project secant.xcodeproj -scheme zodl-testnet -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO` (tests scheme `zodl-internal`).
- Commit `[#MOB-1451] <title>` + Claude co-author trailer; never commit `graphify-out/` or `PartnerKeys.plist`.
- Prototype copy stays hardcoded English. Everything stays behind `MigrationSDKClient` → `DummyMigrationEngine`.

## Confirmed decisions

1. Invalid/expired → dedicated **C5 Transfer Invalid** screen (recreate + reschedule), *not* the Resume Migration screen.
2. Resume Migration actions = **Send now + Reschedule**.

---

## State model

Add a stalled attention reason that carries the affected transfer number (`MigrationModels.swift`):

```swift
enum AttentionReason: Equatable, Sendable, Codable {
    case invalidTransfer(transferId: String)
    case transferExpired
    case syncRequiredBeforeNext
    case transferStalled(transferNumber: Int)   // NEW: scheduled but not sent (network error / missed window)
}
```

`transferNumber` is the 1-based index of the first not-yet-sent transfer. The migration sits in `.requiresAttention(.transferStalled(n))` — so the state **stream fires with a distinguishable value**, which is what lets the SmartBanner and status screen react. `getMigrationProgress()` returns nil outside `.inProgress`, so the status screen already falls back to `migrationSummary()` for the progress card (verified) — no change needed there.

---

## Engine (`DummyMigrationEngine.swift`)

**Network error is no longer silent.** In `executeNext`, the armed `.networkError` branch now stalls instead of returning quietly:

```swift
case let .networkError(retryable):
    // Simulate "scheduled but the background send didn't go through": the transfer stays pending,
    // its window slips one bucket into the past, and the migration enters the stalled attention state.
    snapshot.currentHeight += Const.bucketBlocks
    let number = (snapshot.transfers.firstIndex { $0.status == .pending }.map { $0 + 1 }) ?? index + 1
    snapshot.state = .requiresAttention(.transferStalled(transferNumber: number))
    result = .networkError(retryable: retryable)
    return
```

(The `+= bucketBlocks` makes the failed transfer read as ~6h overdue, matching the design's "Overdue · 6h ago".)

**Stall detection on height change** — a genuinely missed window (height advanced past a pending transfer) also stalls. Add a private helper and call it from `debugAdvanceHeight` and `debugJump(.overdue)`:

```swift
private func reconcileStall(_ snapshot: inout MigrationSnapshot) {
    guard case .inProgress = snapshot.state else { return }
    if let i = snapshot.transfers.firstIndex(where: { $0.status == .pending }),
       snapshot.transfers[i].proposal.nextExecutableAfterHeight + Const.bucketBlocks <= snapshot.currentHeight {
        snapshot.state = .requiresAttention(.transferStalled(transferNumber: i + 1))
    }
}
```

`debugJump(.overdue)` sets the height past the window (as today) then sets `.requiresAttention(.transferStalled(...))`.

**Reads:**
- `overdue()` / `hasOverdueTransfers()` → also true when state is `.requiresAttention(.transferStalled)`.
- `invalid()` / `hasInvalidTransfers()` → true **only** for `.invalidTransfer` / `.transferExpired` (exclude `.transferStalled`).
- `transferRows()` → when the first not-sent transfer is stalled/overdue, emit status `.overdue` and carry the **overdue hours** (see below) so the row can show "Overdue · Xh ago".

**`MigrationTransferRow`** gains the signed overdue magnitude. Simplest: when overdue, set `hoursFromNow` to a negative value = `-(blocksPast / bucketBlocks * 6)`; the view renders "Overdue · \(abs)h ago" for negative hours. (Pending future rows keep positive hours; the existing `.overdue` label path is updated.)

**New mutations:**
- `rescheduleStalled()` — clears the stall: bump the stalled transfer's `nextExecutableAfterHeight`/`anchorHeight`/`expiryHeight` to the next bucket from `currentHeight`, set state back to `.inProgress(progress)`.
- `recreateInvalid()` — for the invalid/expired case: replace the first `.invalid`/`.expired` transfer with a fresh `TransferProposal` (new id, **same amount**, anchor/window at the next bucket), keep all other transfers, set state back to `.inProgress(progress)`. (Distinct from `restart()`, which re-splits the whole remaining balance.)

"Send now" reuses the existing `executeNext` (no armed failure → broadcasts the stalled transfer → success → `.inProgress`/`.complete`, clearing the stall).

---

## SDK boundary (`MigrationSDKInterface.swift` + `MigrationSDKLiveKey.swift`)

Add two closures (safe defaults in the interface; wired to the engine in the live key):

```swift
var rescheduleStalledTransfer: @Sendable () async -> Void = {}
var recreateInvalidTransfer: @Sendable () async -> Void = {}
```

`executeNextPendingTransfer`, `hasOverdueTransfers`, `hasInvalidTransfers` keep their signatures (semantics updated per above).

---

## SmartBanner (`SmartBannerStore.swift` + `SmartBannerContent.swift`)

The banner already mirrors `migrationState` via the state stream. Update the migration copy so the stalled state matches the "Wallet Status Widget" screenshot:

| `migrationState` | Title | Info | Button |
|---|---|---|---|
| `.requiresAttention(.transferStalled(n))` | `Transfer \(n) waiting` | `Tap to reschedule or send now` | `More` |
| `.requiresAttention(_)` (invalid/expired) | `Action Needed` | `A transfer needs your attention` | `Resolve` |
| `.inProgress` | `Migration in Progress` | `Transfers are sending in the background` | `View` |
| else | `Migration Required` | `Move your funds to Ironwood` | `Migrate` |

`transferNumber` comes straight off the state enum (no extra SDK query). Tapping the banner/button → existing `migrationScreenRequested` → Home launches the flow.

---

## Coordinator (`MigrationCoordFlowCoordinator.swift`)

`.start` routing:
- `hasInvalidTransfers()` → `recovery` (C5).  *(unchanged target, screen redesigned)*
- `hasOverdueTransfers()` (stalled/overdue) → **`status(.progress)`** *(was `recovery(.overdue)`)* — the status view auto-renders "Resume Migration" because the state is stalled.
- else by `getMigrationState()` as today.

New/updated delegate handling:
- `status(.delegate(.sendNow))` → `await executeNextPendingTransfer(NetworkPrivacyOptions(useTor: false))` (state stream refreshes the same screen). 
- `status(.delegate(.reschedule))` → `await rescheduleStalledTransfer()` + `migrationBGScheduler.scheduleNextRun(60)`.
- `recovery(.delegate(.recreate))` → `await recreateInvalidTransfer()` + `migrationBGScheduler.scheduleNextRun(60)` (state stream refreshes; the recovery screen is popped on completion via the existing done/close path or by re-routing to `status(.progress)`).
- `recovery(.delegate(.close))` → `dismiss` (unchanged).

The old `recovery(.overdue)` / recovery `sendNow`/`reschedule` paths are removed (overdue now lives on the status screen).

---

## Resume Migration screen (`MigrationStatus*`)

Render a third variant when stalled — no new `Presentation` case needed; detect from state:

```swift
var isStalled: Bool { if case .requiresAttention(.transferStalled) = migrationState { return true }; return false }
var stalledTransferNumber: Int { if case let .requiresAttention(.transferStalled(n)) = migrationState { return n }; return 0 }
```

`MigrationStatusView` body order: `isComplete` → `MigrationCompleteView`; **`isStalled` → `resumeContent`**; `presentation == .scheduledSuccess` → scheduled; else `progressContent`.

`resumeContent` reuses the existing transfers list + progress card, plus:
- Leading **X close** (deep entry → Home), as the progress screen already has.
- Title **"Resume Migration"**.
- Subtitle: `"Transfer \(n) of \(total) was scheduled \(hours)h ago but wasn't sent. Reschedule and send now."` (hours from the stalled row; omit "Xh ago" if 0).
- The transfer list — the stalled transfer shows badge style `.active` (dark numbered, per the design — overdue maps to `.active`, not `.warning`) and label **"Overdue · Xh ago"**; sent rows green check; future rows gray + "~Xh".
- Progress card (existing): "N of M transfers complete · P% complete".
- An info note: ⓘ **"Transfer window missed"** / "Send now or reschedule to the next window."
- Buttons: **"Send now"** (primary) → `sendNowTapped`; **"Reschedule"** (secondary) → `rescheduleTapped`.

`MigrationStatus` gains actions `sendNowTapped` / `rescheduleTapped` and delegate cases `.sendNow` / `.reschedule`.

Badge change: `MigrationStatusView.badgeStyle` maps `.overdue → .active` (dark numbered) so the stalled transfer matches the design; `.invalid/.expired` stay `.warning`.

---

## C5 Transfer Invalid screen (`MigrationRecovery*`)

Repurpose `MigrationRecovery` as the invalid/expired screen only (drop the `.overdue` kind). Redesign to Figma C5 (`2621:10289`):
- Leading **X close**.
- Title **"Transfer No Longer Valid"** (24/semibold).
- Body: `"Transfer \(n) was pre-signed for a balance that has since changed. It needs to be re-created for the remaining amount."`
- **"Stale transfer detected"** card (bg-secondary) with ⓘ and a supporting line (prototype: "The pre-signed key no longer matches your current balance.").
- **"What Happens Next"** with three numbered avatar bullets:
  1. `A new transfer is created for Transfer \(n)`
  2. `Remaining transfers are re-scheduled`
  3. `No funds are lost — only the pre-signed key is discarded`
- ⓘ note: `\(sent) of \(total) transfers done; migration will continue.`
- Buttons: **"Re-create Transfer"** (primary) → `recreateTapped`; **"Learn more"** (secondary) → `learnMoreTapped` (prototype no-op — flagged in the final report).

`MigrationRecovery.State` keeps only the invalid framing (its `kind` enum collapses to invalid/expired, or is dropped). Delegate: `.recreate`, `.close` (the old `.sendNow`/`.reschedule`/`.overdue` are removed).

---

## Debug panel (`MigrationDebugStore.swift`)

The round-3 feedback alert now reports the visible stall. The network-error outcome message becomes: `"Network error — migration paused. Transfer N now needs attention (open the migration flow)."` The snapshot read-out will also show `state: requiresAttention(transferStalled…)`. "Arm Network error → Run background task now" therefore switches the UI to the stalled state, exactly as requested. ("Jump to → Overdue" produces the same stalled state.)

---

## Tests (`zodlTests/MigrationTests/`)

- Update `MigrationBackgroundWorkerTests.reportsNothingPendingThenNetworkError`: after the armed network-error run, assert `engine state == .requiresAttention(.transferStalled(...))` and `hasOverdueTransfers() == true`, `hasInvalidTransfers() == false`.
- New engine tests:
  - `networkErrorStallsThenSendNowCompletes`: arm networkError → executeNext stalls → executeNext again (no arm) → sends → `.inProgress`/`.complete`.
  - `rescheduleStalledReturnsToInProgress`: stall → `rescheduleStalled()` → `.inProgress`, transfer window in the future, `overdue() == false`.
  - `recreateInvalidReplacesOnlyThatTransfer`: arm invalidNote → executeNext → `recreateInvalid()` → same transfer count, the invalid one replaced (new id, same amount), other transfers untouched, state `.inProgress`.

---

## Out of scope / non-blocking (final report)
- C5 "Learn more" is a prototype no-op (no destination in the design).
- Exact Figma node for the "Resume Migration" / "Wallet Status Widget" frames wasn't enumerable (page list only returns "Cover"); implemented from the user's screenshot + existing components. C5 from node `2621:10289`.
- New copy stays hardcoded English.
