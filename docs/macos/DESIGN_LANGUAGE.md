# Zodl Mac — Design Language

The single home for Zodl's macOS design system. **Philosophy: define the system BEFORE extensive UI
work, then only follow the rules.** Each rule is derived hands-on in the throwaway sandbox
`~/Downloads/testApp`, confirmed visually on macOS 26, then set in stone here. New macOS work *follows*
the rules; it does not re-litigate them. This is what lets the app scale without re-deciding chrome,
navigation, sizing, or modality on every screen.

> Read this first for any macOS UI work, then the detailed chapter for the rule you're touching.

> **Rule #11 governs everything below: macOS work must NEVER disrupt iOS.** Every change is
> `#if os(macOS)`-guarded or provably iOS-neutral; iOS Zodl stays exactly as-is. See Rule #11.

## The rules

### Layout & chrome — Rules #1–#4 → [`LAYOUT_FOUNDATION.md`](LAYOUT_FOUNDATION.md)
Container is the native `NavigationSplitView` (never a manual HStack, never view-level AppKit window
hacks).
- **#1 — Sidebar visuals.** Traffic lights inside the sidebar; a button-less screen adds a
  `ToolbarSpacer` (not a placeholder item → no empty glass bubble).
- **#2 — Navigation.** Per-section `NavigationStack`s in `Group { switch }.id(selection)` → push / pop
  / switch with 0 crashes.
- **#3 — Toolbar rendering.** Never `.buttonStyle` above the toolbar; the system draws the Liquid Glass
  capsule. Content buttons style themselves locally.
- **#4 — Sidebar sizing.** Authoritative fixed width (320, matching Messages), scrollable height. The
  constant always wins — persisted width is purged + overridden (the trap is closed; PROVEN).

### Modals — Rule #5 → [`MODALS.md`](MODALS.md)
- **The custom card overlay** (`.zashiSheet`'s macOS form — OUR SwiftUI, not a native sheet) is the
  primary component for **dynamic content** (swap quote, confirmations, dynamic forms).
- **Surface: Liquid Glass** (macOS 26 `glassEffect`), not solid. *(decided)*
- **Scope: global by default** — presented over the WHOLE window (backdrop dims the sidebar too), the
  app-modal feel. **Presentable from anywhere** via a single root-level presenter; customizable
  (size / shape / scope) only when a specific flow needs it. *(decided — implementation: hoist
  presentation to the `MacSplitView` root; see MODALS.md.)*
- **Native modals for their specific purposes** — `.alert` (errors / key decisions), file panel
  (export / save), confirmation dialog (≤3 actions), new window (independent flow), inspector (detail
  beside content). See the MODALS.md decision guide.

### Backgrounds — Rule #6
**The content (detail / right) view's background drives the WHOLE window — always.** Apply the
background on the content view; in a `NavigationSplitView` a `.background` on the detail content fills
behind the entire window (under the sidebar too). The **sidebar floats over it and must NEVER paint an
opaque background** that overrides the content color — it stays translucent material. One source of
truth: the content view. Single-view windows are the same — the content background covers the whole
window. Sandbox: Overview → "Rule #6" (`RootSplitView.contentBackground`).

### Buttons — Rule #7
**Every `ZashiButton` has a capped width — never fully horizontally stretched.** The cap is **360pt**
on macOS, done by the component when `infinityWidth: true` (the default: cap → background → expand &
center, `secant/Sources/UIComponents/Buttons/ZashiButton.swift:89`). A button is a capped, centered
pill — not edge-to-edge. Violations come from (a) call sites passing `infinityWidth: false`, or
(b) wrapping the button in an external `.frame(maxWidth: .infinity)`. Neither is allowed → audit + fix
the stragglers.

### Content width — Rule #8
**No content view is wider than 740pt.** Whether it's a single view over the whole window or the right
side of the split, cap the content at `maxWidth: 740` and center it. Beyond 740 the content centers
with padding while the **background (Rule #6) still full-bleeds the window**. The three sizing rules
compose: full-bleed window background (#6) → ≤740 centered content column (#8) → ≤360 capped buttons (#7).

### Scan view — Rule #9 (full-window single view; exception to #8)
The scan (QR) view is special in two ways:
1. **Exempt from the 740pt cap (#8) — full-bleed content.** Its purposeful semi-transparent gray-out
   overlay with the scan-rect "hole" (the camera viewfinder cutout), plus the library button and
   controls, is built to fill the ENTIRE window. Applying #8 shrinks the overlay and the cutout to
   740pt and breaks both the look and the camera framing.
2. **Must be a SINGLE-view window — sidebar HIDDEN, never overlaid.** Scan is never presented inside the
   split (where the sidebar would sit over it). Present it as a full-window takeover with the sidebar
   hidden — the same pattern as `MacSplitView`'s other full-window `store.path` flows (Keystone, wallet
   backup, server switch), NOT in the detail pane. The camera/overlay owns the whole window.

The one screen where full-width, single-view content is intentional.
(`secant/Sources/Features/Scan/ScanView.swift`, `secant/Sources/Features/CoordFlows/ScanCoordFlowView.swift`.)

### Flows promote split → full-window (lock) — Rule #10
**A sidebar section's `NavigationStack` flow must be able to PROMOTE from the split to a full-window
view mid-flow — hiding the sidebar to LOCK the user into the flow** so they can't switch sections and
cancel an in-progress async / irreversible operation. This is an architectural capability, not just
chrome — the code must support a split-view NavigationStack flow switching to full-window.
- **Why:** during a broadcast / await step the user must not be able to tap another section (e.g. Swap)
  in the sidebar and abandon the flow.
- **Example (Send):** tap Send → detail flips to SendView → fill form → ConfirmationView pushed → tap
  OK → the **sending / awaiting** screen locks full-window (sidebar hidden) until the async send
  resolves, then unlocks.
- **Proposed mechanism (validate in the sandbox first):** drive `NavigationSplitView(columnVisibility:)`
  — on "lock", set `.detailOnly` (sidebar hidden; the sidebar toggle is already removed per the chrome
  rules, so it stays hidden) and disable section switching; restore `.all` when the flow ends. The
  detail's existing `NavigationStack` simply fills the window — the flow is NOT re-hosted. (Alternative:
  push the locked screens onto `Root.path` as a top-level full-window takeover, like Rule #9.)
- **Complements** the SDK transaction guard (which serializes broadcasts): #10 is the UI side — keep
  the user *in* the flow while the guarded async op runs. **This is the "not simple" rule — it needs a
  design/prototype pass before applying.**

### Platform isolation — Rule #11 (governs ALL macOS work)
**macOS work must NOT disrupt iOS code or UI/UX — iOS Zodl stays exactly as-is.** Every macOS change is
either `#if os(macOS)`-guarded or provably iOS-neutral; a shared component adds macOS behavior behind a
platform branch and NEVER alters the iOS path. **Verify** by building an iOS target
(`secant-testnet` / `secant-mainnet`) after macOS changes — iOS must stay green and visually unchanged.
This is a HARD constraint: if a macOS fix can't be made without risking iOS, **stop and flag it rather
than guess.** (It's why, e.g., Rule #7's 360pt cap lives inside `ZashiButton`'s `#if os(macOS)` block,
not in shared layout, and #8's cap is the macOS-only `ScreenBackground.macContentMaxWidth`.)

### (more rules coming)
The design language is still being authored. Add each new rule as its own chapter here once it's been
proven in the sandbox and confirmed.

## Working rules (process — how we fix, not what we build)
**Fix flaws broadly + consolidate.** When a flaw is found (a pattern that breaks a rule), do NOT just
patch the one reported instance — **review the whole codebase and fix EVERY occurrence**, then
**consolidate the pattern into a shared component** so it can't recur. One flaw → one sweep → one shared
fix. Known flaws under this rule:
- **`.zImage(size:)` on a top-bar button breaks the system glass capsule** (Rule #3): it forces a
  size/padding the system can't shape into a circular capsule. Fix everywhere — on macOS render a plain
  SF symbol (no `.resizable()`, frame, color, or padding) and let the system size + capsule it. Audit
  every `zashiNavigationBarItems` / `.toolbar` button. (`.zImage` in regular CONTENT is fine.)
- **Duplicated or raw button widths** (Rule #7): never re-implement the 360pt cap (e.g. the scan Cancel
  button is a separate button that re-hardcodes it) or use a raw SwiftUI `Button` for a CTA (e.g. the
  agency-built Coinholder voting flow likely has pure `Button`s). Consolidate to `ZashiButton`, which
  owns the cap — one source of truth for button sizing.

## How a rule is made (the loop)
1. **Experiment** in the sandbox `~/Downloads/testApp` (one focused section per concern).
2. **Confirm** visually on macOS 26.
3. **Codify** here + the detailed chapter + project memory.
4. **Apply** to the wallet (the layout four → `MacSplitView.swift`; modals → next).

The layout four and the modal card are the worked examples of this loop.

## Reference
- Living sandbox: `~/Downloads/testApp` (`RootSplitView.swift` + `SectionViews.swift`).
- Wallet reference implementation: `secant/Sources/Features/Root/MacSplitView.swift`.
- Sheets today: `secant/Sources/UIComponents/Sheets/ZashiSheet.swift`, `ZashiSelectorSheet.swift`.
