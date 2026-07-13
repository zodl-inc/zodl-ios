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
over the sidebar).

### Rule #2a — the `.id` is NOT enough when a section has a PUSHED path (POST-MORTEM, PROVEN 2026-06-24)
The sandbox showed 0 crashes because it only ever switched sections **at root**. In the real wallet,
switching a section that has a **pushed** screen still crashes: open a transaction detail in Activity
(pushes onto its `NavigationStack`), then tap another section (e.g. Receive) →
`SwiftUI/NavigationColumnState.swift: Fatal error: AnyNavigationPath.Error.comparisonTypeMismatch`.
`.id(selection)` resets the detail **content** but NOT the column's **nav state**, which SwiftUI
reconciles across the switch — a pushed path of one section's type vs the incoming section's different
path type can't be compared. (Clearing the path in the **same** update does NOT help — the pushed path
is still live when SwiftUI reconciles.)

**THE FIX — a three-phase switch through a one-frame BLANK detail** (`MacSplitView.sectionSelection` +
`detailSection`):
1. Intercept the sidebar `List(selection:)` with a custom `Binding` (do NOT bind `selectedSection` directly).
2. On switch, THIS frame: send `Root.macResetSectionPaths` (clears EVERY section's `.path`), move the
   sidebar highlight (`selectedSection`), and **blank the detail** (`detailSection = nil`).
3. NEXT runloop: reveal the new section (`DispatchQueue.main.async { detailSection = newSection }`).
4. The detail renders via **`detailSection`** (not `selectedSection`); the `nil` branch is the blank.
5. The blank branch MUST carry **`.macSidebarToolbarSpacer()`** (Rule #1) — without toolbar content the
   traffic lights jump to the title bar for that frame and the whole window "pops".

The one-frame `nil` (a) breaks the reconcile (no path type present) and (b) HIDES the pop-to-root — the
user sees `B → blank → C`, never the popped root `A`.

**FUTURE-PROOFING — every new sidebar section / detail flow MUST:**
- add its `.path.removeAll()` to `Root.macResetSectionPaths`;
- be reached only through the `sectionSelection` binding (never set `selectedSection` directly elsewhere);
- render through `detailSection` in the detail `switch`;
- give a button-less root a `.macSidebarToolbarSpacer()`;
- use **`.zashiSectionRootBack`** (NOT `.zashiBack`) on a section ROOT screen — it's a no-op on macOS (a
  peer-root has nothing to go back to), so a new section can never reintroduce the macOS back-button bug.

NEVER switch sections in a single update while a pushed path is live — always go through blank-then-reveal.

## Rule #3 — toolbar rendering (let the system draw the capsule)
NEVER apply `.buttonStyle` to a toolbar item, and never let an App/Scene-level `.buttonStyle(.plain)`
CASCADE into the toolbar — it breaks the system Liquid Glass capsule (buttons render as malformed, tall,
zero-horizontal-padding pills). Never force the icon's SIZE either (`.zImage(size:)` / a `.frame`) — that
also breaks the capsule. Content buttons set their style **locally**; the toolbar is left to the system.

### Rule #3a — a toolbar ICON needs HORIZONTAL padding to be circular, not tall (PROVEN 2026-06-24)
macOS 26 sizes the glass capsule to the icon's WIDTH, so a lone SF symbol / asset is narrow → a TALL
pill. The back button (already circular) proved the cure: a sized icon + horizontal padding. So the
toolbar-icon recipe is: a plain `Button` in a toolbar item + a plain `Image(systemName:)` (or asset, NO
`.zImage(size:)`) + NO `.buttonStyle` + **`.zashiToolbarIconPadding()`** (the shared helper — horizontal
padding, ONE source of truth for the value, no-op on iOS). EVERY new toolbar action icon must use it.
The capsule shape comes from WIDTH, so swapping SF → branded Asset icons later keeps the helper unchanged.

## Rule #4 — sidebar sizing (fits any window, fixed width, the CONSTANT is authoritative)
- **Height:** the nav `List` must SCROLL when rows overflow — never `.scrollDisabled(true)` (it
  clips). The sidebar then fits ANY window height.
- **Width:** SwiftUI `.navigationSplitViewColumnWidth` only seeds the INITIAL width and leaves the
  divider draggable (even `min==max`). Pin it in AppKit: walk `superview` to the enclosing
  `NSSplitView` → walk the responder chain to its `NSSplitViewController` → `splitViewItems.first`
  (the sidebar) → set `minimumThickness == maximumThickness == <width>` (Zodl Mac:
  `Design.Mac.sidebarWidth`, proportional to the window), `canCollapse = false`.
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
