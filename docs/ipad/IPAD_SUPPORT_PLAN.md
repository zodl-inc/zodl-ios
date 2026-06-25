# Zodl iPad — Support Plan

**Goal:** a first-class iPad layout, heavily inspired by Zodl Mac (`docs/macos/`), reached by *adapting*
the Mac split-view world to iPad rather than rebuilding it — sharing what's universal (the
`NavigationSplitView` structure, section switching, transaction-flow lock) and substituting iPad-native
pieces where Mac uses bespoke chrome (native `.sheet` instead of MacCard, native nav bar instead of the
liquid-glass window toolbar, an adaptive screen instead of a fixed 900×720 window).

Branch: `slipstream-ipad` (off `slipstream-macos`, so it carries the full Mac implementation as the
reference). Commit format `[#1755] slipstream: iPad — …`. Local-only; never push unless asked.

---

## Status (2026-06-25 — autonomous run)

| Phase | Status |
|---|---|
| iP-1 enable iPad + landscape | ✅ `52826d60` — `TARGETED_DEVICE_FAMILY "1,2"` on **all** app targets (not just testnet — it's a dev branch), iPad-only orientations |
| iP-2 IPadSplitView | ✅ `f6d78937` — split + #2a switching + path takeovers + sidebar/detail + root sheets |
| iP-3 native sheets | ✅ folded into iP-2 — free on iOS (`.zashiSheet` → native sheet; MacCard is Mac-only) |
| iP-4 Design.IPad sizing | 🟡 `dfd392b7` — namespace + sidebar wired; **content-cap NOT wired yet** |
| iP-5 broadcast/scan lock | ✅ folded into iP-2 — `isFullWindowFlow` + `columnVisibility=.detailOnly` |
| iP-6 polish / copy / design-language doc | ⬜ pending — needs iPad visual testing |
| iP-7 consolidate `MacSection`/`PadSection` | ⬜ pending |

**Next — needs eyes on an iPad sim:** run `zodl-testnet` on an iPad in regular width / landscape. The split
(sidebar + detail) should appear; verify section switching (no crash), the account-switch sheet, and scan +
a Send/Pay broadcast going full-screen (sidebar hidden). Then: iP-4 content-cap (generalize
`ScreenBackground`'s `macContentMaxWidth` for iPad-regular WITHOUT touching the iPhone full-bleed path),
iP-6 polish + an **iPad copy table** (device refs "phone"→"iPad" — reuse `MACOS_COPY_AUDIT.md` §1; "tap"
STAYS, iPad is touch), iP-7 consolidation. Builds green on iOS + macOS at every committed rung.

---

## Current state (verified 2026-06-25)

- **No iPad app target.** Every app config is `TARGETED_DEVICE_FAMILY = 1` (iPhone). Only `zodlTests` is
  `1,2`. So today the app runs in iPhone-compatibility (scaled) mode on iPad — greenfield.
- **No size-class / idiom branching anywhere.** One iOS layout for all iOS devices.
- **`RootView`** branches `#if os(macOS)` → `MacSplitView` ; `#else` → the existing iOS (iPhone) root.
- **`MacSplitView.swift` is entirely `#if os(macOS)`** (line 21–588) — not reusable as-is on iOS.

---

## Governing principle — Rule iP-0 (the iPad analog of macOS Rule #11)

**iPad work must NOT disrupt iPhone OR macOS.** Concretely:
- **iPhone stays byte-identical.** The new split layout is gated on **iPad idiom + regular width**
  (`UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular`). iPhones (always
  effectively compact for our purposes, incl. Plus-in-landscape) keep the existing root untouched.
- **macOS stays byte-identical.** iPad code lives in `#if os(iOS)` paths + size-class gates; it never
  edits a `#if os(macOS)` branch. Mac-only types (MacCard, FixedWindowConfigurator, FixedSidebarWidth,
  MacMenuSimplifier, FullAreaButtonStyle, liquid-glass toolbar, Design.Mac dims) are not touched.
- **Verify every phase by building all three:** `zodl-testnet` (iPhone sim), an **iPad sim**, and
  `zodlmac-internal` (macOS). iPhone + macOS must stay green and visually unchanged.

---

## Architecture — adaptive root

```
RootView
 ├─ #if os(macOS)  → MacSplitView                         (unchanged)
 └─ #else (iOS)
     └─ if isIPadRegular  → iPadSplitView   ← NEW          (regular width on iPad)
        else              → <existing iOS/iPhone root>     (unchanged: iPhone, iPad-compact/multitasking)
```

`isIPadRegular` is a small shared helper (idiom == .pad && horizontalSizeClass == .regular), observed via
`@Environment(\.horizontalSizeClass)` so it re-evaluates on rotation and Split-View/Slide-Over changes.
When an iPad drops to compact (Slide Over, narrow Split View), it falls back to the iPhone root — no
custom compact iPad layout in v1.

---

## Mac ↔ iPad merge map (the "two worlds")

| Concern | macOS (today) | **iPad regular (this plan)** | iPhone / iPad-compact |
|---|---|---|---|
| Container | `NavigationSplitView` (`MacSplitView`, fixed) | `NavigationSplitView` (adaptive) — **shared structure** | existing iOS root |
| Section nav | `Group{switch}.id` + 3-phase blank-then-reveal (#2a) | **same logic, shared** | n/a |
| Tx-flow lock | hide sidebar via `columnVisibility=.detailOnly` (#9/#10) | **same mechanism, shared** | full-screen already |
| Modals | **MacCard** custom overlay (`.zashiSheet`) | **native `.sheet`** | native `.sheet` |
| Chrome | liquid-glass window toolbar + traffic lights | **native iOS nav bar + `.toolbar`** | native nav bar |
| Window | fixed 900×720 (`FixedWindowConfigurator`) | **full screen, adaptive** | full screen |
| Sidebar | fixed-width pinned 240 (`FixedSidebarWidth`) | **native collapsible sidebar** (seed a width) | n/a |
| Sizing | `Design.Mac` (cap 530) | **`Design.iPad`** adaptive cap (likely wider) | full-bleed |
| Input | click (`FullAreaButtonStyle`) | **touch** (native button styles) | touch |
| Biometric | Touch ID | Face/Touch ID (existing) | existing |
| Copy | "Mac" / "click" | **"iPad"/"device" / "tap"** (see §Copy) | "iPhone" / "tap" |

**Shared (Mac + iPad):** split structure, the section enum + sidebar items, #2a switching, #9/#10 takeover,
the whole store/coordinator graph (already platform-neutral).
**iPad-specific:** native sheets, native chrome, adaptive sizing, the size-class root switch.
**Mac-only (never on iPad):** MacCard, fixed window/sidebar pinning, menu simplifier, traffic lights,
liquid glass, `Design.Mac` fixed numbers, the macOS share-panel / window code.

---

## Phases

Each phase is a green, committable rung. "Always-green" = build `zodl-testnet` (iPhone) + an iPad sim +
`zodlmac-internal` (macOS). Commit `[#1755] slipstream: iPad — <imperative>` per rung.

### Phase iP-1 — Enable iPad + adaptive-root scaffold (no visual change yet)
- Set `TARGETED_DEVICE_FAMILY = "1,2"` on the dev app target(s) (`zodl-testnet` first; later internal/prod).
- Confirm required iPad Info.plist keys: `UISupportedInterfaceOrientations~ipad` (allow landscape),
  `UIRequiresFullScreen` decision (leave multitasking ON → we must handle compact fallback).
- Add `Design.iPad` namespace (mirror of `Design.Mac`: `viewCapWidth`, `sidebarWidth`, `maxButtonWidth`)
  with iPad-tuned defaults; do not wire yet.
- Add the `isIPadRegular` environment helper + branch `RootView`'s iOS path to it, but point both branches
  at the existing iOS root for now (scaffold only — proves the gate compiles + iPhone unaffected).
- **Verify:** iPhone unchanged; iPad runs (still the iPhone layout); macOS unchanged.

### Phase iP-2 — `iPadSplitView` skeleton (sidebar + detail, native chrome)
- New `iPadSplitView.swift` (`#if os(iOS)`), structurally mirroring `MacSplitView`: a `NavigationSplitView`
  with the same sidebar sections (extract the section enum + sidebar-item list shared with Mac if not
  already shared; else duplicate minimally and note for later consolidation).
- Native chrome: standard nav bar/title, **no** traffic-lights/window-toolbar code, **no** FixedSidebarWidth
  pin (seed width via `.navigationSplitViewColumnWidth`).
- Wire `RootView` iPad-regular → `iPadSplitView`. Sections render their existing section views in the detail.
- Port the #2a section-switch logic (blank-then-reveal) — it's a SwiftUI reconcile fix, not Mac-specific,
  so it's needed on iPad too.
- **Verify:** iPad landscape shows sidebar + detail; section switching doesn't crash; iPhone + macOS green.

### Phase iP-3 — Modals: native sheets on iPad
- `.zashiSheet` / `.zashiSelectorSheet`: today macOS routes to MacCard, iOS already uses native `.sheet`.
  Confirm iPad (being iOS) already gets native sheets — likely **free**. Audit each `.zashiSheet` caller in
  the split context (account switch hosted in the split root, filters, voting, etc.) and confirm they
  present correctly over the iPad split (they should — native sheets are reliable on iPad, unlike macOS).
- The account-switch sheet that `MacSplitView` hosts at its root (because HomeView isn't in the macOS tree)
  — replicate that host in `iPadSplitView` so the iPad split also presents it.
- **Verify:** account switch, filters, selectors all open as native sheets on iPad; iPhone + macOS green.

### Phase iP-4 — Sizing + content caps (`Design.iPad`)
- Apply `Design.iPad.viewCapWidth` to the detail content (the Mac 530 cap is likely too narrow for iPad —
  pick a wider cap, or scale to the detail width). Reuse `applyScreenBackground`'s cap mechanism but
  source the iPad number (generalize `macContentMaxWidth` → a size-class-aware cap, or an iPad sibling).
- Button cap (`Design.iPad.maxButtonWidth`) — touch-appropriate; likely wider than Mac's 260.
- Sidebar width tuned for iPad.
- **Verify:** content centered + readable on iPad (not a stretched phone column, not a too-narrow Mac
  column); iPhone + macOS unchanged.

### Phase iP-5 — Transaction-flow full-screen takeover (Rule #9/#10 on iPad)
- Port the broadcast/scan lock: when scan or a Send/Pay/Swap broadcast is active, set
  `columnVisibility=.detailOnly` to hide the sidebar (same `isFullWindowFlow` / `isBroadcastLocked` logic
  as Mac). This is the exact fix just shipped for Mac — reuse the predicate.
- **Verify:** on iPad, scan + sending/result screens go full-screen (sidebar hidden) like Mac; restores on
  close; iPhone + macOS green.

### Phase iP-6 — Polish, parity sweep, copy
- Walk every section on iPad regular (Activity/Send/Pay/Swap/Receive/Vote/Settings): toolbar items,
  back buttons, onboarding hero (#8a equivalent — full-bleed on iPad too), scan (#9), modals.
- Fix the regression classes the Mac work catalogued (DESIGN_LANGUAGE.md): button widths, content caps,
  detached-modal perception (`WithPerceptionTracking`) — verify they hold on iPad.
- **Copy:** iPad inherits iOS copy. "tap" is correct on iPad (touch). Only the **device references** need
  iPad variants — reuse `MACOS_COPY_AUDIT.md` §1 with "iPad"/"device" instead of "Mac" (e.g.
  `restoreInfo.tip1` → "Keep Zodl open and your iPad awake"). Produce an iPad copy table for review.
- Write `docs/ipad/DESIGN_LANGUAGE.md` codifying the iPad rules + the merge map as the durable reference.
- **Verify:** full visual pass on iPad; all three platforms green.

### (Later, optional) Phase iP-7 — consolidation
- Once `iPadSplitView` and `MacSplitView` both work, extract the genuinely-shared core (section enum,
  sidebar items, #2a switching, #9/#10 predicate) into a platform-neutral `SplitFoundation` used by both,
  deleting the duplication. Do this only after both are proven — premature sharing risks the working Mac.

---

## Risks / open questions
- **Compact iPad fallback:** v1 falls back to the iPhone root in Slide Over / narrow Split View. Acceptable;
  a bespoke compact-iPad layout is out of scope for v1.
- **Sidebar collapse UX:** iPad's `NavigationSplitView` lets the user collapse the sidebar (unlike Mac's
  pinned one). Decide whether to allow it (probably yes — it's native iPad behavior) and ensure the
  full-screen takeover (#9/#10) still works alongside user-driven collapse.
- **Shared section source:** Phase iP-2 must determine whether the section enum / sidebar items are already
  in a platform-neutral file or live inside `MacSplitView`'s `#if os(macOS)`. If the latter, extract first.
- **Onboarding/launch:** the iPhone onboarding is full-bleed; confirm it reads well at iPad size (it may
  want the hero centered in a column like Mac #8a rather than edge-to-edge across a 13" iPad).
