# Zodl macOS Beta — Known Issues & Points to Focus On Later

Living list maintained ahead of / through internal beta. Each entry: **symptom · status · cause/notes ·
next step**. Add points as they surface; move to "Resolved" when fixed.

---

## Open

### 1. Slipstream sync error after importing a Keystone account — PARKED (investigate: option B)
**Symptom.** A "Syncing Error" card appears: `[ZRUST0096] Slipstream sync pass failed during a polling
tick. rustSlipstreamSyncFailed(<n>)`. Observed by QA (Harry) on macOS when **importing a Keystone account
into an already-synced wallet** (not a fresh restore). **Recovers after an app restart.** Tor was **OFF**.

**Status.** Diagnosed (root-cause area identified); parked for a focused fix. The *dialog* itself is being
fixed separately — see entry 2. QA likely can't reproduce on demand; reproduce locally.

**Cause / notes.**
- The number `<n>` is **`chainTip`** (SlipstreamSynchronizer.swift:459 passes `snap.chainTip`) — the chain's
  top, *not* a failure height.
- FFI **state 2 = `SyncState::Error(_)`**, which conflates `Error(1)` (a non-transient **config/logic**
  error) and `Error(2)` (the sync task **panicked**). Transient/transport/Tor errors retry as
  **Disconnected** (state 0) and **never** surface state 2 → **this is a bug, not bad internet.**
- Trigger: `importAccount` on a running wallet **restarts the pass** (`if isRunning { try? await start() }`,
  SlipstreamSynchronizer.swift ~690; `[#1755]`, recently shipped). Suspect: the **restart-while-running
  race** (`slipstream/core/src/ffi_handle.rs:118-123` — "the Swift layer never restarts without `stop()`",
  yet importAccount calls `start()` directly) → `Error(2)`; or a re-scan logic error → `Error(1)`. Tor OFF
  rules out the Tor layer — the fault is in the import-restart / re-scan path itself.
- Recovering on restart (fresh state Arcs + clean scan queue) ⇒ a transient internal-state bug → **fixable**.

**Next step (B).** Get the device log line — `slipstream sync task PANICKED …` (Error 2 + panic payload) vs
`slipstream sync failed` (Error 1 + the error), plus the `tag=4` event value (1 vs 2) — to confirm which
mode. Then check `start()`'s abort/restart sequencing and whether `importAccount` should `stop()`-first or
signal a re-scan **without** a full restart. (SDK-side; see SDK memory `slipstream-syncfailed-importaccount`.)

### 2. Sync-error dialog has no in-app recovery — DEFERRED
**Symptom.** When a sync error surfaces, the dialog offers only **Report / OK** — no in-app way back, so the
user must force-quit and relaunch (which is also bad advice to give).

**Status.** Deferred (pending entry 1). The dialog's *placement* bug — it was rendering **inside the
sidebar** on macOS — is **fixed** (hoisted to the window root, MODALS.md Rule #5).

**Notes.** An in-app retry path exists (`HomeStore.retrySync` → `sdkSynchronizer.start(true)`) but the dialog
doesn't expose it. Proposed: a **"Try Again"** button → `retrySync`, plus friendly copy that does **not**
tell users to restart. Whether `start(true)` actually recovers (vs needing a fuller re-init) is tied to
entry 1.

**Next step.** Wire Try Again → `retrySync` (stopgap) + the no-restart copy, once entry 1 tells us whether
`start(true)` recovers.

### 3. Sync-timeout banner sheet not visually verified on macOS — LOW
Hoisted to the window root like the help sheet, builds green, but the macOS visual hasn't been eyeballed
(uncommon path — fires only on a sync timeout). Verify when convenient.

### 4. "Dimmed capped" — dialog backdrops clamped to the content width (`Design.Mac.viewCapWidth`) — RESOLVED
**RESOLVED (`MacCard.swift`).** All `.zashiSheet` / `.zashiSelectorSheet` cards now present via one root
card host (`.macCardHost()` at the RootView root) — a single centered card dimming the WHOLE window, above
the content cap (`Design.Mac.viewCapWidth`), for both split and single-window screens. (The *onboarding screen-bg* variant below is NOT a
dialog — a capped screen background — so it may still want a separate fix.) Analysis kept for reference.

**Symptom.** A dialog's dimmed semi-transparent backdrop should cover the FULL pane/screen, but it's capped
to the Rule-#8 content max-width (`Design.Mac.viewCapWidth`) — it dims only the centre column. Cosmetic (the dialogs work). One
non-dialog variant: a single-view screen whose own background is capped (empty side margins).

**Status.** PARKED — resume next. The dialog *content* (card + Liquid Glass) is correct; only the backdrop
width is wrong. More restore-flow cases TBD (being listed).

**Candidates.**
- *Split-view dialogs:* Swap/Pay token selector (`.zashiSelectorSheet`); filter-activity dialog;
  recovery-phrase (i) info; delete-wallet confirmation (`.zashiSheet`); restore-flow (i) info (the same
  icon repeats across the WHOLE restore flow → wrong wherever pressed); restore final-step "Tor on/off?".
- *Single-screen dialogs:* add-Keystone (?) info; add-Keystone scan view.
- *Screen-bg variant (NOT a dialog):* onboarding (create / restore wallet) — its background is capped.

**Root cause (confirmed via Lukas's clue).** The backdrop is a SwiftUI `.overlay`, confined to the bounds of
the view it's attached to. macOS caps content via `frame(maxWidth: Design.Mac.viewCapWidth)` (`macCappedScreenContent`
in `ScreenBackground.swift`); the overlay inherits that frame — *"a parental modifier tells the dialog the
frame to render in."*

**Failed attempts (do NOT repeat).** The transaction-detail "Add a note" dialog was fixed, but ONLY because
it sits on a **gradient** bg (`applyDefaultGradientScreenBackground` — a `LinearGradient` drives its ZStack
full-pane). On **solid-`Color`** bg (`applyScreenBackground`) none of these worked: (a) attach the dialog
after the bg; (b) force the overlaid content `.frame(…: .infinity)`; (c) make the `Color` fill the ZStack
`.frame(…: .infinity)`. All reverted.

**Next-step direction.** Stop widening the background. Present the dialog **outside** `macCappedScreenContent`
— the cap must wrap the content ONLY, with the dialog overlay wrapping the whole screen (cap + bg). Likely
clean fix: a screen/window-root dialog presenter (the MODALS.md Rule #5 hoist used for the smart banner), so
dialogs render above the cap. Treat the onboarding screen-bg variant separately (bg should fill the window,
content capped inside).

### 5. Native `.sheet` / `.popover` for app content — converting to MacCard (sweep in progress)
**Symptom.** Some modals were built with a native `.sheet` / `.popover` instead of `.zashiSheet` /
`.zashiSelectorSheet`, so on macOS they render as raw sheets (no MacCard / Liquid Glass) and any
`.presentationDetents` collapse them to 0 height (MODALS gotcha #1). Surfaced by the Swap/Pay **slippage** sheet.

**Status.** Rule codified (MODALS.md **Rule #5a**) + whole-app audit done. **Fixed:** slippage (Swap +
CrossPay), currency picker, voting add/edit-chain — all → `.zashiSheet` / `.zashiSelectorSheet` on macOS, iOS
unchanged. **Keystone: resolved as NOT-cards** (see below). In-app browsers still open.

**Audit (whole `secant/Sources`, 2026-06-24).**
- **App content → card (FIXED):** slippage `SwapForm:193` / `CrossPay:187` → `.zashiSheet` (+ duplicate close
  button hidden on macOS); `CurrencyConversionSetup:45` (currency list) + `VotingConfig:76/81` (add/edit chain)
  → `.zashiSelectorSheet` (definite size so the list/form scrolls; voting's macOS screen-bg stripped so the
  glass shows). iOS keeps its native `.sheet` + detents in every case.
- **Keystone — NOT cards (resolved):** `RootView:272` (sign popover) lives in the `#else`/iOS branch → it
  doesn't exist on macOS, so it's a no-op. `DelegationSigningStore:100` (`.sheet(store:)` → `ScanView`) must
  stay full-window — `ScanView` is **Rule #9 exempt from the content cap** (full-window camera cutout); a
  centered card would shrink/break it. Leave it; any change here is a *full-window* presentation decision, not
  a card. (Also: there is no `.zashiSheet(store:)` overload — store-based presentation would need a binding bridge.)
- **In-app browser (separate concern, NOT a card):** `HomeView:105`, `AboutView:70/75`, `AddHWWalletView:97`,
  `ProposalDetailView:108` — all present `InAppBrowserView(url:)` (web). macOS should open in a window /
  system browser.
- **Correct (library internals):** `ZashiSheet.swift:81`, `ZashiSelectorSheet.swift:42` — the iOS impls.

**Next step.** Visually verify the 3 converted cards on macOS. Decide in-app-browser macOS behavior (window /
system browser). Optional: a full-window macOS presentation for the Keystone delegation scan.

---

## Recently addressed (context for testers)
- Smart-banner sheets (shielding / sync-error / sync-timeout) were rendering **clamped inside the narrow
  sidebar** on macOS → now presented centered over the whole window (MODALS.md Rule #5). Help/shielding
  verified.
- Reset screen (Settings → Advanced → Reset Zodl / `DeleteWalletView`) overflowed above the window and
  ballooned the split sidebar → now uses the scrollable screen background (scrolls within the pane).
- Transaction-detail "Add a note" dialog backdrop was clamped → fixed (attached after the gradient bg).

---

## To triage (add pre-beta points here)
-
