# macOS Foundations Review — is the platform layer sound, stable, extensible?
**Commissioned 2026-07-01 by Lukas. Status: F-1 COMPLETE (2026-07-02) → verdicts in
`FOUNDATIONS_F1_VERDICTS.md` (incl. one NEW latent bug: MacCard single-slot invariant unenforced).
Next: F-2 sandbox adjudications (a/b/c) — needs Lukas's eyeball loop; F-3 hardening can start on the
registry/windowMode design meanwhile.**

## Why (the brief)
Zodl macOS is a native Mac app built by porting the iOS codebase under real trade-off pressure:
NavigationSplitView with hand-rolled rules (#1-#11), a custom MacCard overlay instead of native
sheets, AppKit-poking (FixedSidebarWidth), a blank-frame section-switch to dodge a SwiftUI crash,
full-window takeovers for path/binding flows. It works — the 2026-07-01 audit found the *port* clean
(no new platform gaps). But "works today" ≠ "foundation": Lukas needs to know which pieces are sound
architecture to build years on, which are load-bearing workarounds that will break on a macOS
update, and which (MacCard: "maybe yes, maybe no") deserve a real verdict. Goal: reliable, stable,
easy to extend.

## Review criteria (every component judged on all four)
1. **OS-update fragility** — does it poke private/incidental AppKit/SwiftUI behavior that a macOS
   release can silently change?
2. **Idiomatic alternative** — does macOS 15/26 now offer a native way (the app already requires
   modern macOS: glassEffect, ToolbarSpacer)?
3. **Extension cost** — what does adding the NEXT feature cost, and can a mistake ship silently?
   (The Keystone-popover bug is the archetype: a new iOS flow compiled fine and was invisible on Mac.)
4. **Accessibility & platform citizenship** — VoiceOver, focus order, full keyboard access, ESC/⌘W
   semantics, window restoration — the things Mac users and App Review notice.

## Components under review (the foundation inventory)
- **A. Navigation shell** — MacSplitView: peer-root sections via `Group{switch}.id(section)`, the
  three-phase blank-frame switch (dodges `comparisonTypeMismatch` try! crash), `macResetSectionPaths`
  pop-before-switch, full-window takeovers (path-driven + the new binding-driven Keystone case),
  RULE #9/#10 sidebar collapse. Questions: is the blank-frame a stable contract or a race we won?
  Should takeovers unify into ONE declarative "window mode" enum instead of scattered conditions?
- **B. FixedSidebarWidth** — NSViewRepresentable that walks the responder chain to pin
  NSSplitViewItem min==max, purges autosaved widths, re-pins with retries. THE most fragile piece by
  construction (private view hierarchy, async retry loop, already caused the startup-pop bug).
  Candidates: SwiftUI-only hard min/ideal/max (partially done), or accept + isolate behind a single
  tested seam with a canary UI test.
- **C. MacCard / MacCardCoordinator** — the global overlay presenter replacing native sheets
  (`.zashiSheet`/`.zashiSelectorSheet` reroute; ~40 sites, zero-churn; WithPerceptionTracking
  centralized; ESC works). The "maybe yes, maybe no" verdict, judged honestly:
  PRO: stacking (native sheets can't), whole-window dim, one adoption point, glass styling.
  CON: outside native presentation = no free focus trapping, VoiceOver containment, dismissal
  semantics; and the PROVEN interop trap — a native `.sheet` won't present after/near a MacCard
  (Keystone-browser bug, still parked). Decision inputs: min-OS is modern → native `.sheet` +
  `.presentationSizing(.fitted)` is viable for NON-stacked cases. Likely outcome (to validate, not
  assume): keep MacCard for stacked/dynamic cards, define a hard CONTRACT (what may present from
  where), and route single non-stacked modals native — eliminating the interop trap class.
- **D. The platform-gap CLASS** — binding/flow presenters must be wired twice (iOS branch + Mac).
  The audit proved the failure mode ships silently. Candidates: a single presentation REGISTRY
  (all Root-level flows declared once; both platforms render from the table) — the structural fix;
  plus a cheap CI guard (grep: `.popover(`/`.sheet(`/`.fullScreenCover(` inside `#if os(iOS)`/`#else`
  without a paired macOS presenter) as the tripwire either way.
- **E. Design.Mac constants & rules #1-#11** — are the numbers (sidebarWidth 240, viewCapWidth 530,
  maxButtonWidth 260, cardMaxWidth 364, window 900×720) a coherent system (grid/scale) or frozen
  happenstance? Do the rules compose for the NEXT surface (Settings subpanes, multiwindow, iPad
  inheriting)? Output: DESIGN_LANGUAGE.md updated from "rules discovered" to "system specified".
- **F. Lifecycle semantics** — the onAppear-refire class (pcztForUI wipe; split-view stale gates,
  both already bitten): define ONE documented idiom for "load-once vs re-derive-on-show" state on
  macOS, and sweep current uses against it.
- **G. Accessibility & keyboard pass** — MacCard focus/VoiceOver behavior, ESC/⌘W consistency,
  full-keyboard-access through the sidebar + cards, dynamic type. Currently unverified anywhere.
- **H. Window & scene** — single-window assumption, restoration, Stage Manager behavior, the
  startup-pop family (splash → toolbar leak fix) — codify what the window contract IS.

## Method & phases (evidence over vibes; sandbox before wallet)
- **F-1 Inventory + fragility map (inline, cheap).** Walk A-H against the four criteria using the
  existing docs (DESIGN_LANGUAGE.md, LAYOUT_FOUNDATION.md, MODALS.md) + code. Output: verdict table
  — KEEP / HARDEN (add contract+test) / REPLACE (native path exists) per component, each with
  evidence. No code changes.
- **F-2 Sandbox adjudications (~/Downloads/testApp).** The 2-3 genuinely open calls get prototypes,
  not opinions: (a) native `.sheet(.fitted)` vs MacCard for single modals incl. the after-MacCard
  interop trap; (b) SwiftUI-only sidebar pinning vs FixedSidebarWidth on current macOS; (c) section
  switching without the blank frame (does the crash still reproduce on current SwiftUI?). Lukas
  eyeballs each (his existing loop: sandbox → visual confirm → codify).
- **F-3 Foundation hardening wave.** Implement the KEEP-contracts and HARDEN items: the presentation
  registry (or CI tripwire), the lifecycle idiom + sweep, MacCard contract in MODALS.md, canary
  tests for the fragile seams. REPLACE items land one-per-commit with device verification.
- **F-4 A11y/keyboard pass (G)** — audit + fixes; small, self-contained.
- **F-5 Codify.** DESIGN_LANGUAGE.md v2: the system as specified, each rule with its WHY, its test,
  and its extension recipe ("adding a new section/flow/modal = these 3 steps") — the "easy to
  extend" deliverable.

## Constraints
- Rule #11 stands: never break iOS; iPad branch inherits later (known un-gating conflict, separate).
- Device validation is Lukas's (I can't run the app); sandbox prototypes are structured so a look
  answers each question.
- Uncommitted work (5 Keystone fixes + fix wave) lands FIRST — review a clean baseline.
- Cost: F-1 is inline reading; F-2 is small throwaway code; no agent fan-out anywhere.

## Out of scope
Engine/SDK boundary (see ZcashLightClientKit `docs/slipstream/plans/2026-07-01-engine-sdk-boundary-review.md`);
feature work; iPad reconciliation.
