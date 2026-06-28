# Ironwood Migration Prototype — Round 3 Refinements (Design / Spec)

**Date:** 2026-06-28
**Branch:** `michal/MOB-1451-ironwood-migration-prototype`
**Predecessors:** round-1 (`…-prototype-design.md`), round-2 (`…-prototype-revisions-design.md`)

This round is a set of 7 targeted refinements to the simulated Orchard → Ironwood
migration prototype. Everything stays behind the existing `MigrationSDKClient`
boundary, driven by `DummyMigrationEngine`. No new architecture; this is UI polish,
one engine constant change, one debug-feedback fix, and a navigation audit.

## Global Constraints (carry over, copied verbatim from project rules)

- **Swift style:** no `.init()` shorthand (use explicit type names); no semicolons;
  prefer `OSAllocatedUnfairLock` over `NSLock`.
- **App name:** always `ZODL` (never Zodl/zodl) in any user-facing copy.
- **Tests:** Swift Testing only (`@Suite`/`@Test`/`#expect`/`#require`), never XCTest.
  Serialize suites that touch process-global state.
- **Build/Test:** prefer Xcode MCP; if unavailable, `xcodebuild -project secant.xcodeproj
  -scheme zodl-testnet -skipMacroValidation -skipPackagePluginValidation
  CODE_SIGNING_ALLOWED=NO`. Tests scheme `zodl-internal`, target `zodlTests`.
- **Design source:** Figma file `1aeq8gleYh9Yr1l33TwELR` + the user's attached
  screenshots (B1 entry, Notes Splitting_Explainer_A, C6 Migration Complete — Dust).
- **Commit:** `[#MOB-1451] <title>`, end with the Claude co-author trailer; never
  commit `PartnerKeys.plist` or `graphify-out/`.
- **Prototype copy:** new strings are hardcoded English, consistent with the existing
  migration screens (these are not localized for the prototype).

## Confirmed decisions (clarifying answers)

1. **Debug alerts:** *feedback after action* — every debug action button pops a brief
   alert reporting what actually happened (not an "are you sure?" pre-confirm).
2. **Transfer count:** *random 3–5* for Migrate-with-Privacy (immediate stays 1).

---

## Item 1 + Item 6 — Debug panel feedback alerts (shared fix)

**Problem.** (1) The debug panel gives no feedback when a button runs. (6) Arming
"Network error" then "Run background task now" appears to do nothing.

**Root cause (item 6 — confirmed, not a wiring bug).** `MigrationSDKClient.liveValue`
is a `static let` that builds **one** `DummyMigrationEngine`; the debug `arm` closure and
the background worker's `executeNextPendingTransfer` share that instance, so arming is
seen. But `executeNext`'s `.networkError` branch is a *silent retry by design*: it
consumes the armed failure, sets the result, and returns **without changing any transfer
status or migration state**. The worker then posts a local notification, which is
suppressed while the app is foreground. Net effect: the debug snapshot is unchanged →
"nothing happens."

**Design.** Make the background step report its outcome, and surface it (plus every
other action) in an alert.

- Add an outcome type (in `MigrationBackgroundWorker.swift` or `MigrationModels.swift`):
  ```swift
  enum MigrationStepOutcome: Equatable, Sendable {
      case nothingPending
      case syncRequired
      case result(TransferResult)
  }
  ```
- `MigrationBackgroundWorker.runMigrationStep()` becomes
  `@discardableResult func runMigrationStep() async -> MigrationStepOutcome`,
  returning `.syncRequired` on the sync guard, `.nothingPending` when `executeNext`
  returns nil, and `.result(result)` otherwise. The `AppDelegate` call site
  (`AppDelegate.swift:127`) ignores the value (`@discardableResult` → no warning).
- `MigrationDebug.State` gains `@Presents var alert: AlertState<Action>?`. A new
  internal action `reportOutcome(String)` (or per-action message) sets a one-button
  ("OK") alert. Every existing action — Seed, Reset, Advance, Confirm split, Run
  background task, Arm (each variant), Jump (each variant) — fires the alert after its
  effect runs, with a short human description:
  - Run background task → `"Background task ran.\nResult: <outcome>"`, e.g.
    `"Network error — transfer stays pending, will retry next window."`,
    `"Transfer sent ✓ (txid …)."`, `"No pending transfer to execute."`,
    `"Sync required first — task skipped."`.
  - Arm X → `"Armed next transfer result: <X>."`
  - Seed → `"Seeded <amount> ZEC into <n> notes."`, Reset → `"Migration reset."`, etc.
- The alert is shown via `.alert(store:)` in `MigrationDebugView` and dismisses back to
  the panel. The snapshot still refreshes underneath (existing `.refresh`).

**Files:** `MigrationBackgroundWorker.swift`, `MigrationDebugStore.swift`,
`MigrationDebugView.swift`, (outcome type) `MigrationModels.swift`. `AppDelegate.swift`
unchanged except it now ignores a discardable result.

**Note:** network errors remain intentionally silent in the *real* UI (a retry, not an
error screen). The alert is the debug-only way to observe that the armed result took
effect — this is the intended product behavior, surfaced for the simulator.

---

## Item 2 — Note-split confirmation/explainer screen

**Problem.** The split currently auto-starts when `MigrationNoteSplit` appears. Figma
("Notes Splitting_Explainer_A") shows a **Split Your Wallet Funds** explainer the user
must Confirm before the send-to-self runs.

**Design.** Add a leading `.explainer` step to `MigrationNoteSplit`:

- `State.Step` becomes `{ explainer, splitting, confirmed }`; initial = `.explainer`.
- New action `confirmTapped`. On `.explainer`, `onAppear` only loads the proposal
  (`prepareNoteSplit`) to populate Amount + Fee — it does **not** submit. `confirmTapped`
  submits (`submitNoteSplit`) → `.splitting`, starts the state stream, waits ~15s for the
  simulated confirmation → `.confirmed` → Continue (existing `.delegate(.continued)`).
- Re-entry handling (existing) is preserved: `.readyToPropose` → `.confirmed`;
  `.splitPendingConfirmation` → `.splitting` + observe.
- **View:** explainer layout from Figma — paired ZODL+Ironwood header icons, title
  "Split Your Wallet Funds", explanation paragraph ("This sends a transaction to
  yourself, breaking your balance into smaller notes. Each Ironwood migration transfer
  then settles independently — no waiting for change."), a card showing **Amount** and
  **Fee** (Transaction ID row appears only after Confirm, once a txid exists), and a
  **Confirm** button. Splitting/Confirmed reuse the existing B3a/B3b layout.

**Nav (ties to item 5):** the explainer step shows a **back chevron** (pops to the
previous screen). `.splitting` / `.confirmed` show **no** leading control (broadcast is
irreversible).

**Files:** `MigrationNoteSplitStore.swift`, `MigrationNoteSplitView.swift`.

---

## Item 3 — B1 "Move to Ironwood" entry redesign

**Problem.** The entry screen diverges from Figma B1/A1.

**Design (match Figma 2630:11744 / 2539:63191 + screenshot):**

- **Header:** paired circular icons — ZODL logo + Ironwood ("coins swap") icon — above
  the title (overlapping pair, as in Figma).
- **Leading control:** **X close** at top-left (wired to existing `closeTapped` →
  `delegate(.close)` → coordinator `.dismiss` → Home). See item 5.
- **Balance card:** light secondary surface; small "Orchard balance" label + fiat value
  (top-right) and the ZEC amount (bold, below-left). Fiat via existing `MigrationFiat`.
- **Option cards (radio):** selected state uses the **dark/primary** stroke + filled
  primary radio per Figma — **not** the current amber/brand stroke. Unselected = light
  surface, hairline/none stroke, empty radio. Exact token confirmed from
  `get_design_context` at implementation time.
- **Info row:** an `(i)` icon + "Pool-crossing transfer amounts are visible on-chain."
- **Next button:** disabled (gray) until a mode is selected, primary (dark) once
  selected. (Default selection may start unselected to match B1; confirm against Figma.)

**Files:** `MigrationEntryView.swift` (layout), possibly `MigrationEntryStore.swift` if
the initial selection should be "none" (add an optional selected mode / `nextEnabled`).

---

## Item 4 — Cap transfers at random 3–5

**Problem.** Private migration splits into 5–8 transfers; max should be 5.

**Design.** `DummyMigrationEngine.Const`: `minNotes = 3`, `maxNotes = 5` (was 5/8).
All three split sites already read these constants (`prepareSplit`, `restart`,
`buildSchedule` fallback). Immediate mode is unchanged (always 1 transfer). The debug
seed `noteCount` override (1…10 stepper) still forces an exact count for previews.

**Tests:** update `DummyMigrationEngineTests` — the "5…8" assertion becomes "3…5"; the
note-count-override test is unaffected (override bypasses the range).

**Files:** `DummyMigrationEngine.swift`, `zodlTests/MigrationTests/DummyMigrationEngineTests.swift`.

---

## Item 5 — Navigation audit: back vs close per Figma

**Problem.** Leading nav controls are inconsistent with Figma — some screens should show
a back chevron, some an X (close).

**Rule.**
- **Flow root (entry) and deep-entry screens** (reached directly from the Home banner,
  with no meaningful previous screen) → **X close** → dismiss whole flow to Home.
- **Forward-pushed screens** (a real previous screen exists) → **back chevron** → pop.
- **Irreversible in-flight screens** (note-split `.splitting`/`.confirmed`,
  immediate-review `.sending`/`.sent`, complete) → **no leading control**; the primary
  button (Continue/Done) advances.

**Per-screen target:**

| Screen | Reached by | Leading control |
|---|---|---|
| MigrationEntry (B1) | flow root | **X close** → Home |
| NoteSplit · explainer | push from entry | **back chevron** → pop |
| NoteSplit · splitting/confirmed | (post-confirm) | none |
| BackgroundDelivery | push | **back chevron** |
| NetworkPrivacy | push | **back chevron** |
| TransferPlan (B4) | push | **back chevron** |
| ImmediateReview (A2) · review | push | **back chevron** |
| ImmediateReview · sending/sent | (post-confirm) | none |
| Status · scheduledSuccess | push (after plan) | none (Done dismisses) |
| Status · in-progress | deep entry (banner) | **X close** → Home |
| Status · complete | terminal | none (Done dismisses) |
| Recovery | deep entry (banner) | **X close** → Home |

Each screen's actual control is verified against its Figma node during implementation
(`get_design_context`/`get_screenshot`); the table is the default where Figma is silent.
Deep-entry close reuses existing delegates (`status(.done)`, `recovery(.close)`); the
only behavioral change vs round-2 is the **icon** (chevron → X) on deep-entry screens.

**Files:** `MigrationEntryView.swift`, `MigrationNoteSplitView.swift`,
`MigrationStatusView.swift`, `MigrationRecoveryView.swift`, and the other pushed-screen
views as needed (`MigrationBackgroundDeliveryView`, `MigrationNetworkPrivacyView`,
`MigrationTransferPlanView`, `MigrationImmediateReviewView`).

---

## Item 7 — C6 "Migration Complete — Dust" redesign

**Problem.** The current complete screen (dark hero + green check) doesn't match Figma
C6.

**Design (match Figma 2539:58787 + screenshot):** redesign `MigrationCompleteView`:

- **Background:** light green vertical gradient (light green at top → screen background).
- **Illustration:** the raised-fist celebration — **`Asset.Assets.Illustrations.success1`**
  (confirmed: `success1.png` is exactly the C6 fist), centered near the top.
- **Title/subtitle:** centered "Migration Complete" + "Your ZEC is now in the Ironwood
  pool."
- **Summary card:** neutral surface, rows: **Total transferred**, **Remaining dust**
  (only when dust > 0), **Transfers** ("N of M sent"), **Duration** ("Instant" / "~Xh").
  Amounts shown to full precision via `decimalString()`.
- **Dust card:** only when dust > 0 — neutral card (per Figma, not amber) with an `(i)`
  icon: "Dust balance remaining — `<amount>` ZEC stayed in Orchard, below the transfer
  threshold. It will migrate in a future batch."
- **Done** button (full width) → existing `onDone`.
- Clean (no-dust) case: same screen without the Remaining-dust row and the dust card.

The view stays presentation-only with the same initializer
(`transferred/dust/transfersSent/transfersTotal/durationHours/tokenName/onDone`), so both
call sites (immediate `sent`, scheduled `complete`) are unchanged.

**Files:** `MigrationCompleteView.swift`.

---

## Out of scope / non-blocking (for the final report, not gates)

- The explainer's Figma card shows a Transaction ID and a 0.001 ZEC fee; the engine's
  cosmetic fee is 0.0001 ZEC and no txid exists pre-Confirm. We keep the engine fee and
  show the txid only after Confirm — a deliberate, minor mock discrepancy.
- Existing migration screens remain hardcoded-English (prototype), so new copy is too.

## Testing

- Update `DummyMigrationEngineTests` for the 3–5 range; keep the override test.
- (Optional) a small Swift Testing check that `runMigrationStep()` returns
  `.nothingPending` when no transfers exist and `.result(.networkError)` after arming a
  network error with a pending transfer.
- Full build (Xcode MCP preferred) + migration suite + a regression pass on
  Home/SmartBanner. `graphify update .` after changes. Commit to the current branch.
