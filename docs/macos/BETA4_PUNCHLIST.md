# Beta4 punch list (macOS) — observed by Lukas, 2026-07-02

**Source: Lukas's device testing before Beta4 can ship. 11 items, numbered as reported.
Triage annotations = Claude's first-pass classification (verify before trusting).
Cross-refs: TRACKS.md (SDK repo) track 1 · FOUNDATIONS_F1_VERDICTS.md · MODALS.md.**

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
