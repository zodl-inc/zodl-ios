# macOS Modals — what to use for what (Zodl Mac)

Companion to `LAYOUT_FOUNDATION.md`. The native modal/overlay menu, a decision guide, **what Zodl
Mac actually uses today (verified in code)**, the macOS gotchas that shaped those choices, and a
use-case table to extend as flows land. Proven hands-on in the sandbox `~/Downloads/testApp` →
**Modals** section (one live button per option).

## Rule #5 — the custom card is the dynamic-content workhorse (DECIDED)
The macOS design language's modal rule (see `DESIGN_LANGUAGE.md`):
- **The custom card overlay** (`.zashiSheet`'s macOS form — OUR SwiftUI, not a native `.sheet`) is the
  primary component for dynamic content: swap quotes, confirmations, dynamic forms. Because it's ours,
  every visual is a knob (size, shape, surface, animation, position).
- **Surface: Liquid Glass** (macOS 26 `glassEffect`), not solid. *(decided — proven + loved in the
  sandbox.)*
- **Scope: GLOBAL by default** — presented over the WHOLE window (the backdrop dims the sidebar too),
  the proper app-modal feel. **It must be presentable from anywhere.** Customizable (size / shape /
  scope) only when a specific flow genuinely needs it.
- **Native modals stay for their specific purposes** — alert, file panel, confirmation dialog, new
  window, inspector (see the decision guide + use-case table below).

**Implementation path — BUILT (`MacCard.swift`).** Done. `.zashiSheet` / `.zashiSelectorSheet` on macOS no
longer overlay locally (that local backdrop was clamped to the content cap (`Design.Mac.viewCapWidth`) — the "dimmed capped"
bug). They write their content to a `MacCardCoordinator` injected via the **environment** by
`.macCardHost()` at the **RootView root** — above the cap, above both MacSplitView and the single-window
screens. The host renders ONE centered, dimmed card over the whole window, in two sizing modes
(content-hug for `.zashiSheet`; fixed 460×[320–600] for the selector). **All ~40 sites adopted it with zero
call-site changes** — the reroute lives in the two modifiers' macOS impl. iOS keeps native `.sheet` /
`.popover`.

**Key learning:** a `PreferenceKey` (up-propagation) is swallowed by `NavigationStack` /
`NavigationSplitView` and never reaches the root — the card simply never appeared. The **environment**
(down-propagation) crosses navigation reliably, so an injected coordinator is the right channel. Content is
built in the child's body (store + colorScheme correct); because it renders DETACHED at the root host, the
plumbing wraps it in `WithPerceptionTracking` so it stays reactive to store changes (Rule #5b).

**Still open (minor):** the appear/dismiss animation (currently instant). Sizing, surface, scope and
dismissal are settled.

## Rule #5a — native `.sheet` / `.popover` / `presentationDetents` are BANNED for app content (audit the whole app, don't patch one)
A native `.sheet` or `.popover` does **not** become a MacCard on macOS — it renders as a raw macOS
sheet/popover, and any `.presentationDetents([...])` collapse it to **0 height** (gotcha #1). So every
app-content modal MUST use `.zashiSheet` (dynamic content) or `.zashiSelectorSheet` (searchable list) —
never the native modifiers directly. On iOS those reroute to a native `.sheet`/`.popover`, so nothing is lost.

**Discipline (learned from slippage, which shipped as a native `.sheet`):** one native modal is almost never
alone. When you find one, sweep the ENTIRE app and fix the *class*, not the instance:

```
grep -rn '\.sheet(\|\.popover(\|\.fullScreenCover(\|presentationDetents' --include='*.swift' secant/Sources | grep -v /Tests/
```

Classify each hit: **app content** → `.zashiSheet` / `.zashiSelectorSheet` (bug on macOS); **`ZashiSheet.swift`
/ `ZashiSelectorSheet.swift`** → the iOS implementations, correct; **`InAppBrowserView` / web** → a separate
macOS concern (window / system browser, not a card); **QR scan / file panel** → its own native treatment.
Current audit + the still-to-convert sites: `KNOWN_ISSUES.md` entry 5. (This is the modal instance of the
process rule "discover a flaw → sweep the whole tree → fix every instance.")

## Rule #5b — DETACHED card content must be `WithPerceptionTracking`-wrapped (the chips-don't-toggle bug)
The card renders the dialog's content at the **root host** (`MacCardOverlay`), captured into the coordinator
entry — i.e. OUTSIDE the presenting view's TCA observation scope. A TCA view only re-renders on store changes
when the store access happens inside a `WithPerceptionTracking`. So a dialog whose body reads store state
directly (e.g. `FiltersSheet`: each chip's `active: store.isSentFilterActive`) updates the *state* on tap but
the card keeps drawing the **stale snapshot** — chips never toggle from unselected→selected, Reset doesn't
clear them. iOS is immune: the native `.sheet` re-renders in-hierarchy whenever the parent re-renders.

**Fix — central, not per-dialog.** `.zashiSheet` / `.zashiSelectorSheet` wrap the content in
`WithPerceptionTracking { content() }` inside the two modifiers (`ZashiSheet.swift` / `ZashiSelectorSheet.swift`,
the *only* two `macCardPublish` callers). One wrap each makes **all ~40 dialogs** self-reactive; it is
behaviour-neutral on iOS (the native sheet already propagated). A new dialog therefore needs NO per-view
`WithPerceptionTracking` for the card to track it (adding one anyway is harmless — nesting is fine).

**Symptom to recognise:** "the data flow is correct but the UI doesn't refresh" on a macOS card → it's this.

## Decision guide — what an iOS sheet *becomes* on Mac
iOS reaches for one bottom sheet for almost everything. On Mac that splits by the task's relationship
to the window:
| The task is… | Use | Native API |
|---|---|---|
| Tied to THIS window, finish-before-continuing | **Sheet** (or a custom card overlay — see below) | `.sheet` + `.presentationSizing(.fitted)` |
| A decision with no real content (error, confirm, destructive) | **Alert** | `.alert` |
| Pick one of ≤3 actions | **Confirmation dialog** | `.confirmationDialog` |
| A small anchored quick pick | **Popover** (careful with lists — see gotchas) | `.popover` |
| Independent, may sit side-by-side | **New window** | `openWindow` + `Window` |
| Contextual detail *beside* content (not a task) | **Inspector** | `.inspector` |
| Save / open a file (export logs, PCZT, backups) | **File panel** | `.fileExporter` / `.fileImporter` |
| App settings | **Settings window** | `Settings` scene (⌘,) |

## What Zodl Mac uses TODAY (verified)
**Key finding: Zodl Mac does NOT use the native `.sheet` for its sheets — both are hand-rolled overlay
cards.** The native sheet was deliberately avoided (see gotchas).

- **`.zashiSheet`** — the dynamic-content sheet (swap quote, confirmations, dynamic cards). On macOS it
  is a **custom centered overlay card**: a dimmed `Rectangle` backdrop (click-outside dismiss), a
  content-hugging card (`maxWidth: 480`, height follows content), an explicit close ✕, and
  `.keyboardShortcut(.cancelAction)` (ESC). NOT a native `.sheet`.
  File: `secant/Sources/UIComponents/Sheets/ZashiSheet.swift`.
- **`.zashiSelectorSheet`** — the searchable selector (swap token, address-book chain). On macOS it is a
  **custom definite-size overlay card** (`460 × [320…600]`) so the inner `List` can fill + scroll; on
  iOS it's a `.popover`. File: `secant/Sources/UIComponents/Sheets/ZashiSelectorSheet.swift`.
- **Alerts** (errors, key decisions) — native `.alert`, same as iOS.

So `.zashiSheet` *is* the key dynamic-content component — but its macOS realization is an **overlay**,
not `.sheet`. That's a deliberate, correct choice given the gotchas below; the native `.sheet` is the
*alternative*, viable for single (non-stacked) standalone content now that `.presentationSizing` exists.

## The macOS gotchas (why native isn't always the answer)
1. **iOS `presentationDetents` collapse a macOS sheet to 0 height.** Never use detents on macOS; size a
   native sheet with `.presentationSizing(.fitted)` (macOS 15+) — this is the macOS-correct content-hug
   and is what makes a native `.sheet` usable here at all.
2. **Only ONE native `.sheet` per view; they don't stack.** Flows that stack sheets can't all be native
   → the overlay card (which stacks freely) is why `ZashiSheet` exists.
3. **A `.popover` collapses a `List`/`ScrollView`** (no intrinsic height) to an unusable bubble → give a
   popover a definite size, or use a card. This is why `ZashiSelectorSheet` is a card on macOS.
4. **`.confirmationDialog` shows at most 3 actions on macOS** (incl. cancel); extras are silently
   dropped. For more choices use a sheet or a menu.

## Use-case mapping (EXTEND this as Zodl Mac flows are decided)
| Flow | iOS | Zodl Mac today | Recommended macOS |
|---|---|---|---|
| Dynamic content (swap quote, confirmations) | `.zashiSheet` | custom overlay card | keep overlay (stacks; full chrome) — or native `.sheet` + `.presentationSizing(.fitted)` if single/non-stacked |
| Searchable selector (token, chain) | `.popover` | custom definite-size overlay card | keep overlay (popover collapses lists) |
| Error / key decision | `.alert` | native `.alert` | native `.alert` ✓ |
| Export logs / files | native share sheet | _(TBD)_ | **file panel** `.fileExporter` / NSSavePanel — save anywhere, share later (more Mac than an in-app share) |
| Big standalone flow | full screen | _(n/a)_ | **new window** `openWindow` (modeless, side-by-side) |
| Detail beside content (tx metadata) | — | — | **inspector** `.inspector` |

## Reference
Live trial of every option: sandbox `~/Downloads/testApp` → **Modals** section (`SectionViews.swift`
`ModalsView`). Layout rules: `LAYOUT_FOUNDATION.md`.
