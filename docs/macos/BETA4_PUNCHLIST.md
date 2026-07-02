# Beta4 punch list (macOS) — observed by Lukas, 2026-07-02

**Source: Lukas's device testing before Beta4 can ship. 11 items, numbered as reported.
Triage annotations = Claude's first-pass classification (verify before trusting).
Cross-refs: TRACKS.md (SDK repo) track 1 · FOUNDATIONS_F1_VERDICTS.md · MODALS.md.**

## STATUS 2026-07-02 (autonomous fix wave) — ALL 11 IMPLEMENTED, awaiting Lukas's visual pass
- B4-1 ScanView: progress bar was rendering OFF-SCREEN in the sign flow (larger cutout ⇒
  `topLeft.y − 56` above the window) — clamped to stay visible.
- B4-2 SendFormView (round 2, field-tested): the info box's inner `VStack { icon; Spacer }` was
  the height-stretcher — replaced with `HStack(alignment: .top)`; box hugs its text. (Round 1's
  whole-box fixedSize broke the form layout — reverted.)
- B4-3 MacSplitView: account switch (compared by account id, launch transition skipped) →
  `selectSection(.activity)` (resets all section paths).
- B4-4 AddHWWalletStore/KeystoneDeviceReadyView: `isImportInFlight` — Connect shows a spinner +
  both buttons disable + re-entry guard (import legitimately waits on a restore-busy data.db).
- B4-5 WalletBalancesStore: offline-first — instant `latestState` balances emitted BEFORE the
  (possibly slow) `getAccountsBalances` refresh; spinner no longer gated on it.
- B4-6 AddressBookView: invisible 14pt tail row — the offset chain circle no longer clips.
- B4-7 SuccessView + PendingView: View-transaction is regular-only (mutually exclusive with
  Check-status).
- B4-8 SwapForm (round 3, field-tested): fixed 32pt line box on macOS too (`frame(height: 32)`
  now unconditional — same geometry as iOS and as the row's non-editing Text state); prompt and
  typed value share the box. Placeholder overlay patch deleted; round 2's fixedSize (floating
  glyph) reverted.
- B4-9 SwapForm: kept the `writingToolsBehavior(.disabled)` suppression (was already in the
  working tree); if the bubble still flashes on device it is a different affordance — retest.
- B4-10 RootTorInitCheck: Settings-path currency-conversion enable (and Tor enable — the class
  sweep) now sends `.home(.smartBanner(.closeAndCleanupBanner))`.
- B4-11 HomeStore: on macOS the Keystone advert opens the link in the DEFAULT browser
  (NSWorkspace) — sidesteps the present-after-MacCard trap; structural fix stays with F-2(a).
- **B4-12 (NEW, found during Lukas's pass): disconnect→re-add Keystone → instant ZRUST0096,
  sync wedged.** Diagnosed via a CLI run on a snapshot of the wedged data.db (it syncs CLEANLY —
  wallet state healthy): importAccount's pass restart aborts the old pass, but its in-flight
  write-behind commit runs in `spawn_blocking` (abort can't cancel it) and overlaps the new
  pass's writes; the MAIN wallet connection had NO busy_timeout (upstream `for_path` sets none)
  → instant SQLITE_BUSY → non-transient error → Error state; a dead pass never auto-restarts =
  the wedge. **ENGINE FIX committed SDK-side (`22add7cd`): main connection opened with a 15 s
  busy_timeout** (mirrors for_path otherwise). Re-test: disconnect → re-add w/ old birthday —
  expect no dialog, Keystone re-scans. Follow-up candidates (not Beta4-blocking): drain the
  orphan commit across restarts; auto-retry policy after Error state; carry the Rust error
  detail across the FFI so the dialog isn't detail-less.

Legend: `[app]` Zodl-only · `[app+SDK]` needs SDK/engine understanding · `[class:X]` a known
failure class with an existing pattern/fix precedent.

---

## B4-1 · Keystone scan: progress bar missing for sign-flow scans `[app]`
Scanning the animated QR for a Keystone ACCOUNT renders the gold frames-read progress bar;
scanning for shielding/sending (sign flow) renders NO progress bar at all.
**Triage:** the sign flow's scanner instance isn't wired with the progress overlay the
account-import scanner has (different Scan feature config or a macOS-only branch missing it).
Compare the two scan-view invocations; likely a missing binding/flag, not a new component.

## B4-2 · Send→transparent: disabled memo placeholder too tall on macOS `[app]`
Transparent recipients disable the memo (correct), but macOS renders the disabled placeholder
at full memo height; iOS shows a small rounded rect.
**Triage:** height fix in the memo input's disabled state on macOS — mirror the iOS compact
variant.

## B4-3 · Account switch must reset navigation to section root `[app]` — **DECIDED**
Repro: Zodl account → Receive → UA QR (pushed) → switch account in the sidebar → still on
Zodl's QR screen (now wrong-account content).
**Lukas's decision: on ANY account switch, reset navigation to root (Activity section).**
This is a NEW macOS-native class: iOS switches accounts only from Home (single place); macOS
keeps the switcher always available, so pushed per-account content can go stale cross-account.
**Triage:** implement in the Root/coordinator layer where the switch action lands (single
choke point), popping every section's NavigationStack path + closing account-scoped overlays.
Feeds the F-3 `windowMode`/presentation-registry design (account-switch = a declared
navigation event), but does not need to wait for it. iPad will inherit the same rule.

## B4-4 · Keystone connect during an active restore: unresponsive OK, then late success `[app+SDK]`
Repro: restore Zodl wallet; while restoring, add Keystone (older birthday) — scan works,
account selectable, Connect works, but the confirmation screen's OK does "nothing" through
several clicks/waits, then finally pushes the green "keystone connected" success screen.
**Triage (hypothesis to verify):** `importAccount` writes through the shared `data.db` while
the restore pass holds write transactions — the import write waits on the SQLite lock until a
pass boundary (busy-wait), and the SDK's `importAccount` also restarts the sync pass. So the
protection is likely CORRECT (no bug), but the await lands seconds-to-minutes later with zero
UI feedback.
**Lukas's framing:** decide the contract first — if importAccount can't complete until restore
finishes, the UX should gate connecting Keystone until restore is done; if it can complete,
show progress/spinner state on OK instead of a dead button.
**Owner note:** needs SDK/engine-level answer (where exactly it blocks) before choosing the
UX. Post-E-4 the synchronizer is an actor — verify the OK-tap handler isn't also queueing
behind poll ticks (actor reentrancy should prevent that, but confirm).

## B4-5 · Spendable component spinner on every Send visit; QA saw 14–30 s `[app+SDK]`
Every entry to Send (and Send→Pay→Send churn) re-renders the spendable component with a
spinner that resolves in <1 s for Lukas, but Harry reported 14–30 s.
**Triage (hypothesis to verify):** the spendable resolution likely awaits a NETWORK call —
`latestHeight()` (gRPC `latestBlockHeight`) is the prime suspect; 14–30 s matches a gRPC
timeout/retry against an unreachable/slow server, which would explain Harry vs Lukas.
**Answer to the embedded question:** yes, spendability CAN resolve offline — balances +
spendable come from the DB/state stream (`getAccountsBalances` is DB-only outside recovery);
only tip-freshness needs the network and must not gate the display. Fix shape: render from
`latestState` immediately (no spinner unless truly no data), refresh network-dependent bits in
the background.

## B4-6 · Address book: chain icon circle clipped on the last row `[app]`
Rows start with token+chain icons (chain = smaller offset circle); the last row clips the
circle — list clips to frame with no bottom padding.
**Triage:** add bottom content inset / disable clipping on the list container; cosmetic.

## B4-7 · Near Intents success/pending: "Check status" and "View transaction" both shown `[app]`
Both CTAs render at once; they are mutually exclusive.
**Lukas's rule: when Check status is present, View transaction must be hidden.**

## B4-8 · Swap form amount field: value loses top padding on macOS `[app]`
Placeholder "0.00" is fixed (Opus's patch), but an entered value ("1") jumps to the top again.
**Lukas's direction: proper fix; DROP the placeholder-only patch.**
**Triage:** native macOS TextField vertical alignment in the styled container — fix the
field's vertical centering for all content states, not per-state.

## B4-9 · Swap amount field: 1-frame system bubble flash on focus `[app]`
On form appear + autofocus, a system bubble (empty) renders for ~1 frame and vanishes.
**Triage:** AppKit text-input suggestion/inline-prediction UI firing on focus. Prevent it from
appearing at all (disable automatic text completion / inline predictions on that field —
`.autocorrectionDisabled` equivalent for AppKit-backed field, `NSTextInputTraits`-level).

## B4-10 · SmartBanner (currency conversion) doesn't dismiss after enabling via Settings `[app] [class: split-view stale gate]`
Banner offers currency conversion; user enables it in Settings instead; banner stays open.
**Lukas's read (correct per prior diagnosis):** iOS pops back to Home → `.onAppear` re-derives;
macOS keeps the banner host always-visible → nothing re-fires. Same class as the fixed
currency-conversion-via-Settings gate (poke from Root reducer, commit `6f731bc7`).
**Triage:** on the Settings enable action, poke the SmartBanner store to re-evaluate/dismiss.
**Sweep the class:** Lukas flags Tor setup as the same likely case — check every SmartBanner
whose precondition can be satisfied from Settings.

## B4-11 · Keystone 5% advert (account-switcher MacCard) → browser never opens `[app] [class: present-after-MacCard trap]`
Click on the Keystone-sale banner inside the account-switcher MacCard does nothing.
**This is the PARKED keystone-banner-browser issue resurfacing** (structural: presentations
won't present over/after the MacCard overlay; timing already ruled out).
**Triage — two paths:**
(a) pragmatic Beta4 fix: on macOS open the hardcoded Keystone URL in the DEFAULT browser
(`NSWorkspace.shared.open`) — arguably better desktop UX than an in-app browser, ships now;
(b) structural: F-2(a) adjudication (native `.sheet` after MacCard) retires the whole trap
class. Recommend (a) for Beta4, (b) stays on the Foundations track.

---

## Suggested attack order
1. Known-pattern quick wins: **B4-10** (poke pattern exists) · **B4-7** (CTA logic) ·
   **B4-6** (padding) · **B4-2** (disabled memo height) · **B4-11(a)** (external browser).
2. Wiring/UI: **B4-1** (progress overlay) · **B4-8 + B4-9** (macOS text-field behaviors —
   fiddly, do together).
3. Navigation design (decided): **B4-3** reset-to-root on account switch.
4. Investigation-first (SDK/engine lane): **B4-4** (import-during-restore contract) ·
   **B4-5** (offline spendable + Harry's 14–30 s network stall).

## B4-13 · App Review Guideline 4 (external testing): no menu item to reopen the closed main window
**FIXED `f8970b6d`.** `WindowGroup("")` → `Window("Zodl", id: "main")` — the single-window scene
adds a persistent "Zodl" reopen item to the Window menu (MacMenuSimplifier keeps that menu);
Dock click reopens too. Keep-running behavior preserved (sync pauses on close via
scenePhase.background, resumes on reopen); NSWindow title blanked in FixedWindowConfigurator so
the "← Zodl" nav-fallback fix stays. ALTERNATIVE (if closed-means-quit is preferred): 3-line
NSApplicationDelegateAdaptor with `applicationShouldTerminateAfterLastWindowClosed = true` —
Apple sanctions either. Verify: close → Window menu → Zodl reopens; startup pops still gone.

## B4-14 · Swap/Pay auto-status loop dies on one dropped request (row stuck "Paying…")
**FIXED.** Field case: crosspay deposit mined (17 confs, amounts correct — 57,557 ≥ minAmountIn
56,405), Near reported FAILED at 13:35Z, row stayed "Paying…". The RootSwaps status fetch was
`try?` with NO failure branch: a single network/Tor blip left `autoUpdateCandidate` occupied
forever → every later poll bailed on its guard without rescheduling → metadata frozen pending
for the whole session. Fix: `autoUpdateSwapStatusFetchFailed` releases the slot + re-arms the
loop (existing 5–15 s pacing). The FAILED mapping itself was always correct ("Payment failed",
warning styling). Related, still open: Near-side refund for the failed swap (fee 47,000 zats,
deadline 2026-07-05) should arrive as a receive — user-watch item, not an app bug.

---

# ROUND 2 — Lukas's post-first-build findings (2026-07-02, his numbering 12–17)

## B4-14 (STILL OPEN after fix): row still "Paying…", status still pending
User read: "Near API either doesn't return status or doesn't fire the request." Two hypotheses
to instrument: (a) the in-app Near status transport fails silently (if it routes via
Tor/swapAPIAccess and the Tor client is unhealthy, every request throws → try? → endless polite
retries, never a flip); (b) the candidate's `address` used for the lookup isn't the DEPOSIT
address the API keys on. NEXT: read SwapAndPayClient.status transport + add a visible log of
(address, result/error) per poll.

## B4-15 (his 12) · Custom slippage % label is white `[app]`
The custom-slippage input's label/value renders white (unreadable). Suspect the macOS
FocusableTextField/label styling in SwapComponents (slippage sheet).

## B4-16 (his 13) · Disconnect Keystone while it's restoring → error + "try again" `[app+SDK]`
deleteAccount during an active restore pass — same shared-data.db write-contention family as
B4-12 (the engine's busy_timeout fix may already help; deleteAccount goes through the Swift-side
DBActor connection, which needs the same wait-not-die posture). Decide contract: allow (wait +
spinner) or gate disconnect while that account is recovering.

## B4-17 (his 14) · Shielding SmartBanner for KS survives KS disconnect `[app] [class: stale gate]`
Waited for 100% KS restore → shielding banner appeared → disconnected KS → banner stayed.
Account removal must re-evaluate/dismiss account-scoped banners (same poke pattern as B4-10;
sweep: any banner keyed to an account must dismiss on that account's removal/switch).

## B4-18 (his 15) · Add-HW-wallet: "Restoring" state not rendered at all `[app+SDK]` — ENGINE-LANE
First add: no restoring UI, 0 balance, 0 txs. Disconnect+reconnect: restore clearly RUNNING
(balance>0, tx count>0) but the restoring SmartBanner still missing. Suspects: (a) Zodl's
restoring banner derives from walletStatus/isRecovering — check it consumes
SynchronizerState.isRecovering post-import (the engine flag flips on the first suggest round
after the import-restart); (b) the first-add path may have hit the pre-B4-12 wedge (pass died →
no recovery state at all). Re-test on the busy_timeout build FIRST, then instrument
isRecovering through the import path.

## B4-19 (his 16) · Check status → detail (x) lands back in Swap/Pay, not Activity `[app]`
The single-view transaction detail opened from "Check status" closes back to the split view but
stays on the Swap/Pay section. Expected: land on Activity. Pattern exists —
`macRedirectToActivityAfterClose` (used by Result-screen closes); set it on this close path too.

## B4-20 (his 17) · REGRESSION: back arrow renders a trailing "Zodl" label again `[app]`
Cause: B4-13 set the SCENE title to "Zodl" (for the Window-menu reopen item); SwiftUI
RE-ASSERTS the scene title onto the NSWindow on navigation pushes, so the one-time
`window.title = ""` blank doesn't stick → the nav-fallback "Zodl" is back next to every back
arrow. FIX: scene title back to "" + rename the (then blank) persistent Window-menu item to
"Zodl" post-hoc in MacMenuSimplifier (it already rewrites menus), keeping
`NSApp.changeWindowsItem` for the live/minimized entry. Guideline-4 compliance preserved,
title bar permanently blank again.
