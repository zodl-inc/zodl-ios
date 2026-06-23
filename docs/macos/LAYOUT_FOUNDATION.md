# macOS Layout Foundation — the 4 rules (LAW)

These four rules govern **all** macOS layout / chrome / navigation work for Zodl Mac. They were
derived empirically in the throwaway sandbox `~/Downloads/testApp` (each rule proven by a section
A–J / X–Y) and validated visually on macOS 26. **Do not deviate without re-validating in the sandbox.**

**Container: native `NavigationSplitView`. NEVER a manual HStack. NEVER view-level AppKit window
hacks.** (`window.toolbar = NSToolbar()` CRASHES — `NSRangeException` in SwiftUI's
`updateToolbarIfNeeded`; `titlebarAppearsTransparent`/`toolbarStyle` set in a `viewDidMoveToWindow`
configurator get OVERRIDDEN — SwiftUI's `WindowGroup`/`NavigationSplitView` owns the window chrome.)
Let the native split own the chrome.

## Rule #1 — sidebar visuals (traffic lights INSIDE the sidebar)
The traffic-light window buttons sit inside the full-height sidebar (the Mail/Xcode look) **only when
the current screen contributes toolbar content.** A screen with no toolbar → plain title bar → lights
float OUTSIDE the sidebar.
- A screen with **real toolbar buttons**: fine.
- A screen with **NO buttons**: add a **`ToolbarSpacer`** — NOT a placeholder `ToolbarItem`. macOS 26
  Liquid Glass draws a glass capsule around any *item* (even `Color.clear`) → an empty bubble; a
  spacer is *space*, not an item → no bubble. `.opacity(0)` / `.hidden()` do NOT remove the capsule.
- Pattern: a `.macSidebarToolbarSpacer()` helper that adds `ToolbarSpacer(.fixed, placement: .primaryAction)` (macOS 26+).

## Rule #2 — navigation (0 crashes, reset-on-switch)
Sidebar options are **peer roots**; each is its own `NavigationStack`. The detail is
`Group { switch selection { … } }.id(selection)`. The `.id(selection)` forces a full teardown of the
previous section's stack on switch (resetting it to root) instead of the shared detail column
reconciling mismatched path types. Push / pop / pop-to-root / switch between independent options run
with **0 crashes**, and the native back button renders correctly at the detail's leading edge (not
over the sidebar). NOTE: 0 crashes contradicts the earlier assumption that "mismatched path types"
alone caused the wallet's `comparisonTypeMismatch` — the `.id` teardown sidesteps it. (Worth a
post-mortem on the original crash.)

## Rule #3 — toolbar rendering (let the system draw the capsule)
NEVER apply `.buttonStyle` / custom padding / sizes ABOVE the toolbar, and never on a toolbar item.
An App/Scene-level `.buttonStyle(.plain)` CASCADES into the toolbar and breaks the system Liquid
Glass capsule (buttons render as malformed, tall, zero-horizontal-padding pills). Content buttons set
their style **locally**; the toolbar is left entirely to the system → correct capsules, no sizes from
us.

## Rule #4 — sidebar sizing (fits any window, fixed width, the CONSTANT is authoritative)
- **Height:** the nav `List` must SCROLL when rows overflow — never `.scrollDisabled(true)` (it
  clips). The sidebar then fits ANY window height.
- **Width:** SwiftUI `.navigationSplitViewColumnWidth` only seeds the INITIAL width and leaves the
  divider draggable (even `min==max`). Pin it in AppKit: walk `superview` to the enclosing
  `NSSplitView` → walk the responder chain to its `NSSplitViewController` → `splitViewItems.first`
  (the sidebar) → set `minimumThickness == maximumThickness == <width>` (Zodl Mac: **232**, proportional to the
  900×720 Beta window), `canCollapse = false`.
  **CRUCIAL: SwiftUI re-asserts a resizable width on EVERY `body` re-run (e.g. a section switch),
  undoing the pin → RE-PIN every time** — pass `selection` as a trigger to the `NSViewRepresentable`
  so `updateNSView` re-applies it. The walk is timing-flaky (the `NSSplitViewController` may not be
  in the responder chain yet), so RETRY across a few runloop turns (deferred via
  `DispatchQueue.main.async`) until it succeeds.
- **The persisted-width TRAP (the constant must win).** SwiftUI's `NavigationSplitView` AUTOSAVES the
  sidebar width to `UserDefaults` under a key like `"NSSplitView Subview Frames …SidebarNavigationSplitView"`
  and RESTORES it on launch — *before* the pin runs. `splitView.autosaveName = ""` runs too late and
  does NOT delete what's already stored, so the remembered width wins. **Consequence: the hard-coded
  width stops being authoritative — ship 320, later change to 300, and every user who already launched
  stays pinned to 320.** Unacceptable for a foundation constant. The fix makes the constant the single
  source of truth on every launch: (1) `splitView.autosaveName = ""` (stop new saves); (2) a ONE-TIME
  purge of every `"NSSplitView Subview Frames"` key from `UserDefaults` (kill stale remembered widths);
  (3) `splitView.setPosition(<width>, ofDividerAt: 0)` to slam the divider to the constant, overriding
  any width SwiftUI restored this launch. See `FixedSidebarWidth` (its `pinSidebar()` + `purgeRememberedWidthsOnce()`).
- **Regression check (PROVEN 2026-06-23).** The constant is now authoritative — validated by changing
  `sidebarWidth` 320 → 150 → 320, where every rebuild + relaunch took the new width immediately and the
  previously-shown/persisted width never won. **To re-verify after ANY change to `FixedSidebarWidth`:**
  bump the constant, rebuild, relaunch — the new width MUST appear. If it sticks at the old value, the
  purge / `setPosition` path has regressed and the persisted-width trap is back.

## Consequence
All four rules require `NavigationSplitView`. `MacSplitView` was a manual HStack (to dodge the crash) —
that's what "destroyed the glass." The foundation's first action is **migrating `MacSplitView` from
the HStack back to `NavigationSplitView`** with these four rules. **Reference implementation:** the
sandbox `~/Downloads/testApp` (`RootSplitView.swift` + `SectionViews.swift`).
