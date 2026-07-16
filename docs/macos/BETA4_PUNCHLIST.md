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
- B4-8 SwapForm (round 4 — ROOT CAUSE, rig-verified): SwiftUI's macOS TextField cell runs in
  `usesSingleLineMode`, whose fixed-baseline EDITING layout uses default-system-font metrics —
  typed Inter@24 lands in a 16.0pt line box (exactly 13pt-system line height): top-clipped,
  rides high, snaps right on blur ("2 Y positions"). Sub-pixel at 14pt (16≈17) ⇒ every other
  field in the app looks fine. macOS now renders `MacAmountTextField` (NSViewRepresentable,
  `usesSingleLineMode=false`) at both swap-field sites; iOS chain untouched. Rounds 1–3 were
  symptom-level and are superseded — details in the B4-8 section below.
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

**RESOLVED (round 4, 2026-07-02) — root cause found via isolated AppKit rig** (6 field variants,
programmatic focus/typing, bitmap captures + NSLayoutManager measurements):
`NSTextFieldCell.usesSingleLineMode` — which SwiftUI's macOS TextField enables with no opt-out —
lays EDITING text on a fixed baseline computed from default-system-font metrics. With the
process-registered Inter at 24pt, the typed line gets a 16.0pt box (exactly the 13pt-system line
height) while glyphs draw at 24pt into it: top-clipped and riding high while editing; the static
cell draw uses correct metrics (29pt) ⇒ the focus-dependent jump Lukas described as "2 Y
positions". Measured facts: paragraph-style min/max line-height pins are IGNORED in that mode
(pin present on the run, layout still 16.0); `.plain` vs bezeled, frames, and trailing-alignment
are all irrelevant (each isolated); the bug reproduces in pure AppKit (not SwiftUI); the system
font is immune (its metrics ARE the defaults the fixed-baseline path uses); at 14pt broken ≈
correct (16 vs 17) ⇒ ZashiTextField et al. unaffected in practice (latent ~1pt). Lukas's
font-size hunch was exactly right. Bonus finding: the default (non-`.plain`) style also draws a
37pt bezel that ignores the 32pt frame. FIX: `MacAmountTextField` (NSViewRepresentable:
`usesSingleLineMode=false`, `wraps=false` + `isScrollable=true`, right-aligned, native
right-aligned placeholder, Writing Tools disabled in-editor for B4-9 parity) swapped in at both
SwapForm sites macOS-only; iOS chain untouched; Opus's focus-conditional prompt dropped
(constant placeholder restored on iOS).

**Round 4.1 (field feedback, 2026-07-02):** two ergonomics amendments to MacAmountTextField —
(1) the placeholder dismisses while focused and returns on blur (and the iOS focus-conditional
prompt is RESTORED — it was the branch's shipped behavior, not part of the Opus overlay patch);
(2) acquiring focus places the caret at the END of the value: the text is right-aligned in a
full-width field, so clicks land in the empty area LEFT of the glyphs and AppKit snapped the
caret to the string start ("|122", then typing 3 made "3122"). Applied on the next runloop turn
so it wins over the click's own caret placement; clicks while ALREADY focused reposition
normally, so mid-value edits stay possible.

**Round 5 (2026-07-03, RC blocker — placeholder still visible + caret on the LEFT of the
empty trailing field):** both round-4.1 mechanisms misfired for identifiable AppKit reasons.
(1) `becomeFirstResponder` nil'd `placeholderAttributedString` but never triggered a repaint —
a borderless, focus-ring-less field gets no redraw from the focus change itself, so the stale
placeholder pixels stayed on screen; fix = `needsDisplay = true` on both the dismiss and the
blur-restore. (2) An EMPTY field editor (`NSTextView`) draws its insertion point from
`typingAttributes`, NOT from the field's `alignment` (which only reaches the editor's storage
once text exists) — unconfigured, the caret blinked at the LEFT edge with 13pt-system metrics
(short caret, high baseline = the "wrong baseline"), jumping right on the first typed char;
fix = `configureFieldEditor()` at focus: right-aligned `defaultParagraphStyle` + the real
Inter font + color into `typingAttributes` → caret at the RIGHT edge with correct height and
baseline from the first frame. (3) The `asyncAfter(0.1)` autofocus could silently no-op when
the field wasn't in a window yet (leaving all round-4.1 fixes never running) → autofocus now
fires from `viewDidMoveToWindow`. Native `NSTextField` throughout — no third-party component
needed; the whole class of problems was the unconfigured field editor. Build green; needs
Lukas's visual pass (fallback if any residue: 3-variant testApp rig with responder/attribute
instrumentation, the proven B4-8 method).

**Round 5.1 (2026-07-04, device feedback on round 5):** caret-at-tap-position DROPPED as an
issue (iOS parity — Lukas's call; caret code left untouched). The one remaining defect —
placeholder visible for the whole focused-empty session — root-caused to `updateNSView`:
round 5 DID nil the placeholder on focus, but SwiftUI re-runs `updateNSView` around
appearance/store changes and its `currentEditor() == nil` guard raced focus acquisition (the
field editor can install a beat AFTER `becomeFirstResponder`), resurrecting the placeholder;
once resurrected nothing re-dismissed it (becomeFirstResponder won't re-fire on a focused
field). Fix = an explicit `isEditingSession` boolean owned by the field (TRUE in
`becomeFirstResponder`, FALSE in `textDidEndEditing`) + ONE gated write path
(`setIdlePlaceholder`) that `updateNSView` must use — `placeholderAttributedString` is never
poked directly from SwiftUI anymore. Localized placeholder ("0.00"/"0,00") preserved — it
flows from `store.localePlaceholder` unchanged. Build green; awaiting visual confirm.

**Round 5.2 (2026-07-04, Lukas's `__LD` device log = the decisive evidence):** the 5.1 session
flag desynced because the responder CALLBACKS lie about the net state in the SwiftUI-hosted
window: `becomeFirstResponder` → transient `textDidEndEditing` (hosting-view focus
arbitration bounces the responder) → focus lands back on the FIELD EDITOR with no new
`becomeFirstResponder` → flag ends FALSE while visibly focused (log: become(true) →
end(false)). Fix = never TRACK, always ASK: `isEffectivelyFocused` reads the live responder
truth (window.firstResponder === field, or a field editor whose delegate === field) and
`refreshPlaceholderVisibility()` re-derives the placeholder from it ONE RUNLOOP TURN after
every responder event — become does an optimistic hide now + truth later; textDidEndEditing
does NO synchronous restore (it fires as a transient during the bounce), only the deferred
truth check: genuinely blurred ⇒ "0.00" returns; still focused ⇒ stays hidden. Event order
can no longer strand either state. Temp `__LD` prints removed (diagnosis served; SwiftLint
bans print). **CONFIRMED WORKING on device (Lukas, 2026-07-04) — B4-8 CLOSED; the last
Beta4/RC1 blocker.** Component rule reaffirmed for the design language: on macOS, any
focus-conditional UI inside an NSViewRepresentable must derive from the LIVE responder
chain, never from become/end event tracking (the hosting view bounces the responder).
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
adds a persistent "Zodl" reopen item to the Window menu (MacMenuSimplifier keeps that menu).
CORRECTION (2026-07-16, MOB-1486): "keep-running behavior preserved" was WRONG — a
single-`Window` app quits when its window closes (documented SwiftUI behavior), so the scene
swap silently delivered the ALTERNATIVE below. Closed-means-quit is verified and DELIBERATELY
KEPT: platform convention for single-window apps, and it kills the security-audit finding of a
typed recovery phrase surviving close→reopen (real on the pre-swap `WindowGroup` builds the
auditors tested). NSWindow title blanked in FixedWindowConfigurator so the "← Zodl" nav-fallback
fix stays. (Original alternative, now the actual behavior with zero code:
`applicationShouldTerminateAfterLastWindowClosed = true` — Apple sanctions either.)
Verify: close → app quits (no Dock dot); relaunch starts clean; startup pops still gone.

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

**RESOLVED (2026-07-02) — unblocked by the B4-8 rig findings.** The macOS `FocusableTextField`
was a DEFAULT-styled bare `TextField`, which on macOS means two system defaults leak through:
(1) the default style draws a bezel + its own background box inside the switcher pill (the rig
measured this: `bezel=true`, ignores the proposed frame); (2) the placeholder was passed as the
TextField TITLE, which renders in the SYSTEM placeholder color — white-ish in dark mode — no
foreground modifier reaches it. That unstyled "%" is the white label. (The typed value itself
was already tinted — `zFont(color:)` → `.foregroundColor`.) FIX: `.textFieldStyle(.plain)` +
explicitly styled `prompt:` (Inter medium 16, `Switcher.selectedText`, matching iOS's
`attributedPlaceholder`) + an `@FocusState` bridge for the `isFirstResponder` binding so the
auto-focus on selecting the Custom chip now works on macOS too. Residual (watch on device): at
16pt the B4-8 single-line-mode metric quirk is ~4pt (20 vs 16 box) — if a small edit-time jump
is visible on this field, extend `MacAmountTextField` with alignment/size params and swap it in.
NOTE: Lukas's "still white" re-report (2026-07-02) came from a build cut BEFORE `5426df58`
(that build had B4-8/B4-21 but not this fix) — re-verify on the next build before reopening.
**Round 2 (screenshot, 2026-07-02):** the shot confirmed BOTH already-fixed layers (grey box in
the pill = the default-style bezel; white "%" = system placeholder color) AND exposed one more:
the caret renders CROSSING the centered "%" glyph while focused-empty — even a correctly-dark
placeholder looks broken under the caret. Fix: the prompt now dismisses while focused (the
`@FocusState` bridge made it a one-line conditional), mirroring the amount field's round-4.1
behavior.

## B4-16 (his 13) · Disconnect Keystone while it's restoring → error + "try again" `[app+SDK]`
**ROOT-CAUSED + FIXED SDK-side 2026-07-03 (device log confirmed the failure verbatim:
`write-behind deferred put_blocks [2740001..=2750000]: The account with the given ID does not
belong to this wallet`).** THREE stacked causes: (1) `SlipstreamSynchronizer.deleteAccount` was
a raw pass-through — no engine serialization (importAccount got it in `5ee74ee8`) — so the
in-flight range kept scanning with the per-range façade's CACHED copy of the deleted Keystone
viewing key and `put_blocks` then wrote its notes for a vanished account → non-transient pass
error; (2) upstream `delete_account` never touches `scan_queue`, so the deep-birthday import's
Historic ranges survived → the wallet ground a phantom deep restore for keys that no longer
exist; (3) a non-transient pass failure KILLED the session permanently (`run_session` returned;
nothing restarts it — the B4-12 follow-up "a dead pass never auto-restarts", promoted to
must-fix) → app relaunch was the only recovery. FIXES (SDK `slipstream` branch, crates 0.3.6):
deleteAccount now serializes (engine.stop → delete → `notifyTxChange` so Activity drops the
dead rows → restart); new engine `scan_queue.rs` prune drops orphaned Historic ranges at EVERY
session open (wedged wallets heal at launch, an in-app delete heals immediately); ALL FFI
wallet-DB connections + the persist lane got the B4-12 wait-not-die 15 s busy_timeout; and the
session now REVIVES after non-transient failures (capped backoff 15 s→5 min — error still
surfaced, sync self-resumes). **Contract decision: ALLOW disconnect during restore** (wait +
existing spinner) — gating it would punish exactly the add-wrong-birthday → remove → re-add
flow. Re-test: add KS (old birthday) → restore starts → disconnect immediately → no error (or
one dialog + self-resume ≤30 s), banner clears if only the KS was recovering, Activity drops KS
rows ≤1 tick, no background deep-scan grind after disconnect. Zodl-side: NO code change needed.

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

## B4-14 — ROOT CAUSE CONFIRMED (found by Lukas): status-parser missed terminal cases
Tor was OFF (transport hypothesis refuted — requests fired and returned fine). The from-ZEC/
crosspay branch of Near1Click's status switch was MISSING `FAILED` → fell to `default:
.pending` → the flip gate (`!status.isPending`) could never fire → "Paying…" forever, detail
screen agreeing. Lukas added `failed` to the else branch; completion of the class: `EXPIRED`
was missing from BOTH branches (same forever-pending failure), `processing` added to the else
for parity. Earlier loop-death fix (`56a9ca3b`) stands as adjacent hardening (a dropped request
really did kill the loop permanently). Re-test: relaunch → the stuck row must flip to
"Payment failed" on the first poll.

---

# ROUND 3 — (2026-07-02, his numbering continues)

## B4-21 (his 18) · Activity filter icon resets to outline after a section round-trip `[app] [class: peer-root reset]`
Filled filter icon (= active filters) reverts to not-filled after switching to Send/Receive and
back to Activity.
**ROOT CAUSE (code-confirmed):** macOS section re-entry funnels through
`.home(.seeAllTransactionsTapped)` → RootCoordinator sets `transactionsCoordFlowState = .initial`
(the peer-root "fresh section" semantics). The FILTERS (and search term) are wiped with the rest
of the flow state — the icon is honest; the whole filter state died, not just the glyph. iOS is
unaffected (there the action means a genuine fresh "See all" visit from Home).
**FIX (v1, reverted):** carried `activeFilters` + `searchTerm` across the reset.
**PRODUCT DECISION (2026-07-02, supersedes v1):** full reset is INTENDED — filters/search live
only while the user stays on Activity; leaving to Send/Receive and back = clean unfiltered
Activity (outline icon AND full content). The carry-over was reverted; the original
`state.transactionsCoordFlowState = .initial` stands, now with a comment recording the decision
so the "bug" isn't re-fixed later. Within-section navigation (tx detail push/pop) never fires
this action, so filters DO survive while working inside Activity — which is the intended scope.

## B4-23 · Sidebar selection color: custom rows replace the native List (Lukas's direction)
The native sidebar selection is AppKit-owned — accent blue when focused, grey when the sidebar
loses focus, and the highlight draws ON TOP of any row background, which is why every earlier
tint attempt failed. Lukas's call (correct): stop tinting the native selection; disable it and
draw our own. Implemented: the sidebar `List` is GONE — `ScrollView` + custom Button rows
(7 fixed rows never needed a List). Selection = plain view state: a rounded-rect pill in the
app's canonical selected pair (`Switcher.selectedBg`/`selectedText` — guaranteed contrast,
themed both schemes, focus-INDEPENDENT) + a subtle hover wash; the crash-fix switching path
(`selectSection`) is reused verbatim; RULE #4 width machinery untouched; rows still scroll on
overflow. Restyle point = the two `isSelected ?` branches in `sidebarRow`. Accepted trade-off:
List's arrow-key row navigation is gone (nothing relied on it).

## FINDING · SwiftUI `prompt:` foreground styling is IGNORED on macOS (rig-proven, 4th AppKit-input trap)
A styled prompt (`Text(...).foregroundColor(near-black)`) still renders in the SYSTEM
placeholder color (white-ish in dark mode) — pixel-proven in the isolated rig. Consequence:
B4-15's white "%" was NEVER fixable via `prompt:`; `5426df58` fixed the bezel + focus but not
the color. REAL fix (held while Lukas is in these files): route the slippage field through
`MacAmountTextField` (add alignment/fontSize/color params) — its AppKit
`placeholderAttributedString` renders colors correctly, and it brings dismiss-on-focus +
caret-to-end + the single-line-mode fix along. Rule extended: styled placeholders on macOS
require the AppKit path, never `prompt:`. ALSO rig-proven the same run: round-4.1 caret-to-end
mechanics WORK in isolation (click left of "122", type "3" → "1223") — if the app still
prepends on a ≥`80c322ba` build, instrument the in-app focus path.

## B4-22 · Slippage warning box (red) not full-width in the MacCard `[app]`
Screenshot-confirmed: the "<2% slippage" warning box hugs its wrapped text and falls short of
the card's content width. Cause: the sibling info box above it has an explicit
`.frame(maxWidth: .infinity, alignment: .leading)`; the warning box never got one — iOS masks
it because the narrow sheet makes the wrapped text fill the width anyway. FIX: same frame
added (cross-platform; on iOS it's a no-op-to-improvement, matching the sibling box).

## B4-24 · Keystone "Keep Zodl open" OK: dead-feeling button while the import runs `[app] [class: B4-4]`
Field (Lukas, 2026-07-04): connecting a Keystone as an ACTIVE device (older birthday) lands on
the "Keep Zodl open" screen (`RestoreInfoView`); its OK triggered the import on the FIRST click
(coordinator forwards `gotItTapped` → `keystoneDeviceReady(.unlockTapped)` → the B4-4
`isImportInFlight` guard swallows repeats — extra clicks were harmless no-ops), but the button
bound to NOTHING visually: the in-flight flag lives on the `keystoneDeviceReady` element while
the user looks at `restoreInfo`. The wait also grew to seconds this week (import now = engine
stop → drain → anchor fetch → import → restart), so it read as a broken screen. FIX (same
recipe as B4-4's "Connect new" spinner): `RestoreInfo.State.isProcessing` (owned by the
coordinator — set when forwarding `gotItTapped` in the KS flow, cleared on
`accountImportFailed`; success navigates away) + `RestoreInfoView` swaps OK for the
spinner-accessory no-op button while processing. Cross-platform improvement (iOS shares the
flow and the same wait); resync flow unaffected (navigates instantly on `resyncFinished`).
Both schemes built green. Awaiting visual confirm.

## B4-25 · Keystone SHIELDING sign flow: scanner maxWidth-capped `[app] [class: Rule #9 scan exemption]`
Field (Lukas, 2026-07-04): shielding with Keystone → the sign-flow scanner renders boxed to the
content column instead of full-window. Cause: `SignWithKeystoneCoordFlowView` was the ONLY
ScanView-hosting coord flow still applying a CAPPED flow background (`applyScreenBackground()`);
Send/SwapAndPay/AddKeystoneHWWallet all carry `capped: false` (Rule #9). FIX: same flip —
safe because the root `SignWithKeystoneView` applies its OWN capped background and every other
destination is the IDENTICAL set SendCoordFlow already hosts uncapped. macOS scheme green
(iOS unaffected — the cap is macOS-only). Awaiting visual confirm.

## B4-26 · "Shield funds" SmartBanner survives the Keystone shield flow `[app] [class: split-view stale gate]`
Field (Lukas, 2026-07-04, right after the first successful KS shield on macOS): shield via the
full-window sign flow → back to Activity → the banner still advertises shielding. FOURTH member
of the stale-gate class (B4-10 currency, Tor setup, B4-17 KS-disconnect): macOS Home never
re-fires onAppear, so banner state derived there goes stale after any full-window round-trip.
FIX (the established recipe): `RootCoordinator`'s sign-flow close handlers — the combined
success/failure/pending `closeTapped` case and the `transactionDetails(.closeDetailTapped)`
case — now also send `.home(.smartBanner(.closeAndCleanupBanner))`. Self-correcting per
outcome: success ⇒ re-evaluation drops the banner; failure ⇒ it legitimately re-opens. iOS
unaffected in practice (onAppear re-fires anyway; the poke is the same action the banner system
itself uses). macOS green. NOTE: the class keeps producing members — the structural kill
remains F-3's presentation-registry/declared-navigation-events design (foundations plan).

## B4-27 · macOS spinners: oversized + invisible-in-dark — consolidated into ZashiSpinner `[app] [class: consolidation]`
Field (Lukas, 2026-07-04, on B4-24's OK spinner): (1) invisible in dark mode — the CTA is
light and the spinner white-ish; (2) macOS `ProgressView()` in general renders the
REGULAR-size NSProgressIndicator (~20 pt) and "breaks the heights at almost all places" —
several sites had already hand-patched with `.scaleEffect(0.7/0.75)`, which shrinks PIXELS
but not the LAYOUT BOX (heights stayed broken). Root facts: the macOS system spinner
IGNORES SwiftUI tinting entirely (NSProgressIndicator-backed), and `.controlSize`/scale
patches were scattered per-site. FIX (house rule: consolidate): NEW
`UIComponents/ProgressViews/ZashiSpinner.swift` — iOS renders EXACTLY what each site
rendered before (bare `ProgressView` or `CircularProgressViewStyle(iosTint:)`; zero iPhone
change); macOS renders a small pure-SwiftUI ARC (14 pt layout box, honors color) with
`macTint: .auto` (adaptive secondary) / `.buttonAccessory` (Design.Btns.Primary.fg —
resolved via the component's OWN colorScheme, so call sites need none) / `.fixed(Color)`.
ALL 30 inline `ProgressView()` sites across 22 files swept onto it (button accessories →
`.buttonAccessory`; ServerSetup's scheme-aware helper → `.fixed`; existing
scaleEffect/frame modifiers preserved verbatim for iOS fidelity). RULE going forward:
never a bare `ProgressView()` in app code — always `ZashiSpinner`. Both schemes green.
Awaiting visual pass (spinner size 14 pt is the one tuning knob if it reads too small).

**B4-27 round 2 (2026-07-04, Lukas: "CTA bcg is sometimes light, sometimes dark"):** round 1's
`.buttonAccessory` hardcoded the PRIMARY button's label color — wrong on ghost/secondary/
disabled surfaces. Better than any inversion logic: ZashiButton ALREADY applies its per-type,
per-state label color to the whole label row (`.zForegroundColor(fgColor())` in its body), and
a `stroke(style:)` with no explicit color draws with the inherited foreground. So
`.buttonAccessory` now resolves to NIL tint = the arc inherits — the spinner is always exactly
the color of the title next to it, for all 8 button types, enabled AND disabled, both modes.
macOS green. Awaiting visual confirm.
